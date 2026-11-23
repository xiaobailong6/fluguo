package core

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var errNativePlaybackListener = errors.New("本机播放监听已失效，请重试")

// 持有 listenerMu 时探测当前监听；该函数不重建、不改变任何会话身份。
func (stream *nativeStreamServer) probeLoopback(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case <-stream.listenerDone:
		return errNativePlaybackListener
	default:
	}
	dialer := net.Dialer{Timeout: 500 * time.Millisecond}
	conn, err := dialer.DialContext(ctx, "tcp4", strings.TrimPrefix(stream.address, "http://"))
	if conn != nil {
		_ = conn.Close()
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	select {
	case <-stream.listenerDone:
		return errNativePlaybackListener
	default:
		return err
	}
}

// 身份比较与有界存活探测共用生命周期锁，不能把另一代监听当作旧计划的成功。
func (stream *nativeStreamServer) validateLoopbackSession(ctx context.Context, token string) error {
	stream.listenerMu.Lock()
	defer stream.listenerMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if session == nil || session.ctx.Err() != nil || session.listener == nil ||
		session.listener != stream.server || session.origin != stream.address {
		return errNativePlaybackListener
	}
	err := stream.probeLoopback(ctx)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil || session.ctx.Err() != nil {
		return errNativePlaybackListener
	}
	return nil
}

// 适配 guoapp fb6103b：系统挂起可能让监听失效但不关闭描述符，
// 因此不能只检查 server != nil；创建新计划前用本机 TCP 有界探测。
func (stream *nativeStreamServer) ensureLoopback(ctx context.Context) error {
	stream.listenerMu.Lock()
	defer stream.listenerMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	err := stream.probeLoopback(ctx)
	// 用户取消不能触发重建，更不能登记新的播放会话。
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err == nil {
		return nil
	}
	_, portText, _ := net.SplitHostPort(strings.TrimPrefix(stream.address, "http://"))
	port, _ := strconv.Atoi(portText)
	recordStreamListener(stream.downloader, "listen_probe_failed", port, err)
	return stream.startLoopback()
}

// stream 发布后调用者必须持 listenerMu；先成功绑定再替换旧监听，
// 重建失败保留原状态，且不清空已有会话、资源租约或媒体缓存。
func (stream *nativeStreamServer) startLoopback() error {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		recordStreamListener(stream.downloader, "listen_failed", 0, err)
		return errors.New("无法初始化本机播放器")
	}
	server := &http.Server{Handler: http.HandlerFunc(stream.nativeServe), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	previous := stream.server
	done := make(chan struct{})
	stream.listenerDone = done
	stream.server = server
	stream.address = "http://" + listener.Addr().String()
	port := listener.Addr().(*net.TCPAddr).Port
	recordStreamListener(stream.downloader, "listen_started", port, nil)
	go func() {
		err := server.Serve(listener)
		close(done)
		recordStreamListener(stream.downloader, "listen_exited", port, err)
	}()
	if previous != nil {
		_ = previous.Close()
	}
	return nil
}

func recordStreamListener(d *Downloader, event string, port int, err error) {
	level := "info"
	message := fmt.Sprintf("port=%d", port)
	switch {
	case errors.Is(err, http.ErrServerClosed):
		message += " reason=server_closed"
	case err != nil:
		level = "warning"
		message += " reason=" + nativeStreamError(err)
		var errno syscall.Errno
		if errors.As(err, &errno) {
			message += fmt.Sprintf(" errno=%d", errno)
		}
	}
	entry := diagnosticEvent{Event: "stream." + event, Level: level, Host: "127.0.0.1", Message: message}
	// 保持本项目正常播放不落诊断的约定；真正监听故障无需开启调试也能排查。
	if level == "warning" {
		d.recordDiagnostic(entry)
	} else {
		d.recordTrace(entry)
	}
}
