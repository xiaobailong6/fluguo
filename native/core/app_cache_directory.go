package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const nativeDeviceStateFile = "hongguo-devices.json"
const nativeCacheMigrationFile = "native-cache-layout.json"

type nativeDeviceDisk struct {
	Version int                  `json:"version"`
	Hongguo *hongguoCatalogState `json:"hongguo,omitempty"`
}

type nativeCacheLayout struct {
	Version int    `json:"version"`
	Cache   string `json:"cache"`
}

func (engine *nativeEngine) cacheRoot() string {
	return firstNonEmpty(engine.cacheDirectory, engine.directory)
}

func (engine *nativeEngine) separateCache() bool {
	return filepath.Clean(engine.cacheRoot()) != filepath.Clean(engine.directory)
}

func (engine *nativeEngine) catalogCachePath() string {
	return filepath.Join(engine.cacheRoot(), "catalogs.json")
}

// 迁移失败必须保留原件；不跟随文件链接，也不读取无界的损坏文件。
func readNativeMigrationFile(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("迁移文件不是普通文件或超过大小限制")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err == nil && int64(len(body)) > limit {
		err = errors.New("迁移文件超过大小限制")
	}
	return body, err
}

func (engine *nativeEngine) readPersistentDevices() (*hongguoCatalogState, bool, error) {
	body, err := readNativeMigrationFile(filepath.Join(engine.directory, nativeDeviceStateFile), 64<<10)
	if os.IsNotExist(err) {
		return nil, false, nil
	}
	if err != nil {
		return nil, true, err
	}
	var disk nativeDeviceDisk
	if json.Unmarshal(body, &disk) != nil || disk.Version != 1 {
		return nil, true, errors.New("设备状态文件损坏，原文件已保留")
	}
	return disk.Hongguo, true, nil
}

