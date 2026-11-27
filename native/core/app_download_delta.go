package core

import (
	"crypto/rand"
	"encoding/hex"
	"reflect"
	"slices"
	"strconv"
	"strings"
)

const downloadDeltaHistoryLimit = 16
const downloadDeltaIDLimit = 2048

type nativeDownloadChange struct {
	revision uint64
	ids      []string
}

// 只保留一份不可变模型和有界 ID 日志。进度回调只标记目标，轮询时合并。
type nativeDownloadDelta struct {
	token    string
	revision uint64
	jobs     map[string]nativeDownloadJob
	dirty    map[string]bool
	full     bool
	history  []nativeDownloadChange
	ids      int
}

func cloneDownloadJob(job nativeDownloadJob) nativeDownloadJob {
	job.Drama.Tags = slices.Clone(job.Drama.Tags)
	job.Chapter.CurrentEpisode = slices.Clone(job.Chapter.CurrentEpisode)
	if job.Drama.VIP != nil {
		value := *job.Drama.VIP
		job.Drama.VIP = &value
	}
	if job.Chapter.Vertical != nil {
		value := *job.Chapter.Vertical
		job.Chapter.Vertical = &value
	}
	return job
}

func (manager *nativeDownloads) invalidateJobSnapshotLocked(id string) {
	manager.snapshotData = nil
	manager.snapshotEpoch++
	if manager.delta.dirty == nil {
		manager.delta.dirty = make(map[string]bool)
	}
	manager.delta.dirty[id] = true
}

func (manager *nativeDownloads) syncDeltaLocked() error {
	delta := &manager.delta
	if delta.jobs == nil {
		var token [16]byte
		if _, err := rand.Read(token[:]); err != nil {
			return err
		}
		delta.token = hex.EncodeToString(token[:]) + ":"
		delta.jobs = make(map[string]nativeDownloadJob)
		delta.full = true
	}
	changed := make([]string, 0)
	update := func(id string) {
		record := manager.jobs[id]
		old, exists := delta.jobs[id]
		if record == nil || !nativeDownloadAvailable(record.nativeDownloadJob) {
			if exists {
				delete(delta.jobs, id)
				changed = append(changed, id)
			}
		} else if !exists || !reflect.DeepEqual(old, record.nativeDownloadJob) {
			delta.jobs[id] = cloneDownloadJob(record.nativeDownloadJob)
			changed = append(changed, id)
		}
	}
	if delta.full {
		for id := range manager.jobs {
			update(id)
		}
		for id := range delta.jobs {
			if manager.jobs[id] == nil {
				update(id)
			}
		}
	} else {
		for id := range delta.dirty {
			update(id)
		}
	}
	delta.full = false
	clear(delta.dirty)
	if len(changed) != 0 || delta.revision == 0 {
		delta.revision++
		delta.history = append(delta.history, nativeDownloadChange{delta.revision, changed})
		delta.ids += len(changed)
		for len(delta.history) > downloadDeltaHistoryLimit || delta.ids > downloadDeltaIDLimit {
			delta.ids -= len(delta.history[0].ids)
			delta.history[0] = nativeDownloadChange{}
			delta.history = delta.history[1:]
		}
	}
	return nil
}

func (manager *nativeDownloads) snapshotChanges(since string) (map[string]any, error) {
	manager.mu.Lock()
	if manager.loadErr != nil {
		err := manager.loadErr
		manager.mu.Unlock()
		return nil, err
	}
	if err := manager.syncDeltaLocked(); err != nil {
		manager.mu.Unlock()
		return nil, err
	}
	delta := &manager.delta
	fingerprint := delta.token + strconv.FormatUint(delta.revision, 10)
	if since == fingerprint {
		manager.mu.Unlock()
		return map[string]any{"fingerprint": fingerprint}, nil
	}
	base, err := strconv.ParseUint(strings.TrimPrefix(since, delta.token), 10, 64)
	floor := delta.revision
	if len(delta.history) > 0 {
		floor = delta.history[0].revision - 1
	}
	if strings.HasPrefix(since, delta.token) && err == nil && base >= floor && base < delta.revision {
		ids := make(map[string]bool)
		for _, change := range delta.history {
			if change.revision > base {
				for _, id := range change.ids {
					ids[id] = true
				}
			}
		}
		jobs := make([]nativeDownloadJob, 0, len(ids))
		removed := make([]string, 0)
		for id := range ids {
			if job, ok := delta.jobs[id]; ok {
				jobs = append(jobs, job)
			} else {
				removed = append(removed, id)
			}
		}
		manager.mu.Unlock()
		return map[string]any{"fingerprint": fingerprint, "base": since, "changed": jobs, "removed": removed}, nil
	}
	jobs := make([]nativeDownloadJob, 0, len(delta.jobs))
	for _, job := range delta.jobs {
		jobs = append(jobs, job)
	}
	manager.mu.Unlock()
	// 仅全量同步排序；JSON 编码由响应层在锁外完成。
	sortDownloadJobs(jobs)
	return map[string]any{"fingerprint": fingerprint, "jobs": jobs}, nil
}
