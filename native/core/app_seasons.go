package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const hongguoSeriesPackPath = "/reading/distribution/book_pack_fields/inner_feed_detail/v1/"
const nativeSeasonLimit = 200
const nativeSeasonCacheLimit = 128
const nativeSeasonTimeout = 30 * time.Second

type nativeSeason struct {
	Number int         `json:"number"`
	Drama  nativeDrama `json:"drama"`
}

type nativeSeasonCacheEntry struct {
	items   []nativeSeason
	expires time.Time
}

func validHongguoSeasonID(id string) bool {
	if len(id) == 0 || len(id) > 19 || id[0] == '0' {
		return false
	}
	value, err := strconv.ParseInt(id, 10, 64)
	return err == nil && value > 0 && strconv.FormatInt(value, 10) == id
}

// ID 按 JSON 整数发送，不能经 float64 转换而丢失 64 位精度。
func hongguoSeasonPackBody(ids []string, fields []string) map[string]any {
	numbers := make([]json.Number, len(ids))
	for index, id := range ids {
		numbers[index] = json.Number(id)
	}
	return map[string]any{"book_pack_channel": "inner_feed_detail", "req_ids": numbers, "req_fields": fields}
}

func hongguoOfficialSeasonIDs(result map[string]any, id string) ([]string, error) {
	value := nestedMap(result, "data", id, "album_info")["album_series_ids"]
	if value == nil {
		return nil, nil
	}
	rows, ok := value.([]any)
	if !ok || len(rows) > nativeSeasonLimit {
		return nil, errors.New("红果官方分季关系格式异常或超过上限")
	}
	ids := []string{}
	seen := map[string]bool{}
	for _, row := range rows {
		var candidate string
		switch typed := row.(type) {
		case string:
			candidate = typed
		case json.Number:
			candidate = string(typed)
		default:
			return nil, errors.New("红果官方分季 ID 类型无效")
		}
		if !validHongguoSeasonID(candidate) {
			return nil, errors.New("红果官方分季 ID 无效")
		}
		if !seen[candidate] {
			seen[candidate] = true
			ids = append(ids, candidate)
		}
	}
	// 同名不是关系证明；官方集合必须包含请求剧集本身。
	if len(ids) < 2 || !seen[id] {
		return nil, nil
	}
	return ids, nil
}

func (d *Downloader) fetchHongguoSeasons(ctx context.Context, id string) ([]nativeSeason, error) {
	result, err := d.hongguoAppRequest(ctx, http.MethodPost, hongguoSeriesPackPath, nil, hongguoSeasonPackBody([]string{id}, []string{
		"album_id", "album_title", "album_serial_count", "series_in_album_order", "album_series_ids",
	}))
	if err != nil {
		return nil, err
	}
	ids, err := hongguoOfficialSeasonIDs(result, id)
	if err != nil || len(ids) < 2 {
		return []nativeSeason{}, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	packed, err := d.hongguoAppRequest(ctx, http.MethodPost, hongguoSeriesPackPath, nil, hongguoSeasonPackBody(ids, []string{
		"series_id", "series_title", "series_cover", "series_intro", "episode_cnt", "series_status", "category_schema", "series_play_cnt", "publish_time",
	}))
	if err != nil {
		return nil, err
	}
	items := []nativeSeason{}
	fallbacks := 0
	self := false
	for index, seriesID := range ids {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		row := nestedMap(packed, "data", seriesID)
		base := nestedMap(row, "base_info")
		var drama Drama
		if mapString(base, "series_id") == seriesID && mapString(base, "series_title") != "" {
			fields := make(map[string]any, len(base)+1)
			for key, value := range base {
				fields[key] = value
			}
			fields["series_play_cnt"] = nestedMap(row, "stat_info")["series_play_cnt"]
			drama = hongguoDramaFromAny(fields, "短剧")
			drama.OnlineDate = providerTimestampDate(mapString(base, "publish_time"))
		} else if fallbacks < 2 {
			// 仅补少量缺项；不能因批量结果异常退化成 200 次详情请求。
			fallbacks++
			detail, detailErr := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": seriesID})
			if detailErr == nil {
				base := nestedMap(detail, "data", "video_data")
				if mapString(base, "series_id_str", "series_id") == seriesID && mapString(base, "series_title") != "" {
					drama = hongguoDramaFromAny(base, "短剧")
				}
			}
		}
		if drama.ID == providerDramaID(sourceHongguo, seriesID) {
			items = append(items, nativeSeason{Number: index + 1, Drama: nativeNormalize(drama)})
			self = self || seriesID == id
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(items) < 2 || !self {
		return []nativeSeason{}, nil
	}
	return items, nil
}

func cloneNativeSeasons(items []nativeSeason) []nativeSeason {
	cloned := append([]nativeSeason{}, items...)
	for index := range cloned {
		cloned[index].Drama.Tags = append([]string(nil), cloned[index].Drama.Tags...)
		if vip := cloned[index].Drama.VIP; vip != nil {
			value := *vip
			cloned[index].Drama.VIP = &value
		}
	}
	return cloned
}

func (engine *nativeEngine) nativeSeasons(ctx context.Context, drama nativeDrama) (map[string]any, error) {
	if !nativeDramaAvailable(drama) {
		return nil, errNativeBuildSource
	}
	empty := map[string]any{"items": []nativeSeason{}}
	source, id, _ := splitProviderDramaID(drama.ID)
	if source != sourceHongguo || strings.HasPrefix(id, "book-") {
		return empty, nil
	}
	if !validHongguoSeasonID(id) || drama.ID != providerDramaID(source, id) || drama.SourceID != "" && drama.SourceID != id {
		return nil, errors.New("红果剧集 ID 无效")
	}
	ctx, cancel := context.WithTimeout(ctx, nativeSeasonTimeout)
	defer cancel()
	ctx, finish, err := engine.beginCacheRead(ctx)
	if err != nil {
		return nil, err
	}
	defer finish()
	engine.mu.Lock()
	cached, found := engine.seasons[id]
	engine.mu.Unlock()
	if found && time.Now().Before(cached.expires) {
		return map[string]any{"items": cloneNativeSeasons(cached.items)}, nil
	}
	items, err := engine.downloader.fetchHongguoSeasons(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.seasons == nil {
		engine.seasons = map[string]nativeSeasonCacheEntry{}
	}
	for key, entry := range engine.seasons {
		if !time.Now().Before(entry.expires) {
			delete(engine.seasons, key)
		}
	}
	if len(engine.seasons) >= nativeSeasonCacheLimit {
		oldestKey := ""
		var oldest time.Time
		for key, entry := range engine.seasons {
			if oldestKey == "" || entry.expires.Before(oldest) {
				oldestKey, oldest = key, entry.expires
			}
		}
		delete(engine.seasons, oldestKey)
	}
	engine.seasons[id] = nativeSeasonCacheEntry{items: cloneNativeSeasons(items), expires: time.Now().Add(30 * time.Minute)}
	return map[string]any{"items": items}, nil
}
