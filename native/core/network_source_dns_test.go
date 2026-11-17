package core

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func sourceDNSTestHosts(t *testing.T) []string {
	t.Helper()
	var hosts []string
	for _, descriptor := range nativeSourceDescriptors {
		hosts = append(hosts, descriptor.DNSHosts...)
	}
	if len(hosts) == 0 {
		t.Fatal("missing explicit DNS policy hosts")
	}
	return hosts
}

func sourceDNSTestResolver(base *http.Transport, lookups *atomic.Int32, answer string) *dnsResolver {
	resolver := newDNSResolver(base)
	resolver.endpoints = []string{"https://dns-fixture.invalid/resolve"}
	resolver.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		lookups.Add(1)
		return sourceFixtureResponse(request, http.StatusOK, answer), nil
	})
	return resolver
}

// 使用临时 CA 信任库验证真正 TLS 握手，既不访问真实站源，也不关闭证书验证。
func sourceDNSTestServer(t *testing.T, host string, handler http.Handler) (*httptest.Server, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: host}, DNSNames: []string{host},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server, roots
}

func TestSourceDNSAllowedHostsRecoverWithIdentityAndReplay(t *testing.T) {
	for _, host := range sourceDNSTestHosts(t) {
		t.Run(host, func(t *testing.T) {
			var direct, pinned, lookups, replays atomic.Int32
			server, roots := sourceDNSTestServer(t, host, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, err := io.ReadAll(r.Body)
				if err != nil || string(body) != "fixture-body" || r.Host != "original-host.test:9443" ||
					r.TLS.ServerName != host || r.URL.RequestURI() != "/api/fixture%2Fpath?signature=a%2Fb&x=1" {
					t.Error("DNS recovery changed request identity", r.Host, r.TLS.ServerName, r.URL, string(body), err)
				}
				_, _ = io.WriteString(w, "recovered")
			}))
			base := http.DefaultTransport.(*http.Transport).Clone()
			base.Proxy = func(*http.Request) (*url.URL, error) { return nil, nil }
			base.TLSClientConfig = &tls.Config{RootCAs: roots}
			base.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
				if address == net.JoinHostPort(host, "9443") {
					direct.Add(1)
					if direct.Load() == 2 {
						return nil, &net.OpError{Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9443}, Err: io.EOF}
					}
					return nil, &net.DNSError{Name: host, IsNotFound: true}
				}
				if address != "93.184.216.34:9443" {
					t.Error("unexpected destination", address)
					return nil, io.EOF
				}
				pinned.Add(1)
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}
			resolver := sourceDNSTestResolver(base, &lookups, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"}]}`)
			transport := newCDNTransport(base, resolver)
			defer transport.CloseIdleConnections()
			for attempt := 0; attempt < 2; attempt++ {
				request, _ := http.NewRequest(http.MethodPost, "https://"+host+":9443/api/fixture%2Fpath?signature=a%2Fb&x=1", strings.NewReader("fixture-body"))
				request.Host = "original-host.test:9443"
				request.GetBody = func() (io.ReadCloser, error) {
					replays.Add(1)
					return io.NopCloser(strings.NewReader("fixture-body")), nil
				}
				originalURL := request.URL.String()
				response, err := transport.RoundTrip(request)
				if err != nil {
					t.Fatal(err)
				}
				body, err := io.ReadAll(response.Body)
				response.Body.Close()
				if err != nil || string(body) != "recovered" || response.Request != request || request.URL.String() != originalURL || len(response.TLS.VerifiedChains) == 0 {
					t.Fatal("recovery lost URL or TLS verification", err)
				}
			}
			if lookups.Load() != 1 || direct.Load() != 2 || replays.Load() != 2 || pinned.Load() != 1 {
				t.Fatal("TTL, replay or connection reuse lost", lookups.Load(), direct.Load(), replays.Load(), pinned.Load())
			}
			resolver.mu.Lock()
			entry := resolver.cache[host+"|"]
			if ttl := time.Until(entry.expires); ttl <= 0 || ttl > 120*time.Second {
				t.Error("resolver TTL was not preserved", ttl)
			}
			entry.expires = time.Now().Add(-time.Second)
			resolver.cache[host+"|"] = entry
			resolver.mu.Unlock()
			if _, err := resolver.lookupEntry(context.Background(), host, ""); err != nil || lookups.Load() != 2 {
				t.Error("expired DNS cache was reused", err)
			}
		})
	}
}

