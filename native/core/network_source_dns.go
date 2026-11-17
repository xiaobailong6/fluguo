package core

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type sourceDNSProxyKey struct{}
type sourceDNSDialKey struct{}

type sourceDNSProxyDecision struct {
	mu      sync.Mutex
	checked bool
	blocked bool
}

// 记录首个请求实际使用的代理决策，不能在失败后重新求值而把代理错误变为直连。
// 对其他请求不改变原 Proxy 回调；状态仅存在于当前请求的 context 中。
func sourceDNSProxy(proxy func(*http.Request) (*url.URL, error)) func(*http.Request) (*url.URL, error) {
	if proxy == nil {
		return nil
	}
	return func(request *http.Request) (*url.URL, error) {
		address, err := proxy(request)
		if decision, ok := request.Context().Value(sourceDNSProxyKey{}).(*sourceDNSProxyDecision); ok {
			decision.mu.Lock()
			decision.checked = true
			decision.blocked = decision.blocked || address != nil || err != nil
			decision.mu.Unlock()
		}
		return address, err
	}
}

// 首次拨号仍使用原实现，不新建/丢弃探测连接；若实现同时返回连接与错误则负责关闭。
func sourceDNSInitialDialer(dial func(context.Context, string, string) (net.Conn, error)) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		original, tracked := ctx.Value(sourceDNSDialKey{}).(context.Context)
		if _, hasDeadline := ctx.Deadline(); tracked && !hasDeadline {
			ctx = original
		}
		connection, err := dial(ctx, network, address)
		if tracked && err != nil && connection != nil {
			connection.Close()
			connection = nil
		}
		return connection, err
	}
}

func sourceDNSHost(host string) bool {
	if net.ParseIP(host) != nil || strings.EqualFold(host, "localhost") {
		return false
	}
	for _, descriptor := range nativeSourceDescriptors {
		for _, allowed := range descriptor.DNSHosts {
			if strings.EqualFold(host, allowed) {
				return true
			}
		}
	}
	return false
}

func replayableNetworkBody(request *http.Request) bool {
	return request.Body == nil || request.Body == http.NoBody || request.GetBody != nil
}

// 仅认定 NXDOMAIN 或 TCP 拨号落到本机/未指定地址，普通超时、TLS 和 HTTP 错误不重试。
func blockedSourceDNS(request *http.Request, err error) bool {
	if err == nil || request.Context().Err() != nil || request.URL.Scheme != "https" ||
		!sourceDNSHost(request.URL.Hostname()) || !replayableNetworkBody(request) ||
		errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || sourceDNSTLSError(err) {
		return false
	}
	var lookupErr *net.DNSError
	if errors.As(err, &lookupErr) {
		return lookupErr.IsNotFound && !lookupErr.IsTimeout
	}
	var dialErr *net.OpError
	if !errors.As(err, &dialErr) || dialErr.Op != "dial" || dialErr.Timeout() {
		return false
	}
	address, ok := dialErr.Addr.(*net.TCPAddr)
	return ok && address != nil && (address.IP.IsUnspecified() || address.IP.IsLoopback())
}

func sourceDNSTLSError(err error) bool {
	var verification *tls.CertificateVerificationError
	var unknown x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var record tls.RecordHeaderError
	return errors.As(err, &verification) || errors.As(err, &unknown) || errors.As(err, &hostname) ||
		errors.As(err, &invalid) || errors.As(err, &record)
}

