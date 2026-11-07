package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

const hongguoDashOnlyModel = `{"status":10,"message":"success","version":3,"video_id":"v02043g1","enable_ssl":true,"video_duration":5069.824,"media_type":"video","dynamic_video":{"dynamic_type":"segment_base"},"fallback_api":{"fallback_api":"https://vas-lf-x.snssdk.com/video/fplay/1/abc/v02043g1?aid=8662&format_type=dash&stream_type=encrypt"}}`

const hongguoFallbackBody = `{"video_info":{"data":{"status":10,"message":"success","video_duration":5069.824,"video_list":{"video_1":{"main_url":"https://cdn.example.com/movie.mp4","gear_des_key":"0:MP4|1:default|2:h264|4:unknown|5:normal|10000:105"}}}}}`

// 单集长视频（电影类）只下发 DASH 分片，必须靠 fallback_api 换成渐进式 mp4 才能取流。
func TestResolveHongguoAppMediaFallsBackForDashOnlyContent(t *testing.T) {
	var playerCalls, fallbackCalls int
	var fallbackQuery string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == hongguoPlayerModelPath {
			playerCalls++
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"video_model":`+quoteJSON(hongguoDashOnlyModel)+`}}`), nil
		}
		if request.URL.Host == "vas-lf-x.snssdk.com" {
			fallbackCalls++
			fallbackQuery = request.URL.Query().Get("format_type")
			return sourceFixtureResponse(request, http.StatusOK, hongguoFallbackBody), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "7319421489961241615")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://cdn.example.com/movie.mp4" {
		t.Fatal("unexpected media url", media.URL)
	}
	if media.Duration < time.Hour {
		t.Fatal("duration was not taken from the fallback payload", media.Duration)
	}
	if fallbackCalls != 1 || fallbackQuery != "mp4" {
		t.Fatal("fallback api was not asked for progressive mp4", fallbackCalls, fallbackQuery)
	}
	if playerCalls != 1 {
		t.Fatal("dash-only content should not repeat the same request", playerCalls)
	}
}

func TestHongguoAppMediaModelAcceptsMapVideoList(t *testing.T) {
	model, err := hongguoAppMediaModel(map[string]any{"data": map[string]any{
		"video_duration": "146.2",
		"video_list": map[string]any{"video_1": map[string]any{
			"main_url":     "https://cdn.example.com/ep1.mp4",
			"gear_des_key": "0:MP4|2:h264|4:360p",
			"video_meta":   map[string]any{"codec_type": "h264", "definition": "360p"},
		}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://cdn.example.com/ep1.mp4" || media.Quality != 360 {
		t.Fatal("map video_list was not selected", media.URL, media.Quality)
	}
	if media.Duration != 146*time.Second+200*time.Millisecond {
		t.Fatal("duration was not carried over", media.Duration)
	}
}

func TestHongguoFallbackURLOnlyRewritesDash(t *testing.T) {
	cases := map[string]string{
		"": "",
		"https://vas-lf-x.snssdk.com/video/fplay/1/a/b?format_type=dash&aid=8662": "https://vas-lf-x.snssdk.com/video/fplay/1/a/b?format_type=mp4&aid=8662",
		"https://vas-lf-x.snssdk.com/video/fplay/1/a/b?format_type=mp4":           "https://vas-lf-x.snssdk.com/video/fplay/1/a/b?format_type=mp4",
		"not-a-url": "",
	}
	for address, want := range cases {
		model := map[string]any{}
		if address != "" {
			model["fallback_api"] = map[string]any{"fallback_api": address}
		}
		if got := hongguoAppFallbackURL(model); got != want {
			t.Fatalf("fallback url %q => %q, want %q", address, got, want)
		}
	}
}

// 设备注册只有网络失败时才直接报错，避免用未注册设备号去请求、把根因伪装成"接口返回异常"。
func TestResolveHongguoAppMediaReportsRegisterFailure(t *testing.T) {
	var playerCalls int
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			return nil, errors.New("connection reset by peer")
		}
		if request.URL.Path == hongguoPlayerModelPath {
			playerCalls++
		}
		return sourceFixtureResponse(request, http.StatusOK, ""), nil
	})
	client := d.hongguoClient()
	client.mu.Lock()
	client.state.Registered = false
	client.mu.Unlock()
	_, err := d.resolveHongguoAppMedia(context.Background(), "7703100251762084888")
	if err == nil || !strings.Contains(err.Error(), "红果设备注册失败") {
		t.Fatal("register failure was not surfaced", err)
	}
	if playerCalls != 0 {
		t.Fatal("player api was called without a registered device", playerCalls)
	}
}

// bytevc2-only 内容：第一轮所有参数都被服务端按设备能力下发 H.266，第二轮带
// 编码提示参数（vps/default_codec）应能拿到 bytevc1。
func TestResolveHongguoAppMediaRetriesWithCodecHint(t *testing.T) {
	bytevc2Model := `{"video_duration":120,"video_list":[{"main_url":"https://cdn.example.com/vvc.mp4","gear_des_key":"0:MP4|2:bytevc2|4:720p","video_meta":{"codec_type":"bytevc2","definition":"720p"}}]}`
	bytevc1Model := `{"video_duration":120,"video_list":[{"main_url":"https://cdn.example.com/h264.mp4","gear_des_key":"0:MP4|2:h264|4:720p","video_meta":{"codec_type":"h264","definition":"720p"}}]}`
	var sawHintPayload bool
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != hongguoPlayerModelPath {
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
		}
		var payload map[string]any
		if request.Body != nil {
			_ = json.NewDecoder(request.Body).Decode(&payload)
		}
		if _, has := payload["vps"]; has {
			sawHintPayload = true
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"video_model":`+quoteJSON(bytevc1Model)+`}}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"video_model":`+quoteJSON(bytevc2Model)+`}}`), nil
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "7701924192073026622")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://cdn.example.com/h264.mp4" {
		t.Fatal("codec-hint retry did not return the compatible variant", media.URL)
	}
	if !sawHintPayload {
		t.Fatal("codec hint payload was never sent")
	}
}

