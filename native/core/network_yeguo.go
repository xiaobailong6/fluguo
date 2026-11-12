package core

import (
	"context"
	"net"
	"time"
)

// 只在野果 TCP 建连阶段回退，HTTP 状态、证书错误和业务响应不会触发 DNS 重试。
// Transport 仍持有原 URL，因此 Host、SNI 和证书校验保持原域名；配置代理时
// DialContext 收到的是代理地址，正常代理连接不会改成直连目标站。
func yeguoDNSDialer(dial func(context.Context, string, string) (net.Conn, error), resolver *dnsResolver) func(context.Context, string, string) (net.Conn, error) {
	if dial == nil {
		dial = (&net.Dialer{Timeout: 10 * time.Second}).DialContext
	}
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil || !isYeguoActiveSite("https://"+host) {
			return dial(ctx, network, address)
		}
		// 为错误系统 DNS 地址限制首次拨号预算，给同一请求中的 DoH 回退留出时间。
		attempt, cancel := context.WithTimeout(ctx, 3*time.Second)
		connection, firstErr := dial(attempt, network, address)
		cancel()
		if firstErr == nil || ctx.Err() != nil {
			return connection, firstErr
		}
		addresses, err := resolver.lookup(ctx, host)
		if err != nil {
			return nil, firstErr
		}
		for index, ip := range addresses {
			if index >= 4 || ctx.Err() != nil {
				break
			}
			attempt, cancel := context.WithTimeout(ctx, 3*time.Second)
			connection, err := dial(attempt, network, net.JoinHostPort(ip, port))
			cancel()
			if err == nil {
				return connection, nil
			}
		}
		return nil, firstErr
	}
}
