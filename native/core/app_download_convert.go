package core

import (
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode"
)

const nativeConversionFile = ".convert.mp4"

type nativeDownloadConversion struct {
	Input  string `json:"input"`
	Key    string `json:"key"`
	Output string `json:"output"`
}

var nativeReservedFileNames = map[string]bool{"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true, "COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true, "LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true}

func nativeDownloadEpisodeFile(index int) string {
	return fmt.Sprintf("第%d集.mp4", index)
}

func nativeDownloadNameTrimmed(r rune) bool {
	return unicode.IsSpace(r) || r == '.'
}

func nativeDownloadFolderName(title string) string {
	runes := []rune(title)
	for index, r := range runes {
		if r < 0x20 || r == 0x7f || strings.ContainsRune(`<>:"/\|?*`, r) {
			runes[index] = '_'
		}
	}
	name := strings.TrimFunc(string(runes[:min(len(runes), 60)]), nativeDownloadNameTrimmed)
	if name == "" {
		return "未命名"
	}
	if stem, _, _ := strings.Cut(strings.ToUpper(name), "."); nativeReservedFileNames[stem] {
		name = "_" + name
	}
	return name
}

func nativeDownloadNameValid(name string) bool {
	if name == "" || len([]rune(name)) > 80 || strings.TrimFunc(name, nativeDownloadNameTrimmed) != name {
		return false
	}
	for _, r := range name {
		if r < 0x20 || r == 0x7f || strings.ContainsRune(`<>:"/\|?*`, r) {
			return false
		}
	}
	stem, _, _ := strings.Cut(strings.ToUpper(name), ".")
	return !nativeReservedFileNames[stem]
}

func nativeDownloadOutputValid(job nativeDownloadJob, output string) bool {
	parts := strings.Split(output, "/")
	if len(parts) == 3 {
		if parts[0] != job.Drama.Source {
			return false
		}
		parts = parts[1:]
	}
	return len(parts) == 2 && nativeDownloadNameValid(parts[0]) && parts[1] == nativeDownloadEpisodeFile(job.Index)
}

func (manager *nativeDownloads) outputFile(output string) string {
	return filepath.Join(manager.root, filepath.FromSlash(output))
}

func (manager *nativeDownloads) outputFolderTakenLocked(drama, folder string) bool {
	if strings.EqualFold(folder, "exports") {
		return true
	}
	for _, other := range manager.jobs {
		if other.Drama.ID != drama && other.Output != "" && strings.EqualFold(path.Dir(other.Output), folder) {
			return true
		}
	}
	_, err := os.Lstat(manager.outputFile(folder))
	return !os.IsNotExist(err)
}

func (manager *nativeDownloads) outputPathLocked(record nativeDownloadRecord) string {
	file := nativeDownloadEpisodeFile(record.Index)
	if record.Output != "" {
		return record.Output
	}
	for _, other := range manager.jobs {
		if other.Drama.ID == record.Drama.ID && other.Output != "" {
			return path.Dir(other.Output) + "/" + file
		}
	}
	prefix := ""
	if record.Folder != "" {
		prefix = record.Drama.Source + "/"
	}
	base := nativeDownloadFolderName(record.Drama.Title)
	folder := base
	for attempt := 2; manager.outputFolderTakenLocked(record.Drama.ID, prefix+folder); attempt++ {
		folder = fmt.Sprintf("%s (%d)", base, attempt)
	}
	return prefix + folder + "/" + file
}

func (manager *nativeDownloads) resumeState(record nativeDownloadRecord) string {
	if record.File != "" && manager.rawFilesValid(record) {
		return "converting"
	}
	return "queued"
}

func (manager *nativeDownloads) removeFiles(record nativeDownloadRecord) error {
	if err := os.RemoveAll(manager.jobDirectory(record.nativeDownloadJob)); err != nil {
		return err
	}
	if record.Output == "" {
		return nil
	}
	file := manager.outputFile(record.Output)
	if err := os.Remove(file); err != nil && !os.IsNotExist(err) {
		return err
	}
	_ = os.Remove(filepath.Dir(file))
	return nil
}

// rename 前持久化 Output 和可选的 pending 标记；旧索引缺省为 false。
// 保存完成状态失败时保留成品及原始下载，下次调用/启动继续提交。
func (manager *nativeDownloads) recoverConversionLocked(record *nativeDownloadRecord) error {
	if record.State != "converting" || !record.ConversionPending {
		return nil
	}
	target := manager.outputFile(record.Output)
	info, err := os.Lstat(target)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return errors.New("待恢复的视频文件无效，原文件已保留")
	}
	previous := *record
	record.State, record.Error = "completed", ""
	record.File, record.Key = "", ""
	record.ConversionPending = false
	record.Bytes, record.Total = info.Size(), info.Size()
	if err := manager.saveLocked(); err != nil {
		*record = previous
		return err
	}
	_ = os.RemoveAll(manager.jobDirectory(record.nativeDownloadJob))
	return nil
}

