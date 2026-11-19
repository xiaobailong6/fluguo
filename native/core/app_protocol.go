package core

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"time"
)

// 协议与应用显示版本独立；纯查询不能创建目录、启动下载或访问站源。
const nativeProtocolVersion = 1

func nativeProtocolInfo() map[string]any {
	return map[string]any{
		"version": "0.2.17", "standalone": true, "allSources": buildAllSources == "true",
		"protocolVersion": nativeProtocolVersion, "minCompatibleVersion": 1,
		"capabilities": []string{"structuredErrors", "catalogWarningDetails"},
	}
}

// 错误码以类型判定，保留原始错误的因果链，不依赖可能变化的展示文案。
type nativeFailureDetails struct {
	Code    string     `json:"code,omitempty"`
	RetryAt *time.Time `json:"retryAt,omitempty"`
}

func nativeFailureFor(err error) nativeFailureDetails {
	var backoff *requestBackoff
	var network net.Error
	switch {
	case errors.Is(err, errNativeLocalFile):
		return nativeFailureDetails{Code: "local_media"}
	case errors.Is(err, errSoraniLoginRequired), errors.Is(err, errSoraniLoginExpired):
		return nativeFailureDetails{Code: "source_login"}
	case errors.Is(err, errNativeBuildSource):
		return nativeFailureDetails{Code: "source_unavailable"}
	case errors.As(err, &backoff):
		return nativeFailureDetails{Code: "source_blocked", RetryAt: &backoff.until}
	case errors.Is(err, context.Canceled):
		return nativeFailureDetails{Code: "cancelled"}
	case errors.Is(err, context.DeadlineExceeded):
		return nativeFailureDetails{Code: "timeout"}
	case errors.As(err, &network):
		if network.Timeout() {
			return nativeFailureDetails{Code: "timeout"}
		}
		return nativeFailureDetails{Code: "network"}
	default:
		return nativeFailureDetails{}
	}
}

// C ABI 的 JSON 信封单独管理，业务分派不再承担编码与错误分类。
func NativeRequest(raw string) (result string) {
	defer func() {
		if recover() != nil {
			result = `{"ok":false,"error":"本地核心处理失败，请重试","code":"internal"}`
		}
	}()
	var input nativeInput
	if len(raw) > 1<<20 || json.Unmarshal([]byte(raw), &input) != nil {
		return `{"ok":false,"error":"请求格式无效","code":"invalid_request"}`
	}
	data, err := nativeDispatch(input)
	envelope := map[string]any{"ok": err == nil}
	if err != nil {
		envelope["error"] = publicError(err).Error()
		details := nativeFailureFor(err)
		if details.Code != "" {
			envelope["code"] = details.Code
		}
		if details.RetryAt != nil {
			envelope["retryAt"] = details.RetryAt
		}
	} else {
		envelope["data"] = data
	}
	body, marshalErr := json.Marshal(envelope)
	if marshalErr != nil {
		return `{"ok":false,"error":"无法读取站源返回的数据","code":"internal"}`
	}
	return string(body)
}
