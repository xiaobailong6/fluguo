#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

APPS = {
    # Keep legacy directory names and CLI choices; also guard renamed executables.
    "zhen": ("真果鉴", ("FlGuo.exe", "FlGuo-all-sources.exe", "zhenguojian.exe", "hongguojian.exe")),
    "hong": ("红果鉴", ("FlGuo.exe", "FlGuo-all-sources.exe", "zhenguojian.exe", "hongguojian.exe")),
}


def running(executable: str) -> bool:
    output = subprocess.run(
        ["tasklist", "/FI", f"IMAGENAME eq {executable}", "/NH"],
        capture_output=True,
        text=True,
    ).stdout
    return executable.lower() in output.lower()


def remove(path: Path) -> None:
    if path.is_symlink():
        path.unlink()
    elif not path.exists():
        return
    elif path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()
    print(f"已删除 {path}")


def cache_directory(directory: Path) -> Path:
    marker = directory / "native-cache-layout.json"
    if not marker.exists():
        if (directory / "catalogs.json").exists():
            raise ValueError("旧剧库尚未完成设备身份拆分，请先启动新版完成迁移；未删除任何数据")
        return directory
    if marker.is_symlink() or marker.stat().st_size > 16 * 1024:
        raise ValueError("缓存定位文件无效，未删除任何数据")
    layout = json.loads(marker.read_text(encoding="utf-8"))
    if not isinstance(layout, dict):
        raise ValueError("缓存定位文件无效，未删除任何数据")
    cache = Path(layout.get("cache", ""))
    if layout.get("version") != 1 or not cache.is_absolute():
        raise ValueError("缓存定位文件无效，未删除任何数据")
    devices = directory / "hongguo-devices.json"
    if devices.is_symlink() or not devices.is_file() or devices.stat().st_size > 64 * 1024:
        raise ValueError("设备状态未安全保存，未删除任何数据")
    state = json.loads(devices.read_text(encoding="utf-8"))
    if not isinstance(state, dict) or state.get("version") != 1:
        raise ValueError("设备状态文件无效，未删除任何数据")
    data, cache = directory.resolve(), cache.resolve()
    if (cache == data or cache in data.parents or
            (data in cache.parents and cache != data / "cache")):
        raise ValueError("缓存目录与用户数据重叠，未删除任何数据")
    location = directory / "download-location.json"
    downloads = data / "downloads"
    if location.exists():
        downloads = Path(json.loads(location.read_text(encoding="utf-8"))["directory"]).resolve()
    if cache == downloads or cache in downloads.parents or downloads in cache.parents:
        raise ValueError("缓存目录与下载目录重叠，未删除任何数据")
    return cache


def main() -> int:
    parser = argparse.ArgumentParser(description="清空 Windows 版剧库缓存，模拟首次加载")
    parser.add_argument("--app", choices=APPS, default="zhen")
    parser.add_argument("--covers", action="store_true", help="同时清空海报缓存")
    args = parser.parse_args()

    name, executables = APPS[args.app]
    if any(running(executable) for executable in executables):
        print("FlGuo 或旧版应用正在运行，请先退出应用")
        return 1
    directory = Path(os.environ["APPDATA"]) / name / name
    if not directory.is_dir():
        print(f"找不到数据目录 {directory}")
        return 1

    try:
        cache = cache_directory(directory)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(error)
        return 1
    remove(cache / "catalogs.json")
    remove(cache / "rankings.json")
    remove(cache / "sources.json")
    for temporary in cache.glob(".cache-write-*"):
        remove(temporary)
    if args.covers:
        remove(cache / "covers-v1")
    print("完成，追剧、收藏、设置和下载未改动")
    return 0


if __name__ == "__main__":
    sys.exit(main())
