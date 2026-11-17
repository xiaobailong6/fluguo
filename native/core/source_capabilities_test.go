package core

import (
	"errors"
	"net/url"
	"strings"
	"testing"
)

func TestSourceCapabilitiesKeepEditionAndSpecialCapabilities(t *testing.T) {
	if len(nativeSourceDescriptors) != 20 {
		t.Fatal("source descriptors must include 18 existing and 2 new sources")
	}
	seen := map[string]bool{}
	for _, descriptor := range nativeSourceDescriptors {
		if seen[descriptor.ID] || !isHuangguoProviderSource(descriptor.ID) {
			t.Fatal("duplicate or unregistered descriptor", descriptor.ID)
		}
		seen[descriptor.ID] = true
		standard := descriptor.ID == "hongguo" || descriptor.ID == "fanguo" || descriptor.ID == "shuangguo"
		if descriptor.Standard != standard || nativeSourceAvailable(descriptor.ID) != (standard || buildAllSources == "true") {
			t.Fatal("edition policy changed", descriptor.ID)
		}
		if nativeSourceHasCapability(descriptor.ID, "danmaku") != (descriptor.ID == "hongguo") ||
			nativeSourceHasCapability(descriptor.ID, "account") != (descriptor.ID == "sorani") {
			t.Fatal("special capability owner changed", descriptor.ID)
		}
		for _, host := range append(append([]string{}, descriptor.BrowserHosts...), descriptor.DNSHosts...) {
			parsed, err := url.Parse("https://" + host)
			if err != nil || parsed.Hostname() != host || strings.ContainsAny(host, "*/:@") {
				t.Fatal("non-explicit policy host", host)
			}
		}
	}
	if nativeSourceAvailable("unknown") || nativeSourceHasCapability("unknown", "search") {
		t.Fatal("unknown source gained capabilities")
	}
}

func TestNewSourcesUseExistingNativeAuthorization(t *testing.T) {
	for _, source := range []string{"missav", "hanime1"} {
		descriptor, found := nativeSourceDescriptorFor(source)
		if !found || !descriptor.Adult || descriptor.Standard || !descriptor.BrowserFingerprint {
			t.Fatal("new source lost restricted policy", source)
		}
		for _, action := range []string{"catalog", "categories", "cached", "detail", "cover", "resolve", "enqueueDownloads", "localPlayback"} {
			input := nativeInput{Action: action, Source: source, Drama: nativeDrama{ID: source + ":123", Source: source}}
			err := nativeAuthorizeInput(input)
			if (err == nil) != (buildAllSources == "true") {
				t.Fatal("source crossed edition boundary", source, action, err)
			}
		}
		input := nativeInput{Action: "resolve", Drama: nativeDrama{ID: source + ":123", Source: source}, Chapter: Chapter{Source: "hongguo"}}
		if !errors.Is(nativeAuthorizeInput(input), errNativeBuildSource) {
			t.Fatal("mixed source chapter accepted")
		}
		if _, _, valid := splitProviderDramaID(source + ":123"); !valid {
			t.Fatal("new source cannot restore saved identity")
		}
	}
}
