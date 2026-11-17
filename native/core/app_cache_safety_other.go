//go:build !windows

package core

// 非 Windows 平台的链接检查由公共 Lstat 路径校验完成。
func nativeCacheReparsePoint(path string) bool { return false }
