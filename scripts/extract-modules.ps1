<#
.SYNOPSIS
    从 duanju/guoapp 系 APK 中提取内嵌的站源模块（JS runtime 模块）。

.DESCRIPTION
    上游把站源实现为可热插拔的 JS 模块，通过 Go 的 //go:embed all:bundled
    编译进 libduanju_core.so。模块以「明文 JSON 清单 + 明文 JS 源码」的形式
    存在于 so 的 .rodata 里，彼此之间用 0x00 分隔。

    本脚本不反汇编、不脱壳，只做三件事：
      1. 解出 APK 里所有 ABI 的 libduanju_core.so
      2. 扫描连续非零字节块，按内容特征区分「模块清单 JSON」与「模块 JS 源码」
      3. 按 manifest 的 id 归位，写出 <OutDir>/<id>/{manifest.json,main.js}

    so 里同时散落着 Go 的字符串表/类型表，因此不能只按大小筛选，
    必须靠内容特征（JSON 可配平解析 + 含 "runtime"；JS 含 module.exports）。

.PARAMETER Apk
    上游 APK 路径。

.PARAMETER OutDir
    输出目录，默认 upstream_modules。

.PARAMETER SoPath
    跳过 APK 解包，直接分析某个已解出的 .so（用于排查/复现）。

.EXAMPLE
    .\scripts\extract-modules.ps1 -Apk .\source\guoapp-2.0.0+112-arm64-v8a.apk

.EXAMPLE
    .\scripts\extract-modules.ps1 -SoPath D:\tmp\libduanju_core.so -OutDir .\upstream_modules
#>
[CmdletBinding(DefaultParameterSetName = 'Apk')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Apk', Position = 0)]
    [string]$Apk,

    [Parameter(Mandatory = $true, ParameterSetName = 'So')]
    [string]$SoPath,

    [string]$OutDir = 'upstream_modules',

    # 只报告不写文件
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$utf8 = New-Object System.Text.UTF8Encoding($false)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

# ---------- 1. 取出 .so ----------

function Get-CoreLibraries {
    param([string]$ApkPath)

    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ApkPath))
    try {
        $entries = $zip.Entries | Where-Object { $_.FullName -match '^lib/[^/]+/libduanju_core\.so$' }
        if (-not $entries) {
            # 兜底：名字变了也要能找到承载 Go 核心的那个 so
            $entries = $zip.Entries | Where-Object { $_.FullName -match '^lib/[^/]+/.*core.*\.so$' }
        }
        if (-not $entries) { throw "APK 里没找到 libduanju_core.so（上游可能改了原生库名）" }

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("extract-modules-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $result = @()
        foreach ($entry in $entries) {
            $abi = ($entry.FullName -split '/')[1]
            $dest = Join-Path $tmp ($abi + '-libduanju_core.so')
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            $result += [pscustomobject]@{ Abi = $abi; Path = $dest }
        }
        return $result
    }
    finally { $zip.Dispose() }
}

# ---------- 2. 扫描连续非零块 ----------

function Get-RawBlocks {
    param([byte[]]$Bytes, [int]$MinLength = 1024)

    $blocks = New-Object System.Collections.ArrayList
    $n = $Bytes.Length
    $i = 0
    while ($i -lt $n) {
        if ($Bytes[$i] -ne 0) {
            $start = $i
            while ($i -lt $n -and $Bytes[$i] -ne 0) { $i++ }
            $len = $i - $start
            if ($len -ge $MinLength) {
                [void]$blocks.Add([pscustomobject]@{ Start = $start; Length = $len })
            }
        }
        else { $i++ }
    }
    return $blocks
}

# ---------- 3. 识别清单 JSON ----------

# 从 $Start 处 '{' 开始按大括号配平（感知字符串与转义）截取 JSON
function Get-BalancedJson {
    param([string]$Text, [int]$Start)

    if ($Text[$Start] -ne '{') { return $null }
    $depth = 0; $j = $Start; $inStr = $false; $esc = $false
    while ($j -lt $Text.Length) {
        $c = $Text[$j]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq [char]'\') { $esc = $true }
            elseif ($c -eq [char]'"') { $inStr = $false }
        }
        else {
            if ($c -eq [char]'"') { $inStr = $true }
            elseif ($c -eq [char]'{') { $depth++ }
            elseif ($c -eq [char]'}') {
                $depth--
                if ($depth -eq 0) { return $Text.Substring($Start, $j - $Start + 1) }
            }
        }
        $j++
    }
    return $null
}

# ---------- 主流程 ----------

$sources = @()
if ($PSCmdlet.ParameterSetName -eq 'So') {
    $sources = @([pscustomobject]@{ Abi = 'direct'; Path = (Resolve-Path $SoPath).Path })
}
else {
    Write-Step "解包 $Apk"
    $sources = Get-CoreLibraries -ApkPath $Apk
}
Write-Ok ("找到 " + $sources.Count + " 个核心库: " + (($sources | ForEach-Object { $_.Abi }) -join ', '))

