package core

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestNativePreloadReadCancellationOwnership(t *testing.T) {
	for _, cancelDuring := range []bool{false, true} {
		name := "completed"
		if cancelDuring {
			name = "in_flight"
		}
		t.Run(name, func(t *testing.T) {
			reached := make(chan struct{}, 1)
			engine := sourceFixtureEngine(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == hongguoVideoTabPath {
					return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", hongguoFreshModel)), nil
				}
				if r.URL.Host != "cdn.example.com" {
					t.Errorf("unexpected host %s", r.URL.Host)
				}
				if cancelDuring && r.URL.Path == "/fresh.mp4" {
					reached <- struct{}{}
					<-r.Context().Done()
					return nil, r.Context().Err()
				}
				response := sourceFixtureResponse(r, 200, "synthetic-mp4")
				response.Header.Set("Content-Type", "video/mp4")
				return response, nil
			})
			current, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoice{media: []providerMedia{{URL: "https://cdn.example.com/current.mp4"}}})
			if err != nil {
				t.Fatal(err)
			}
			defer engine.nativeReleasePlayback(current.Session)
			defer engine.stream.server.Close()
			input := nativeInput{Drama: nativeDrama{ID: "hongguo:11", Source: sourceHongguo}, Chapter: Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://2222"}, Index: 1, Force: true, Session: "probe:preload", Sequence: 1}
			parent, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			ctx, finish, err := engine.beginRead(parent, input)
			if err != nil {
				t.Fatal(err)
			}
			type outcome struct {
				plan nativePlan
				err  error
			}
			done := make(chan outcome, 1)
			go func() { p, e := engine.nativePreload(ctx, input); finish(); done <- outcome{p, e} }()
			if cancelDuring {
				select {
				case <-reached:
				case <-parent.Done():
					t.Fatal("preload never reached media")
				}
				engine.cancelRead(input)
			}
			var result outcome
			select {
			case result = <-done:
			case <-parent.Done():
				t.Fatal("preload did not settle")
			}
			if cancelDuring {
				if !errors.Is(result.err, context.Canceled) {
					t.Fatalf("want canceled, got %v", result.err)
				}
				engine.mu.Lock()
				count := len(engine.playbacks)
				engine.mu.Unlock()
				if count != 1 {
					t.Fatalf("cancelled preload leaked playback: %d", count)
				}
			} else {
				if result.err != nil || result.plan.PrefetchedBytes == 0 {
					t.Fatalf("preload failed: %v", result.err)
				}
				defer engine.nativeReleasePlayback(result.plan.Session)
				engine.cancelRead(input)
				status, _, body := preloadTestGet(t, result.plan.URL, "")
				if status != 200 || string(body) != "synthetic-mp4" {
					t.Fatalf("completed plan killed by read finish/cancel: %d", status)
				}
			}
			status, _, body := preloadTestGet(t, current.URL, "")
			if status != 200 || string(body) != "synthetic-mp4" {
				t.Fatalf("current playback interrupted: %d", status)
			}
		})
	}
}
