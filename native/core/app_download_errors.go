package core

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
)

func nativeDownloadConnectionError(ctx, requestCtx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if requestCtx.Err() != nil {
		return errors.New("下载连接 30 秒没有响应，请检查网络后继续")
	}
	var transport *url.Error
	if errors.As(err, &transport) {
		err = transport.Err
	}
	var network net.Error
	if errors.As(err, &network) && network.Timeout() {
		return fmt.Errorf("下载连接超时：%w", publicError(err))
	}
	// 保留可定位的连接原因，但不把签名查询和代理口令显示给用户。
	return fmt.Errorf("下载连接失败：%w", publicError(err))
}
