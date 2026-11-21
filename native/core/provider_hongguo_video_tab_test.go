package core

import (
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

func hongguoTabFixture(id, model string) string {
	return `{"code":0,"data":{"video_model_data":{"` + id + `":{"video_model":` + quoteJSON(model) + `}}}}`
}

func TestHongguoVideoTabPrefersSignedGET(t *testing.T) {
	for _, form := range []string{"json", "object", "base64", "flat"} {
		t.Run(form, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != http.MethodGet || r.URL.Path != hongguoVideoTabPath || r.URL.Host != "api5-normal-sinfonlineb.fqnovel.com" {
					t.Fatal("wrong tab endpoint", r.URL)
				}
				q := r.URL.Query()
				for key, want := range map[string]string{"video_id": "2222", "video_id_type": "0", "device_level": "1", "need_all_video_definition": "1", "need_mp4_align": "0", "use_os_player": "0", "video_platform": "1024", "source": "0", "from_video_id": "", "version_name": "7.4.5.32", "version_code": "74532", "manifest_version_code": "74532", "update_version_code": "74532", "channel": "update_64", "device_type": "25053RT47C", "os_version": "16"} {
					if q.Get(key) != want || !q.Has(key) {
						t.Fatalf("query %s=%q want %q", key, q.Get(key), want)
					}
				}
				if r.Header.Get("User-Agent") != hongguoPlaybackUserAgent {
					t.Fatal("wrong v5 UA")
				}
				for _, key := range []string{"X-Helios", "X-Medusa", "X-Khronos"} {
					if r.Header.Get(key) == "" {
						t.Fatal("missing v5 header", key)
					}
				}
				for _, key := range []string{"X-Gorgon", "X-Argus", "X-Ladon", "X-SS-STUB", "X-XS-From-Web", "Sdk-Version", "Cookie", "Content-Type"} {
					if r.Header.Get(key) != "" {
						t.Fatal("unexpected header", key)
					}
				}
				if b, _ := io.ReadAll(r.Body); len(b) != 0 {
					t.Fatal("GET has body")
				}
				if _, ok := r.Context().Deadline(); !ok {
					t.Fatal("lost timeout")
				}
				stamp, _ := strconv.ParseUint(r.Header.Get("X-Khronos"), 10, 32)
				hash := hongguoSM3([]byte(r.URL.RawQuery))
				var zero [md5.Size]byte
				if hongguoV5IV(hash[:], zero[:], uint32(stamp))&15 != 12 {
					t.Fatal("GET signed with incorrect body hash")
				}
				var model map[string]any
				_ = json.Unmarshal([]byte(hongguoV5Variants), &model)
				entry := map[string]any{"video_model": any(hongguoV5Variants)}
				switch form {
				case "object":
					entry["video_model"] = model
				case "base64":
					entry["video_model"] = base64.StdEncoding.EncodeToString([]byte(hongguoV5Variants))
				case "flat":
					entry = model
				}
				body, _ := json.Marshal(map[string]any{"code": 0, "data": map[string]any{"video_model_data": map[string]any{"2222": entry}}})
				return sourceFixtureResponse(r, 200, string(body)), nil
			})
			media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
			if err != nil {
				t.Fatal(err)
			}
			if calls != 1 || media.URL != "https://media.example.invalid/main.mp4" || media.Quality != 1080 || media.Duration != 80500*time.Millisecond || len(media.Variants) != 3 {
				t.Fatal("tab selection lost media metadata", calls, media)
			}
		})
	}
}

func TestHongguoVideoTabFailureFallsBackToPlayer(t *testing.T) {
	for _, body := range []string{`{"data":{}}`, `{"data":{"video_model_data":{"9999":{"video_model":{}}}}}`, `{"data":{"video_model_data":{"2222":{"video_model":"not-json"}}}}`, `{"code":403}`, `not-json`} {
		var paths []string
		d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
			paths = append(paths, r.URL.Path)
			if r.URL.Path == hongguoVideoTabPath {
				return sourceFixtureResponse(r, 200, body), nil
			}
			return sourceFixtureResponse(r, 200, hongguoMultiFixture("2222", hongguoFreshModel)), nil
		})
		media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
		if err != nil || media.URL != "https://cdn.example.com/fresh.mp4" || len(paths) != 2 || paths[0] != hongguoVideoTabPath || paths[1] != hongguoPlayerModelPath {
			t.Fatalf("fallback failed: %v %v", paths, err)
		}
	}
}

func TestHongguoVideoTabCodecRetriesWithoutPlayer(t *testing.T) {
	calls, registers := 0, 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			registers++
			return sourceFixtureResponse(r, 200, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
		}
		if r.URL.Path != hongguoVideoTabPath {
			t.Fatal("codec failure fell through to player")
		}
		calls++
		model := `{"video_list":[{"main_url":"https://media.example.invalid/vvc.mp4","video_meta":{"codec_type":"bytevc2"}}]}`
		if r.URL.Query().Get("device_id") == "1001" {
			model = hongguoFreshModel
		}
		return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", model)), nil
	})
	if _, err := d.resolveHongguoAppMedia(context.Background(), "2222"); err != nil {
		t.Fatal(err)
	}
	if calls != 3 || registers != 1 {
		t.Fatal("codec rotation changed", calls, registers)
	}
}

func TestHongguoVideoTabFailuresKeepBothReasons(t *testing.T) {
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(r, 200, `{"data":{}}`), nil
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "2222")
	if err == nil || !strings.Contains(err.Error(), "video_tab") || !strings.Contains(err.Error(), "播放器接口") {
		t.Fatal("lost failure reasons", err)
	}
}

func TestHongguoVideoTabUsesDashFallbackBeforePlayer(t *testing.T) {
	var paths []string
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.Path)
		if r.URL.Path == hongguoVideoTabPath {
			return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", hongguoDashOnlyModel)), nil
		}
		if r.URL.Host == "vas-lf-x.snssdk.com" {
			if r.URL.Query().Get("format_type") != "mp4" {
				t.Fatal("fallback must request progressive mp4")
			}
			return sourceFixtureResponse(r, 200, hongguoFallbackBody), nil
		}
		return sourceFixtureResponse(r, 200, `{"data":{}}`), nil
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
	if err != nil || media.URL != "https://cdn.example.com/movie.mp4" || len(paths) != 2 {
		t.Fatalf("tab DASH fallback lost: paths=%v err=%v", paths, err)
	}
}
