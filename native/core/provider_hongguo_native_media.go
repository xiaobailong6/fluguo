package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const hongguoPlayerModelPath = "/novel/player/multi_video_model/player/v1"
const hongguoVideoTabPath = "/reading/bookapi/video_tab/multi_video_model/v1/"

const hongguoFallbackPlayURLSalt = "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58"
const hongguoFallbackCodecURLHeaderSize = 4

// errHongguoDashOnly 表示该内容只有 DASH 分片（电影/单集长视频），当前播放管线无法处理。
var errHongguoDashOnly = errors.New("红果该内容是电影/长视频，仅提供 DASH 分片，当前版本暂不支持播放")

// hongguoCodecError 表示服务端只下发了播放器不支持的编码（如 bytevc2/H.266）。
type hongguoCodecError struct{ error }

type hongguoNoMediaError struct{ error }

type hongguoMediaRequest struct {
	label   string
	payload map[string]any
}

// 新协议只接受 mixed_video_id_map + player 场景，不再尝试旧 content_type 组合。
// 编码重试仍保留 vps/default_codec 提示，但不改变新接口的 video_platform。
func hongguoMediaRequests(videoID string, preferCompatibleCodec bool) []hongguoMediaRequest {
	payload := map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 1,
			"disable_digg_stat": false, "disable_video_relate_book": false,
			"need_all_video_definition": true, "need_mp4_align": false,
			"use_os_player": false, "use_server_dns": false, "video_platform": 1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []string{videoID}},
		"dr_scene":           "player",
	}
	label := "multi_video_model"
	if preferCompatibleCodec {
		payload["vps"] = 3
		payload["biz_param"].(map[string]any)["default_codec"] = "h264"
		label += ",codec=h264"
	}
	return []hongguoMediaRequest{{label: label, payload: payload}}
}