func nativeDeviceIdentity(state *hongguoCatalogState) string {
	if state == nil {
		return ""
	}
	devices := cloneHongguoCatalogState(state)
	devices.Feeds = nil
	data, _ := json.Marshal(devices)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func (engine *nativeEngine) discardHongguoCache() {
	belongs := func(key string) bool {
		return key == sourceHongguo || strings.HasPrefix(key, sourceHongguo+"|")
	}
	for key := range engine.catalogs {
		if belongs(key) {
			delete(engine.catalogs, key)
		}
	}
	for key := range engine.catalogStates {
		if belongs(key) {
			delete(engine.catalogStates, key)
		}
	}
	delete(engine.categoryOptions, sourceHongguo)
	engine.recommendations = make(map[string]nativeRecommendationState)
	engine.hongguoCatalog = nil
}

func (engine *nativeEngine) savePersistentDevices(state *hongguoCatalogState) error {
	devices := cloneHongguoCatalogState(state)
	if devices != nil {
		// 分页游标必须与目录内容一起提交，不能从独立状态恢复未保存的页。
		devices.Feeds = nil
	}
	body, err := json.Marshal(nativeDeviceDisk{Version: 1, Hongguo: devices})
	if err != nil {
		return err
	}
	path := filepath.Join(engine.directory, nativeDeviceStateFile)
	if previous, readErr := readNativeMigrationFile(path, 64<<10); readErr == nil {
		if devices == nil || string(previous) == string(body) {
			return nil
		}
		var disk nativeDeviceDisk
		if json.Unmarshal(previous, &disk) != nil || disk.Version != 1 {
			return errors.New("设备状态文件损坏，未覆盖原文件")
		}
	} else if !os.IsNotExist(readErr) {
		return readErr
	}
	return writeNativeCacheFile(path, body)
}

func (engine *nativeEngine) restorePersistentDevices() error {
	if !engine.separateCache() {
		return nil
	}
	devices, found, err := engine.readPersistentDevices()
	if err != nil {
		return fmt.Errorf("无法恢复站源设备状态，原数据已保留：%w", err)
	}
	if !found {
		return errors.New("站源设备状态文件缺失，已停止启动以保留原数据")
	}
	// 换号后写剧库失败或使用了另一实例缓存时，旧游标不能拼给新身份。
	if engine.catalogDeviceIdentity != nativeDeviceIdentity(devices) {
		engine.discardHongguoCache()
	}
	if devices == nil {
		return nil
	}
	devices = cloneHongguoCatalogState(devices)
	if engine.hongguoCatalog != nil {
		devices.Feeds = cloneHongguoCatalogState(engine.hongguoCatalog).Feeds
	}
	engine.downloader.restoreHongguoCatalog(devices)
	engine.hongguoCatalog = engine.downloader.hongguoCatalogSnapshot()
	return nil
}

func (engine *nativeEngine) cacheMigrationWarning(err error) {
	engine.downloader.recordDiagnostic(diagnosticEvent{Event: "storage.cache_migration", Level: "warning", Message: publicError(err).Error()})
}

func (engine *nativeEngine) selectCacheDirectory(caches []string) error {
	cache := ""
	if len(caches) > 0 {
		cache = caches[0]
	}
	if cache == "" {
		body, err := readNativeMigrationFile(filepath.Join(engine.directory, nativeCacheMigrationFile), 16<<10)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		var layout nativeCacheLayout
		if json.Unmarshal(body, &layout) != nil || layout.Version != 1 || !filepath.IsAbs(layout.Cache) {
			return errors.New("缓存迁移记录损坏，原数据已保留")
		}
		cache = layout.Cache
	}
	return engine.prepareCacheDirectory(cache)
}

func (engine *nativeEngine) prepareCacheDirectory(cache string) error {
	if !filepath.IsAbs(cache) {
		return errors.New("应用缓存目录无效")
	}
	markerPath := filepath.Join(engine.directory, nativeCacheMigrationFile)
	if err := os.MkdirAll(cache, 0700); err != nil {
		if _, markerErr := os.Lstat(markerPath); !os.IsNotExist(markerErr) {
			return fmt.Errorf("已迁移的缓存目录不可用，未改动原数据：%w", err)
		}
		engine.cacheMigrationWarning(fmt.Errorf("缓存目录不可用，继续使用原目录：%w", err))
		return nil
	}
	resolved, err := filepath.EvalSymlinks(cache)
	if err != nil {
		return err
	}
	data, err := filepath.EvalSymlinks(engine.directory)
	if err != nil {
		return err
	}
	dataInfo, err := os.Stat(data)
	if err != nil {
		return err
	}
	cacheInfo, err := os.Stat(resolved)
	if err != nil {
		return err
	}
	if os.SameFile(dataInfo, cacheInfo) {
		return nil
	}
	// 便携版仅允许 data/cache；不能将用户配置或下载目录当作缓存。
	if nativePathsOverlap(data, resolved) && filepath.Clean(resolved) != filepath.Join(data, "cache") {
		return errors.New("缓存目录不能包含应用数据或占用用户数据子目录")
	}
	for _, download := range []string{engine.defaultDownloads, nativeDownloadLocation(engine.directory, engine.defaultDownloads)} {
		if path, resolveErr := filepath.EvalSymlinks(download); resolveErr == nil {
			download = path
		}
		if nativePathsOverlap(download, resolved) {
			return errors.New("缓存目录不能与下载目录互相包含")
		}
	}
	marker, markerErr := readNativeMigrationFile(markerPath, 16<<10)
	if markerErr == nil {
		var layout nativeCacheLayout
		if json.Unmarshal(marker, &layout) != nil || layout.Version != 1 {
			return errors.New("缓存迁移记录损坏，原数据已保留")
		}
		// 应用移动或平台改变路径时只更新定位，不再导入旧目录的分页。
		if layout.Cache != resolved {
			body, _ := json.Marshal(nativeCacheLayout{Version: 1, Cache: resolved})
			if err := writeNativeCacheFile(markerPath, body); err != nil {
				return err
			}
		}
		engine.cacheDirectory = resolved
		return nil
	}
	if !os.IsNotExist(markerErr) {
		return markerErr
	}
	if err := engine.migrateCacheFiles(resolved, markerPath); err != nil {
		engine.cacheMigrationWarning(fmt.Errorf("缓存迁移未完成，原目录已保留：%w", err))
		return nil
	}
	engine.cacheDirectory = resolved
	return nil
}

func (engine *nativeEngine) migrateCacheFiles(cache, marker string) error {
	legacy := filepath.Join(engine.directory, "catalogs.json")
	raw, err := readNativeMigrationFile(legacy, nativeCatalogMaxBytes)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var catalog nativeCatalogDisk
	var devices *hongguoCatalogState
	if err == nil {
		if json.Unmarshal(raw, &catalog) == nil && (catalog.Version == 2 || catalog.Version == 3) {
			devices = catalog.HongguoApp
			catalog.DeviceIdentity = nativeDeviceIdentity(devices)
			if devices != nil {
				catalog.HongguoApp = &hongguoCatalogState{Version: devices.Version, Feeds: devices.Feeds}
			}
			raw, err = json.Marshal(catalog)
			if err != nil {
				return err
			}
		} else {
			var old map[string][]nativeDrama
			if json.Unmarshal(raw, &old) != nil || old == nil {
				return errors.New("旧剧库格式无效，未迁移或删除")
			}
		}
	}
	_, found, err := engine.readPersistentDevices()
	if err != nil {
		return err
	}
	if !found || devices != nil {
		if err := engine.savePersistentDevices(devices); err != nil {
			return err
		}
	}
	target := filepath.Join(cache, "catalogs.json")
	if len(raw) > 0 {
		if _, err := os.Lstat(target); err != nil && !os.IsNotExist(err) {
			return err
		} else if err == nil {
			if _, err := readNativeMigrationFile(target, nativeCatalogMaxBytes); err != nil {
				return err
			}
		}
		// 完成标记之前，旧目录一直是权威来源；重试要更新旧的中间缓存。
		if err := writeNativeCacheFile(target, raw); err != nil {
			return err
		}
	}
	layout, _ := json.Marshal(nativeCacheLayout{Version: 1, Cache: cache})
	if err := writeNativeCacheFile(marker, layout); err != nil {
		return err
	}
	// 保留一份旧剧库恢复材料；清缓存后不从此备份自动恢复过期分页。
	backup := filepath.Join(engine.directory, "catalogs.pre-cache-v1.json")
	if _, err := os.Lstat(backup); os.IsNotExist(err) {
		if err := os.Rename(legacy, backup); err != nil && !os.IsNotExist(err) {
			engine.cacheMigrationWarning(err)
		}
	}
	for _, name := range []string{"rankings.json", "covers-v1"} {
		source, target := filepath.Join(engine.directory, name), filepath.Join(cache, name)
		info, err := os.Lstat(source)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			engine.cacheMigrationWarning(err)
			continue
		}
		if info.Mode()&os.ModeSymlink != 0 {
			engine.cacheMigrationWarning(fmt.Errorf("缓存 %s 是符号链接，已保留原件", name))
			continue
		}
		if _, err := os.Lstat(target); os.IsNotExist(err) {
			if err := os.Rename(source, target); err != nil {
				// 跨盘、占用、权限失败只留下旧缓存，不删除或覆盖现有目标。
				engine.cacheMigrationWarning(fmt.Errorf("缓存 %s 留在原目录：%w", name, err))
			}
		}
	}
	return nil
}
