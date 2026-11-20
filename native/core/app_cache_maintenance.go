package core

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type nativeCacheReadKey struct{}

// 仅目录类操作进入维护锁；嵌套调用沿用同一个租约，不递归获取 RWMutex。
func (engine *nativeEngine) beginCacheRead(ctx context.Context) (context.Context, func(), error) {
	if owner, _ := ctx.Value(nativeCacheReadKey{}).(*nativeEngine); owner == engine {
		return ctx, func() {}, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return ctx, nil, err
	}
	if engine.cacheClearPending.Load() != 0 || !engine.cacheMaintenance.TryRLock() {
		return ctx, nil, errors.New("缓存正在清理，请稍后重试")
	}
	if engine.cacheClearPending.Load() != 0 {
		engine.cacheMaintenance.RUnlock()
		return ctx, nil, errors.New("缓存正在清理，请稍后重试")
	}
	return context.WithValue(ctx, nativeCacheReadKey{}, engine), engine.cacheMaintenance.RUnlock, nil
}

// 每一层都使用 Lstat；Windows 额外检查所有 reparse point（包括 junction）。
func nativeCacheSafePath(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("缓存相关路径必须是绝对路径")
	}
	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || nativeCacheReparsePoint(current) {
			return errors.New("缓存相关路径包含链接或重解析点，已停止操作")
		}
		if parent := filepath.Dir(current); parent == current {
			break
		}
	}
	return nil
}

func (engine *nativeEngine) safeCacheRoot() (string, error) {
	root := filepath.Clean(engine.cacheRoot())
	if !engine.separateCache() {
		return "", errors.New("缓存尚未完成独立迁移，不能安全清理")
	}
	if info, err := os.Lstat(root); err != nil || !info.IsDir() {
		return "", errors.New("缓存根目录不可用")
	}
	for _, path := range []string{root, engine.directory, filepath.Join(engine.directory, nativeCacheMigrationFile), filepath.Join(engine.directory, nativeDeviceStateFile)} {
		if err := nativeCacheSafePath(path); err != nil {
			return "", err
		}
	}
	// 只保留既有迁移协议定义的 data/cache 便携布局例外。
	if nativePathsOverlap(root, engine.directory) && root != filepath.Join(filepath.Clean(engine.directory), "cache") {
		return "", errors.New("缓存目录与用户数据重叠")
	}
	engine.downloads.mu.Lock()
	download, moving := engine.downloads.root, engine.downloads.moving
	engine.downloads.mu.Unlock()
	if moving {
		return "", errors.New("下载目录正在迁移，不能清理缓存")
	}
	for _, path := range []string{download, engine.defaultDownloads} {
		if resolved, err := filepath.EvalSymlinks(path); err == nil {
			path = resolved
		} else if !os.IsNotExist(err) {
			return "", err
		}
		if nativePathsOverlap(root, path) {
			return "", errors.New("缓存目录与下载目录重叠")
		}
	}
	body, err := readNativeMigrationFile(filepath.Join(engine.directory, nativeCacheMigrationFile), 16<<10)
	if err != nil {
		return "", err
	}
	var layout nativeCacheLayout
	if json.Unmarshal(body, &layout) != nil || layout.Version != 1 || filepath.Clean(layout.Cache) != root {
		return "", errors.New("缓存迁移记录无效或与当前目录不一致")
	}
	devices, found, err := engine.readPersistentDevices()
	if err != nil || !found {
		return "", errors.New("设备状态不可用，已保留缓存和用户数据")
	}
	validDeviceID := func(id string) bool { return hongguoNumericID.MatchString(id) && strings.Trim(id, "0") != "" }
	if devices != nil && (devices.Version != 1 || !validDeviceID(devices.DeviceID) || !validDeviceID(devices.InstallID) ||
		(devices.HelperDeviceID != "" || devices.HelperInstallID != "") && (!validDeviceID(devices.HelperDeviceID) || !validDeviceID(devices.HelperInstallID))) {
		return "", errors.New("设备状态无效，已保留缓存和用户数据")
	}
	return root, nil
}

type nativeCacheFile struct {
	path string
	info os.FileInfo
}

// 与 CoverDecoder 的 <哈希>-<修改时间微秒>-<原文件字节数>.jpg 保持一致。
var nativeCompatibleCoverName = regexp.MustCompile(`^[a-f0-9]{64}-[0-9]{1,20}-[1-9][0-9]{0,19}\.jpg$`)