// 此分支仅服务普通 net/http 站源请求。浏览器指纹客户端自行处理连接，不能在这里
// 将 tls-client 请求降级为普通 TLS，也不因 403 或浏览器验证导入外部 Cookie。
func (transport *cdnTransport) roundTripSourceDNS(request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "https" || !sourceDNSHost(request.URL.Hostname()) || !replayableNetworkBody(request) ||
		transport.base.DialTLSContext != nil || transport.base.DialTLS != nil {
		return transport.base.RoundTrip(request)
	}
	decision := &sourceDNSProxyDecision{}
	ctx := context.WithValue(request.Context(), sourceDNSProxyKey{}, decision)
	upstream := request.Clone(context.WithValue(ctx, sourceDNSDialKey{}, request.Context()))
	response, firstErr := transport.base.RoundTrip(upstream)
	if response != nil {
		response.Request = request
	}
	decision.mu.Lock()
	proxyBlocked := decision.blocked || (transport.base.Proxy != nil && !decision.checked)
	decision.mu.Unlock()
	if proxyBlocked || !blockedSourceDNS(request, firstErr) || transport.resolver == nil {
		return response, firstErr
	}
	if response != nil && response.Body != nil {
		response.Body.Close()
	}
	entry, err := transport.resolver.lookupEntry(request.Context(), request.URL.Hostname(), "")
	if request.Context().Err() != nil {
		return nil, request.Context().Err()
	}
	if err != nil {
		return nil, firstErr
	}
	lastErr := firstErr
	tried := map[string]bool{}
	for _, address := range entry.addresses {
		if len(tried) >= 4 {
			break
		}
		if tried[address] {
			continue
		}
		if err := request.Context().Err(); err != nil {
			return nil, err
		}
		tried[address] = true
		response, err := transport.roundTripSourceAddress(request, address)
		if err == nil {
			return response, nil
		}
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		if request.Context().Err() != nil {
			return nil, request.Context().Err()
		}
		// 解析恢复后的证书失败仍应直接报错，不通过下一个地址绕过身份校验。
		if sourceDNSTLSError(err) {
			return nil, err
		}
		lastErr = err
	}
	return nil, fmt.Errorf("站源 %s 连接失败（已尝试备用 DNS 地址）: %w", request.URL.Hostname(), publicError(lastErr))
}

func (transport *cdnTransport) roundTripSourceAddress(request *http.Request, address string) (*http.Response, error) {
	upstream := request.Clone(context.WithValue(request.Context(), sourceDNSDialKey{}, request.Context()))
	if request.Body != nil && request.Body != http.NoBody {
		if request.GetBody == nil {
			return nil, errors.New("站源请求体无法重放")
		}
		body, err := request.GetBody()
		if err != nil {
			return nil, err
		}
		if body == nil {
			return nil, errors.New("站源请求体重放为空")
		}
		upstream.Body = body
	}
	// 仅替换拨号目标：URL、Host、签名 query 和 Transport 的 TLS/SNI 校验保持不变。
	response, err := transport.sourcePinnedTransport(request.URL.Host, address).RoundTrip(upstream)
	if response != nil {
		response.Request = request
	}
	return response, err
}

func (transport *cdnTransport) sourcePinnedTransport(host, address string) *http.Transport {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	key := "source-dns|" + host + "|" + address
	if existing := transport.transports[key]; existing != nil {
		return existing
	}
	pinned := transport.base.Clone()
	pinned.Proxy = nil // 仅在首个请求确认为直连后才能进入此方法。
	dial := transport.base.DialContext
	if dial == nil {
		dial = (&net.Dialer{Timeout: 10 * time.Second}).DialContext
	}
	pinned.DialContext = func(ctx context.Context, network, target string) (net.Conn, error) {
		// net/http 可为连接池剥离拨号 context 的取消信号，显式取回本次请求预算。
		if original, ok := ctx.Value(sourceDNSDialKey{}).(context.Context); ok {
			ctx = original
		}
		_, port, err := net.SplitHostPort(target)
		if err != nil {
			return nil, err
		}
		attempt, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		connection, err := dial(attempt, network, net.JoinHostPort(address, port))
		if err != nil && connection != nil {
			connection.Close()
			connection = nil
		}
		return connection, err
	}
	if len(transport.transports) >= 32 {
		for key, old := range transport.transports {
			old.CloseIdleConnections()
			delete(transport.transports, key)
			break
		}
	}
	transport.transports[key] = pinned
	return pinned
}
