package core

import (
	"context"
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
		if proxy.PAC {
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