// 只取请求的分集，不能把另一集或旧接口的根 video_model 误作本集结果。
// 上游兼容不带 1004 外层的 data[videoID]，但 fallback 仍单独使用旧解析器。
func hongguoMultiMediaData(result map[string]any, videoID string) (map[string]any, error) {
	entries := nestedMap(result, "data")
	if grouped, ok := entries["1004"].(map[string]any); ok {
		entries = grouped
	}
	data := nestedMap(entries, videoID)
	if len(data) == 0 {
		return nil, errors.New("红果 App 未返回所请求的分集播放信息")
	}
	return map[string]any{"data": data}, nil
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

// 红果 fallback_api 的 URL 按 key_seed 派生 AES-128-CBC 参数加密，明文以 PKCS#7 补齐。
func decodeHongguoFallbackPlayURL(encoded, seed string) (string, error) {
	if len(encoded) > 8192 || seed == "" {
		return encoded, nil
	}
	blob, err := decodeHongguoBase64(encoded)
	if err != nil || len(blob) < hongguoFallbackCodecURLHeaderSize+aes.BlockSize || blob[0] != 0xa8 || blob[1] != 0 || (len(blob)-hongguoFallbackCodecURLHeaderSize)%aes.BlockSize != 0 {
		return encoded, nil
	}
	keySeed, err := decodeHongguoBase64(seed)
	if err != nil {
		return encoded, nil
	}
	keyMaterial := sha512.Sum512(keySeed)
	salt, err := hex.DecodeString(hongguoFallbackPlayURLSalt)
	if err != nil {
		return "", err
	}
	combined := append(append(make([]byte, 0, len(keyMaterial)+len(salt)), keyMaterial[:]...), salt...)
	derived := sha512.Sum512(combined)
	block, err := aes.NewCipher(derived[:aes.BlockSize])
	if err != nil {
		return "", err
	}
	cipherText := blob[hongguoFallbackCodecURLHeaderSize:]
	plain := make([]byte, len(cipherText))
	unsupported := fmt.Errorf("红果备用线路编码版本 %d 暂不支持", uint16(blob[2])|uint16(blob[3])<<8)
	cipher.NewCBCDecrypter(block, derived[aes.BlockSize:2*aes.BlockSize]).CryptBlocks(plain, cipherText)
	padding := int(plain[len(plain)-1])
	if padding == 0 || padding > aes.BlockSize || padding > len(plain) {
		return "", unsupported
	}
	for _, value := range plain[len(plain)-padding:] {
		if int(value) != padding {
			return "", unsupported
		}
	}
	address := strings.TrimSpace(string(plain[:len(plain)-padding]))
	if !isProviderHTTPMediaURL(address) {
		return "", unsupported
	}
	return address, nil
}

func hongguoFallbackCodecVariants(data map[string]any) (map[string]any, error) {
	seed := mapString(data, "key_seed")
	entries := anyList(data["video_list"])
	if rows, ok := data["video_list"].(map[string]any); ok && len(entries) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			entries = append(entries, rows[key])
		}
	}
	variants := make([]any, 0, len(entries))
	decodedCount := 0
	var versionErr error
	for _, entry := range entries {
		variant, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		copy := map[string]any{
			"gear_des_key": mapString(variant, "gear_des_key"),
			"video_meta": map[string]any{
				"codec_type": mapString(variant, "codec_type"), "definition": mapString(variant, "definition"),
				"vwidth": mapString(variant, "vwidth"), "vheight": mapString(variant, "vheight"),
			},
		}
		for _, key := range []string{"main_url", "backup_url_1", "backup_url_2"} {
			address, err := decodeHongguoFallbackPlayURL(mapString(variant, key), seed)
			if err != nil {
				versionErr = err
				continue
			}
			if address != "" {
				copy[key] = address
				decodedCount++
			}
		}
		if encryption := mapString(variant, "spade_a"); encryption != "" || mapString(variant, "encryption_method") != "" || variant["encrypt"] == true {
			copy["encrypt_info"] = map[string]any{"spade_a": encryption, "encryption_method": mapString(variant, "encryption_method"), "encrypt": variant["encrypt"] == true}
		}
		variants = append(variants, copy)
	}
	if decodedCount == 0 && versionErr != nil {
		return nil, versionErr
	}
	return map[string]any{"video_list": variants, "video_duration": mapString(data, "video_duration")}, nil
}

