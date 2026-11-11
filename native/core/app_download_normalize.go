package core

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const (
	nativeNormalizationSuffix = ".normalize.mp4"
	nativeNormalizationBackup = ".normalize.bak"
)

// 所有路径均从已验证的下载记录派生；拒绝目录链上的链接，避免越出下载目录。
func (manager *nativeDownloads) normalizationTarget(record *nativeDownloadRecord) (string, error) {
	if record.Output == "" || !nativeDownloadOutputValid(record.nativeDownloadJob, record.Output) || manager.outputClaimedByOther(record, record.Output) {
		return "", errors.New("标准化目标无效，已保留原视频")
	}
	target := manager.outputFile(record.Output)
	for directory := filepath.Dir(target); ; directory = filepath.Dir(directory) {
		info, err := os.Lstat(directory)
		if err != nil {
			return "", err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("标准化目录不是普通目录")
		}
		if directory == filepath.Clean(manager.root) {
			break
		}
		if filepath.Dir(directory) == directory {
			return "", errors.New("标准化目标超出下载目录")
		}
	}
	return target, nil
}

func nativeNormalizationFile(name string) (os.FileInfo, error) {
	info, err := os.Lstat(name)
	if err == nil && !info.Mode().IsRegular() {
		return nil, errors.New("标准化文件不是普通文件，已保留原视频")
	}
	return info, err
}

func nativeNormalizationRemove(name string) error {
	if _, err := nativeNormalizationFile(name); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	return os.Remove(name)
}

func (record *nativeDownloadRecord) clearNormalizationPending() {
	record.NormalizationPending = false
	record.NormalizationSHA256, record.NormalizationSize = "", 0
}

