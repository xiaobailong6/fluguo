//go:build windows

package core

import "syscall"

// 不能只检查 ModeSymlink：junction、挂载点及未知重解析标签也不允许清理。
func nativeCacheReparsePoint(path string) bool {
	pointer, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return true
	}
	attributes, err := syscall.GetFileAttributes(pointer)
	return err != nil || attributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0
}
