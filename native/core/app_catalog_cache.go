package core

import (
	"encoding/json"
	"io"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"time"
)

const nativeCatalogTTL = 15 * time.Minute

type nativeCatalogState struct {
	UpdatedAt time.Time `json:"updatedAt"`
	Page      int       `json:"page"`
	HasMore   bool      `json:"hasMore"`
	Warning   string    `json:"warning,omitempty"`
}

type nativeCatalogDisk struct {
	Version           int                                  `json:"version"`
	Catalogs          map[string][]nativeDrama             `json:"catalogs"`
	States            map[string]nativeCatalogState        `json:"states"`
	Categories        map[string][]nativeCategory          `json:"categories,omitempty"`
	CategoryRevisions map[string]string                    `json:"categoryRevisions,omitempty"`
	HongguoApp        *hongguoCatalogState                 `json:"hongguoApp,omitempty"`
	DeviceIdentity    string                               `json:"deviceIdentity,omitempty"`
	Recommendations   map[string]nativeRecommendationState `json:"recommendations,omitempty"`
}

func (engine *nativeEngine) loadCatalogCache() {
	file, err := os.Open(engine.catalogCachePath())
	if err != nil {
		return
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, nativeCatalogMaxBytes+1))
	if err != nil || len(body) > nativeCatalogMaxBytes {
		return
	}
	var disk nativeCatalogDisk
	if json.Unmarshal(body, &disk) == nil && (disk.Version == 2 || disk.Version == 3) {
		if disk.Catalogs != nil {
			engine.catalogs = disk.Catalogs
			trimNativeCatalogs(engine.catalogs)
			for _, items := range engine.catalogs {
				for index := range items {
					items[index] = migrateNativeDrama(items[index])
				}
			}
		}
		if disk.States != nil {
			engine.catalogStates = disk.States
		}
		engine.categoryOptions = disk.Categories
		engine.categoryRevisions = disk.CategoryRevisions
		engine.catalogDurableRevisions = maps.Clone(disk.CategoryRevisions)
		engine.recommendations = make(map[string]nativeRecommendationState)
		for genre, state := range disk.Recommendations {
			if genre == state.Query.Genre && state.Query.validate() == nil && state.Page > 0 {
				engine.recommendations[genre] = state
			}
		}
		engine.hongguoCatalog = cloneHongguoCatalogState(disk.HongguoApp)
		engine.catalogDeviceIdentity = disk.DeviceIdentity
		if engine.downloader != nil && !engine.separateCache() {
			engine.downloader.restoreHongguoCatalog(disk.HongguoApp)
			if disk.HongguoApp != nil {
				engine.hongguoCatalog = engine.downloader.hongguoCatalogSnapshot()
			}
		}
		return
	}
	var legacy map[string][]nativeDrama
	if json.Unmarshal(body, &legacy) == nil && legacy != nil {
		engine.catalogs = legacy
		trimNativeCatalogs(engine.catalogs)
		for _, items := range engine.catalogs {
			for index := range items {
				items[index] = migrateNativeDrama(items[index])
			}
		}
	}
}

func trimNativeCatalogs(catalogs map[string][]nativeDrama) {
	for key, items := range catalogs {
		if len(items) > nativeCatalogMaxItems {
			catalogs[key] = append([]nativeDrama(nil), items[:nativeCatalogMaxItems]...)
		}
	}
}

func migrateNativeDrama(drama nativeDrama) nativeDrama {
	if drama.MetadataSchema == 0 && drama.Source == sourceHuangdou && drama.VIP != nil && !*drama.VIP {
		drama.VIP = nil
	}
	drama.MetadataSchema = 1
	return drama
}

func (engine *nativeEngine) nativeCached(source string) nativeCatalogResult {
	return engine.nativeCachedQuery(source, "")
}

