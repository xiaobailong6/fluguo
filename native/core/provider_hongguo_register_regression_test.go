package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
)

func TestHongguoRegisterGatewayClassification(t *testing.T) {
	body, err := os.ReadFile("testdata/backend_register_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name     string
		Status   int
		Body     string
		Rejected bool
	}
	if err := json.Unmarshal(body, &cases); err != nil {
		t.Fatal(err)
	}
	for _, check := range cases {
		t.Run(check.Name, func(t *testing.T) {
			calls := 0
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return sourceFixtureResponse(request, check.Status, check.Body), nil
				}
				return sourceFixtureResponse(request, 200, `{"device_id_str":"5001","install_id_str":"5002"}`), nil
			})
			client := d.hongguoClient()
			client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", false
			err := d.ensureHongguoDevice(context.Background(), false, "")
			var rejection hongguoRegisterRejection
			if err == nil || errors.As(err, &rejection) != check.Rejected {
				t.Fatal("wrong error classification", err)
			}
			if client.state.DeviceID != "7" || client.state.InstallID != "8" {
				t.Fatal("old identity changed")
			}
			// HTTP 403/429 的通用网络退避仍应保留；这里只验证注册自己的十分钟暂停。
			d.limiter = newRequestLimiter(3, 0)
			err = d.ensureHongguoDevice(context.Background(), false, "")
			if check.Rejected {
				if err == nil || calls != 1 || client.registerPausedUntil.IsZero() {
					t.Fatal("real rejection not paused", err, calls)
				}
			} else if err != nil || calls != 2 || client.state.DeviceID != "5001" || !client.registerPausedUntil.IsZero() {
				t.Fatal("temporary error poisoned registration", err, calls)
			}
		})
	}
}

func TestHongguoRegisterOversizeAndCancellationStayTemporary(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			if cancelled {
				cancel()
			}
			return sourceFixtureResponse(request, 200, strings.Repeat("x", (64<<10)+1)), nil
		})
		d.hongguoClient().state.Registered = false
		err := d.ensureHongguoDevice(ctx, false, "")
		cancel()
		var rejection hongguoRegisterRejection
		if err == nil || errors.As(err, &rejection) || !d.hongguoClient().registerPausedUntil.IsZero() {
			t.Fatal("temporary error paused registration", err)
		}
	}
}