func TestSourceDNSFailurePolicy(t *testing.T) {
	host := sourceDNSTestHosts(t)[0]
	nxdomain := &net.DNSError{Name: host, IsNotFound: true}
	loopback := func(ip string, cause error) error {
		return &net.OpError{Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP(ip), Port: 443}, Err: cause}
	}
	cases := []struct {
		name, address string
		err           error
		want          bool
	}{
		{"NXDOMAIN", "https://" + host, fmt.Errorf("wrapped: %w", nxdomain), true},
		{"loopback", "https://" + host, loopback("127.0.0.1", io.EOF), true},
		{"unspecified", "https://" + host, loopback("0.0.0.0", io.EOF), true},
		{"ipv6 loopback", "https://" + host, loopback("::1", io.EOF), true},
		{"unknown", "https://unregistered.invalid", nxdomain, false},
		{"suffix", "https://" + host + ".evil.invalid", nxdomain, false},
		{"subdomain", "https://not-official." + host, nxdomain, false},
		{"http", "http://" + host, nxdomain, false},
		{"literal IP", "https://127.0.0.1", nxdomain, false},
		{"localhost", "https://localhost", nxdomain, false},
		{"DNS timeout", "https://" + host, &net.DNSError{IsTimeout: true}, false},
		{"TCP timeout", "https://" + host, loopback("127.0.0.1", context.DeadlineExceeded), false},
		{"public refused", "https://" + host, loopback("93.184.216.34", io.EOF), false},
		{"certificate", "https://" + host, x509.UnknownAuthorityError{}, false},
		{"cancel", "https://" + host, context.Canceled, false},
		{"HTTP response", "https://" + host, nil, false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			request, _ := http.NewRequest(http.MethodGet, test.address, nil)
			if got := blockedSourceDNS(request, test.err); got != test.want {
				t.Fatalf("fallback eligibility = %v, want %v", got, test.want)
			}
		})
	}
}

func TestSourceDNSExcludedRequestsNeverLookup(t *testing.T) {
	host := sourceDNSTestHosts(t)[0]
	for _, test := range []string{"unknown", "http", "body without GetBody", "certificate", "timeout", "proxy", "proxy callback error", "canceled"} {
		t.Run(test, func(t *testing.T) {
			var lookups, dials, proxyCalls atomic.Int32
			base := http.DefaultTransport.(*http.Transport).Clone()
			base.Proxy = nil
			failure := error(&net.DNSError{Name: host, IsNotFound: true})
			address := "https://" + host + "/fixture"
			switch test {
			case "unknown":
				address = "https://unregistered.invalid/fixture"
			case "http":
				address = "http://" + host + "/fixture"
			case "certificate":
				failure = x509.UnknownAuthorityError{}
			case "timeout":
				failure = &net.OpError{Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("127.0.0.1")}, Err: context.DeadlineExceeded}
			case "proxy", "proxy callback error":
				base.Proxy = func(*http.Request) (*url.URL, error) {
					// 后续若错误地重新求值，会变成直连；必须使用实际首个决策。
					if proxyCalls.Add(1) > 1 {
						return nil, nil
					}
					if test == "proxy callback error" {
						return nil, failure
					}
					return url.Parse("http://fixture-proxy.invalid:8080")
				}
			}
			base.DialContext = func(ctx context.Context, network, target string) (net.Conn, error) {
				dials.Add(1)
				if test == "proxy" && target != "fixture-proxy.invalid:8080" {
					t.Error("proxy bypass", target)
				}
				return nil, failure
			}
			resolver := sourceDNSTestResolver(base, &lookups, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"}]}`)
			transport := newCDNTransport(base, resolver)
			defer transport.CloseIdleConnections()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if test == "canceled" {
				cancel()
			}
			request, _ := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
			if test == "body without GetBody" {
				request.Body = io.NopCloser(strings.NewReader("cannot replay"))
			}
			response, err := transport.RoundTrip(request)
			if response != nil {
				response.Body.Close()
			}
			if err == nil || lookups.Load() != 0 || dials.Load() > 1 {
				t.Fatal("excluded request attempted fallback", err, lookups.Load(), dials.Load())
			}
			if strings.HasPrefix(test, "proxy") && proxyCalls.Load() != 1 {
				t.Fatal("proxy callback reevaluated", proxyCalls.Load())
			}
		})
	}
}

func TestSourceDNSHTTPAndTLSNeverRetry(t *testing.T) {
	host := sourceDNSTestHosts(t)[0]
	for _, test := range []string{"403", "fallback 403", "certificate", "fallback certificate"} {
		t.Run(test, func(t *testing.T) {
			var dials, lookups atomic.Int32
			server, roots := sourceDNSTestServer(t, host, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusForbidden)
			}))
			base := http.DefaultTransport.(*http.Transport).Clone()
			base.Proxy = nil
			base.TLSClientConfig = &tls.Config{RootCAs: roots}
			if strings.Contains(test, "certificate") {
				base.TLSClientConfig.RootCAs = x509.NewCertPool()
			}
			base.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
				dials.Add(1)
				if strings.HasPrefix(test, "fallback") && address == host+":443" {
					return nil, &net.DNSError{IsNotFound: true}
				}
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}
			resolver := sourceDNSTestResolver(base, &lookups, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"},{"type":1,"TTL":120,"data":"93.184.216.35"}]}`)
			transport := newCDNTransport(base, resolver)
			defer transport.CloseIdleConnections()
			request, _ := http.NewRequest(http.MethodGet, "https://"+host, nil)
			response, err := transport.RoundTrip(request)
			if response != nil {
				defer response.Body.Close()
			}
			if strings.Contains(test, "403") && (err != nil || response == nil || response.StatusCode != http.StatusForbidden) {
				t.Fatal("business response replaced", err)
			}
			if strings.Contains(test, "certificate") && (err == nil || !sourceDNSTLSError(err)) {
				t.Fatal("TLS identity failure suppressed", err)
			}
			wantDials, wantLookups := int32(1), int32(0)
			if strings.HasPrefix(test, "fallback") {
				wantDials, wantLookups = 2, 1
			}
			if dials.Load() != wantDials || lookups.Load() != wantLookups {
				t.Fatal("HTTP/TLS failure retried", dials.Load(), lookups.Load())
			}
		})
	}
}

