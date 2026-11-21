package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

type nativeCategory struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

var nativeAICategories = []nativeCategory{
	{ID: "ai-duanju", Name: "AI 短剧"},
	{ID: "ai-manju", Name: "AI 漫剧"},
	{ID: "ai-huanlian", Name: "AI 换脸"},
	{ID: "ai-mogai", Name: "AI 魔改"},
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

func validNativeCategory(source, category string) bool {
	if isImportedSource(source) {
		return validImportedCategory(source, category)
	}
	if source == sourceMissav {
		return validMissavCategory(category)
	}
	if source == sourceHanime1 {
		return validHanime1Category(category)
	}
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			if category == genre.key {
				return true
			}
		}
		return hongguoTagPattern.MatchString(category)
	case sourceHuangguoAI:
		for _, entry := range nativeAICategories {
			if category == entry.ID {
				return true
			}
		}
	case sourceHuangguoVideo:
		id, err := strconv.Atoi(category)
		return err == nil && id > 0
	case sourceCloudFront:
		return strings.TrimSpace(category) == category
	case sourceHuangju:
		return category == huangjuNewestCategory || validHuangjuID(category) && !strings.HasPrefix(category, "@")
	case sourceYeguo:
		return validYeguoCategory(category)
	case sourceJinguoDuanju:
		return validJinguoDuanjuCategory(category)
	case sourceJinguo:
		return validJinguoCategory(category)
	case sourceDSD:
		return webProviderNumericID.MatchString(category)
	case sourceSorani:
		return validSoraniCategory(category)
	case sourceGuipian:
		return validGuipianCategory(category)
	case sourceHanxiaoquan:
		return validHanxiaoquanCategory(category)
	case sourceHeitao:
		return validHeitaoCategory(category)
	case sourceBeabox:
		return validBeaboxCategory(category)
	}
	return false
}

// 分类协议单独按原生站源修订；修改某站的分类规则时只递增该站，
// 不依赖 JS 模块版本、应用版本或剧库磁盘格式版本。
func nativeCategoryRevision(source string) string {
	switch source {
	case sourceHongguo:
		return "hongguo-1"
	case sourceCloudFront:
		return "cloudfront-1"
	case sourceHuangguoVideo:
		return "huangguo-video-1"
	case sourceHuangju:
		return "huangju-1"
	case sourceYeguo:
		return "yeguo-1"
	case sourceJinguoDuanju:
		return "jinguo-duanju-1"
	case sourceJinguo:
		return "jinguo-1"
	case sourceDSD:
		return "dsd-1"
	case sourceSorani:
		return "sorani-1"
	case sourceGuipian:
		return "guipian-1"
	case sourceHanxiaoquan:
		return "hanxiaoquan-1"
	case sourceHeitao:
		return "heitao-1"
	case sourceBeabox:
		return "beabox-1"
	case sourceMissav:
		return "missav-1"
	case sourceHanime1:
		return "hanime1-1"
	}
	return ""
}

// 基础分类优先，旧缓存只补充仍合法的 ID；不改历史剧集/收藏 ID。
func mergeNativeCategories(source string, base, extra []nativeCategory) []nativeCategory {
	all := make([]nativeCategory, 0, len(base)+len(extra))
	seen := map[string]bool{}
	for _, list := range [][]nativeCategory{base, extra} {
		for _, entry := range list {
			entry.Name = strings.TrimSpace(entry.Name)
			if entry.Name == "" || seen[entry.ID] || !validNativeCategory(source, entry.ID) {
				continue
			}
			seen[entry.ID] = true
			all = append(all, entry)
		}
	}
	return all
}

func nativeCategoriesComplete(source string, all []nativeCategory) bool {
	seen := map[string]bool{}
	hasTag := false
	for _, entry := range all {
		if strings.TrimSpace(entry.Name) == "" || seen[entry.ID] || !validNativeCategory(source, entry.ID) {
			return false
		}
		seen[entry.ID] = true
		hasTag = hasTag || hongguoTagPattern.MatchString(entry.ID)
	}
	if !seen[""] || len(seen) < 2 {
		return false
	}
	if source == sourceHongguo {
		// 长度无法证明完整性：大量 tags 不能替代任一基础 genre。
		for _, genre := range hongguoAppGenres {
			if !seen[genre.key] {
				return false
			}
		}
		return hasTag
	}
	return true
}