// 删除入口只清理本功能拥有的两个固定后缀；不递归删除相邻内容。
func (manager *nativeDownloads) removeNormalizationFiles(record nativeDownloadRecord) error {
	if record.Output == "" {
		return nil
	}
	target, err := manager.normalizationTarget(&record)
	if err != nil {
		// 已删除的整目录没有可清理的后缀，允许 removing 重试提交索引。
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, name := range []string{target, target + nativeNormalizationSuffix, target + nativeNormalizationBackup} {
		if _, err := nativeNormalizationFile(name); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := nativeNormalizationRemove(target + nativeNormalizationSuffix); err != nil {
		return err
	}
	return nativeNormalizationRemove(target + nativeNormalizationBackup)
}

func (manager *nativeDownloads) removeNormalizedDownloadFiles(record nativeDownloadRecord) error {
	if err := manager.removeNormalizationFiles(record); err != nil {
		return err
	}
	return manager.removeFiles(record)
}

// pending 始终保存替换前的 revision；只有新成品身份吻合才补交一次 revision。
func (manager *nativeDownloads) recoverNormalizationLocked(record *nativeDownloadRecord) error {
	if record.Output == "" {
		if record.NormalizationPending {
			return errors.New("标准化记录缺少目标")
		}
		return nil
	}
	target, err := manager.normalizationTarget(record)
	if err != nil {
		if !record.NormalizationPending && os.IsNotExist(err) {
			return nil
		}
		return err
	}
	temporary, backup := target+nativeNormalizationSuffix, target+nativeNormalizationBackup
	for _, name := range []string{target, temporary, backup} {
		if _, err := nativeNormalizationFile(name); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if !record.NormalizationPending {
		// 最终索引已提交、删除备份前退出；仅在目标仍存在时回收备份。
		if _, err := os.Lstat(backup); err == nil {
			if info, err := nativeNormalizationFile(target); err != nil {
				return err
			} else if info.Size() <= 0 {
				return errors.New("标准化目标为空，已保留备份")
			}
		}
		return manager.removeNormalizationFiles(*record)
	}
	digest, decodeErr := hex.DecodeString(record.NormalizationSHA256)
	if decodeErr != nil || len(digest) != sha256.Size || record.NormalizationSize <= 0 {
		return errors.New("标准化提交身份无效，已保留原视频")
	}
	matched := false
	if info, err := nativeNormalizationFile(target); err == nil {
		if info.Size() == record.NormalizationSize {
			hash, size, err := nativeConversionIdentity(target)
			if err != nil {
				return err
			}
			matched = hash == record.NormalizationSHA256 && size == record.NormalizationSize
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if !matched {
		if _, err := os.Lstat(backup); err == nil {
			// 旧文件移走后退出：只有空缺目标可安全恢复，未知目标不得覆盖。
			if _, err := os.Lstat(target); !os.IsNotExist(err) {
				return errors.New("标准化目标身份不符，已保留目标和备份")
			}
			if err := os.Rename(backup, target); err != nil {
				return err
			}
		}
		if _, err := nativeNormalizationFile(target); err != nil {
			return err
		}
	}
	previous := *record
	if matched {
		record.Bytes, record.Total, record.Progress = record.NormalizationSize, record.NormalizationSize, 1
		record.Revision++
	}
	record.clearNormalizationPending()
	if err := manager.saveLocked(); err != nil {
		*record = previous
		return err
	}
	return manager.removeNormalizationFiles(*record)
}

func nativeNormalizationExpected(record *nativeDownloadRecord, expected *nativeDownloadIdentity) bool {
	return record != nil && expected != nil && record.Created == expected.Created && record.Revision == expected.Revision
}

func (manager *nativeDownloads) beginNormalization(id string, expected *nativeDownloadIdentity) (nativeDownloadConversion, error) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.loadErr != nil {
		return nativeDownloadConversion{}, manager.loadErr
	}
	if manager.closed || manager.moving || manager.converting[id] {
		return nativeDownloadConversion{}, errors.New("下载正在处理或迁移，请稍后重试")
	}
	record := manager.jobs[id]
	if !nativeNormalizationExpected(record, expected) || record.State != "completed" {
		return nativeDownloadConversion{}, errors.New("分集已变化，已保留当前下载，请刷新后重试")
	}
	if !nativeDownloadAvailable(record.nativeDownloadJob) {
		return nativeDownloadConversion{}, errNativeBuildSource
	}
	if err := manager.recoverNormalizationLocked(record); err != nil {
		return nativeDownloadConversion{}, err
	}
	if !nativeNormalizationExpected(record, expected) {
		return nativeDownloadConversion{}, errors.New("分集已变化，请刷新后重试")
	}
	target, err := manager.normalizationTarget(record)
	if err != nil {
		return nativeDownloadConversion{}, err
	}
	if info, err := nativeNormalizationFile(target); err != nil || info.Size() <= 0 {
		return nativeDownloadConversion{}, errNativeLocalFile
	}
	manager.converting[id] = true
	return nativeDownloadConversion{Input: target, Output: target + nativeNormalizationSuffix}, nil
}

// 仅在原生转换进程确认退出后调用；没有提前释放占用的独立入口。
func (manager *nativeDownloads) finishNormalization(id string, expected *nativeDownloadIdentity, result string) (nativeDownloadJob, error) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	record := manager.jobs[id]
	if !manager.converting[id] {
		if result == "cancel" || result == "failed" {
			if record != nil { return record.nativeDownloadJob, nil }
			return nativeDownloadJob{}, nil
		}
		if record != nil && expected != nil && record.Created == expected.Created && record.Revision == expected.Revision+1 && record.State == "completed" {
			return record.nativeDownloadJob, nil
		}
		return nativeDownloadJob{}, errors.New("该集没有正在进行的标准化")
	}
	if !nativeNormalizationExpected(record, expected) {
		return nativeDownloadJob{}, errors.New("分集已变化，已保留当前下载")
	}
	if result != "done" && result != "cancel" && result != "failed" {
		return record.nativeDownloadJob, errors.New("无效的处理结果")
	}
	defer delete(manager.converting, id)
	if record.State == "removing" {
		if err := manager.removeNormalizedDownloadFiles(*record); err != nil {
			record.Error = "文件无法删除，请稍后重试"
			_ = manager.saveLocked()
			return record.nativeDownloadJob, err
		}
		delete(manager.jobs, id)
		if err := manager.saveLocked(); err != nil {
			record.Error = "文件已删除，记录尚未清理，请重试"
			manager.jobs[id] = record
			return record.nativeDownloadJob, err
		}
		return record.nativeDownloadJob, nil
	}
	if record.State != "completed" {
		return record.nativeDownloadJob, errors.New("分集状态已变化")
	}
	target, err := manager.normalizationTarget(record)
	if err != nil {
		return record.nativeDownloadJob, err
	}
	temporary, backup := target+nativeNormalizationSuffix, target+nativeNormalizationBackup
	if result != "done" {
		return record.nativeDownloadJob, nativeNormalizationRemove(temporary)
	}
	if info, err := nativeNormalizationFile(target); err != nil || info.Size() <= 0 {
		return record.nativeDownloadJob, errNativeLocalFile
	}
	if _, err := os.Lstat(backup); !os.IsNotExist(err) {
		return record.nativeDownloadJob, errors.New("标准化备份已存在，请先恢复")
	}
	if info, err := nativeNormalizationFile(temporary); err != nil || info.Size() <= 0 {
		return record.nativeDownloadJob, errors.New("标准化结果无效，已保留原视频")
	}
	file, err := os.OpenFile(temporary, os.O_RDWR, 0600)
	if err != nil {
		return record.nativeDownloadJob, err
	}
	err = file.Sync()
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return record.nativeDownloadJob, err
	}
	hash, size, err := nativeConversionIdentity(temporary)
	if err != nil {
		return record.nativeDownloadJob, err
	}
	previous := *record
	record.NormalizationPending, record.NormalizationSHA256, record.NormalizationSize = true, hash, size
	if err := manager.saveLocked(); err != nil {
		*record = previous
		_ = nativeNormalizationRemove(temporary)
		return record.nativeDownloadJob, err
	}
	pending := *record
	rename := os.Rename
	if manager.renameFile != nil {
		rename = manager.renameFile
	}
	err = rename(target, backup)
	if err == nil {
		err = rename(temporary, target)
	}
	if err == nil {
		record.Bytes, record.Total, record.Progress = size, size, 1
		record.Revision++
		record.clearNormalizationPending()
		err = manager.saveLocked()
	}
	if err == nil {
		return record.nativeDownloadJob, nativeNormalizationRemove(backup)
	}
	// 即使故障注入在 rename 已生效后才报错，也按磁盘实际状态回滚。
	*record = pending
	if _, statErr := nativeNormalizationFile(backup); statErr == nil {
		if _, targetErr := os.Lstat(target); targetErr == nil {
			if removeErr := nativeNormalizationRemove(temporary); removeErr != nil {
				return record.nativeDownloadJob, fmt.Errorf("%v；回滚失败：%w", err, removeErr)
			}
			if moveErr := os.Rename(target, temporary); moveErr != nil {
				return record.nativeDownloadJob, fmt.Errorf("%v；回滚失败：%w", err, moveErr)
			}
		} else if !os.IsNotExist(targetErr) {
			return record.nativeDownloadJob, targetErr
		}
		if restoreErr := os.Rename(backup, target); restoreErr != nil {
			return record.nativeDownloadJob, fmt.Errorf("%v；恢复备份失败：%w", err, restoreErr)
		}
	} else if !os.IsNotExist(statErr) {
		return record.nativeDownloadJob, statErr
	}
	*record = previous
	if saveErr := manager.saveLocked(); saveErr != nil {
		// 磁盘 pending 必须与内存一致，重启可按哈希识别已恢复的旧文件。
		*record = pending
		return record.nativeDownloadJob, fmt.Errorf("%v；回滚索引失败：%w", err, saveErr)
	}
	if cleanupErr := nativeNormalizationRemove(temporary); cleanupErr != nil {
		return record.nativeDownloadJob, fmt.Errorf("%v；清理失败：%w", err, cleanupErr)
	}
	return record.nativeDownloadJob, err
}