// 白名单仅包含剧库、榜单、原始封面及转换后的正式 JPEG 缓存。
// 不删除目录，也不删除解码中的临时文件或未知文件。
func nativeCacheFiles(root string) ([]nativeCacheFile, error) {
	files := []nativeCacheFile{}
	add := func(path string) error {
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := nativeCacheSafePath(path); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("缓存文件类型异常，已停止操作")
		}
		files = append(files, nativeCacheFile{path: path, info: info})
		return nil
	}
	for _, name := range []string{"catalogs.json", "rankings.json"} {
		if err := add(filepath.Join(root, name)); err != nil {
			return nil, err
		}
	}
	covers := filepath.Join(root, "covers-v1")
	if _, err := os.Lstat(covers); os.IsNotExist(err) {
		return files, nil
	} else if err != nil {
		return nil, err
	}
	if err := nativeCacheSafePath(covers); err != nil {
		return nil, err
	}
	dir, err := os.Open(covers)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	entries, err := dir.ReadDir(10001)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(entries) > 10000 {
		return nil, errors.New("封面目录文件数量异常，已停止操作")
	}
	for _, entry := range entries {
		path := filepath.Join(covers, entry.Name())
		if err := nativeCacheSafePath(path); err != nil {
			return nil, err
		}
		key, ok := strings.CutSuffix(entry.Name(), ".img")
		if !ok || len(key) != 64 {
			continue
		}
		if _, err := hex.DecodeString(key); err != nil {
			continue
		}
		if err := add(path); err != nil {
			return nil, err
		}
	}
	compatible := filepath.Join(covers, "compatible-v1")
	if info, err := os.Lstat(compatible); os.IsNotExist(err) {
		return files, nil
	} else if err != nil {
		return nil, err
	} else if !info.IsDir() {
		return nil, errors.New("兼容封面目录类型异常，已停止操作")
	}
	if err := nativeCacheSafePath(compatible); err != nil {
		return nil, err
	}
	converted, err := os.Open(compatible)
	if err != nil {
		return nil, err
	}
	defer converted.Close()
	entries, err = converted.ReadDir(10001)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(entries) > 10000 {
		return nil, errors.New("兼容封面文件数量异常，已停止操作")
	}
	for _, entry := range entries {
		path := filepath.Join(compatible, entry.Name())
		if err := nativeCacheSafePath(path); err != nil {
			return nil, err
		}
		if nativeCompatibleCoverName.MatchString(entry.Name()) {
			if err := add(path); err != nil {
				return nil, err
			}
		}
	}
	return files, nil
}

func (engine *nativeEngine) cacheStorage(info *nativeStorageInfo) {
	engine.cacheMaintenance.RLock()
	defer engine.cacheMaintenance.RUnlock()
	info.CacheDirectory = engine.cacheRoot()
	root, err := engine.safeCacheRoot()
	if err != nil {
		info.CacheWarning = err.Error()
		return
	}
	files, err := nativeCacheFiles(root)
	if err != nil {
		info.CacheWarning = err.Error()
		return
	}
	for _, file := range files {
		info.CacheBytes += file.info.Size()
		info.CacheFiles++
	}
	info.CacheFree = nativeFreeSpace(root)
}

func (engine *nativeEngine) clearCache(ctx context.Context) (map[string]int64, error) {
	return engine.clearCacheFiles(ctx, nil)
}

