package core

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeHLSPortraitQuality(t *testing.T) {
	for _, test := range []struct {
		name, first, second string
		quality, want       int
		uri                 string
	}{
		{"portrait", "720x1280", "1080x1920", 720, 720, "first.m3u8"},
		{"landscape", "1280x720", "1920x1080", 720, 720, "first.m3u8"},
		{"square", "720x720", "1080x1080", 720, 720, "first.m3u8"},
		{"automatic", "720x1280", "1080x1920", 0, 1080, "second.m3u8"},
		{"invalid", "bad", "1080x1920", 720, 1080, "second.m3u8"},
	} {
		t.Run(test.name, func(t *testing.T) {
			lines := []string{"#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=" + test.first, "first.m3u8", "#EXT-X-STREAM-INF:BANDWIDTH=200,RESOLUTION=" + test.second, "second.m3u8"}
			selected, actual, master := nativeHLSSelect(lines, test.quality)
			if !master || actual != test.want || !strings.Contains(strings.Join(selected, "\n"), test.uri) {
				t.Fatalf("selection = %v %d %v", selected, actual, master)
			}
		})
	}
}

func TestNativeDownloadConnectionClassification(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := nativeDownloadConnectionError(ctx, ctx, errors.New("network")); !errors.Is(err, context.Canceled) {
		t.Fatal("user cancellation lost", err)
	}
	if err := nativeDownloadConnectionError(context.Background(), ctx, errors.New("network")); !strings.Contains(err.Error(), "30 秒") {
		t.Fatal("inactivity timeout lost", err)
	}
	cause := &net.DNSError{Err: "timeout", Name: "fixture.invalid", IsTimeout: true}
	err := nativeDownloadConnectionError(context.Background(), context.Background(), &url.Error{Op: "Get", URL: "https://fixture.invalid/media?secret=hidden", Err: cause})
	if !errors.Is(err, cause) || !strings.Contains(err.Error(), "超时") || strings.Contains(err.Error(), "secret") {
		t.Fatal("timeout cause or redaction lost", err)
	}
	err = nativeDownloadConnectionError(context.Background(), context.Background(), errors.New("proxy https://user:private@fixture.invalid/a?signature=secret failed"))
	if strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "signature=secret") || !strings.Contains(err.Error(), "连接失败") {
		t.Fatal("unsafe transport message", err)
	}
}

func TestNativeDownloadConnectionFailureKeepsPartial(t *testing.T) {
	manager := downloadTestManager(t)
	target := filepath.Join(manager.root, "offline.mp4")
	if err := os.WriteFile(target+".part", []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	manager.engine.downloader.client.Transport = sourceFixtureTransport(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("synthetic TLS failure")
	})
	_, _, err := manager.downloadFileAttempt(context.Background(), "https://fixture.invalid/a?token=secret", "", target, false, 8, nativeDownloadFileState{}, func(int64, int64) {})
	if err == nil || !strings.Contains(err.Error(), "synthetic TLS failure") || strings.Contains(err.Error(), "token=secret") {
		t.Fatal("connection error not preserved safely", err)
	}
	if body, err := os.ReadFile(target + ".part"); err != nil || string(body) != "existing" {
		t.Fatal("partial changed on connection failure", err)
	}
}

func TestDownloadMigrationCleanupFailureIsDiagnosticOnly(t *testing.T) {
	engine, _ := storageFixture(t)
	source := filepath.Join(t.TempDir(), "old")
	root := engine.downloads.root
	engine.cleanupMovedDownloads(source, func(path string) error {
		if path != source {
			t.Fatal("wrong cleanup path")
		}
		return errors.New("synthetic file in use")
	})
	if engine.downloads.root != root {
		t.Fatal("cleanup failure changed committed root")
	}
	body, err := os.ReadFile(filepath.Join(engine.directory, "logs", "app.log"))
	if err != nil || !strings.Contains(string(body), "storage.download_migration_leftover") || !strings.Contains(string(body), "synthetic file in use") {
		t.Fatal("missing leftover diagnostic", err)
	}
}
