package core

import (
	"io"
	"net/http"
)

// 只旁观调用方读到的错误页前缀；不消费、替换正文，也不改变原有超时。
type mediaBackoffBody struct {
	io.ReadCloser
	limiter  *requestLimiter
	request  *http.Request
	response *http.Response
	prefix   []byte
	finished bool
}

func (body *mediaBackoffBody) Read(p []byte) (int, error) {
	n, err := body.ReadCloser.Read(p)
	if !body.finished {
		remaining := (64 << 10) - len(body.prefix)
		body.prefix = append(body.prefix, p[:min(n, remaining)]...)
		if catalogResponseBlockReason(body.response, body.prefix) != "" {
			body.limiter.observeBlock(body.request, body.response)
			body.finished = true
		}
		if err != nil || len(body.prefix) == 64<<10 {
			body.finished = true
		}
		if body.finished {
			body.prefix = nil
		}
	}
	return n, err
}
