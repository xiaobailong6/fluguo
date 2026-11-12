package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"strings"
	"time"
)

func TestHuangguoBrowserStreamsBeyondFormerTimeout(t *testing.T) {
	if testing.Short() {
		t.Skip("requires 46 seconds to cross the former browser timeout")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "first")
		w.(http.Flusher).Flush()
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		finished := time.NewTimer(46 * time.Second)
		defer finished.Stop()
		for {
			select {
			case <-ticker.C:
				_, _ = io.WriteString(w, ".")
				w.(http.Flusher).Flush()
			case <-finished.C:
				_, _ = io.WriteString(w, "last")
				return
			case <-r.Context().Done():
				return
			}
		}
	}))
	defer server.Close()
	d := sourceFixtureDownloader(t, nil)
	d.cfg.HuangguoVideoURL = server.URL
	d.proxyRouter = &proxyRouter{}
	transport := newHuangguoBrowserTransport(http.DefaultTransport, d)
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	ctx, cancel := context.WithTimeout(context.Background(), 55*time.Second)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, server.URL, nil)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || !strings.HasPrefix(string(body), "first") || !strings.HasSuffix(string(body), "last") {
		t.Fatalf("browser truncated active response: %q %v", body, err)
	}
}

func TestHuangguoBrowserHonorsOuterDeadline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	d := sourceFixtureDownloader(t, nil)
	d.cfg.HuangguoVideoURL = server.URL
	d.proxyRouter = &proxyRouter{}
	transport := newHuangguoBrowserTransport(http.DefaultTransport, d)
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 100 * time.Millisecond}
	response, err := client.Get(server.URL)
	if response != nil {
		response.Body.Close()
	}
	if err == nil {
		t.Fatal("ordinary request lost outer deadline")
	}
}
