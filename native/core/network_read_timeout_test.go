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

func TestIdleReadBodyCancelsStalledResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, server.URL, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body := &idleReadBody{ReadCloser: response.Body, cancel: cancel, timeout: 50 * time.Millisecond}
	defer body.Close()
	_, err = io.ReadAll(body)
	if err == nil || !errors.Is(ctx.Err(), context.Canceled) {
		t.Fatalf("stalled read did not cancel its request: %v / %v", err, ctx.Err())
	}
}

func TestIdleReadBodyDoesNotTimeOutPausedConsumer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	body := &idleReadBody{
		ReadCloser: io.NopCloser(strings.NewReader("ab")),
		cancel: cancel, timeout: 10 * time.Millisecond,
	}
	defer body.Close()
	buffer := make([]byte, 1)
	if n, err := body.Read(buffer); n != 1 || err != nil {
		t.Fatalf("first read: %d %v", n, err)
	}
	// 暂停消费远长于读取时限，不能误判为上游没有发送数据。
	select {
	case <-ctx.Done():
		t.Fatal("consumer pause canceled request")
	case <-time.After(50 * time.Millisecond):
	}
	if n, err := body.Read(buffer); n != 1 || err != nil || buffer[0] != 'b' {
		t.Fatalf("resume read: %d %v %q", n, err, buffer)
	}
}
