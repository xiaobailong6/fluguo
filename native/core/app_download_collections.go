package core

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

func (manager *nativeDownloads) jobDirectory(job nativeDownloadJob) string {
	if job.Folder != "" {
		return filepath.Join(manager.root, filepath.FromSlash(job.Folder))
	}
	return filepath.Join(manager.root, job.ID)
}

func (manager *nativeDownloads) localFilesValid(record nativeDownloadRecord) bool {
	if record.Output != "" {
		info, err := os.Stat(manager.outputFile(record.Output))
		return err == nil && info.Mode().IsRegular() && info.Size() > 0 && (record.Bytes <= 0 || info.Size() == record.Bytes)
	}
	return manager.rawFilesValid(record)
}

func (manager *nativeDownloads) rawFilesValid(record nativeDownloadRecord) bool {
	if record.File == "" {
		return false
	}
	directory := manager.jobDirectory(record.nativeDownloadJob)
	seen := map[string]bool{}
	var validate func(string, int) bool
	validate = func(name string, depth int) bool {
		if depth > 8 || len(seen) > 20100 || filepath.Base(name) != name || strings.ContainsAny(name, "/\\:") {
			return false
		}
		if seen[name] {
			return true
		}
		seen[name] = true
		file := filepath.Join(directory, name)
		info, err := os.Stat(file)
		if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
			return false
		}
		if name == "media.mp4" && record.Bytes > 0 && info.Size() != record.Bytes {
			return false
		}
		if !strings.HasSuffix(name, ".m3u8") {
			return true
		}
		if info.Size() > 4<<20 {
			return false
		}
		data, err := os.ReadFile(file)
		if err != nil || !strings.HasPrefix(strings.TrimSpace(string(data)), "#EXTM3U") {
			return false
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") && !validate(line, depth+1) {
				return false
			}
			for _, match := range nativePlaylistURI.FindAllStringSubmatch(line, -1) {
				if !validate(match[1], depth+1) {
					return false
				}
			}
		}
		return true
	}
	return validate(record.File, 0)
}

type nativeDownloadControlResult struct {
	Completed []string          `json:"completed"`
	Failures  map[string]string `json:"failures"`
}

func (manager *nativeDownloads) controlBatch(ctx context.Context, ids []string, command string) (nativeDownloadControlResult, error) {
	result := nativeDownloadControlResult{Completed: []string{}, Failures: map[string]string{}}
	if len(ids) == 0 || len(ids) > 500 {
		return result, errors.New("请选择 1 至 500 个下载任务")
	}
	switch command {
	case "pause", "resume", "remove", "archive", "restore":
	default:
		return result, errors.New("批量下载操作无效")
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	seen := map[string]bool{}
	ready := []string{}
	previous := map[string]nativeDownloadRecord{}
	cancelIDs := []string{}
	tasks := 0
	if command == "restore" {
		tasks = manager.unarchivedCountLocked()
	}
	// 只在提交结果确定后组装成功列表，避免回滚项或删除失败项被报告成功。
	finish := func() (nativeDownloadControlResult, error) {
		for _, id := range ready {
			if _, failed := result.Failures[id]; !failed {
				result.Completed = append(result.Completed, id)
			}
		}
		return result, nil
	}
	remember := func(job *nativeDownloadRecord) { previous[job.ID] = *job }
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		// 保留逐项取消语义：已处理的前缀提交，尚未处理的唯一 ID 报停止。
		if ctx.Err() != nil {
			result.Failures[id] = "操作已停止，尚未处理此任务"
			continue
		}
		if manager.loadErr != nil {
			result.Failures[id] = publicError(manager.loadErr).Error()
			continue
		}
		if manager.closed || manager.moving {
			result.Failures[id] = "下载目录正在迁移或队列已关闭，请稍后重试"
			continue
		}
		job := manager.jobs[id]
		if job == nil {
			result.Failures[id] = "下载任务不存在，请刷新列表"
			continue
		}
		if !nativeDownloadAvailable(job.nativeDownloadJob) {
			result.Failures[id] = publicError(errNativeBuildSource).Error()
			continue
		}
		switch command {
		case "archive", "restore":
			if job.State != "completed" {
				result.Failures[id] = "只能清理已完成的下载任务，未完成的分集请先暂停或取消"
				continue
			}
			archived := command == "archive"
			if job.Archived != archived {
				if !archived && tasks >= 5000 {
					result.Failures[id] = "下载任务已满，请先清理其他已完成任务；视频仍保留"
					continue
				}
				remember(job)
				job.Archived = archived
				if !archived {
					tasks++
				}
			}
		case "pause":
			if job.State == "queued" || job.State == "downloading" {
				remember(job)
				job.State = "paused"
				cancelIDs = append(cancelIDs, id)
			}
		case "resume":
			if job.State == "paused" || job.State == "failed" {
				remember(job)
				job.State, job.Error, job.Archived = manager.resumeState(*job), "", false
			}
		case "remove":
			if job.State != "removing" {
				remember(job)
				job.State, job.Error = "removing", ""
				cancelIDs = append(cancelIDs, id)
			}
		}
		ready = append(ready, id)
	}
	// 持久化之前不 cancel、不 schedule；失败只回滚内存状态，no-op 仍算成功。
	if len(previous) > 0 {
		if err := manager.saveLocked(); err != nil {
			for id, old := range previous {
				*manager.jobs[id] = old
				result.Failures[id] = publicError(err).Error()
			}
			if command == "remove" {
				for _, id := range ready {
					result.Failures[id] = publicError(err).Error()
				}
			}
			return finish()
		}
	}
	for _, id := range cancelIDs {
		if cancel := manager.active[id]; cancel != nil {
			cancel()
		}
	}
	if command == "remove" {
		// removing 已持久化；即使此时请求取消，也必须完成这段可重试的收尾。
		// 在途 worker/converter 仍由原回调清理，绝不在其写文件期间直接删除。
		removed := map[string]*nativeDownloadRecord{}
		changed := false
		for _, id := range ready {
			if manager.active[id] != nil || manager.converting[id] {
				continue
			}
			job := manager.jobs[id]
			if err := manager.removeFiles(*job); err != nil {
				message := "文件正在使用或无法删除，请退出播放后重试"
				changed = changed || job.Error != message
				job.Error = message
				result.Failures[id] = message
				continue
			}
			removed[id] = job
			delete(manager.jobs, id)
			changed = true
		}
		if changed {
			if err := manager.saveLocked(); err != nil {
				// 文件删除不可回滚：保留 removing 墓碑，重试或重启可幂等清理。
				for id, job := range removed {
					job.Error = "文件已删除，记录尚未清理，请重试"
					manager.jobs[id] = job
					result.Failures[id] = publicError(err).Error()
				}
				return finish()
			}
		}
	}
	if len(previous) > 0 {
		manager.scheduleLocked()
	}
	return finish()
}
