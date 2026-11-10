package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeDownloadRestartFailureOrdering(t *testing.T) {
	for _, failure := range []string{"truncate", "metadata"} {
		t.Run(failure, func(t *testing.T) {
			manager := downloadTestManager(t)
			target := filepath.Join(manager.root, "restart.mp4")
			data := []byte("NEW!-the-entire-new-response")
			ranges := make(chan string, 4)
			validators := make(chan string, 4)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ranges <- r.Header.Get("Range")
				validators <- r.Header.Get("If-Range")
				w.Header().Set("ETag", "\"new\"")
				w.Header().Set("Content-Type", "video/mp4")
				// 同 URL 已变化，忽略旧 Range 并返回完整 200。
				_, _ = w.Write(data)
			}))
			t.Cleanup(upstream.Close)
			old := nativeDownloadFileState{URL: upstream.URL, Validator: "\"old\"", Total: int64(len(data))}
			encoded, _ := json.Marshal(old)
			if err := os.WriteFile(target+".json", encoded, 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(target+".part", []byte("OLD!"), 0600); err != nil {
				t.Fatal(err)
			}
			blocked := target + ".part"
			if failure == "metadata" {
				blocked = target + ".json"
			}
			// 用非空目录制造确定性的文件操作失败，不依赖 chmod/管理员权限。
			if err := os.Rename(blocked, blocked+".saved"); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(blocked, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(blocked, "block"), []byte("block"), 0600); err != nil {
				t.Fatal(err)
			}
			if _, restart, err := manager.downloadFileAttempt(context.Background(), old.URL, "", target, false, 4, old, func(int64, int64) {}); err == nil || restart {
				t.Fatalf("expected storage failure: restart=%v err=%v", restart, err)
			}
			if got := <-ranges; got != "bytes=4-" {
				t.Fatalf("first range: %q", got)
			}
			if got := <-validators; got != old.Validator {
				t.Fatalf("first validator: %q", got)
			}
			if failure == "truncate" {
				got, err := os.ReadFile(target + ".json")
				if err != nil || !bytes.Equal(got, encoded) {
					t.Fatalf("new metadata published before truncation: %s %v", got, err)
				}
			} else {
				info, err := os.Stat(target + ".part")
				if err != nil || info.Size() != 0 {
					t.Fatalf("metadata failure left old prefix: %v", err)
				}
			}
			if err := os.RemoveAll(blocked); err != nil {
				t.Fatal(err)
			}
			if err := os.Rename(blocked+".saved", blocked); err != nil {
				t.Fatal(err)
			}
			if _, err := manager.downloadFile(context.Background(), old.URL, "", target, false, func(int64, int64) {}); err != nil {
				t.Fatal(err)
			}
			wantRange, wantValidator := "", ""
			if failure == "truncate" {
				wantRange, wantValidator = "bytes=4-", old.Validator
			}
			if got := <-ranges; got != wantRange {
				t.Fatalf("retry range %q, want %q", got, wantRange)
			}
			if got := <-validators; got != wantValidator {
				t.Fatalf("retry validator %q, want %q", got, wantValidator)
			}
			got, err := os.ReadFile(target)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("retry mixed old and new data: %q %v", got, err)
			}
		})
	}
}

func TestNativeDownloadValid206PreservesPrefix(t *testing.T) {
	manager := downloadTestManager(t)
	target := filepath.Join(manager.root, "append.mp4")
	data := []byte("prefix-and-the-rest")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=6-" || r.Header.Get("If-Range") != "\"same\"" {
			t.Error("lost resume headers")
		}
		w.Header().Set("ETag", "\"same\"")
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes 6-%d/%d", len(data)-1, len(data)))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(data[6:])
	}))
	t.Cleanup(upstream.Close)
	metadata := nativeDownloadFileState{URL: upstream.URL, Validator: "\"same\"", Total: int64(len(data))}
	encoded, _ := json.Marshal(metadata)
	if err := os.WriteFile(target+".json", encoded, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target+".part", data[:6], 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.downloadFile(context.Background(), upstream.URL, "", target, false, func(int64, int64) {}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(target)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("valid 206 truncated the prefix: %q %v", got, err)
	}
}
