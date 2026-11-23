package core

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
)

func TestHongguoEmptyResponseDiagnosisAndRotationBound(t *testing.T) {
	requests, registers := 0, 0
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/service/2/device_register/" {
			registers++
			return sourceFixtureResponse(r, http.StatusOK, fmt.Sprintf(`{"device_id_str":"%d","install_id_str":"%d"}`, 1000+registers, 2000+registers)), nil
		}
		requests++
		return sourceFixtureResponse(r, http.StatusOK, ""), nil
	})
	d.trace.Store(true)
	d.diagnostics = newDiagnosticLog(t.TempDir())
	query := url.Values{"video_id": {"2222"}, "private_probe": {"must-not-appear-in-log"}}
	_, err := d.hongguoAppRequest(context.Background(), http.MethodGet, hongguoVideoTabPath, query, nil)
	if err == nil || !strings.Contains(err.Error(), "空响应") || !strings.Contains(err.Error(), "HTTP 200") {
		t.Fatal("empty response lost its concrete diagnosis", err)
	}
	if registers != hongguoDeviceRotations || requests != hongguoDeviceRotations+1 {
		t.Fatalf("empty response exceeded rotation budget: register=%d request=%d", registers, requests)
	}
	data, err := os.ReadFile(d.diagnostics.path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, want := range []string{"stream.hongguo_empty_response", hongguoVideoTabPath, "HTTP 200", "字节数 0", "已轮换 3 次"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing diagnostic %q", want)
		}
	}
	for _, secret := range []string{"must-not-appear-in-log", "private_probe", "device_id", "iid=", "X-Medusa", "X-Helios", "video_id="} {
		if strings.Contains(text, secret) {
			t.Errorf("diagnostic leaked request data: %s", secret)
		}
	}
}

func TestHongguoOversizeResponseIsNotEmptyResponse(t *testing.T) {
	d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(r, http.StatusOK, strings.Repeat("x", providerMaxBodyBytes+1)), nil
	})
	_, err := d.hongguoAppRequest(context.Background(), http.MethodGet, hongguoBookmallTabPath, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "超过大小限制") || strings.Contains(err.Error(), "空响应") {
		t.Fatal("oversize response misreported as empty", err)
	}
}
