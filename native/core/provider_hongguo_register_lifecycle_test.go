package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// 模拟只收到响应头、响应体仍依赖请求上下文的真实网络响应。
// strings.Reader 不会感知取消，旧注册测试因此漏掉了提前 cancel 的故障。
type hongguoRegisterContextBody struct {
	ctx context.Context
	io.Reader
}

func (body *hongguoRegisterContextBody) Read(data []byte) (int, error) {
	if err := body.ctx.Err(); err != nil {
		return 0, err
	}
	return body.Reader.Read(data)
}

func (*hongguoRegisterContextBody) Close() error { return nil }

func TestHongguoProxylessRegisterResponseLifetime(t *testing.T) {
	d := sourceFixtureDownloader(t, nil)
	var requestContext context.Context
	d.directOnce.Do(func() {
		d.directClient = &http.Client{Transport: sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
			requestContext = r.Context()
			response := sourceFixtureResponse(r, http.StatusOK, "")
			response.Body = &hongguoRegisterContextBody{r.Context(), strings.NewReader(`{"device_id_str":"1001","install_id_str":"10019"}`)}
			return response, nil
		})}
	})
	response, err := d.doProxylessRegister(context.Background(), []byte(`{}`), url.Values{})
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if _, ok := requestContext.Deadline(); !ok {
		t.Fatal("registration lost its request timeout")
	}
	body, err := io.ReadAll(response.Body)
	if err != nil || !strings.Contains(string(body), "10019") {
		t.Fatalf("registration response cancelled before reading: %v", err)
	}
	d.limiter.mu.Lock()
	active := d.limiter.active
	d.limiter.mu.Unlock()
	if active != 1 {
		t.Fatalf("registration released its request slot before body close: %d", active)
	}
	response.Body.Close()
	if !errors.Is(requestContext.Err(), context.Canceled) {
		t.Fatal("body close did not cancel request timeout")
	}
	d.limiter.mu.Lock()
	active = d.limiter.active
	d.limiter.mu.Unlock()
	if active != 0 {
		t.Fatal("body close leaked request slot")
	}
}

func TestHongguoProxylessRegisterFailureReleasesRequest(t *testing.T) {
	d := sourceFixtureDownloader(t, nil)
	var requestContext context.Context
	failure := errors.New("registration connection failed")
	d.directOnce.Do(func() {
		d.directClient = &http.Client{Transport: sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
			requestContext = r.Context()
			return nil, failure
		})}
	})
	response, err := d.doProxylessRegister(context.Background(), []byte(`{}`), url.Values{})
	if response != nil || !errors.Is(err, failure) || !errors.Is(requestContext.Err(), context.Canceled) {
		t.Fatal("failed registration lost error or timeout cleanup", err)
	}
	d.limiter.mu.Lock()
	active := d.limiter.active
	d.limiter.mu.Unlock()
	if active != 0 {
		t.Fatal("failed registration leaked request slot")
	}
}