func TestSelectHongguoAppMediaExplainsBytevc2Only(t *testing.T) {
	_, err := selectHongguoAppMedia(map[string]any{"video_duration": "60", "video_list": []any{
		map[string]any{"main_url": "https://cdn.example.com/v.mp4", "video_meta": map[string]any{"codec_type": "bytevc2", "definition": "720p"}},
	}})
	var codecErr hongguoCodecError
	if !errors.As(err, &codecErr) || !strings.Contains(err.Error(), "H.266") {
		t.Fatal("bytevc2-only model was not reported as a codec error", err)
	}
}

func quoteJSON(value string) string {
	replaced := strings.ReplaceAll(value, `\`, `\\`)
	return `"` + strings.ReplaceAll(replaced, `"`, `\"`) + `"`
}

func TestSelectHongguoAppMediaExplainsDashOnlyContent(t *testing.T) {
	_, err := selectHongguoAppMedia(map[string]any{"dynamic_video": map[string]any{"dynamic_type": "segment_base"}})
	if err == nil || !strings.Contains(err.Error(), "DASH") {
		t.Fatal("dash-only content was not explained", err)
	}
}

// 备用播放接口的档位是平铺结构，质量与编码要能从顶层字段读到。
func TestSelectHongguoAppMediaReadsFlatVariants(t *testing.T) {
	media, err := selectHongguoAppMedia(map[string]any{
		"video_duration": "5069.824",
		"video_list": map[string]any{"video_1": map[string]any{
			"main_url":   "https://cdn.example.com/movie.mp4",
			"codec_type": "h264",
			"definition": "720p",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://cdn.example.com/movie.mp4" || media.Quality != 720 {
		t.Fatal("flat variant was not selected", media.URL, media.Quality)
	}
}

// 搜索页/详情缓存给出过期分集 ID 时，要按集号刷新详情后再取一次。
func TestResolveHongguoMediaRefreshesStaleChapter(t *testing.T) {
	detailCalls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/novel/player/video_model/v1/":
			var payload map[string]any
			if request.Body != nil {
				_ = json.NewDecoder(request.Body).Decode(&payload)
			}
			if fmt.Sprint(payload["video_id"]) != "2222" {
				return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
			}
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"video_model":`+quoteJSON(hongguoFreshModel)+`}}`), nil
		case "/novel/player/video_detail/v1/":
			detailCalls++
			return sourceFixtureResponse(request, http.StatusOK, hongguoFreshDetail), nil
		default:
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
	})
	task := Task{
		DramaID: providerDramaID(sourceHongguo, "7700000000000000001"),
		Chapter: Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://1111", CurrentEpisode: rawEpisode(1)},
		Index:   1,
	}
	media, err := d.resolveHongguoMedia(context.Background(), task)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://cdn.example.com/fresh.mp4" {
		t.Fatal("stale chapter was not refreshed", media.URL)
	}
	if detailCalls != 1 {
		t.Fatal("detail was not refreshed exactly once", detailCalls)
	}
}

const hongguoFreshDetail = `{"code":0,"data":{"video_data":{"series_id_str":"7700000000000000001","episode_cnt":"1","video_list":[{"vid":"2222","vid_index":"1"}]}}}`

const hongguoFreshModel = `{"video_duration":120,"video_list":[{"main_url":"https://cdn.example.com/fresh.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}`