func (downloader *Downloader) resolveHongguoCodecFallback(ctx context.Context, model map[string]any) (providerMedia, error) {
	endpoint := mapString(nestedMap(model, "fallback_api"), "fallback_api")
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme != "https" || parsed.Host != "vas-lf-x.snssdk.com" || parsed.User != nil || !strings.HasPrefix(parsed.Path, "/video/fplay/") {
		return providerMedia{}, errors.New("红果未提供有效的 H.265 备用线路")
	}
	var lastErr error
	for _, codecType := range []string{"1", "3"} {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		// 不重排备用接口的其他查询参数，保持上游下发的原始编码。
		address := *parsed
		parts := strings.Split(address.RawQuery, "&")
		replaced := false
		for i, part := range parts {
			if strings.HasPrefix(part, "codec_type=") {
				parts[i] = "codec_type=" + codecType
				replaced = true
				break
			}
		}
		if !replaced {
			parts = append(parts, "codec_type="+codecType)
		}
		address.RawQuery = strings.TrimPrefix(strings.Join(parts, "&"), "&")
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, address.String(), nil)
		if err != nil {
			return providerMedia{}, err
		}
		request.Header.Set("User-Agent", hongguoPlaybackUserAgent)
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
		if response.StatusCode == http.StatusTooManyRequests {
			// doPreparedCatalogRequest 已记录冷却；保留类型以停止本次编码重试。
			host := request.URL.Hostname()
			downloader.limiter.mu.Lock()
			backoff := downloader.limiter.backoffs[host]
			downloader.limiter.mu.Unlock()
			return providerMedia{}, backoff
		}
		if response.StatusCode != http.StatusOK || len(content) == 0 || len(content) > providerMaxBodyBytes {
			return providerMedia{}, fmt.Errorf("红果 H.265 备用线路 HTTP %d 或响应无效", response.StatusCode)
		}
		var result map[string]any
		decoder := json.NewDecoder(strings.NewReader(string(content)))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil {
			return providerMedia{}, errors.New("红果 H.265 备用线路响应格式异常")
		}
		data := nestedMap(result, "video_info", "data")
		if len(data) == 0 {
			return providerMedia{}, errors.New("红果备用线路未返回有效数据")
		}
		converted, err := hongguoFallbackCodecVariants(data)
		if err == nil {
			var media providerMedia
			media, err = selectHongguoAppMedia(converted)
			if err == nil {
				return media, nil
			}
		}
		if !isHongguoNoCompatibleMedia(err) {
			return providerMedia{}, err
		}
		lastErr = err
	}
	return providerMedia{}, fmt.Errorf("红果备用线路仍无兼容编码：%w", lastErr)
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
	media, err := downloader.resolveHongguoAppMediaOnce(ctx, videoID, false)
	if err == nil {
		return media, nil
	}
	if ctx.Err() != nil {
		return providerMedia{}, ctx.Err()
	}
	var codecErr hongguoCodecError
	if errors.As(err, &codecErr) {
		// 服务端按设备能力只下发 bytevc2(H.266)：带编码提示参数再要一轮 bytevc1。
		retried, retryErr := downloader.resolveHongguoAppMediaOnce(ctx, videoID, true)
		if retryErr == nil {
			return retried, nil
		}
		var backoff *requestBackoff
		if errors.As(retryErr, &backoff) {
			return providerMedia{}, retryErr
		}
		if errors.As(retryErr, &codecErr) && ctx.Err() == nil {
			downloader.recordTrace(diagnosticEvent{Event: "stream.hongguo_device_rotation", Source: sourceHongguo, DramaID: videoID, Message: "换设备重注册以获取兼容编码"})
			current, _, _ := downloader.hongguoClient().device(false)
			if rotateErr := downloader.ensureHongguoDevice(ctx, false, current); rotateErr == nil {
				if rotated, rotateErr := downloader.resolveHongguoAppMediaOnce(ctx, videoID, true); rotateErr == nil {
					return rotated, nil
				}
			}
		}
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
		return media, err
	}
	if !hongguoRegisterFailure(err) {
		return media, err
	}
	// 首次播放常是本会话第一次注册设备：代理瞬时故障（如 EOF）会直接把取流判死，
	// 而下一次点击就能成功。这里清掉注册暂停、强制重注册后整体再试一次。
	client := downloader.hongguoClient()
	client.deviceMu.Lock()
	client.registerPausedUntil, client.registerPauseErr = time.Time{}, nil
	client.deviceMu.Unlock()
	if retryErr := downloader.ensureHongguoDevice(ctx, false, ""); retryErr != nil {
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
		return media, fmt.Errorf("%v（重试注册仍失败：%v）", publicError(err), publicError(retryErr))
	}
	retried, retryErr := downloader.resolveHongguoAppMediaOnce(ctx, videoID, false)
	if ctx.Err() != nil {
		return providerMedia{}, ctx.Err()
	}
	if retryErr == nil {
		return retried, nil
	}
	return media, err
}

func hongguoRegisterFailure(err error) bool {
	return err != nil && strings.Contains(err.Error(), "红果设备注册失败")
}

