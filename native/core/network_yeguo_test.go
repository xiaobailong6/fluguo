package core

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
)

func TestYeguoDNSRecoveryKeepsVerifiedIdentity(t *testing.T) {
	const host = "attract.vgbyziuz.cc"
	var lookups atomic.Int32
	var dials atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != host || r.TLS.ServerName != host || r.URL.RequestURI() != "/api/test?sign=a%2Fb" || r.Method != http.MethodPost {
			t.Error("DNS fallback changed request identity")
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "" {
			t.Error("unexpected body")
		}
		w.WriteHeader(http.StatusForbidden)
	}))
	defer server.Close()
	// 用测试 CA 签发匹配野果域名的证书，回归测试也保持 TLS 验证开启。
	certificate := server.TLS.Certificates[0]
	template := *server.Certificate()
	template.DNSNames = []string{host}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, template.PublicKey, certificate.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	certificate.Certificate = [][]byte{der}
	certificate.Leaf = nil
	server.TLS.Certificates[0] = certificate
	trusted, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(trusted)
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	base.DisableKeepAlives = true
	base.TLSClientConfig = &tls.Config{RootCAs: roots}
	base.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address == host+":443" {
			dials.Add(1)
			return nil, &net.DNSError{Err: "synthetic wrong system address timeout", Name: host, IsTimeout: true}
		}
		if address != "93.184.216.34:443" {
			t.Errorf("unexpected destination %s", address)
			return nil, io.EOF
		}
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	resolver := newDNSResolver(base)
	resolver.client.Transport = sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
		lookups.Add(1)
		return sourceFixtureResponse(r, 200, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"}]}`), nil
	})
	transport := newCDNTransport(base, resolver)
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	for index := 0; index < 2; index++ {
		request, _ := http.NewRequest(http.MethodPost, "https://"+host+"/api/test?sign=a%2Fb", nil)
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatal("HTTP business response changed", response.StatusCode)
		}
	}
	if lookups.Load() != 1 || dials.Load() != 2 {
		t.Fatalf("DNS TTL reuse mismatch: lookups=%d dials=%d", lookups.Load(), dials.Load())
	}
}

func TestYeguoDNSDoesNotBypassProxyOrRetryOtherHosts(t *testing.T) {
	for _, mode := range []string{"proxy", "other", "canceled", "private"} {
		t.Run(mode, func(t *testing.T) {
			var lookups, dials atomic.Int32
			base := http.DefaultTransport.(*http.Transport).Clone()
			base.Proxy = nil
			base.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
				dials.Add(1)
				if mode == "proxy" && address != "proxy.example:8080" {
					t.Error("configured proxy bypassed", address)
				}
				return nil, errors.New("synthetic dial failure")
			}
			if mode == "proxy" {
				proxy, _ := url.Parse("http://proxy.example:8080")
				base.Proxy = http.ProxyURL(proxy)
			}
			resolver := newDNSResolver(base)
			resolver.client.Transport = sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
				lookups.Add(1)
				return sourceFixtureResponse(r, 200, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"127.0.0.1"}]}`), nil
			})
			transport := newCDNTransport(base, resolver)
			defer transport.CloseIdleConnections()
			address := "https://attract.vgbyziuz.cc/"
			if mode == "other" {
				address = "https://unrelated.example/"
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if mode == "canceled" {
				cancel()
			}
			request, _ := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
			response, err := transport.RoundTrip(request)
			if response != nil {
				response.Body.Close()
			}
			if err == nil || (mode != "private" && lookups.Load() != 0) || dials.Load() > 1 {
				t.Fatalf("unsafe fallback: err=%v lookups=%d dials=%d", err, lookups.Load(), dials.Load())
			}
		})
	}
}