// 查询在核心内筛选，仅复制匹配项；深拷贝保证回包编码不再引用可变缓存。
func (engine *nativeEngine) nativeCachedQuery(source, query string) nativeCatalogResult {
	source = canonicalProviderSource(source)
	words := strings.Fields(strings.ToLower(query))
	base, _, _ := strings.Cut(source, "|")
	engine.mu.Lock()
	defer engine.mu.Unlock()
	items := make([]nativeDrama, 0)
	seen := make(map[string]bool)
	for _, item := range engine.catalogs[source] {
		if query != "" {
			if item.Source != base || seen[item.ID] {
				continue
			}
			seen[item.ID] = true
			text := strings.ToLower(item.Title + " " + item.Description + " " + strings.Join(item.Tags, " "))
			if !slices.ContainsFunc(words, func(word string) bool { return !strings.Contains(text, word) }) {
				items = append(items, cloneNativeCatalogDrama(item))
			}
		} else {
			items = append(items, cloneNativeCatalogDrama(item))
		}
	}
	for index := range items {
		items[index].Cover = repairLegacyCoverURL(items[index])
	}
	state, found := engine.catalogStates[source]
	age := time.Since(state.UpdatedAt)
	result := nativeCatalogResult{
		Items: items, Page: max(1, state.Page), HasMore: !found || state.HasMore,
		Fresh:   len(items) > 0 && state.Warning == "" && !state.UpdatedAt.IsZero() && age >= 0 && age < nativeCatalogTTL,
		Warning: state.Warning,
	}
	if engine.catalogSaveError != nil {
		result.Warning = joinNativeWarnings(result.Warning, engine.catalogSaveError.Error())
		result.saveError = engine.catalogSaveError
		result.Fresh, result.HasMore = false, true
	}
	return result
}

func mergeNativeCatalog(first, second []nativeDrama) []nativeDrama {
	items := append([]nativeDrama{}, first...)
	indices := make(map[string]int, len(items))
	for index, item := range items {
		indices[item.ID] = index
	}
	for _, item := range second {
		if index, found := indices[item.ID]; found {
			items[index] = mergeNativeDrama(items[index], item)
		} else {
			indices[item.ID] = len(items)
			items = append(items, item)
		}
	}
	return items
}

func mergeNativeDrama(previous, fresh nativeDrama) nativeDrama {
	previous, fresh = migrateNativeDrama(previous), migrateNativeDrama(fresh)
	if previous.ID != "" && fresh.ID != previous.ID {
		return fresh
	}
	if fresh.Source == "" {
		fresh.Source = previous.Source
	}
	if fresh.SourceID == "" {
		fresh.SourceID = previous.SourceID
	}
	if fresh.Title == "" || fresh.Title == "短剧" {
		fresh.Title = previous.Title
	}
	if fresh.Description == "" {
		fresh.Description = previous.Description
	}
	if fresh.Cover == "" {
		fresh.Cover = previous.Cover
	}
	if fresh.Category == "" || nativeGenericCategory(fresh.Category) && previous.Category != "" && !nativeGenericCategory(previous.Category) {
		fresh.Category = previous.Category
	}
	if fresh.Episodes == 0 {
		fresh.Episodes = previous.Episodes
	}
	if fresh.VIP == nil {
		fresh.VIP = previous.VIP
	}
	if fresh.Heat == "" {
		fresh.Heat = previous.Heat
	}
	if fresh.Views == "" {
		fresh.Views = previous.Views
	}
	if fresh.OnlineDate == "" {
		fresh.OnlineDate = previous.OnlineDate
	}
	if fresh.Score == "" {
		fresh.Score = previous.Score
	}
	if len(fresh.Tags) == 0 {
		fresh.Tags = previous.Tags
	}
	if fresh.ReleaseStatus == "" || fresh.ReleaseStatus == "unknown" {
		fresh.ReleaseStatus = previous.ReleaseStatus
	}
	if fresh.Badge == "" {
		fresh.Badge = previous.Badge
	}
	return fresh
}

func nativeGenericCategory(category string) bool {
	switch category {
	case "短剧", "真人剧", "漫剧", "AI剧", "AI 剧", "AI短剧", "AI 短剧", "AI漫剧", "AI 漫剧":
		return true
	}
	return false
}