// 上游 1.0.6 优先使用 video_tab；编码错误交给外层兼容重试，其他失败保留旧播放器兜底。
func (downloader *Downloader) resolveHongguoAppMediaOnce(ctx context.Context, videoID string, preferCompatibleCodec bool) (providerMedia, error) {
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, tabErr := downloader.resolveHongguoTabMedia(ctx, videoID)
	if tabErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	var codecErr hongguoCodecError
	var backoff *requestBackoff
	if errors.As(tabErr, &codecErr) || errors.As(tabErr, &backoff) {
		return providerMedia{}, tabErr
	}
	media, playerErr := downloader.resolveHongguoPlayerMediaOnce(ctx, videoID, preferCompatibleCodec)
	if playerErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	// 不包掉编码错误，否则现有编码提示与设备轮换无法识别。
	if errors.As(playerErr, &codecErr) || errors.As(playerErr, &backoff) {
		return providerMedia{}, playerErr
	}
	return providerMedia{}, fmt.Errorf("video_tab：%v；播放器接口：%w", publicError(tabErr), playerErr)
}

func (downloader *Downloader) resolveHongguoTabMedia(ctx context.Context, videoID string) (providerMedia, error) {
	query := url.Values{
		"video_id": {videoID}, "video_id_type": {"0"}, "device_level": {"1"},
		"need_all_video_definition": {"1"}, "need_mp4_align": {"0"}, "use_os_player": {"0"},
		"video_platform": {"1024"}, "source": {"0"}, "from_video_id": {""},
	}
	result, err := downloader.hongguoAppRequest(ctx, http.MethodGet, hongguoVideoTabPath, query, nil)
	if err != nil {
		return providerMedia{}, err
	}
	// 只读取所请求分集，不能把其他分集或根级 video_model 当成当前集。
	data := nestedMap(result, "data", "video_model_data", videoID)
	if len(data) == 0 {
		return providerMedia{}, errors.New("红果 App 未返回所请求的分集播放信息")
	}
	model, err := hongguoAppMediaModel(map[string]any{"data": data})
	if err != nil {
		return providerMedia{}, err
	}
	media, err := downloader.selectHongguoMediaWithCodecFallback(ctx, model)
	// video_tab 也会返回 DASH-only 长视频；先用本次模型里的 MP4 兜底，
	// 不能丢掉它再请求可能已经空包的旧播放器接口。
	if errors.Is(err, errHongguoDashOnly) {
		if fallback := hongguoAppFallbackURL(model); fallback != "" {
			media, err = downloader.resolveHongguoFallbackMedia(ctx, fallback)
		}
	}
	if ctx.Err() != nil {
		return providerMedia{}, ctx.Err()
	}
	if err == nil {
		downloader.recordTrace(diagnosticEvent{Event: "stream.hongguo_media_selected", Source: sourceHongguo, DramaID: videoID, Host: diagnosticHost(media.URL), Message: "video_tab 取流成功"})
	}
	return media, err
}

