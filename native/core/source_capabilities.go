package core

// 能力描述来自与 Dart 共用的配置；站点私有协议仍由原 provider 实现。
func nativeSourceDescriptorFor(source string) (nativeSourceDescriptor, bool) {
	for _, descriptor := range nativeSourceDescriptors {
		if descriptor.ID == source {
			return descriptor, true
		}
	}
	return nativeSourceDescriptor{}, false
}

func nativeSourceHasCapability(source, capability string) bool {
	descriptor, found := nativeSourceDescriptorFor(canonicalProviderSource(source))
	if !found {
		return false
	}
	for _, value := range descriptor.Capabilities {
		if value == capability {
			return true
		}
	}
	return false
}

func nativeSourceAllowsEmptyCatalog(source string) bool {
	descriptor, _ := nativeSourceDescriptorFor(source)
	return descriptor.AllowEmptyCatalog
}