func (engine *nativeEngine) cachedCategories(source string, base []nativeCategory) ([]nativeCategory, bool) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	cached := engine.categoryOptions[source]
	revision := nativeCategoryRevision(source)
	fresh := revision != "" && engine.categoryRevisions[source] == revision && nativeCategoriesComplete(source, cached)
	return mergeNativeCategories(source, base, cached), fresh
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	ctx, finish, gateErr := engine.beginCacheRead(ctx)
	if gateErr != nil {
		return nil, gateErr
	}
	defer finish()
	source = canonicalProviderSource(source)
	ctx = withProxySource(ctx, source)
	if isImportedSource(source) {
		return importedCategories(source), nil
	}
	all := []nativeCategory{{Name: "全部"}}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			all = append(all, nativeCategory{ID: genre.key, Name: genre.name})
		}
		return engine.hongguoCategories(ctx, all, force), nil
	case sourceHuangguoAI:
		return append(all, nativeAICategories...), nil
	case sourceHuangdou:
		return all, nil
	}
	cached, fresh := engine.cachedCategories(source, all)
	if fresh && !force {
		return cached, nil
	}
	d := engine.downloader
	var err error
	switch source {
	case sourceCloudFront:
		var tabs legacyTabList
		err = d.fetchAPI(ctx, "/api/app/playlet-tab/all", nil, &tabs)
		for _, tab := range tabs {
			if validNativeCategory(source, tab.ID) && tab.ID != "" && tab.Name != "" {
				all = append(all, nativeCategory{ID: tab.ID, Name: tab.Name})
			}
		}
	case sourceHuangguoVideo:
		address := d.providerBaseURL(source) + "/videos"
		var body string
		body, err = d.fetchProviderText(ctx, address, d.providerBaseURL(source)+"/")
		if err == nil {
			all = append(all, parseHuangguoVideoCategories(body)...)
		}
	case sourceHuangju:
		var categories []nativeCategory
		categories, err = d.fetchHuangjuCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceYeguo:
		var categories []nativeCategory
		categories, err = d.fetchYeguoCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceJinguoDuanju:
		var categories []nativeCategory
		categories, err = d.fetchJinguoDuanjuCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceJinguo:
		var categories []nativeCategory
		categories, err = d.fetchJinguoCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceDSD:
		var categories []nativeCategory
		// 修订失效同样绕过 DSD 的内部分类缓存，不能把旧解析结果标成新版。
		categories, err = d.fetchDSDCategories(ctx, force || !fresh)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceSorani:
		all = append(all, d.fetchSoraniCategories()...)
	case sourceGuipian:
		all = append(all, d.fetchGuipianCategories()...)
	case sourceHanxiaoquan:
		all = append(all, d.fetchHanxiaoquanCategories()...)
	case sourceHeitao:
		var categories []nativeCategory
		categories, err = d.fetchHeitaoCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceBeabox:
		var categories []nativeCategory
		categories, err = d.fetchBeaboxCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceMissav:
		var categories []nativeCategory
		categories, err = d.fetchMissavCategories(ctx)
		all = append(all, categories...)
	case sourceHanime1:
		var categories []nativeCategory
		categories, err = d.fetchHanime1Categories(ctx)
		all = append(all, categories...)
	default:
		return nil, errors.New("请选择有效站源")
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	all = mergeNativeCategories(source, []nativeCategory{{Name: "全部"}}, all)
	if err != nil || !nativeCategoriesComplete(source, all) {
		// 有可用旧分类才静默降级；完全没有时仍把失败交给上层提示。
		if len(cached) > 1 {
			return cached, nil
		}
		if err != nil {
			return nil, err
		}
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.rememberCategories(source, all)
	return all, nil
}

func (engine *nativeEngine) hongguoCategories(ctx context.Context, genres []nativeCategory, force bool) []nativeCategory {
	cached, fresh := engine.cachedCategories(sourceHongguo, genres)
	if fresh && !force {
		return cached
	}
	tags, err := engine.downloader.fetchHongguoTagCategories(ctx)
	all := mergeNativeCategories(sourceHongguo, genres, tags)
	if err != nil || ctx.Err() != nil || !nativeCategoriesComplete(sourceHongguo, all) {
		return cached
	}
	engine.rememberCategories(sourceHongguo, all)
	return all
}

// 调用者持有 beginCacheRead 租约直到落盘，清理必须等待本次写入完成。
func (engine *nativeEngine) rememberCategories(source string, all []nativeCategory) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	if engine.categoryRevisions == nil {
		engine.categoryRevisions = map[string]string{}
	}
	engine.categoryOptions[source] = append([]nativeCategory(nil), all...)
	engine.categoryRevisions[source] = nativeCategoryRevision(source)
	// 串行持久化器已经按最后成功提交恢复 revision；不能再用进入函数时
	// 捕获的旧值回滚，否则等待期间另一个成功提交会被覆盖。
	_ = engine.writeCatalogDiskLocked()
}

var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)

func parseHuangguoVideoCategories(body string) []nativeCategory {
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, match := range categoryAnchorPattern.FindAllStringSubmatch(body, -1) {
		href := html.UnescapeString(extractAttr("<a "+match[1]+">", "href"))
		address, err := url.Parse(href)
		if err != nil || address.Path != "" && strings.TrimRight(address.Path, "/") != "/videos" {
			continue
		}
		id := address.Query().Get("category")
		name := strings.TrimSpace(html.UnescapeString(categoryTextPattern.ReplaceAllString(match[2], "")))
		if !validNativeCategory(sourceHuangguoVideo, id) || id == "" || seen[id] || name == "" || len([]rune(name)) > 24 {
			continue
		}
		seen[id] = true
		categories = append(categories, nativeCategory{ID: id, Name: name})
	}
	return categories
}

func (d *Downloader) fetchHuangguoAICatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	categories := nativeAICategories
	if category != "" {
		for _, entry := range categories {
			if entry.ID == category {
				categories = []nativeCategory{entry}
				break
			}
		}
	}
	type categoryResult struct {
		items []Drama
		err   error
	}
	results := make([]categoryResult, len(categories))
	slots := make(chan struct{}, 2)
	var group sync.WaitGroup
	for index, entry := range categories {
		group.Add(1)
		go func(index int, entry nativeCategory) {
			defer group.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			path := fmt.Sprintf("/api/videos/category/%s?sort=hot&page=%d&size=24", url.PathEscape(entry.ID), page)
			var body json.RawMessage
			err := d.huangguoAIAPI(ctx, path, &body)
			if err == nil {
				results[index].items = parseHuangguoAIJSONCards(body, d.providerBaseURL(sourceHuangguoAI)+"/", entry.Name)
			}
			if err != nil {
				results[index].err = fmt.Errorf("%s: %w", entry.Name, err)
			}
		}(index, entry)
	}
	group.Wait()
	var items []Drama
	var failures []error
	more := false
	for _, result := range results {
		items = append(items, result.items...)
		more = more || len(result.items) >= 24 || result.err != nil
		if result.err != nil {
			failures = append(failures, result.err)
		}
	}
	return items, more, errors.Join(failures...)
}
