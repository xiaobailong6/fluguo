package core

import (
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

const hongguoV5Variants = `{"video_duration":80.5,"video_list":[{"main_url":"https://media.example.invalid/vvc.mp4","video_meta":{"codec_type":"bytevc2","definition":"2160p"}},{"main_url":"https://media.example.invalid/main.mp4","backup_url":"https://media.example.invalid/backup.mp4","video_meta":{"codec_type":"bytevc1","definition":"1080p"}},{"main_url":"https://media.example.invalid/low.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}`

func TestHongguoV5PlaybackPayloadAndNestedVariants(t *testing.T) {
	for _, form := range []string{"object", "json", "base64", "flat", "ungrouped"} {
		t.Run(form, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.Method != http.MethodPost || request.URL.Path != "/novel/player/multi_video_model/player/v1" || request.URL.Host != "api5-normal-sinfonlinea.fqnovel.com" {
					t.Fatal("wrong playback endpoint")
				}
				if request.Header.Get("User-Agent") != hongguoPlaybackUserAgent || request.Header.Get("Cookie") != "" {
					t.Fatal("wrong anonymous playback identity")
				}
				for _, name := range []string{"X-Argus", "X-Ladon", "X-Gorgon", "X-SS-Req-Ticket", "X-XS-From-Web", "Sdk-Version"} {
					if request.Header.Get(name) != "" {
						t.Fatalf("old header leaked: %s", name)
					}
				}
				for _, name := range []string{"X-Helios", "X-Medusa", "X-Khronos"} {
					if request.Header.Get(name) == "" {
						t.Fatalf("missing v5 header: %s", name)
					}
				}
				query := request.URL.Query()
				if query.Get("version_name") != "7.4.3.32" || query.Get("version_code") != "74332" || query.Get("channel") != "vivo_8662_64" || query.Get("device_type") != "PGT-AN10" || query.Get("os_version") != "12" || query.Get("cdid") == "" || query.Has("ts") {
					t.Fatal("wrong playback query")
				}
				if _, ok := request.Context().Deadline(); !ok {
					t.Fatal("playback request lost timeout")
				}
				body, err := io.ReadAll(request.Body)
				if err != nil {
					t.Fatal(err)
				}
				var payload map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatal(err)
				}
				var want map[string]any
				_ = json.Unmarshal([]byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"disable_video_relate_book":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["2222"]},"dr_scene":"player"}`), &want)
				if !reflect.DeepEqual(payload, want) {
					t.Fatal("new payload mismatch or legacy content_type leaked")
				}
				bodyHash, queryHash := md5.Sum(body), hongguoSM3([]byte(request.URL.RawQuery))
				stamp, err := strconv.ParseUint(request.Header.Get("X-Khronos"), 10, 32)
				if err != nil || hongguoV5IV(queryHash[:], bodyHash[:], uint32(stamp))&15 != 12 || request.Header.Get("X-SS-STUB") != strings.ToUpper(hex.EncodeToString(bodyHash[:])) {
					t.Fatal("wire body/query not signed")
				}
				var model map[string]any
				_ = json.Unmarshal([]byte(hongguoV5Variants), &model)
				entry := map[string]any{"video_model": model}
				switch form {
				case "json":
					entry["video_model"] = hongguoV5Variants
				case "base64":
					entry["video_model"] = base64.StdEncoding.EncodeToString([]byte(hongguoV5Variants))
				case "flat":
					entry = model
				}
				entries := map[string]any{"2222": entry, "9999": map[string]any{"video_model": map[string]any{}}}
				var data any = map[string]any{"1004": entries}
				if form == "ungrouped" {
					data = entries
				}
				encoded, _ := json.Marshal(map[string]any{"code": 0, "data": data})
				return sourceFixtureResponse(request, 200, string(encoded)), nil
			})
			media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
			if err != nil {
				t.Fatal(err)
			}
			if calls != 1 || media.URL != "https://media.example.invalid/main.mp4" || media.Quality != 1080 || media.Duration != 80500*time.Millisecond || len(media.Variants) != 3 {
				t.Fatal("quality, fallback addresses or duration lost")
			}
		})
	}
}

func TestHongguoV5DeviceLevelForNormalAndCompatibleRequests(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		preferCompatibleCodec bool
	}{
		{name: "normal"},
		{name: "compatible", preferCompatibleCodec: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := hongguoMediaRequests("2222", tc.preferCompatibleCodec)
			if len(requests) != 1 {
				t.Fatalf("got %d requests, want one multi-video request", len(requests))
			}
			payload := requests[0].payload
			biz := nestedMap(payload, "biz_param")
			if biz["device_level"] != 3 || biz["video_platform"] != 1024 {
				t.Fatalf("unexpected device capability: %v", biz)
			}
			// 兼容重试只增加编码提示，不能重新提高设备等级或污染普通请求。
			if tc.preferCompatibleCodec {
				if payload["vps"] != 3 || biz["default_codec"] != "h264" {
					t.Fatal("compatible codec hints lost")
				}
			} else if payload["vps"] != nil || biz["default_codec"] != nil {
				t.Fatal("compatible codec hints leaked into normal request")
			}
		})
	}
}

func TestHongguoV5RejectsMissingOrMalformedEpisode(t *testing.T) {
	for _, body := range []string{
		`{"data":{}}`, `{"data":{"1004":{"9999":{"video_model":{}}}}}`,
		`{"data":{"video_model":` + hongguoV5Variants + `}}`,
		`{"data":{"1004":{"2222":{"video_model":"not-json"}}}}`,
		`{"data":{"1004":{"2222":{"video_model":"[]"}}}}`,
		`{"data":{"1004":{"2222":{"video_model":null}}}}`,
	} {
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			return sourceFixtureResponse(request, 200, body), nil
		})
		if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err == nil {
			t.Fatal("missing or malformed episode accepted")
		}
	}
}

func TestHongguoV5DoesNotChangeCatalogOrCommentSigning(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Host != "api5-normal-sinfonlineb.fqnovel.com" || request.Header.Get("User-Agent") != hongguoAppUserAgent || request.URL.Query().Get("version_name") != "7.3.5.32" {
			t.Fatal("playback identity leaked into legacy request")
		}
		if request.Header.Get("X-Helios") != "" || request.Header.Get("X-Medusa") != "" {
			t.Fatal("v5 leaked into legacy request")
		}
		if request.URL.Path != hongguoBookmallTabPath {
			for _, name := range []string{"X-Argus", "X-Ladon", "X-Gorgon", "X-Khronos"} {
				if request.Header.Get(name) == "" {
					t.Fatalf("legacy signature missing: %s", name)
				}
			}
		} else if request.Header.Get("X-Argus") != "" {
			t.Fatal("unsigned catalog was signed")
		}
		return sourceFixtureResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	for _, path := range []string{hongguoBookmallTabPath, "/novel/player/video_detail/v1/", "/novel/player/video_model/v1/", "/novel/commentapi/comment/list/2222/v1/"} {
		ctx := context.Background()
		if strings.Contains(path, "commentapi") {
			ctx = context.WithValue(ctx, hongguoCommentKey{}, true)
		}
		if _, err := d.hongguoAppRequest(ctx, http.MethodPost, path, nil, map[string]any{}); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 4 {
		t.Fatal("legacy request coverage incomplete")
	}
}

func TestHongguoV5CodecHintThenDeviceRotation(t *testing.T) {
	playerCalls, registerCalls := 0, 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registerCalls++
			return sourceFixtureResponse(request, 200, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
		}
		if request.URL.Path != hongguoPlayerModelPath {
			t.Fatal("unexpected request")
		}
		playerCalls++
		var payload map[string]any
		_ = json.NewDecoder(request.Body).Decode(&payload)
		if nestedMap(payload, "biz_param")["device_level"] != float64(3) {
			t.Fatal("normal, compatible or rotated request changed device level")
		}
		if playerCalls > 1 && (payload["vps"] != float64(3) || nestedMap(payload, "biz_param")["default_codec"] != "h264") {
			t.Fatal("compatible codec hints lost")
		}
		if payload["content_type"] != nil || payload["video_id"] != nil || nestedMap(payload, "biz_param")["video_platform"] != float64(1024) {
			t.Fatal("legacy payload leaked into retry")
		}
		model := `{"video_list":[{"main_url":"https://media.example.invalid/vvc.mp4","video_meta":{"codec_type":"bytevc2"}}]}`
		if request.URL.Query().Get("device_id") == "1001" {
			model = hongguoFreshModel
		}
		return sourceFixtureResponse(request, 200, hongguoMultiFixture("2222", model)), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err != nil {
		t.Fatal(err)
	}
	if playerCalls != 3 || registerCalls != 1 {
		t.Fatal("codec retry/rotation count changed")
	}
}

func TestHongguoV5RegistrationNetworkRetry(t *testing.T) {
	registerCalls, playerCalls := 0, 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registerCalls++
			if registerCalls == 1 {
				return nil, errors.New("synthetic EOF")
			}
			return sourceFixtureResponse(request, 200, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
		}
		if request.URL.Path != hongguoPlayerModelPath {
			t.Fatal("unexpected request")
		}
		playerCalls++
		return sourceFixtureResponse(request, 200, hongguoMultiFixture("2222", hongguoFreshModel)), nil
	})
	d.hongguoClient().state.Registered = false
	if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err != nil {
		t.Fatal(err)
	}
	if registerCalls != 2 || playerCalls != 1 {
		t.Fatal("registration retry changed")
	}
}

func TestHongguoV5CancellationAndRateLimit(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		response := sourceFixtureResponse(request, http.StatusTooManyRequests, "")
		response.Header.Set("Retry-After", "60")
		return response, nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := d.resolveHongguoAppMedia(ctx, "2222"); !errors.Is(err, context.Canceled) || calls != 0 {
		t.Fatal("canceled playback reached transport")
	}
	ctx, cancel = context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	if _, err := d.resolveHongguoAppMedia(ctx, "2222"); !errors.Is(err, context.DeadlineExceeded) || calls != 0 {
		t.Fatal("expired playback reached transport")
	}
	if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err == nil || calls != 1 {
		t.Fatal("429 retried or accepted")
	}
	if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err == nil || calls != 1 {
		t.Fatal("rate-limit backoff bypassed")
	}
}

func TestHongguoV5InFlightCancellationAndDeadline(t *testing.T) {
	for _, deadline := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		if deadline {
			cancel()
			ctx, cancel = context.WithTimeout(context.Background(), 25*time.Millisecond)
		}
		calls := 0
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			calls++
			if !deadline {
				cancel()
			}
			<-request.Context().Done()
			return nil, request.Context().Err()
		})
		_, err := d.resolveHongguoAppMedia(ctx, "2222")
		cancel()
		want := context.Canceled
		if deadline {
			want = context.DeadlineExceeded
		}
		if !errors.Is(err, want) || calls > 1 {
			t.Fatal("in-flight cancellation was wrapped or retried")
		}
	}
}

func TestHongguoV5EmptyResponseRotatesAndResigns(t *testing.T) {
	playerCalls, registerCalls := 0, 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/service/2/device_register/" {
			registerCalls++
			return sourceFixtureResponse(request, 200, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
		}
		playerCalls++
		if playerCalls == 1 {
			return sourceFixtureResponse(request, 200, ""), nil
		}
		if request.URL.Query().Get("device_id") != "1001" || request.URL.Query().Get("iid") != "10019" || request.Header.Get("X-Medusa") == "" || request.Header.Get("X-Argus") != "" {
			t.Fatal("rotated playback was not re-signed with v5")
		}
		return sourceFixtureResponse(request, 200, hongguoMultiFixture("2222", hongguoFreshModel)), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err != nil {
		t.Fatal(err)
	}
	if playerCalls != 2 || registerCalls != 1 {
		t.Fatal("empty-response rotation changed")
	}
}

func TestHongguoV5CancellationDuringCodecRetry(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if calls == 2 {
			cancel()
			return nil, context.Canceled
		}
		model := `{"video_list":[{"main_url":"https://media.example.invalid/vvc.mp4","video_meta":{"codec_type":"bytevc2"}}]}`
		return sourceFixtureResponse(request, 200, hongguoMultiFixture("2222", model)), nil
	})
	if _, err := d.resolveHongguoAppMedia(ctx, "2222"); !errors.Is(err, context.Canceled) || calls != 2 {
		t.Fatal("codec retry masked cancellation or registered another device")
	}
}