foreach ($lib in $sources) {
    Write-Step ("分析 " + $lib.Abi + " (" + [math]::Round((Get-Item $lib.Path).Length / 1MB, 1) + " MB)")

    $bytes = [System.IO.File]::ReadAllBytes($lib.Path)
    $text = $latin1.GetString($bytes)

    # 3.1 先看 so 里声称嵌入了哪些模块（bundled/<id>/...）
    $declared = [regex]::Matches($text, 'bundled/([A-Za-z0-9._\-]+)/(?:manifest\.json|main\.js|entry\.js|index\.js)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if ($declared) { Write-Ok ("嵌入声明: " + ($declared -join ', ')) }
    else { Write-Warn2 '未在 so 里找到 bundled/<id>/ 路径字符串' }

    # 3.2 扫块并按内容分类
    $blocks = Get-RawBlocks -Bytes $bytes -MinLength 1024
    Write-Ok "候选块: $($blocks.Count)（>=1KB）"

    $manifests = @{}
    $codes = @{}

    foreach ($block in $blocks) {
        $blockText = $latin1.GetString($bytes, $block.Start, $block.Length)

        # --- 清单 JSON：以 { 开头、含 "runtime"、能配平解析 ---
        if ($blockText.TrimStart().StartsWith('{') -and $blockText.Contains('"runtime"')) {
            $offset = $blockText.IndexOf('{')
            $json = Get-BalancedJson -Text $blockText -Start $offset
            if ($json) {
                try {
                    $obj = $json | ConvertFrom-Json
                    if ($obj.id -and $obj.runtime) {
                        $id = [string]$obj.id
                        # so 里的中文是 UTF-8，但我们按 Latin1 读进来了；还原成真正 UTF-8
                        $fixed = $utf8.GetString($latin1.GetBytes($json))
                        if (-not $manifests.ContainsKey($id)) {
                            $manifests[$id] = $fixed
                        }
                    }
                }
                catch { }
            }
        }

        # --- 模块 JS：含 module.exports，且看起来是源码而不是字符串表碎片 ---
        if ($blockText.Contains('module.exports') -and $block.Length -ge 2048) {
            $head = $blockText.Substring(0, [Math]::Min(200, $blockText.Length))
            $looksLikeCode = $head -match '^\s*(//|/\*|const |let |var |function |\(function|import )'
            $codeLike = ([regex]::Matches($blockText, '\b(function|const|return|if|throw)\b')).Count
            if ($looksLikeCode -and $codeLike -ge 20) {
                $decoded = $utf8.GetString($bytes, $block.Start, $block.Length)
                # 归属：优先用块内出现的 bundled/<id>/ 提示，其次按 baseUrl 无法判定时先存待定
                $owner = $null
                $hint = [regex]::Match($blockText, 'bundled/([A-Za-z0-9._\-]+)/')
                if ($hint.Success) { $owner = $hint.Groups[1].Value }
                if (-not $owner) { $owner = "block@$($block.Start)" }
                if (-not $codes.ContainsKey($owner)) { $codes[$owner] = $decoded }
            }
        }
    }

    Write-Ok ("识别到清单 $($manifests.Count) 个, JS 源码块 $($codes.Count) 个")

    # 3.3 落盘
    $ids = @($manifests.Keys) + @($codes.Keys) | Sort-Object -Unique
    foreach ($id in $ids) {
        if ($manifests.ContainsKey($id) -and $codes.ContainsKey($id)) {
        }
        elseif ($manifests.ContainsKey($id)) {
            # 只有清单没有 JS：JS 可能在未识别出的块里，或该模块不含代码
            $candidate = $codes.Keys | Where-Object { $_ -like 'block@*' } | Select-Object -First 1
            if ($candidate) { $codes[$id] = $codes[$candidate]; $codes.Remove($candidate) }
        }

        $dir = Join-Path $OutDir $id
        if ($DryRun) {
            Write-Host ("      [dry] {0}  manifest={1} js={2}" -f $id,
                $manifests.ContainsKey($id), $codes.ContainsKey($id))
            continue
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($manifests.ContainsKey($id)) {
            [System.IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), $manifests[$id], $utf8)
        }
        if ($codes.ContainsKey($id)) {
            [System.IO.File]::WriteAllText((Join-Path $dir 'main.js'), $codes[$id], $utf8)
        }
        $sizeJs = if ($codes.ContainsKey($id)) { $codes[$id].Length } else { 0 }
        $sizeMf = if ($manifests.ContainsKey($id)) { $manifests[$id].Length } else { 0 }
        Write-Ok ("导出 {0,-16} manifest.json={1,6}B  main.js={2,8}B" -f $id, $sizeMf, $sizeJs)
    }

    if ($declared) {
        $missing = $declared | Where-Object { -not $manifests.ContainsKey($_) }
        if ($missing) { Write-Warn2 ("so 声明但未提取到: " + ($missing -join ', ')) }
    }
}

Write-Host ''
Write-Ok '完成。'
Write-Host @'

说明：
  - 只有「上游真正编进 APK」的模块才能这样提取。上游设计上只内置少数模块
    （当前版本仅 hongguo）作为离线兜底，其余站源走私有索引仓库在线安装，
    APK 里不存在，无法提取。
  - 若新版本 APK 的 so 里出现更多 bundled/<id>/，本脚本会自动一并导出。
  - 索引仓库地址见上游 native/core/module_index.go 的 moduleIndexAddresses。
'@ -ForegroundColor DarkGray
