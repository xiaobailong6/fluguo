package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeDownloadHLSRawFilesRequireCompletedMetadata(t *testing.T) {
	for _, test := range []struct {
		name     string
		ext      string
		body     string
		metadata string
		valid    bool
	}{
		{"complete-segment", ".ts", "12345678", `{"complete":true,"total":8}`, true},
		{"complete-init", ".mp4", "12345678", `{"complete":true,"total":8}`, true},
		{"complete-fragment", ".m4s", "12345678", `{"complete":true,"total":8}`, true},
		{"complete-audio", ".aac", "12345678", `{"complete":true,"total":8}`, true},
		{"truncated-segment", ".ts", "123", `{"complete":true,"total":8}`, false},
		{"truncated-init", ".mp4", "123", `{"complete":true,"total":8}`, false},
		{"oversized-segment", ".ts", "123456789", `{"complete":true,"total":8}`, false},
		{"unfinished-segment", ".ts", "12345678", `{"complete":false,"total":8}`, false},
		{"unknown-length", ".ts", "12345678", `{"complete":true,"total":0}`, false},
		{"missing-metadata", ".ts", "12345678", "", false},
		{"malformed-metadata", ".ts", "12345678", "{", false},
		{"downloaded-key", ".key", "0123456789abcdef", `{"complete":true,"total":16}`, true},
		{"inline-key-without-metadata", ".key", "0123456789abcdef", "", true},
		{"truncated-inline-key", ".key", "0123456789abcde", "", false},
		{"oversized-inline-key", ".key", "0123456789abcdef0", "", false},
		{"short-key-matching-metadata", ".key", "0123456789abcde", `{"complete":true,"total":15}`, false},
		{"key-length-mismatch", ".key", "0123456789abcdef", `{"complete":true,"total":17}`, false},
		{"unfinished-key", ".key", "0123456789abcdef", `{"complete":false,"total":16}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			manager := batchTestManager(t)
			job := batchTestJob(manager, 1, "failed", false)
			job.File = "index.m3u8"
			directory := manager.jobDirectory(job.nativeDownloadJob)
			if err := os.MkdirAll(directory, 0700); err != nil {
				t.Fatal(err)
			}
			write := func(name, data string) {
				t.Helper()
				if err := os.WriteFile(filepath.Join(directory, name), []byte(data), 0600); err != nil {
					t.Fatal(err)
				}
			}
			asset := nativeDownloadAssetName("https://synthetic.test/resource", test.ext)
			write(asset, test.body)
			if test.metadata != "" {
				write(asset+".json", test.metadata)
			}
			// 主列表/媒体列表不带下载 sidecar；MAP、分片、密钥都通过递归校验。
			playlist := "#EXTM3U\n"
			switch test.ext {
			case ".mp4":
				playlist += "#EXT-X-MAP:URI=\"" + asset + "\"\n"
			case ".key":
				playlist += "#EXT-X-KEY:METHOD=AES-128,URI=\"" + asset + "\"\n"
			default:
				playlist += "#EXTINF:2,\n" + asset + "\n"
			}
			write("nested.m3u8", playlist+"#EXT-X-ENDLIST\n")
			write(job.File, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nnested.m3u8\n")
			if got := manager.rawFilesValid(*job); got != test.valid {
				t.Fatalf("rawFilesValid = %v, want %v", got, test.valid)
			}
			want := "queued"
			if test.valid {
				want = "converting"
			} else {
				job.State = "converting"
				if _, err := manager.beginConversion(job.ID); err == nil || job.State != "failed" {
					t.Fatal("damaged HLS was accepted for conversion")
				}
			}
			// 占满 worker 槽位，直接检查 resume 的持久化 queued 状态而不启动网络。
			manager.active["occupied"] = func() {}
			result, err := manager.controlBatch(context.Background(), []string{job.ID}, "resume")
			batchTestResult(t, result, err, []string{job.ID}, 0)
			if job.State != want || batchTestIndex(t, manager)[job.ID].State != want {
				t.Fatalf("batch resume state = %s, want %s", job.State, want)
			}
			job.State = "failed"
			if err := manager.control(job.ID, "resume"); err != nil || job.State != want {
				t.Fatalf("single resume state = %s, want %s: %v", job.State, want, err)
			}
		})
	}
}

func TestNativeDownloadRawFilesLegacyMP4WithoutMetadata(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "failed", false)
	job.File = "media.mp4"
	job.Bytes = int64(len("synthetic-video"))
	batchTestWriteFile(t, filepath.Join(manager.jobDirectory(job.nativeDownloadJob), job.File))
	if !manager.rawFilesValid(*job) || manager.resumeState(*job) != "converting" {
		t.Fatal("legacy complete MP4 without sidecar became invalid")
	}
	// 新增转换身份字段使用 omitempty，不改变普通旧索引的编码。
	encoded, err := json.Marshal(job)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	if fields["conversionSHA256"] != nil || fields["conversionSize"] != nil {
		t.Fatal("empty conversion identity leaked into legacy index")
	}
}