func (downloader *Downloader) resolveHongguoPlayerMediaOnce(ctx context.Context, videoID string, preferCompatibleCodec bool) (providerMedia, error) {
	reasons := make([]string, 0, 4)
	fallback := ""
	var codecFailure error
	codecOnly := true
	for _, attempt := range hongguoMediaRequests(videoID, preferCompatibleCodec) {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, hongguoPlayerModelPath, nil, attempt.payload)
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
		model := map[string]any{}
		if err == nil {
			result, err = hongguoMultiMediaData(result, videoID)
			if err == nil {
				model, err = hongguoAppMediaModel(result)
			}
		}
		if err == nil && len(model) == 0 {
			err = errors.New(hongguoAppMediaReason(result))
		}
		if err == nil {
			if fallback == "" {
				fallback = hongguoAppFallbackURL(model)
			}
			var media providerMedia
			if media, err = downloader.selectHongguoMediaWithCodecFallback(ctx, model); err == nil {
				downloader.recordTrace(diagnosticEvent{Event: "stream.hongguo_media_selected", Source: sourceHongguo, DramaID: videoID, Host: diagnosticHost(media.URL), Message: fmt.Sprintf("%s：画质 %d，档位 %d", attempt.label, media.Quality, len(media.Variants)+1)})
				return media, nil
			}
		}
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			return providerMedia{}, err
		}
		reasons = append(reasons, attempt.label+"："+publicError(err).Error())
		downloader.recordTrace(diagnosticEvent{Event: "stream.hongguo_media_attempt_failed", Source: sourceHongguo, DramaID: videoID, Message: reasons[len(reasons)-1]})
		var codecErr hongguoCodecError
		if errors.As(err, &codecErr) {
			codecFailure = err
			// 编码兜底已经请求过兼容线路，不再向同一接口请求原编码。
			fallback = ""
		} else {
			codecOnly = false
		}
		if model["video_list"] == nil && model["dynamic_video"] != nil {
			// 其余参数组合只会拿到同样的 DASH 分片，不必重复请求。
			break
		}
	}
	if fallback != "" {
		media, err := downloader.resolveHongguoFallbackMedia(ctx, fallback)
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
		if err == nil {
			downloader.recordTrace(diagnosticEvent{Event: "stream.hongguo_fallback_selected", Source: sourceHongguo, DramaID: videoID, Host: diagnosticHost(media.URL), Message: "备用播放接口取流成功"})
			return media, nil
		}
		reasons = append(reasons, "备用播放接口："+publicError(err).Error())
		downloader.recordTrace(diagnosticEvent{Event: "stream.hongguo_fallback_failed", Source: sourceHongguo, DramaID: videoID, Message: reasons[len(reasons)-1]})
	}
	if len(reasons) == 0 {
		return providerMedia{}, errors.New("红果 App 未返回播放信息")
	}
	if codecOnly && codecFailure != nil {
		// 保留类型化的编码错误，外层才能据此触发编码提示重试与换设备重试。
		return providerMedia{}, codecFailure
	}
	return providerMedia{}, fmt.Errorf("红果 App 未取到可播放地址（%s）", strings.Join(reasons, "；"))
}

func isHongguoNoCompatibleMedia(err error) bool {
	var codecErr hongguoCodecError
	var noMediaErr hongguoNoMediaError
	return errors.As(err, &codecErr) || errors.As(err, &noMediaErr)
}

// 正常线路优先；主模型没有兼容媒体时才请求备用接口。DASH 仍走原生 MP4 兜底。
func (downloader *Downloader) selectHongguoMediaWithCodecFallback(ctx context.Context, model map[string]any) (providerMedia, error) {
	media, err := selectHongguoAppMedia(model)
	if !isHongguoNoCompatibleMedia(err) || mapString(nestedMap(model, "fallback_api"), "fallback_api") == "" {
		return media, err
	}
	fallback, fallbackErr := downloader.resolveHongguoCodecFallback(ctx, model)
	if fallbackErr == nil {
		return fallback, nil
	}
	if ctx.Err() != nil {
		return providerMedia{}, ctx.Err()
	}
	var backoff *requestBackoff
	if errors.As(fallbackErr, &backoff) {
		return providerMedia{}, fallbackErr
	}
	var codecErr hongguoCodecError
	combined := fmt.Errorf("%v；备用线路：%v", err, publicError(fallbackErr))
	if errors.As(err, &codecErr) {
		return providerMedia{}, hongguoCodecError{combined}
	}
	return providerMedia{}, hongguoNoMediaError{combined}
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
	if skippedCodec > 0 && skippedAddress == 0 {
		return providerMedia{}, hongguoCodecError{fmt.Errorf(
			"该集仅提供 H.266(VVC) 编码（%d 个档位），当前播放器不支持", skippedCodec)}
	}
	if len(variants) == 0 {
		if model["dynamic_video"] != nil {
			// 电影/单集长视频只下发 DASH 分片（视频轨与音频轨分离），当前播放管线不支持。
			return providerMedia{}, errHongguoDashOnly
		}
		return providerMedia{}, hongguoNoMediaError{errors.New("红果 App 未返回任何播放档位")}
	}
	return providerMedia{}, hongguoNoMediaError{fmt.Errorf("红果 App 未返回兼容的媒体（%d 个档位：不支持的编码 %d、无播放地址 %d）",
		len(variants), skippedCodec, skippedAddress)}
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