func (engine *nativeEngine) clearCacheFiles(ctx context.Context, remove func(string) error) (map[string]int64, error) {
	engine.cacheClearPending.Add(1)
	defer engine.cacheClearPending.Add(-1)
	// 等待已有缓存读取完成；有界轮询支持取消，不取消任何播放/下载任务。
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for !engine.cacheMaintenance.TryLock() {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
	defer engine.cacheMaintenance.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	root, err := engine.safeCacheRoot()
	if err != nil {
		return nil, err
	}
	// Go 1.24 的目录句柄限制真实删除范围，路径竞态不能跳到根目录之外。
	if remove == nil {
		info, err := os.Lstat(root)
		if err != nil {
			return nil, err
		}
		anchored, err := os.OpenRoot(root)
		if err != nil {
			return nil, err
		}
		defer anchored.Close()
		opened, err := anchored.Stat(".")
		if err != nil || !os.SameFile(info, opened) {
			return nil, errors.New("缓存根目录已变化，未删除任何文件")
		}
		var coversRoot *os.Root
		coversPath := filepath.Join(root, "covers-v1")
		if coversInfo, statErr := os.Lstat(coversPath); statErr == nil {
			if !coversInfo.IsDir() || nativeCacheSafePath(coversPath) != nil {
				return nil, errors.New("封面缓存目录不安全，未删除任何文件")
			}
			coversRoot, err = anchored.OpenRoot("covers-v1")
			if err != nil {
				return nil, err
			}
			defer coversRoot.Close()
			opened, err := coversRoot.Stat(".")
			if err != nil || !os.SameFile(coversInfo, opened) {
				return nil, errors.New("封面缓存目录已变化，未删除任何文件")
			}
		} else if !os.IsNotExist(statErr) {
			return nil, statErr
		}
		var compatibleRoot *os.Root
		compatiblePath := filepath.Join(coversPath, "compatible-v1")
		if compatibleInfo, statErr := os.Lstat(compatiblePath); statErr == nil {
			if coversRoot == nil || !compatibleInfo.IsDir() || nativeCacheSafePath(compatiblePath) != nil {
				return nil, errors.New("兼容封面目录不安全，未删除任何文件")
			}
			compatibleRoot, err = coversRoot.OpenRoot("compatible-v1")
			if err != nil {
				return nil, err
			}
			defer compatibleRoot.Close()
			opened, err := compatibleRoot.Stat(".")
			if err != nil || !os.SameFile(compatibleInfo, opened) {
				return nil, errors.New("兼容封面目录已变化，未删除任何文件")
			}
		} else if !os.IsNotExist(statErr) {
			return nil, statErr
		}
		remove = func(path string) error {
			if filepath.Dir(path) == root {
				return anchored.Remove(filepath.Base(path))
			}
			if coversRoot != nil && filepath.Dir(path) == coversPath {
				return coversRoot.Remove(filepath.Base(path))
			}
			if compatibleRoot != nil && filepath.Dir(path) == compatiblePath {
				return compatibleRoot.Remove(filepath.Base(path))
			}
			return errors.New("拒绝删除非白名单目录的文件")
		}
	}
	// 锁顺序：维护 -> engine -> cover -> ranking -> hongguo catalog -> hongguo。
	engine.mu.Lock()
	defer engine.mu.Unlock()
	engine.covers.mu.Lock()
	defer engine.covers.mu.Unlock()
	files, err := nativeCacheFiles(root)
	if err != nil {
		return nil, err
	}
	engine.downloader.rankings.mu.Lock()
	defer engine.downloader.rankings.mu.Unlock()
	client := engine.downloader.hongguoClient()
	client.catalogMu.Lock()
	client.mu.Lock()
	// 设备锁只覆盖状态重置，磁盘删除期间播放取流可继续使用原身份。
	// 即使磁盘部分失败，也不能让内存或已取消的封面任务复活旧目录。
	engine.catalogs = map[string][]nativeDrama{}
	engine.catalogStates = map[string]nativeCatalogState{}
	engine.categoryOptions = map[string][]nativeCategory{}
	engine.categoryRevisions = map[string]string{}
	engine.catalogDurableRevisions = map[string]string{}
	engine.catalogWriteDone = nil
	engine.recommendations = map[string]nativeRecommendationState{}
	engine.seasons = map[string]nativeSeasonCacheEntry{}
	engine.catalogSaveError = nil
	client.state.Feeds = map[string]hongguoCatalogCursor{}
	client.tagCursors = map[string]hongguoTagCursor{}
	engine.hongguoCatalog = cloneHongguoCatalogState(&client.state)
	engine.catalogDeviceIdentity = nativeDeviceIdentity(engine.hongguoCatalog)
	engine.downloader.rankings.pages = map[string]rankingPage{}
	client.mu.Unlock()
	client.catalogMu.Unlock()
	engine.covers.generation++
	engine.covers.entries = map[string]nativeCoverEntry{}
	engine.covers.pending = map[string]*nativeCoverCall{}
	engine.covers.repairs = map[string]*nativeCoverRepair{}
	engine.covers.size = 0
	var cleared int64
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("缓存清理未完成（已清理 %d 字节）：%w", cleared, err)
		}
		if err := nativeCacheSafePath(file.path); err != nil {
			return nil, fmt.Errorf("缓存清理未完成（已清理 %d 字节）：%w", cleared, err)
		}
		current, err := os.Lstat(file.path)
		if err != nil || !current.Mode().IsRegular() || !os.SameFile(file.info, current) {
			return nil, fmt.Errorf("缓存清理未完成（已清理 %d 字节）：文件已变化，未继续删除", cleared)
		}
		if err := remove(file.path); err != nil {
			return nil, fmt.Errorf("缓存清理未完成（已清理 %d 字节），其余文件已保留：%w", cleared, err)
		}
		cleared += current.Size()
	}
	remaining, err := nativeCacheFiles(root)
	if err != nil {
		return nil, fmt.Errorf("缓存清理后无法确认剩余大小：%w", err)
	}
	var bytes int64
	for _, file := range remaining {
		bytes += file.info.Size()
	}
	if len(remaining) != 0 {
		return nil, errors.New("缓存清理未完成，仍有缓存文件，请重试")
	}
	return map[string]int64{"clearedBytes": cleared, "remainingBytes": bytes}, nil
}
