package core

import (
	"context"
	"io"
	"time"
)

// 只限制正在等待的 Read，播放器暂停消费不算上游停滞；每次读取独立计时。
// cancel 中断 HTTP 请求上下文，让底层阻塞的 Read 返回。
type idleReadBody struct {
	io.ReadCloser
	cancel context.CancelFunc
	timeout time.Duration
}

func (body *idleReadBody) Read(buffer []byte) (int, error) {
	timer := time.AfterFunc(body.timeout, body.cancel)
	defer timer.Stop()
	return body.ReadCloser.Read(buffer)
}

func (body *idleReadBody) Close() error {
	body.cancel()
	return body.ReadCloser.Close()
}
