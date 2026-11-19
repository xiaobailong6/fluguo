package core

import (
	"context"
	"io"
	"net/http"
	"sync"
	"time"
)

const mediaIdleReadTimeout = 30 * time.Second

// 只限制正在等待的 Read，播放器暂停消费不算上游停滞；每次读取独立计时。
// cancel 中断 HTTP 请求上下文，让底层阻塞的 Read 返回。
type idleReadBody struct {
	io.ReadCloser
	cancel  context.CancelFunc
	timeout time.Duration
}

func (body *idleReadBody) Read(buffer []byte) (int, error) {
	if len(buffer) == 0 {
		return body.ReadCloser.Read(buffer)
	}
	// Stop 不会等待已启动的回调；用同一把锁撤销活动状态，防止旧计时器
	// 在 Read 返回后取消下一次读取或暂停中的消费者。
	var mu sync.Mutex
	active, expired := true, false
	timer := time.AfterFunc(body.timeout, func() {
		mu.Lock()
		defer mu.Unlock()
		if active {
			expired = true
			body.cancel()
		}
	})
	n, err := body.ReadCloser.Read(buffer)
	mu.Lock()
	active = false
	timer.Stop()
	if expired {
		err = context.DeadlineExceeded
	}
	mu.Unlock()
	return n, err
}

func (body *idleReadBody) Close() error {
	body.cancel()
	return body.ReadCloser.Close()
}

// 在 RoundTrip 边界包装，既覆盖普通传输，也覆盖凭证刷新内部读取的错误正文。
// 不改共享 client/transport，不丢失重定向、授权、代理和浏览器指纹策略。
type idleReadTransport struct {
	base    http.RoundTripper
	timeout time.Duration
}

func (transport *idleReadTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	ctx, cancel := context.WithCancel(request.Context())
	response, err := transport.base.RoundTrip(request.WithContext(ctx))
	if err != nil {
		cancel()
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		return response, err
	}
	if body, ok := response.Body.(*idleReadBody); ok {
		// 浏览器路径已有相同保护；复用一个计时器，并一起释放两层请求上下文。
		previous := body.cancel
		body.cancel = func() { previous(); cancel() }
		body.timeout = transport.timeout
	} else {
		response.Body = &idleReadBody{ReadCloser: response.Body, cancel: cancel, timeout: transport.timeout}
	}
	return response, nil
}
