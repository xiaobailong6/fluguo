package core

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestHongguoMediaCodecFallback(t *testing.T) {
	const endpoint = "https://vas-lf-x.snssdk.com/video/fplay/1/test/video?token=a%20b&codec_type=4&stream_type=encrypt"
	const model = `{"fallback_api":{"fallback_api":"` + endpoint + `"},"video_list":[{"main_url":"https://media.example.invalid/vvc.mp4","video_meta":{"codec_type":"bytevc2"}}]}`
	// 独立生成的 AES-CBC 测试向量，不依赖生产代码生成密文。
	const compatible = `{"video_info":{"data":{"video_duration":80.5,"key_seed":"c3ludGhldGljLXBsYXktdXJsLXNlZWQtdmFsdWU=","video_list":{"video_1":{"codec_type":"h265","definition":"1080p","main_url":"qAABALUkO1MRVTUg+MSemgpTZZVSP0rNJcYa/ZvyhQOF0DBl0BkmeRs0vWldWTnt/sKIRQ==","backup_url_1":"https://media.example.invalid/backup.mp4"}}}}}`
	const incompatible = `{"video_info":{"data":{"video_list":[{"codec_type":"bytevc2","main_url":"https://media.example.invalid/vvc.mp4"}]}}}`

	for _, usePlayer := range []bool{false, true} {
		name := "video_tab"
		if usePlayer {
			name = "player"
		}
		t.Run(name, func(t *testing.T) {
			var calls []string
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				switch r.URL.Path {
				case hongguoVideoTabPath:
					calls = append(calls, "tab")
					if usePlayer {
						return sourceFixtureResponse(r, 200, `{"code":0,"data":{}}`), nil
					}
					return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", model)), nil
				case hongguoPlayerModelPath:
					calls = append(calls, "player")
					return sourceFixtureResponse(r, 200, hongguoMultiFixture("2222", model)), nil
				case "/video/fplay/1/test/video":
					query := r.URL.Query()
					codec := query.Get("codec_type")
					calls = append(calls, codec)
					if r.Method != http.MethodGet || r.URL.Host != "vas-lf-x.snssdk.com" || r.Header.Get("User-Agent") != hongguoPlaybackUserAgent || r.URL.RawQuery != "token=a%20b&codec_type="+codec+"&stream_type=encrypt" {
						t.Fatalf("unexpected fallback request: %s %s", r.Method, r.URL)
					}
					if usePlayer && codec == "1" {
						return sourceFixtureResponse(r, 200, incompatible), nil
					}
					return sourceFixtureResponse(r, 200, compatible), nil
				default:
					t.Fatalf("unexpected request: %s", r.URL)
					return nil, nil
				}
			})
			media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
			if err != nil {
				t.Fatal(err)
			}
			if media.URL != "https://media.example.invalid/h265.mp4" || media.Quality != 1080 || media.Duration != 80500*time.Millisecond || len(media.Variants) != 2 || media.Variants[1].URL != "https://media.example.invalid/backup.mp4" {
				t.Fatalf("unexpected fallback media: %+v", media)
			}
			want := []string{"tab", "1"}
			if usePlayer {
				want = []string{"tab", "player", "1", "3"}
			}
			if !reflect.DeepEqual(calls, want) {
				t.Fatalf("requests = %v, want %v", calls, want)
			}
		})
	}
}

func TestHongguoMediaFallbackWithoutPrimaryAddresses(t *testing.T) {
	const model = `{"fallback_api":{"fallback_api":"https://vas-lf-x.snssdk.com/video/fplay/test"},"video_list":[{"video_meta":{"codec_type":"h264"}}]}`
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case hongguoVideoTabPath:
			return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", model)), nil
		case "/video/fplay/test":
			if r.URL.RawQuery != "codec_type=1" {
				t.Fatalf("unexpected fallback query: %s", r.URL.RawQuery)
			}
			return sourceFixtureResponse(r, 200, `{"video_info":{"data":{"video_list":[{"main_url":"https://media.example.invalid/plain.mp4","codec_type":"h265"}]}}}`), nil
		default:
			t.Fatalf("unexpected request: %s", r.URL)
			return nil, nil
		}
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
	if err != nil || media.URL != "https://media.example.invalid/plain.mp4" {
		t.Fatalf("fallback did not recover missing addresses: %q, %v", media.URL, err)
	}
}

func TestHongguoFallbackReportsUnsupportedAddressVersion(t *testing.T) {
	entry := map[string]any{"main_url": "qAACAAcHBwcHBwcHBwcHBwcHBwc="}
	data := map[string]any{"key_seed": "c3ludGhldGljLXBsYXktdXJsLXNlZWQtdmFsdWU=", "video_list": []any{entry}}
	if _, err := hongguoFallbackCodecVariants(data); err == nil || !strings.Contains(err.Error(), "编码版本 2") {
		t.Fatalf("missing version error: %v", err)
	}
	entry["backup_url_1"] = "https://media.example.invalid/plain.mp4"
	model, err := hongguoFallbackCodecVariants(data)
	if err != nil {
		t.Fatal(err)
	}
	media, err := selectHongguoAppMedia(model)
	if err != nil || media.URL != entry["backup_url_1"] {
		t.Fatalf("valid backup address lost: %q, %v", media.URL, err)
	}
}
