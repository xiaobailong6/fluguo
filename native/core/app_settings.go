package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type nativeResourceSettings struct {
	ProxyMode           string                       `json:"proxyMode"`
	ProxyURL            string                       `json:"proxyUrl"`
	CatalogConcurrency  int                          `json:"catalogConcurrency"`
	CatalogIntervalMS   int                          `json:"catalogIntervalMs"`
	DownloadConcurrency int                          `json:"downloadConcurrency"`
	DownloadBySource    bool                         `json:"downloadBySource"`
	TraceEnabled        bool                         `json:"traceEnabled"`
	Warning             string                       `json:"warning,omitempty"`
	SystemProxyStatus   string                       `json:"systemProxyStatus,omitempty"`
	SourceProxies       map[string]nativeSourceProxy `json:"sourceProxies,omitempty"`
}

const maxResourceSettingsBytes = 1 << 20

type nativeSourceProxy struct {
	Mode string `json:"mode"`
	URL  string `json:"url,omitempty"`
}

func defaultResourceSettings() nativeResourceSettings {
	return nativeResourceSettings{ProxyMode: "auto", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2}
}

func (settings nativeResourceSettings) validate() error {
	if settings.CatalogConcurrency < 1 || settings.CatalogConcurrency > 6 ||
		settings.CatalogIntervalMS < 0 || settings.CatalogIntervalMS > 5000 ||
		settings.DownloadConcurrency < 1 || settings.DownloadConcurrency > 6 {
		return errors.New("并发应为 1 至 6，请求间隔应为 0 至 5000 毫秒")
	}
	if err := validateProxy(settings.ProxyMode, settings.ProxyURL); err != nil {
		return err
	}
	if len(settings.SourceProxies) > 200 {
		return errors.New("站源代理设置过多")
	}
	for group, proxy := range settings.SourceProxies {
		if !validProxyGroup(group) {
			return errors.New("站源代理设置无效")
		}
		if err := validateProxy(proxy.Mode, proxy.URL); err != nil {
			return err
		}
	}
	if data, err := json.Marshal(settings); err != nil || len(data) > maxResourceSettingsBytes {
		return errors.New("网络与下载设置过大")
	}
	return nil
}

func validateProxy(mode, address string) error {
	if mode != "auto" && mode != "direct" && mode != "manual" {
		return errors.New("代理模式无效")
	}
	if mode == "manual" || address != "" {
		if len(address) > 2048 {
			return errors.New("代理地址过长")
		}
		parsed, err := url.Parse(address)
		if err != nil || parsed.Hostname() == "" || parsed.Fragment != "" || parsed.RawQuery != "" || parsed.ForceQuery || strings.HasSuffix(parsed.Host, ":") ||
			(parsed.Path != "" && parsed.Path != "/") ||
			(parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "socks5" && parsed.Scheme != "socks5h") {
			return errors.New("请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址")
		}
		if port := parsed.Port(); port != "" {
			number, err := strconv.Atoi(port)
			if err != nil || number < 1 || number > 65535 {
				return errors.New("代理端口无效")
			}
		}
	}
	return nil
}

type proxySourceKey struct{}

// 来源由调用方业务身份传递，不能按共享 CDN 或重定向域名猜测。
func withProxySource(ctx context.Context, source string) context.Context {
	return context.WithValue(ctx, proxySourceKey{}, canonicalProviderSource(source))
}

// 与 Dart SourceSite.groupId 一致：黄果三个原生 provider 共用一组设置。
func proxyGroup(source string) string {
	switch source = canonicalProviderSource(source); source {
	case sourceHuangguoAI, sourceHuangguoVideo, sourceCloudFront:
		return "huangguo"
	default:
		return source
	}
}

func validProxyGroup(group string) bool {
	if group == "" || len(group) > 64 || group != proxyGroup(group) {
		return false
	}
	if group == "huangguo" {
		return true
	}
	_, ok := nativeSourceDescriptorFor(group)
	return ok
}

// 旧配置没有 map 时继承全局；历史 provider/域名键迁移到组键，冲突拒绝而非随机覆盖。
func normalizeSourceProxies(settings *nativeResourceSettings) error {
	if len(settings.SourceProxies) > 200 {
		return errors.New("站源代理设置过多")
	}
	proxies := make(map[string]nativeSourceProxy, len(settings.SourceProxies))
	for source, proxy := range settings.SourceProxies {
		group := proxyGroup(source)
		if len(source) > 64 || strings.ContainsAny(source, "\x00\r\n\t/\\") || !validProxyGroup(group) {
			return errors.New("站源代理设置无效")
		}
		proxy.URL = strings.TrimSpace(proxy.URL)
		if previous, exists := proxies[group]; exists && previous != proxy {
			return errors.New("同一站源组的代理设置冲突")
		}
		proxies[group] = proxy
	}
	settings.SourceProxies = proxies
	return nil
}

type proxyRoute struct {
	mode   string
	manual *url.URL
}

type proxyRouter struct {
	mu             sync.RWMutex
	mode           string
	manual         *url.URL
	sources        map[string]proxyRoute
	system         nativeSystemProxy
	systemRead     time.Time
	systemOverride bool
	record         func(diagnosticEvent)
	pacFailures    map[[32]byte]time.Time
	// 可选依赖仅作用于当前路由器，避免离线测试替换全局函数。
	pacResolver func(string, *url.URL) (*url.URL, error)
	pacNow      func() time.Time
}