func (engine *nativeEngine) saveCatalogCache(source string, result *nativeCatalogResult) error {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	previous := engine.catalogs[source]
	state := engine.catalogStates[source]
	var items []nativeDrama
	if result.Page == 1 {
		items = result.Items
		if len(previous) > 0 {
			old := make(map[string]nativeDrama, len(previous))
			for _, item := range previous {
				old[item.ID] = item
			}
			for index, item := range items {
				items[index] = mergeNativeDrama(old[item.ID], item)
			}
			fresh := make(map[string]bool, len(items))
			for _, item := range items {
				fresh[item.ID] = true
			}
			for _, item := range previous {
				if !fresh[item.ID] {
					items = append(items, item)
				}
			}
			result.Items = items
			result.Page = max(1, state.Page)
			if source != sourceHongguo && state.Page > 1 {
				result.HasMore = state.HasMore
			}
		}
	} else {
		items = mergeNativeCatalog(previous, result.Items)
		if result.Page < state.Page {
			result.Page, result.HasMore = state.Page, state.HasMore
		}
	}
	// 内存缓存与返回值不共享 slice/Tags/VIP，后续详情和封面更新不会竞态编码回包。
	engine.catalogs[source] = cloneNativeCatalogItems(items)
	if result.hongguo != nil {
		engine.hongguoCatalog = cloneHongguoCatalogState(result.hongguo)
	}
	if result.Warning != "" {
		result.Page = max(1, state.Page)
		result.HasMore = true
	}
	state.Page, state.HasMore = result.Page, result.HasMore
	state.Warning = result.Warning
	if result.Warning == "" {
		state.UpdatedAt = time.Now()
		result.Fresh = true
	}
	engine.catalogStates[source] = state
	if base, _, categorized := strings.Cut(source, "|"); categorized {
		engine.catalogs[base] = mergeNativeCatalog(engine.catalogs[base], cloneNativeCatalogItems(items))
	}
	err := engine.writeCatalogDiskLocked()
	result.saveError = err
	if err != nil {
		result.Warning = joinNativeWarnings(result.Warning, err.Error())
		result.Fresh, result.HasMore = false, true
	}
	return err
}

// 调用契约不变：进入和返回均持有 engine.mu。所有旧调用点（分类回滚、
// 封面、详情、推荐、设备和重试）共用此队列，调用者的缓存租约直到返回仍有效。
// 前一任务返回后才取下一份快照，因此失败回调的 revision 回滚也先于下一次编码。
func (engine *nativeEngine) writeCatalogDiskLocked() error {
	// 分类调用者在进入前暂设新 revision，失败后自行回滚。等待期间隐藏这些
	// 未提交值，避免另一个分类请求把它们误当成可回滚的耐久版本。
	revisions := make(map[string]string)
	removed := make(map[string]bool)
	for key, value := range engine.categoryRevisions {
		if value != engine.catalogDurableRevisions[key] {
			revisions[key] = value
		}
	}
	for key := range engine.catalogDurableRevisions {
		if _, found := engine.categoryRevisions[key]; !found {
			removed[key] = true
		}
	}
	engine.categoryRevisions = maps.Clone(engine.catalogDurableRevisions)
	previous := engine.catalogWriteDone
	done := make(chan struct{})
	engine.catalogWriteDone = done
	if previous != nil {
		engine.mu.Unlock()
		<-previous
		engine.mu.Lock()
	}
	trimNativeCatalogs(engine.catalogs)
	disk := engine.catalogSnapshotLocked()
	disk.CategoryRevisions = maps.Clone(engine.catalogDurableRevisions)
	if disk.CategoryRevisions == nil {
		disk.CategoryRevisions = map[string]string{}
	}
	for key := range removed {
		delete(disk.CategoryRevisions, key)
	}
	for key, value := range revisions {
		disk.CategoryRevisions[key] = value
	}
	write := engine.catalogWriteFile
	if write == nil {
		write = writeNativeCacheFile
	}
	engine.mu.Unlock()
	err := engine.writeCatalogSnapshot(disk, write)
	engine.mu.Lock()
	if err == nil {
		engine.catalogDurableRevisions = disk.CategoryRevisions
	}
	engine.categoryRevisions = maps.Clone(engine.catalogDurableRevisions)
	if engine.categoryRevisions == nil {
		engine.categoryRevisions = map[string]string{}
	}
	engine.catalogSaveError = err
	close(done)
	return err
}

