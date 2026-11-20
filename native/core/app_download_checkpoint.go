package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// 所有可见变更的耐久入口均调用 saveLocked；无提交变更（progress、enqueue 回滚）
// 单独失效。读取不失效，缓存字节发布后不可修改，旧响应可安全继续编码。
func (manager *nativeDownloads) invalidateSnapshotLocked() {
	manager.snapshotData = nil
}

func (manager *nativeDownloads) snapshotJobsLocked() []nativeDownloadJob {
	jobs := make([]nativeDownloadJob, 0, len(manager.jobs))
	for _, record := range manager.jobs {
		if nativeDownloadAvailable(record.nativeDownloadJob) {
			jobs = append(jobs, record.nativeDownloadJob)
		}
	}
	sort.Slice(jobs, func(i, j int) bool {
		if jobs[i].Created != jobs[j].Created {
			return jobs[i].Created > jobs[j].Created
		}
		if jobs[i].Index != jobs[j].Index {
			return jobs[i].Index < jobs[j].Index
		}
		return jobs[i].ID < jobs[j].ID
	})
	return jobs
}

func (manager *nativeDownloads) recordsLocked() []nativeDownloadRecord {
	records := make([]nativeDownloadRecord, 0, len(manager.jobs))
	for _, job := range manager.jobs {
		copy := *job
		// 可变载荷必须与活记录脱离，后台 JSON 编码不能读取共享切片/指针。
		copy.Drama.Tags = append([]string(nil), job.Drama.Tags...)
		copy.Chapter.CurrentEpisode = append(json.RawMessage(nil), job.Chapter.CurrentEpisode...)
		if job.Drama.VIP != nil {
			value := *job.Drama.VIP
			copy.Drama.VIP = &value
		}
		if job.Chapter.Vertical != nil {
			value := *job.Chapter.Vertical
			copy.Chapter.Vertical = &value
		}
		records = append(records, copy)
	}
	return records
}

func nativeEncodeDownloadIndex(records []nativeDownloadRecord) ([]byte, error) {
	sort.Slice(records, func(i, j int) bool {
		if records[i].Created == records[j].Created {
			return records[i].ID < records[j].ID
		}
		return records[i].Created < records[j].Created
	})
	data, err := json.Marshal(records)
	if err == nil && len(data) > 32<<20 {
		err = errors.New("下载记录超过保存上限，原索引已保留")
	}
	return data, err
}

func (manager *nativeDownloads) indexWriterLocked() func(string, []byte) error {
	if manager.writeIndex != nil {
		return manager.writeIndex
	}
	return nativeDownloadWrite
}

func (manager *nativeDownloads) requestCheckpointLocked() {
	if manager.closed || manager.moving || manager.loadErr != nil || time.Since(manager.lastAttempt) < time.Second {
		return
	}
	// 先记尝试时间：编码/磁盘失败也不能让后续每个 64KiB 回调重试。
	manager.lastAttempt = time.Now()
	manager.checkpointPending = true
	if manager.checkpointRunning {
		return
	}
	manager.checkpointRunning = true
	manager.checkpoints.Add(1)
	go manager.checkpointLoop()
}

func (manager *nativeDownloads) checkpointLoop() {
	defer manager.checkpoints.Done()
	for {
		manager.mu.Lock()
		if !manager.checkpointPending || manager.closed || manager.moving || manager.loadErr != nil {
			manager.checkpointRunning = false
			manager.mu.Unlock()
			return
		}
		manager.checkpointPending = false
		manager.lastAttempt = time.Now()
		records, root, epoch, write := manager.recordsLocked(), manager.root, manager.indexEpoch, manager.indexWriterLocked()
		manager.mu.Unlock()

		// 耗时编码、排序、写入及 fsync 全部在锁外；仅最终 rename 是短锁原子提交。
		// 不能直接后台 write(index.json)：暂停/删除/转换事务可能已提交更新索引。
		data, err := nativeEncodeDownloadIndex(records)
		stage := ""
		if err == nil {
			var file *os.File
			file, err = os.CreateTemp(root, ".download-checkpoint-")
			if err == nil {
				stage = file.Name()
				err = file.Close()
				if err == nil {
					err = write(stage, data)
				}
			}
		}
		manager.mu.Lock()
		if err == nil && manager.indexEpoch == epoch && manager.root == root && !manager.closed && !manager.moving && manager.loadErr == nil {
			err = os.Rename(stage, filepath.Join(root, "index.json"))
			if err == nil {
				manager.lastSaved = time.Now()
			}
		}
		manager.mu.Unlock()
		if stage != "" {
			_ = os.Remove(stage)
		}
	}
}