func (router *proxyRouter) proxy(request *http.Request) (*url.URL, error) {
	host := strings.TrimSuffix(strings.ToLower(request.URL.Hostname()), ".")
	if host == "localhost" || net.ParseIP(host).IsLoopback() {
		return nil, nil
	}
	source, _ := request.Context().Value(proxySourceKey{}).(string)
	router.mu.RLock()
	mode, manual := router.mode, router.manual
	if route, exists := router.sources[proxyGroup(source)]; exists {
		mode, manual = route.mode, route.manual
	}
	router.mu.RUnlock()
	switch mode {
	case "direct":
		return nil, nil
	case "manual":
		return manual, nil
	}
	return router.resolveSystem(request)
}

// 显式站源覆盖不能被注册的历史直连兜底绕过（包括 auto 的系统/PAC 决策）。
func (d *Downloader) sourceProxyExplicit(ctx context.Context) bool {
	if d.proxyRouter == nil {
		return false
	}
	source, _ := ctx.Value(proxySourceKey{}).(string)
	d.proxyRouter.mu.RLock()
	_, exists := d.proxyRouter.sources[proxyGroup(source)]
	d.proxyRouter.mu.RUnlock()
	return exists
}

func (engine *nativeEngine) loadResourceSettings() {
	settings := defaultResourceSettings()
	file := filepath.Join(engine.directory, "resource-settings.json")
	info, err := os.Stat(file)
	if err == nil {
		stored := defaultResourceSettings()
		if info.Mode().IsRegular() && info.Size() <= maxResourceSettingsBytes {
			if data, readErr := readResourceSettings(file); readErr == nil && json.Unmarshal(data, &stored) == nil && normalizeSourceProxies(&stored) == nil && stored.validate() == nil {
				settings = stored
			} else {
				settings.Warning = "网络与下载设置无法读取，已使用默认值，请重新保存设置"
			}
		} else {
			settings.Warning = "网络与下载设置无效，已使用默认值，请重新保存设置"
		}
	} else if !os.IsNotExist(err) {
		settings.Warning = "网络与下载设置无法读取，已使用默认值，请重新保存设置"
	}
	engine.settings = settings
	engine.applyResourceSettings(settings)
}

// 再次限制读取字节，避免 Stat 后文件增长绕过配置大小上限。
func readResourceSettings(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxResourceSettingsBytes+1))
	if len(data) > maxResourceSettingsBytes {
		return nil, errors.New("网络与下载设置过大")
	}
	return data, err
}

func (engine *nativeEngine) resourceSettings() nativeResourceSettings {
	engine.settingsMu.Lock()
	defer engine.settingsMu.Unlock()
	if engine.settings.ProxyMode == "" {
		return defaultResourceSettings()
	}
	settings := engine.settings
	settings.SourceProxies = maps.Clone(settings.SourceProxies)
	system := engine.downloader.proxyRouter.systemSettings()
	settings.SystemProxyStatus = "自动读取系统静态代理及环境变量"
	if system.PACURL != "" {
		settings.SystemProxyStatus = "已读取系统自动代理脚本"
	} else if system.PAC && system.HTTP == "" && system.HTTPS == "" {
		settings.SystemProxyStatus = "检测到系统自动代理脚本；请配置手动代理或选择直连"
	} else if system.HTTP != "" || system.HTTPS != "" {
		settings.SystemProxyStatus = "已读取系统静态代理"
	}
	return settings
}

func (engine *nativeEngine) applyResourceSettings(settings nativeResourceSettings) {
	router := engine.downloader.proxyRouter
	manual, _ := url.Parse(settings.ProxyURL)
	sources := make(map[string]proxyRoute, len(settings.SourceProxies))
	for group, proxy := range settings.SourceProxies {
		address, _ := url.Parse(proxy.URL)
		sources[group] = proxyRoute{mode: proxy.Mode, manual: address}
	}
	router.mu.Lock()
	router.mode, router.manual, router.sources = settings.ProxyMode, manual, sources
	router.mu.Unlock()
	limiter := engine.downloader.limiter
	limiter.mu.Lock()
	limiter.concurrency = settings.CatalogConcurrency
	limiter.interval = time.Duration(settings.CatalogIntervalMS) * time.Millisecond
	limiter.notifyLocked()
	limiter.mu.Unlock()
	engine.downloader.trace.Store(settings.TraceEnabled)
	if engine.downloads != nil {
		engine.downloads.mu.Lock()
		engine.downloads.concurrency = settings.DownloadConcurrency
		engine.downloads.bySource = settings.DownloadBySource
		engine.downloads.scheduleLocked()
		engine.downloads.mu.Unlock()
	}
}

func (engine *nativeEngine) saveResourceSettings(settings nativeResourceSettings) (nativeResourceSettings, error) {
	settings.ProxyURL = strings.TrimSpace(settings.ProxyURL)
	if err := normalizeSourceProxies(&settings); err != nil {
		return nativeResourceSettings{}, err
	}
	settings.Warning = ""
	settings.SystemProxyStatus = ""
	if err := settings.validate(); err != nil {
		return nativeResourceSettings{}, err
	}
	engine.settingsMu.Lock()
	defer engine.settingsMu.Unlock()
	data, err := json.Marshal(settings)
	if err == nil {
		err = nativeDownloadWrite(filepath.Join(engine.directory, "resource-settings.json"), data)
	}
	if err != nil {
		return nativeResourceSettings{}, errors.New("未能保存网络与下载设置，原设置保持不变")
	}
	engine.settings = settings
	engine.applyResourceSettings(settings)
	engine.downloader.client.CloseIdleConnections()
	settings.SourceProxies = maps.Clone(settings.SourceProxies)
	return settings, nil
}