func cloneNativeCatalogDrama(item nativeDrama) nativeDrama {
	item.Tags = slices.Clone(item.Tags)
	if item.VIP != nil {
		vip := *item.VIP
		item.VIP = &vip
	}
	return item
}

func cloneNativeCatalogItems(items []nativeDrama) []nativeDrama {
	cloned := make([]nativeDrama, len(items))
	for index, item := range items {
		cloned[index] = cloneNativeCatalogDrama(item)
	}
	return cloned
}

// 除不可变字符串和标量外不共享任何引用；不能只复制 map 头后锁外遍历。
func (engine *nativeEngine) catalogSnapshotLocked() nativeCatalogDisk {
	disk := nativeCatalogDisk{
		Version: 3, Catalogs: make(map[string][]nativeDrama, len(engine.catalogs)),
		States: maps.Clone(engine.catalogStates), Categories: make(map[string][]nativeCategory, len(engine.categoryOptions)),
		CategoryRevisions: maps.Clone(engine.categoryRevisions), HongguoApp: cloneHongguoCatalogState(engine.hongguoCatalog),
		Recommendations: maps.Clone(engine.recommendations),
	}
	for key, items := range engine.catalogs {
		cloned := make([]nativeDrama, len(items))
		for index, item := range items {
			cloned[index] = cloneNativeCatalogDrama(item)
		}
		disk.Catalogs[key] = cloned
	}
	for key, categories := range engine.categoryOptions {
		disk.Categories[key] = slices.Clone(categories)
	}
	for key, state := range disk.Recommendations {
		state.Query.Seen = slices.Clone(state.Query.Seen)
		disk.Recommendations[key] = state
	}
	return disk
}

func (engine *nativeEngine) writeCatalogSnapshot(disk nativeCatalogDisk, write func(string, []byte) error) error {
	if engine.separateCache() {
		if err := engine.savePersistentDevices(disk.HongguoApp); err != nil {
			return nativeSaveError("设备状态", err)
		}
		disk.DeviceIdentity = nativeDeviceIdentity(disk.HongguoApp)
		// 设备先保存且摘要匹配；游标与目录仍然只在同一个原子文件内提交。
		if state := disk.HongguoApp; state != nil {
			disk.HongguoApp = &hongguoCatalogState{Version: state.Version, Feeds: state.Feeds}
		}
	}
	body, err := json.Marshal(disk)
	if err == nil && len(body) > nativeCatalogMaxBytes {
		err = errNativeCatalogLimit
	}
	if err == nil {
		err = write(filepath.Join(engine.cacheRoot(), "catalogs.json"), body)
	}
	return nativeSaveError("剧库", err)
}

func writeNativeCacheFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".cache-write-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	_, writeErr := temporary.Write(data)
	if writeErr == nil {
		writeErr = temporary.Sync()
	}
	closeErr := temporary.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporary.Name(), path)
}

func (engine *nativeEngine) saveDetailMetadata(drama nativeDrama) error {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	needsSave := false
	for _, items := range engine.catalogs {
		for index := range items {
			if items[index].ID != drama.ID {
				continue
			}
			merged := mergeNativeDrama(items[index], drama)
			// 上次落盘失败时内存可能已经是新值；相同的详情也要重试保存。
			if engine.catalogSaveError != nil || !reflect.DeepEqual(items[index], merged) {
				items[index] = merged
				needsSave = true
			}
		}
	}
	if needsSave {
		return engine.writeCatalogDiskLocked()
	}
	return nil
}
