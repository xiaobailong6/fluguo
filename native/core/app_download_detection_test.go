package core

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeDownloadDetectsExtensionlessHLSAfterRedirect(t *testing.T) {
	for _, contentType := range []string{"application/vnd.apple.mpegurl", "application/octet-stream"} {
		t.Run(contentType, func(t *testing.T) {
			manager := downloadTestManager(t)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/play":
					http.Redirect(w, r, "/nested/playlist", http.StatusFound)
				case "/nested/playlist":
					w.Header().Set("Content-Type", contentType)
					fmt.Fprint(w, "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n")
				case "/nested/segment.ts":
					w.Header().Set("Content-Type", "video/mp2t")
					fmt.Fprint(w, "downloaded-segment")
				default:
					http.NotFound(w, r)
				}
			}))
			defer upstream.Close()
			drama := nativeDrama{ID: "hongguo:876", Source: "hongguo", Title: "格式识别"}
			job := nativeDownloadJob{ID: nativeDownloadID(drama.ID, 1), Drama: drama, Index: 1}
			result, err := manager.transferMedia(context.Background(), job, providerMedia{URL: upstream.URL + "/play"})
			if err != nil {
				t.Fatal(err)
			}
			if result.file != "index.m3u8" {
				t.Fatalf("playlist published as %q", result.file)
			}
			directory := manager.jobDirectory(job)
			body, err := os.ReadFile(filepath.Join(directory, result.file))
			if err != nil || strings.Contains(string(body), "http") {
				t.Fatalf("playlist not localized: %s %v", body, err)
			}
			name := nativeDownloadAssetName(upstream.URL+"/nested/segment.ts", ".ts")
			segment, err := os.ReadFile(filepath.Join(directory, name))
			if err != nil || string(segment) != "downloaded-segment" {
				t.Fatalf("redirect-relative segment missing: %s %v", segment, err)
			}
			if _, err := os.Stat(filepath.Join(directory, "media.mp4")); !os.IsNotExist(err) {
				t.Fatal("fake MP4 left behind")
			}
		})
	}
}
