package core

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"testing"
	"time"
)

const helperCodecModel = `{"video_list":[{"main_url":"https://cdn.invalid/vvc.mp4","video_meta":{"codec_type":"bytevc2"}}]}`
const helperNoAddressModel = `{"video_list":[{"video_meta":{"codec_type":"h264"}}]}`

func TestHongguoHelperRetryBoundedAndIdentity(t *testing.T) {
	for _, model := range []string{helperCodecModel, helperNoAddressModel} {
		for successAt := 1; successAt <= 4; successAt++ {
			t.Run(model+string(rune('0'+successAt)), func(t *testing.T) {
				var identities []string
				registers := 0
				d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
					if r.Context().Value(proxySourceKey{}) != sourceHongguo {
						t.Fatal("lost source on media or registration")
					}
					if r.URL.Path == "/service/2/device_register/" {
						registers++
						return sourceFixtureResponse(r, 200, `{"device_id_str":"3001","install_id_str":"3002"}`), nil
					}
					if r.URL.Path != hongguoVideoTabPath {
						t.Fatalf("no-compatible-media must not repeat through player: %s", r.URL.Path)
					}
					identities = append(identities, r.URL.Query().Get("device_id")+":"+r.URL.Query().Get("iid"))
					if r.URL.Query().Has("vps") || r.URL.Query().Has("default_codec") {
						t.Fatal("video_tab received ineffective codec hints")
					}
					body := model
					if len(identities) == successAt {
						body = hongguoFreshModel
					}
					return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", body)), nil
				})
				client := d.hongguoClient()
				client.state.DeviceID, client.state.InstallID = "1001", "1002"
				media, err := d.resolveHongguoAppMedia(context.Background(), "2222")
				want := []string{"1001:1002", "424242:4242429", "3001:3002"}[:min(successAt, 3)]
				if !reflect.DeepEqual(identities, want) || registers != max(0, min(successAt-2, 1)) {
					t.Fatalf("identities=%v registers=%d want=%v", identities, registers, want)
				}
				if successAt <= 3 && (err != nil || media.URL != "https://cdn.example.com/fresh.mp4") || successAt == 4 && !isHongguoNoCompatibleMedia(err) {
					t.Fatalf("unexpected result: %s %v", media.URL, err)
				}
				if client.state.DeviceID != "1001" || client.state.InstallID != "1002" || !client.state.Registered {
					t.Fatal("helper retry reset primary identity")
				}
			})
		}
	}
}

func TestHongguoHelperRetryStopsForCancellationBackoffAndCooldown(t *testing.T) {
	for _, scenario := range []string{"cancel-main", "cancel-helper", "cancel-register", "rate-main", "rate-helper", "rate-register", "reject-register", "paused-register"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			mediaCalls, registerCalls := 0, 0
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/service/2/device_register/" {
					registerCalls++
					switch scenario {
					case "cancel-register":
						cancel()
						return nil, context.Canceled
					case "rate-register":
						return sourceFixtureResponse(r, 429, `{}`), nil
					case "reject-register":
						return sourceFixtureResponse(r, 200, `{}`), nil
					default:
						t.Fatal("unexpected registration")
					}
				}
				if r.URL.Path != hongguoVideoTabPath {
					t.Fatal("unexpected player fallback", r.URL.Path)
				}
				mediaCalls++
				if scenario == "cancel-main" && mediaCalls == 1 || scenario == "cancel-helper" && mediaCalls == 2 {
					cancel()
				}
				if scenario == "rate-main" && mediaCalls == 1 || scenario == "rate-helper" && mediaCalls == 2 {
					return sourceFixtureResponse(r, 429, `{}`), nil
				}
				return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", helperNoAddressModel)), nil
			})
			client := d.hongguoClient()
			primary, install, _ := client.device(false)
			pause := time.Now().Add(time.Hour)
			if scenario == "paused-register" {
				client.registerPausedUntil, client.registerPauseErr = pause, errors.New("fixture rejection")
			}
			_, err := d.resolveHongguoAppMedia(ctx, "2222")
			if err == nil {
				t.Fatal("failure swallowed")
			}
			wantMedia, wantRegister := 2, 0
			if scenario == "cancel-main" || scenario == "rate-main" {
				wantMedia = 1
			}
			if scenario == "cancel-register" || scenario == "rate-register" || scenario == "reject-register" {
				wantRegister = 1
			}
			if mediaCalls != wantMedia || registerCalls != wantRegister {
				t.Fatalf("calls=%d,%d want=%d,%d", mediaCalls, registerCalls, wantMedia, wantRegister)
			}
			if scenario[:6] == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatalf("lost cancellation: %v", err)
			}
			if scenario[:4] == "rate" {
				var backoff *requestBackoff
				if !errors.As(err, &backoff) {
					t.Fatalf("lost backoff: %v", err)
				}
			}
			if scenario == "reject-register" && !client.registerPausedUntil.After(time.Now()) || scenario == "paused-register" && !client.registerPausedUntil.Equal(pause) {
				t.Fatal("registration cooldown was reset")
			}
			if id, iid, _ := client.device(false); id != primary || iid != install {
				t.Fatal("primary identity changed")
			}
		})
	}
}

func TestHongguoPrimaryRegistrationRateLimitStopsImmediately(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != "/service/2/device_register/" {
			t.Fatal("requested media during registration backoff")
		}
		return sourceFixtureResponse(r, 429, `{}`), nil
	})
	d.hongguoClient().state.Registered = false
	_, err := d.resolveHongguoAppMedia(context.Background(), "2222")
	var backoff *requestBackoff
	if !errors.As(err, &backoff) || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestHongguoRegistrationHonorsExplicitSourceProxy(t *testing.T) {
	calls := 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Context().Value(proxySourceKey{}) != sourceHongguo {
			t.Fatal("registration lost source")
		}
		return nil, errors.New("synthetic proxy failure")
	})
	engine := &nativeEngine{downloader: d}
	d.proxyRouter = &proxyRouter{}
	settings := defaultResourceSettings()
	settings.SourceProxies = map[string]nativeSourceProxy{"hongguo": {Mode: "manual", URL: "http://proxy.invalid:7890"}}
	engine.applyResourceSettings(settings)
	// 即使发生回归也不得发真实直连请求。
	d.directOnce.Do(func() {
		d.directClient = &http.Client{Transport: sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
			t.Error("explicit source override bypassed by direct registration")
			return nil, errors.New("offline direct guard")
		})}
	})
	if _, _, err := d.registerHongguoDevice(context.Background()); err == nil || calls != 1 {
		t.Fatalf("registration calls=%d err=%v", calls, err)
	}
}