func TestSourceDNSFourAddressLimitCancellationAndPublicAnswers(t *testing.T) {
	host := sourceDNSTestHosts(t)[0]
	for _, test := range []string{"four addresses", "cancel during dial", "cancel during lookup", "private answer"} {
		t.Run(test, func(t *testing.T) {
			var attempts, lookups atomic.Int32
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			deadline, _ := ctx.Deadline()
			base := http.DefaultTransport.(*http.Transport).Clone()
			base.Proxy = nil
			base.DialContext = func(dialCtx context.Context, network, address string) (net.Conn, error) {
				if address == host+":443" {
					return nil, &net.DNSError{IsNotFound: true}
				}
				attempts.Add(1)
				if limit, ok := dialCtx.Deadline(); !ok || limit.After(deadline) {
					t.Error("fallback extended request budget")
				}
				if test == "cancel during dial" {
					cancel()
					<-dialCtx.Done()
					return nil, dialCtx.Err()
				}
				return nil, io.EOF
			}
			answer := `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"},{"type":1,"TTL":120,"data":"93.184.216.34"},{"type":1,"TTL":120,"data":"93.184.216.35"},{"type":1,"TTL":120,"data":"93.184.216.36"},{"type":1,"TTL":120,"data":"93.184.216.37"},{"type":1,"TTL":120,"data":"93.184.216.38"}]}`
			if test == "private answer" {
				answer = `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"},{"type":1,"TTL":120,"data":"127.0.0.1"}]}`
			}
			resolver := sourceDNSTestResolver(base, &lookups, answer)
			if test == "cancel during lookup" {
				resolver.client.Transport = sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
					lookups.Add(1)
					cancel()
					<-r.Context().Done()
					return nil, r.Context().Err()
				})
			}
			transport := newCDNTransport(base, resolver)
			defer transport.CloseIdleConnections()
			request, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host, nil)
			response, err := transport.RoundTrip(request)
			if response != nil {
				response.Body.Close()
			}
			want := int32(0)
			if test == "four addresses" {
				want = 4
			} else if test == "cancel during dial" {
				want = 1
			}
			if err == nil || attempts.Load() != want || lookups.Load() != 1 {
				t.Fatal("unexpected fallback boundary", err, attempts.Load(), lookups.Load())
			}
			if strings.HasPrefix(test, "cancel") && !errors.Is(err, context.Canceled) {
				t.Fatal("cancellation identity lost", err)
			}
		})
	}
}

func TestSourceDNSRoundTripAddressRejectsMissingGetBody(t *testing.T) {
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	base.DialContext = func(context.Context, string, string) (net.Conn, error) {
		t.Error("non-replayable body reached network")
		return nil, io.EOF
	}
	transport := newCDNTransport(base, newDNSResolver(base))
	defer transport.CloseIdleConnections()
	request, _ := http.NewRequest(http.MethodGet, "https://"+sourceDNSTestHosts(t)[0], nil)
	request.Body = io.NopCloser(strings.NewReader("single use"))
	defer request.Body.Close()
	if _, err := transport.roundTripAddress(request, nil, request.URL.Host, "93.184.216.34"); err == nil {
		t.Fatal("CDN address replay accepted nil GetBody")
	}
	if _, err := transport.roundTripSourceAddress(request, "93.184.216.34"); err == nil {
		t.Fatal("source address replay accepted nil GetBody")
	}
}

func TestSourceDNSInitialDialDoesNotLoseConnections(t *testing.T) {
	for _, fail := range []bool{false, true} {
		connection, peer := net.Pipe()
		ctx := context.WithValue(context.Background(), sourceDNSDialKey{}, context.Background())
		dial := sourceDNSInitialDialer(func(context.Context, string, string) (net.Conn, error) {
			if fail {
				return connection, io.EOF
			}
			return connection, nil
		})
		got, err := dial(ctx, "tcp", "fixture.invalid:443")
		if !fail && (got != connection || err != nil) {
			t.Error("successful first connection was discarded", err)
		}
		if fail {
			if got != nil || err == nil {
				t.Error("failed connection escaped", got, err)
			}
			_ = peer.SetReadDeadline(time.Now().Add(time.Second))
			if _, err := peer.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
				t.Error("failed connection leaked", err)
			}
		}
		connection.Close()
		peer.Close()
	}
}
