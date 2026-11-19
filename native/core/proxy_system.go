package core

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"net"
	"net/http"
	"net/url"
	"path"
	"slices"
	"strings"
	"time"
)

type nativeSystemProxy struct {
	HTTP   string   `json:"http"`
	HTTPS  string   `json:"https"`
	Bypass []string `json:"bypass"`
	PAC    bool     `json:"pac"`
	PACURL string   `json:"-"`
}

func (router *proxyRouter) resolveSystem(request *http.Request) (*url.URL, error) {
	system := router.systemSettings()
	if system.PACURL != "" {
		router.mu.RLock()
		resolve := router.pacResolver
		router.mu.RUnlock()
		if resolve == nil {
			resolve = platformPACProxy
		}
		address, err := resolve(system.PACURL, request.URL)
		if err == nil {
			// PAC 的 DIRECT（nil, nil）也是成功，不能继续套用静态代理。
			return address, nil
		}
		router.reportPACFailure(request.URL.Hostname(), err)
	}
	return system.resolve(request)
}

func (router *proxyRouter) reportPACFailure(host string, err error) {
	if err == nil {
		return
	}
	message := err.Error()
	// 按原始错误文本去重，但只保留定长摘要，不在缓存中保存凭证或任意长错误。
	key := sha256.Sum256([]byte(message))
	router.mu.RLock()
	clock := router.pacNow
	router.mu.RUnlock()
	current := time.Now()
	if clock != nil {
		current = clock()
	}
	router.mu.Lock()
	if router.record == nil {
		router.mu.Unlock()
		return
	}
	if last, seen := router.pacFailures[key]; seen && current.Sub(last) < 5*time.Minute {
		router.mu.Unlock()
		return
	}
	if router.pacFailures == nil {
		router.pacFailures = make(map[[32]byte]time.Time)
	}
	// 先检查重复项；满额时仅淘汰最早记录，避免清空缓存使所有重复错误重新刷屏。
	if _, seen := router.pacFailures[key]; !seen && len(router.pacFailures) >= 64 {
		var oldest [32]byte
		var oldestTime time.Time
		for cached, recorded := range router.pacFailures {
			if oldestTime.IsZero() || recorded.Before(oldestTime) {
				oldest, oldestTime = cached, recorded
			}
		}
		delete(router.pacFailures, oldest)
	}
	router.pacFailures[key] = current
	record := router.record
	router.mu.Unlock()
	// 回调可写日志或重新访问路由器；必须在锁外调用，并复用已有 URL 脱敏规则。
	record(diagnosticEvent{Event: "proxy.pac_failed", Level: "warning", Host: redactErrorString(host),
		Message: "自动代理脚本解析失败，已改用系统静态代理、环境变量或直连：" + redactErrorString(message)})
}

func (proxy nativeSystemProxy) resolve(request *http.Request) (*url.URL, error) {
	host := strings.ToLower(request.URL.Hostname())
	for _, exception := range proxy.Bypass {
		exception = strings.ToLower(strings.TrimSpace(exception))
		if exception == "<local>" && !strings.Contains(host, ".") && net.ParseIP(host) == nil {
			return nil, nil
		}
		if matched, _ := path.Match(exception, host); exception != "" && matched {
			return nil, nil
		}
	}
	address := proxy.HTTP
	if request.URL.Scheme == "https" {
		address = proxy.HTTPS
	}
	if address == "" {
		if proxy.PAC && proxy.PACURL == "" {
			return nil, errors.New("绯荤粺浣跨敤鑷姩浠ｇ悊鑴氭湰锛岃鍦ㄧ綉缁滆缃腑閰嶇疆鎵嬪姩浠ｇ悊鎴栭€夋嫨鐩磋繛")
		}
		return http.ProxyFromEnvironment(request)
	}
	return url.Parse(address)
}

func (router *proxyRouter) systemSettings() nativeSystemProxy {
	router.mu.Lock()
	defer router.mu.Unlock()
	if !router.systemOverride && time.Since(router.systemRead) > 30*time.Second {
		router.system = platformSystemProxy()
		router.systemRead = time.Now()
	}
	return router.system
}

func (engine *nativeEngine) updateSystemProxy(proxy nativeSystemProxy) error {
	for _, address := range []string{proxy.HTTP, proxy.HTTPS} {
		if address == "" {
			continue
		}
		settings := defaultResourceSettings()
		settings.ProxyMode, settings.ProxyURL = "manual", address
		if err := settings.validate(); err != nil {
			return err
		}
	}
	if len(proxy.Bypass) > 1000 {
		return errors.New("绯荤粺浠ｇ悊鎺掗櫎鍒楄〃杩囬暱")
	}
	router := engine.downloader.proxyRouter
	router.mu.Lock()
	if router.systemOverride && router.system.HTTP == proxy.HTTP && router.system.HTTPS == proxy.HTTPS &&
		router.system.PAC == proxy.PAC && slices.Equal(router.system.Bypass, proxy.Bypass) {
		router.mu.Unlock()
		return nil
	}
	router.system, router.systemOverride = proxy, true
	router.mu.Unlock()
	engine.downloader.client.CloseIdleConnections()
	return nil
}

// proxyInUse 判断该地址当前是否真的会经过代理；没有代理时直连重试没有意义。
func (d *Downloader) proxyInUse(ctx context.Context, address string) bool {
	if d.proxyRouter == nil {
		return false
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return false
	}
	request := (&http.Request{URL: parsed}).WithContext(ctx)
	proxy, err := d.proxyRouter.proxy(request)
	return err == nil && proxy != nil
}

// proxylessClient 返回不走代理的 HTTP 客户端，用于代理链路失败后的直连重试。
func (d *Downloader) proxylessClient() *http.Client {
	d.directOnce.Do(func() {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		transport.MaxIdleConnsPerHost = 8
		transport.ResponseHeaderTimeout = 20 * time.Second
		transport.Proxy = nil
		d.directClient = &http.Client{Transport: transport, Timeout: 45 * time.Second}
	})
	return d.directClient
}
