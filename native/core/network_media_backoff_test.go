package core

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestMediaBackoffKeepsDirectoryAvailable(t *testing.T) {
	for _, test := range []struct {
		name    string
		status  int
		headers http.Header
		body    string
		blocked bool
	}{
		{"expired", 403, http.Header{}, "expired media URL", false},
		{"rate-limit", 429, http.Header{"Retry-After": {"2"}}, "slow down", true},
		{"retry-after", 403, http.Header{"Retry-After": {"2"}}, "slow down", true},
		{"challenge-header", 403, http.Header{"Cf-Mitigated": {"challenge"}}, "verify", true},
		{"challenge-body", 403, http.Header{}, "<html><script>_cf_chl_opt = {}</script></html>", true},
		{"normal-media", 200, http.Header{}, "synthetic-media", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				response := sourceFixtureResponse(request, test.status, test.body)
				response.Header = test.headers
				return response, nil
			})
			d.limiter = newRequestLimiter(1, 0)
			request, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://fixture.invalid/media", nil)
			response, err := d.doMediaRequest(request)
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(response.Body)
			response.Body.Close()
			if err != nil || string(body) != test.body {
				t.Fatal("response body changed", err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			directory, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://fixture.invalid/catalog", nil)
			release, err := d.limiter.acquire(ctx, directory)
			if (err != nil) != test.blocked {
				t.Fatalf("blocked=%v err=%v", test.blocked, err)
			}
			if release != nil {
				release()
			}
		})
	}
}

func TestMediaBackoffBodyBoundAndReadSemantics(t *testing.T) {
	limiter := newRequestLimiter(1, 0)
	request, _ := http.NewRequest(http.MethodGet, "https://fixture.invalid/media", nil)
	response := &http.Response{StatusCode: 403, Header: http.Header{}}
	payload := strings.Repeat("x", 64<<10) + "_cf_chl_opt"
	body := &mediaBackoffBody{ReadCloser: io.NopCloser(strings.NewReader(payload)), limiter: limiter, request: request, response: response}
	data, err := io.ReadAll(body)
	body.Close()
	if err != nil || string(data) != payload || !body.finished || body.prefix != nil || len(limiter.backoffs) != 0 {
		t.Fatal("prefix bound or body preservation failed", err)
	}
	// 目录请求仍保持原有单次 403 退避，不改变用户设置或全局策略。
	limiter.observe(request, response)
	if len(limiter.backoffs) != 1 {
		t.Fatal("catalog backoff changed")
	}
}
