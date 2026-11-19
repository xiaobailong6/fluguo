package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNativeStreamReadTimeoutAfterHeaders(t *testing.T) {
	canceled := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(canceled)
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	stream.readTimeout = 50 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, upstream.URL, nil)
	response, err := stream.nativeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	_, err = io.ReadAll(response.Body)
	if !errors.Is(err, context.DeadlineExceeded) || ctx.Err() != nil {
		t.Fatalf("read did not expire independently: read=%v parent=%v", err, ctx.Err())
	}
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("stalled upstream was not canceled")
	}
}

func TestNativeStreamReadTimeoutAllowsContinuousProgress(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < 20; i++ {
			_, _ = io.WriteString(w, "x")
			w.(http.Flusher).Flush()
			select {
			case <-time.After(25 * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	stream.readTimeout = 200 * time.Millisecond
	// 原 client 的总时限仍可供 API 使用，播放请求不能继承它。
	stream.downloader.client.Timeout = 100 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, upstream.URL, nil)
	response, err := stream.nativeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != strings.Repeat("x", 20) {
		t.Fatalf("active stream truncated: %q / %v", body, err)
	}
	if stream.downloader.client.Timeout != 100*time.Millisecond {
		t.Fatal("shared API timeout was changed")
	}
}

func TestNativeStreamReadTimeoutPauseAndClose(t *testing.T) {
	canceled := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ab")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(canceled)
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	stream.readTimeout = 40 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, upstream.URL, nil)
	response, err := stream.nativeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	buffer := make([]byte, 1)
	if _, err := io.ReadFull(response.Body, buffer); err != nil || buffer[0] != 'a' {
		t.Fatalf("first byte: %q / %v", buffer, err)
	}
	select {
	case <-canceled:
		t.Fatal("consumer pause canceled upstream")
	case <-time.After(200 * time.Millisecond):
	}
	if _, err := io.ReadFull(response.Body, buffer); err != nil || buffer[0] != 'b' {
		t.Fatalf("resume: %q / %v", buffer, err)
	}
	response.Body.Close()
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("Close did not promptly cancel paused upstream")
	}
}

func TestNativeStreamReleaseCancelsBlockedBody(t *testing.T) {
	entered, canceled := make(chan struct{}), make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		close(entered)
		<-r.Context().Done()
		close(canceled)
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	stream.readTimeout = time.Minute
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
	defer stream.nativeRelease(token)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, entry, nil)
	done := make(chan struct{})
	go func() {
		defer close(done)
		response, err := http.DefaultClient.Do(request)
		if err == nil {
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
		}
	}()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("upstream not entered")
	}
	stream.nativeRelease(token)
	for _, signal := range []<-chan struct{}{canceled, done} {
		select {
		case <-signal:
		case <-time.After(time.Second):
			t.Fatal("release did not cancel blocked body promptly")
		}
	}
}

type streamTimeoutRoundTripper func(*http.Request) (*http.Response, error)

func (trip streamTimeoutRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return trip(request)
}

func TestNativeStreamReadTimeoutReusesBrowserGuard(t *testing.T) {
	var guarded *idleReadBody
	var upstreamContext context.Context
	browserCanceled := false
	base := streamTimeoutRoundTripper(func(request *http.Request) (*http.Response, error) {
		upstreamContext = request.Context()
		guarded = &idleReadBody{
			ReadCloser: io.NopCloser(strings.NewReader("ok")),
			cancel:     func() { browserCanceled = true }, timeout: time.Minute,
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: guarded}, nil
	})
	transport := &idleReadTransport{base: base, timeout: 50 * time.Millisecond}
	request, _ := http.NewRequest(http.MethodGet, "http://fixture.invalid", nil)
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.Body != guarded || guarded.timeout != transport.timeout {
		t.Fatal("browser guard was double wrapped or timeout was not configured")
	}
	response.Body.Close()
	if !browserCanceled || upstreamContext.Err() != context.Canceled {
		t.Fatal("Close lost a request cancellation")
	}
}