func (manager *nativeDownloads) beginConversion(id string) (nativeDownloadConversion, error) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.loadErr != nil {
		return nativeDownloadConversion{}, manager.loadErr
	}
	if manager.closed || manager.moving {
		return nativeDownloadConversion{}, errors.New("下载目录正在迁移或队列已关闭，请稍后重试")
	}
	record := manager.jobs[id]
	if record == nil {
		return nativeDownloadConversion{}, errors.New("该集不需要处理，请刷新列表")
	}
	if !nativeDownloadAvailable(record.nativeDownloadJob) {
		return nativeDownloadConversion{}, errNativeBuildSource
	}
	if manager.converting[id] {
		return nativeDownloadConversion{}, errors.New("该集正在处理")
	}
	if err := manager.recoverConversionLocked(record); err != nil {
		return nativeDownloadConversion{}, err
	}
	if record.State != "converting" {
		return nativeDownloadConversion{}, errors.New("该集不需要处理，请刷新列表")
	}
	if !manager.rawFilesValid(*record) {
		record.State, record.Error = "failed", "下载文件不完整，点击重试重新下载"
		_ = manager.saveLocked()
		return nativeDownloadConversion{}, errors.New(record.Error)
	}
	manager.converting[id] = true
	directory := manager.jobDirectory(record.nativeDownloadJob)
	return nativeDownloadConversion{Input: filepath.Join(directory, record.File), Key: record.Key,
		Output: filepath.Join(directory, nativeConversionFile)}, nil
}

func (manager *nativeDownloads) finishConversion(id, result string) error {
	if result != "done" && result != "failed" && result != "cancel" {
		return errors.New("无效的处理结果")
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if !manager.converting[id] {
		// 首次提交已 rename、但索引未保存时，允许幂等重试而不重新转码。
		if result == "done" {
			if record := manager.jobs[id]; record != nil && record.State == "converting" && record.Output != "" {
				if err := manager.recoverConversionLocked(record); err != nil {
					return err
				}
				if record.State == "completed" {
					return nil
				}
			}
		}
		return errors.New("该集没有正在进行的处理")
	}
	delete(manager.converting, id)
	record := manager.jobs[id]
	if record == nil {
		return nil
	}
	directory := manager.jobDirectory(record.nativeDownloadJob)
	temporary := filepath.Join(directory, nativeConversionFile)
	if record.State == "removing" {
		if err := manager.removeFiles(*record); err != nil {
			record.Error = "文件无法删除，请稍后重试"
		} else {
			delete(manager.jobs, id)
		}
		if err := manager.saveLocked(); err != nil {
			// 文件删除不可回滚；保留 removing 记录供批量重试或重启恢复。
			if manager.jobs[id] == nil {
				record.Error = "文件已删除，记录尚未清理，请重试"
				manager.jobs[id] = record
			}
			return err
		}
		return nil
	}
	if record.State != "converting" || result == "cancel" {
		_ = os.Remove(temporary)
		return nil
	}
	if result == "failed" {
		_ = os.Remove(temporary)
		record.State, record.Error = "failed", "转换失败，点击重试"
		return manager.saveLocked()
	}
	output := manager.outputPathLocked(*record)
	target := manager.outputFile(output)
	info, err := os.Stat(temporary)
	if err == nil && (!info.Mode().IsRegular() || info.Size() <= 0) {
		err = errors.New("empty conversion")
	}
	if err == nil {
		// 不覆盖同名既有成品，也不在拒绝覆盖后把它记录为本任务所有。
		if _, statErr := os.Lstat(target); !os.IsNotExist(statErr) {
			if statErr != nil {
				err = statErr
			} else {
				err = errors.New("视频目标文件已存在")
			}
		}
	}
	if err == nil {
		file, openErr := os.OpenFile(temporary, os.O_RDWR, 0600)
		if openErr != nil {
			err = openErr
		} else {
			err = file.Sync()
			closeErr := file.Close()
			if err == nil {
				err = closeErr
			}
		}
	}
	if err == nil {
		previous := *record
		record.Output, record.ConversionPending = output, true
		if saveErr := manager.saveLocked(); saveErr != nil {
			*record = previous
			return saveErr
		}
	}
	if err == nil {
		err = os.MkdirAll(filepath.Dir(target), 0700)
	}
	if err == nil {
		rename := os.Rename
		if manager.renameFile != nil {
			rename = manager.renameFile
		}
		err = rename(temporary, target)
	}
	if err != nil {
		_ = os.Remove(temporary)
		record.State, record.Error = "failed", "无法保存视频文件，点击重试"
		return manager.saveLocked()
	}
	return manager.recoverConversionLocked(record)
}
