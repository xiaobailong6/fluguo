package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

const hongguoPlayerModelPath = "/novel/player/video_model/v1/"

// errHongguoDashOnly 表示该内容只有 DASH 分片（电影/单集长视频），当前播放管线无法处理。
var errHongguoDashOnly = errors.New("红果该内容是电影/长视频，仅提供 DASH 分片，当前版本暂不支持播放")

type hongguoMediaRequest struct {
	label   string
	payload map[string]any
}

// 服务端对 content_type 的组合并不总是等价：常规参数拿不到档位时换一组再试，
// 避免出现"短剧页能播、搜索出来的同源剧播不了"。
func hongguoMediaRequests(videoID string) []hongguoMediaRequest {
	build := func(contentType, platform int) hongguoMediaRequest {
		return hongguoMediaRequest{
			label: fmt.Sprintf("content_type=%d,platform=%d", contentType, platform),
			payload: map[string]any{
				"video_id": videoID, "content_type": contentType,
				"biz_param": map[string]any{"need_all_video_definition": true, "video_platform": platform},
			},
		}
	}
	return []hongguoMediaRequest{build(1, 3), build(0, 3)}
}

func hongguoAppMediaModel(result map[string]any) (map[string]any, error) {
	data := nestedMap(result, "data")
	model, _ := data["video_model"].(map[string]any)
	if encoded, ok := data["video_model"].(string); ok && encoded != "" {
		if decoded, err := decodeHongguoBase64(encoded); err == nil && len(decoded) > 0 {
			encoded = string(decoded)
		}
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		if err := decoder.Decode(&model); err != nil {
			return nil, errors.New("红果 App 播放信息格式异常")
		}
	}
	if len(model) == 0 && data["video_list"] != nil {
		// 备用播放接口把档位直接放在 video_list 里，可能是列表，也可能是按档位命名的 map。
		model = map[string]any{
			"video_list":     data["video_list"],
			"video_duration": firstNonEmpty(mapString(data, "video_duration"), mapString(data, "duration")),
			"duration":       firstNonEmpty(mapString(data, "duration"), mapString(data, "video_duration")),
		}
	}
	return model, nil
}

func hongguoAppMediaReason(result map[string]any) string {
	data := nestedMap(result, "data")
	message := firstNonEmpty(mapString(data, "message"), mapString(data, "status"), mapString(result, "message"))
	if message != "" {
		return "服务端返回 " + truncate(message, 60)
	}
	return "服务端未返回播放信息"
}

// 单集长视频（电影类）只下发 DASH 分片（视频轨与音频轨分离），现有播放管线播不了；
// 这类内容自带的 fallback_api 换成渐进式 mp4 后能拿到完整档位，作为最后兜底。
func hongguoAppFallbackURL(model map[string]any) string {
	address := mapString(nestedMap(model, "fallback_api"), "fallback_api")
	if !isProviderHTTPMediaURL(address) {
		return ""
	}
	if strings.Contains(address, "format_type=dash") {
		return strings.Replace(address, "format_type=dash", "format_type=mp4", 1)
	}
	return address
}

func (downloader *Downloader) resolveHongguoFallbackMedia(ctx context.Context, address string) (providerMedia, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, nil)
	if err != nil {
		return providerMedia{}, err
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	if readErr != nil {
		return providerMedia{}, readErr
	}
	if response.StatusCode != http.StatusOK {
		return providerMedia{}, fmt.Errorf("红果备用播放接口 HTTP %d", response.StatusCode)
	}
	if len(content) == 0 || len(content) > providerMaxBodyBytes {
		return providerMedia{}, errors.New("红果备用播放接口未返回有效数据")
	}
	var result map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return providerMedia{}, errors.New("红果备用播放接口返回格式异常")
	}
	data := nestedMap(result, "video_info", "data")
	if len(data) == 0 {
		data = nestedMap(result, "data")
	}
	model, err := hongguoAppMediaModel(map[string]any{"data": data})
	if err != nil {
		return providerMedia{}, err
	}
	return selectHongguoAppMedia(model)
}

func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	reasons := make([]string, 0, 4)
	fallback := ""
	for _, attempt := range hongguoMediaRequests(videoID) {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, hongguoPlayerModelPath, nil, attempt.payload)
		model := map[string]any{}
		if err == nil {
			model, err = hongguoAppMediaModel(result)
		}
		if err == nil && len(model) == 0 {
			err = errors.New(hongguoAppMediaReason(result))
		}
		if err == nil {
			if fallback == "" {
				fallback = hongguoAppFallbackURL(model)
			}
			var media providerMedia
			if media, err = selectHongguoAppMedia(model); err == nil {
				return media, nil
			}
		}
		reasons = append(reasons, attempt.label+"："+publicError(err).Error())
		if model["video_list"] == nil && model["dynamic_video"] != nil {
			// 其余参数组合只会拿到同样的 DASH 分片，不必重复请求。
			break
		}
	}
	if fallback != "" {
		media, err := downloader.resolveHongguoFallbackMedia(ctx, fallback)
		if err == nil {
			return media, nil
		}
		reasons = append(reasons, "备用播放接口："+publicError(err).Error())
	}
	if len(reasons) == 0 {
		return providerMedia{}, errors.New("红果 App 未返回播放信息")
	}
	return providerMedia{}, fmt.Errorf("红果 App 未取到可播放地址（%s）", strings.Join(reasons, "；"))
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var keyErr error
	skippedCodec, skippedAddress := 0, 0
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		if len(meta) == 0 {
			// 备用播放接口的档位是平铺的（codec_type/definition/vheight 与 main_url 同级）。
			meta = variant
		}
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			skippedCodec++
			continue
		}
		addresses := hongguoMediaAddresses(variant)
		if len(addresses) == 0 {
			skippedAddress++
			continue
		}
		media := providerMedia{Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			media.URL = address
			choices = append(choices, scoredMedia{media: media, score: quality})
		}
	}
	if len(choices) > 0 {
		sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
		selected := choices[0].media
		for _, choice := range choices {
			selected.Variants = append(selected.Variants, choice.media)
		}
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	if len(variants) == 0 {
		if model["dynamic_video"] != nil {
			// 电影/单集长视频只下发 DASH 分片（视频轨与音频轨分离），当前播放管线不支持。
			return providerMedia{}, errHongguoDashOnly
		}
		return providerMedia{}, errors.New("红果 App 未返回任何播放档位")
	}
	return providerMedia{}, fmt.Errorf("红果 App 未返回兼容的媒体（%d 个档位：不支持的编码 %d、无播放地址 %d）",
		len(variants), skippedCodec, skippedAddress)
}

func hongguoMediaAddresses(info map[string]any) []string {
	var addresses []string
	seen := map[string]bool{}
	var add func(any)
	add = func(value any) {
		switch value := value.(type) {
		case string:
			address := strings.TrimSpace(value)
			if len(address) > 8192 {
				return
			}
			if !isProviderHTTPMediaURL(address) {
				decoded, err := decodeHongguoBase64(address)
				if err != nil {
					return
				}
				address = strings.TrimSpace(string(decoded))
			}
			if isProviderHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range value {
				add(item)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"} {
		add(info[key])
	}
	return addresses
}
