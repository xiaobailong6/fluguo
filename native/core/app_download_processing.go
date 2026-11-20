package core

import (
	"errors"
	"os"
)

var errNativeDownloadChanged = errors.New("分集已变化，已保留当前下载")

// 摘要仅可在同次提交内复用，不能跨重试/重启按路径或长度缓存。
// rename 前后验证文件对象、大小、修改时间；未知对象仍须重新读取完整 SHA256。
type nativeDownloadFileIdentity struct {
	info   os.FileInfo
	digest string
	size   int64
}

func (identity nativeDownloadFileIdentity) matches(name string) bool {
	info, err := os.Lstat(name)
	return err == nil && identity.info != nil && info.Mode().IsRegular() &&
		os.SameFile(identity.info, info) && info.Size() == identity.size && info.ModTime().Equal(identity.info.ModTime())
}

func (manager *nativeDownloads) claimProcessingLocked(id string) bool {
	if manager.processing[id] {
		return false
	}
	if manager.processing == nil {
		manager.processing = make(map[string]bool)
	}
	manager.processing[id] = true
	return true
}

// 调用者保留 converting + processing 占用：迁移/重复 finish 被拒绝，remove 仅落墓碑。
// unlock=false 只用于尚未对外发布的 load 恢复（以及原有 Locked 单元测试）。
func (manager *nativeDownloads) conversionIdentityLocked(record *nativeDownloadRecord, name string, syncFile, unlock bool) (nativeDownloadFileIdentity, error) {
	id, created, revision, state, root := record.ID, record.Created, record.Revision, record.State, manager.root
	hash := nativeConversionIdentity
	if manager.hashFile != nil {
		hash = manager.hashFile
	}
	var identity nativeDownloadFileIdentity
	work := func() error {
		before, err := os.Lstat(name)
		if err != nil {
			return err
		}
		if !before.Mode().IsRegular() || before.Size() <= 0 {
			return errors.New("转换文件无效")
		}
		if syncFile {
			file, err := os.OpenFile(name, os.O_RDWR, 0600)
			if err != nil {
				return err
			}
			err = file.Sync()
			closeErr := file.Close()
			if err != nil {
				return err
			}
			if closeErr != nil {
				return closeErr
			}
		}
		digest, size, err := hash(name)
		if err != nil {
			return err
		}
		identity = nativeDownloadFileIdentity{info: before, digest: digest, size: size}
		if !identity.matches(name) {
			return errors.New("转换文件已变化，已保留原始下载")
		}
		return nil
	}
	var err error
	if unlock {
		manager.mu.Unlock()
		// 即使测试故障注入 panic，也必须重新取得锁以配对上层 defer。
		func() { defer manager.mu.Lock(); err = work() }()
	} else {
		err = work()
	}
	if manager.jobs[id] != record || record.Created != created || record.Revision != revision || record.State != state || manager.root != root || unlock && (manager.closed || !manager.processing[id] || !manager.converting[id]) {
		return nativeDownloadFileIdentity{}, errNativeDownloadChanged
	}
	return identity, err
}

// 大量 HLS 分片清理不占全局锁；任务占用直到清理结束，避免同 ID 重下被误删。
func (manager *nativeDownloads) cleanupConversionLocked(record *nativeDownloadRecord, directory string, unlock bool) {
	remove := os.RemoveAll
	if manager.removeTree != nil {
		remove = manager.removeTree
	}
	if unlock {
		manager.mu.Unlock()
		func() { defer manager.mu.Lock(); _ = remove(directory) }()
	} else {
		_ = remove(directory)
	}
}

// processing 占用期间 remove 仍能及时提交；占用者结束时执行可恢复删除。
func (manager *nativeDownloads) finishProcessingRemovalLocked(record *nativeDownloadRecord, reportFileError ...bool) error {
	if manager.jobs[record.ID] != record || record.State != "removing" {
		return nil
	}
	copy := *record
	// 路径校验需要 jobs；锁外删除只读取冻结的副本，不能遍历活 map。
	frozen := &nativeDownloads{root: manager.root, jobs: make(map[string]*nativeDownloadRecord, len(manager.jobs))}
	for id, job := range manager.jobs {
		value := *job
		frozen.jobs[id] = &value
	}
	manager.mu.Unlock()
	var err error
	func() { defer manager.mu.Lock(); err = frozen.removeNormalizedDownloadFiles(copy) }()
	if err != nil {
		record.Error = "文件无法删除，请稍后重试"
		saveErr := manager.saveLocked()
		if len(reportFileError) > 0 && reportFileError[0] {
			return err
		}
		return saveErr // 转换旧协议把删除失败写进任务，只有索引失败上抛。
	}
	delete(manager.jobs, record.ID)
	if err := manager.saveLocked(); err != nil {
		record.Error = "文件已删除，记录尚未清理，请重试"
		manager.jobs[record.ID] = record
		return err
	}
	return nil
}

func (manager *nativeDownloads) recoverConversionOnlineLocked(record *nativeDownloadRecord) error {
	if record.State != "converting" || !record.ConversionPending {
		return nil
	}
	if !manager.claimProcessingLocked(record.ID) {
		return errors.New("该集正在处理")
	}
	manager.converting[record.ID] = true
	defer delete(manager.converting, record.ID)
	defer delete(manager.processing, record.ID)
	err := manager.recoverConversionIdentityLocked(record, true)
	if record.State == "removing" {
		if removeErr := manager.finishProcessingRemovalLocked(record); removeErr != nil {
			return removeErr
		}
		return errors.New("分集已删除")
	}
	return err
}

func (manager *nativeDownloads) recoverNormalizationOnlineLocked(record *nativeDownloadRecord) error {
	if !manager.claimProcessingLocked(record.ID) {
		return errors.New("该集正在处理")
	}
	manager.converting[record.ID] = true
	defer delete(manager.converting, record.ID)
	defer delete(manager.processing, record.ID)
	err := manager.recoverNormalizationIdentityLocked(record, true)
	if record.State == "removing" {
		if removeErr := manager.finishProcessingRemovalLocked(record, true); removeErr != nil {
			return removeErr
		}
		return errors.New("分集已删除")
	}
	return err
}
