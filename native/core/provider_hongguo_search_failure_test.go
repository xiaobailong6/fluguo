package core

import (
	"context"
	"errors"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestHongguoPartialSearchPreservesFailure(t *testing.T) {
	until := time.Now().Add(time.Minute)
	for _, row := range []struct {
		name    string
		failure error
		code    string
	}{
		{"timeout", context.DeadlineExceeded, "timeout"},
		{"network", &net.DNSError{Err: "offline", Name: "fixture.invalid"}, "network"},
		{"blocked", &requestBackoff{host: "fixture.invalid", status: 429, until: until}, "source_blocked"},
	} {
		t.Run(row.name, func(t *testing.T) {
			engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "/incent_resource/suggestion" {
					return sourceFixtureResponse(request, 200, `{"suggest_list":[{"name":"合成剧","word_type":"short_play_name","video_data":{"series_id_str":"123456","series_title":"合成剧"}}]}`), nil
				}
				if request.URL.Path == hongguoSearchTabPath {
					return nil, row.failure
				}
				t.Errorf("unexpected fixture path %s", request.URL.Path)
				return nil, errors.New("unexpected fixture request")
			})
			result, err := engine.nativeCatalog(context.Background(), nativeInput{Source: sourceHongguo, Query: "合成剧", Page: 1})
			if err != nil || len(result.Items) != 1 || result.Warning == "" {
				t.Fatalf("partial result lost: %+v, %v", result, err)
			}
			if result.WarningDetails == nil || result.WarningDetails.Code != row.code {
				t.Fatalf("structured error lost: %+v, want %s", result.WarningDetails, row.code)
			}
			if row.code == "source_blocked" && (result.WarningDetails.RetryAt == nil || !result.WarningDetails.RetryAt.Equal(until)) {
				t.Fatal("backoff time lost")
			}
		})
	}
}
