package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"
)

func TestNativeProtocolBeforeInitialization(t *testing.T) {
	nativeState.Lock()
	before := nativeState.engine
	nativeState.Unlock()
	var response struct {
		OK   bool `json:"ok"`
		Data struct {
			Version      int      `json:"protocolVersion"`
			Minimum      int      `json:"minCompatibleVersion"`
			All          bool     `json:"allSources"`
			Capabilities []string `json:"capabilities"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(NativeRequest(`{"action":"protocol"}`)), &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Data.Version != 1 || response.Data.Minimum != 1 || response.Data.All != (buildAllSources == "true") {
		t.Fatalf("invalid handshake: %+v", response)
	}
	capabilities := map[string]bool{}
	for _, capability := range response.Data.Capabilities {
		capabilities[capability] = true
	}
	if !capabilities["structuredErrors"] || !capabilities["catalogWarningDetails"] {
		t.Fatal("missing capabilities")
	}
	nativeState.Lock()
	after := nativeState.engine
	nativeState.Unlock()
	if before != after {
		t.Fatal("protocol query initialized engine")
	}
}

func TestNativeStructuredFailureClassification(t *testing.T) {
	until := time.Now().Add(time.Minute)
	for _, row := range []struct {
		err  error
		code string
	}{
		{errNativeLocalFile, "local_media"},
		{errSoraniLoginRequired, "source_login"},
		{errSoraniLoginExpired, "source_login"},
		{errNativeBuildSource, "source_unavailable"},
		{context.Canceled, "cancelled"},
		{context.DeadlineExceeded, "timeout"},
		{&net.DNSError{Err: "offline", Name: "fixture.invalid"}, "network"},
		{&requestBackoff{until: until}, "source_blocked"},
		{errors.New("source_login is only text"), ""},
	} {
		got := nativeFailureFor(fmt.Errorf("wrapped: %w", row.err))
		if got.Code != row.code {
			t.Errorf("code=%q want %q", got.Code, row.code)
		}
		if row.code == "source_blocked" && (got.RetryAt == nil || !got.RetryAt.Equal(until)) {
			t.Fatal("retry deadline lost")
		}
	}
}

func TestNativeProtocolEnvelopeAndPartialWarning(t *testing.T) {
	var malformed map[string]any
	if err := json.Unmarshal([]byte(NativeRequest(`{`)), &malformed); err != nil {
		t.Fatal(err)
	}
	if malformed["ok"] != false || malformed["code"] != "invalid_request" {
		t.Fatalf("%v", malformed)
	}
	details := nativeFailureFor(context.DeadlineExceeded)
	body, err := json.Marshal(nativeCatalogResult{Items: []nativeDrama{}, Warning: "部分失败", WarningDetails: &details})
	if err != nil {
		t.Fatal(err)
	}
	var page map[string]any
	if err := json.Unmarshal(body, &page); err != nil {
		t.Fatal(err)
	}
	if page["warning"] != "部分失败" || page["warningDetails"].(map[string]any)["code"] != "timeout" {
		t.Fatalf("%s", body)
	}
}
