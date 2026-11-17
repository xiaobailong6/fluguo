package core

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"

	fhttp "github.com/bogdanfinn/fhttp"
)

type sourcePolicyBrowserClient struct {
	do     func(*fhttp.Request) (*fhttp.Response, error)
	closed int
}

func (client *sourcePolicyBrowserClient) Do(request *fhttp.Request) (*fhttp.Response, error) {
	return client.do(request)
}

func (client *sourcePolicyBrowserClient) CloseIdleConnections() {
	client.closed++
}

func sourcePolicyBrowserDescriptor(t *testing.T) nativeSourceDescriptor {
	t.Helper()
	for _, descriptor := range nativeSourceDescriptors {
		if descriptor.BrowserFingerprint && len(descriptor.BrowserHosts) > 0 {
			return descriptor
		}
	}
	t.Fatal("missing browser fingerprint policy")
	return nativeSourceDescriptor{}
}

func TestSourceBrowserExplicitPolicyAndForwarding(t *testing.T) {
	forwarded := 0
	transport := &huangguoBrowserTransport{
		host: "legacy-unknown.invalid",
		baseURL: func(id string) string {
			return "https://" + id + ".configured.invalid:9443"
		},
		base: sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
			forwarded++
			return sourceFixtureResponse(request, 204, ""), nil
		}),
	}
	for _, descriptor := range nativeSourceDescriptors {
		for _, address := range append(append([]string{}, descriptor.BrowserHosts...), descriptor.ID+".configured.invalid:9443") {
			request, _ := http.NewRequest(http.MethodGet, "https://"+address+"/fixture", nil)
			got := transport.source(request.URL)
			if descriptor.BrowserFingerprint {
				if !transport.matches(request) || got.ID != descriptor.ID {
					t.Error("enabled descriptor not matched", descriptor.ID, address, got.ID)
				}
			} else if transport.matches(request) {
				t.Error("disabled descriptor acquired fingerprint", descriptor.ID, address)
			}
		}
	}
	descriptor := sourcePolicyBrowserDescriptor(t)
	host := descriptor.BrowserHosts[0]
	for _, test := range []struct{ method, address string }{
		{http.MethodGet, "https://unregistered.invalid"},
		{http.MethodGet, "https://legacy-unknown.invalid"},
		{http.MethodGet, "https://" + host + ".evil.invalid"},
		{http.MethodGet, "https://cdn." + host},
		{http.MethodGet, "https://tp.tuafjz.cn/videos/synthetic/crypt.key"},
		{http.MethodGet, "https://" + descriptor.ID + ".configured.invalid:9444"},
		{http.MethodPost, "https://" + host},
		{http.MethodGet, "ftp://" + host},
	} {
		request, _ := http.NewRequest(test.method, test.address, nil)
		if transport.matches(request) {
			t.Error("non-target acquired fingerprint", test)
			continue
		}
		before := forwarded
		response, err := transport.RoundTrip(request)
		if err != nil || response == nil || response.Request != request || forwarded != before+1 {
			t.Fatal("non-target not forwarded unchanged", test, err)
		}
		response.Body.Close()
	}
	request, _ := http.NewRequest(http.MethodHead, "https://"+strings.ToUpper(host), nil)
	if !transport.matches(request) {
		t.Fatal("exact case-insensitive official hostname lost")
	}
}

func TestSourceBrowserDefaultFingerprintHosts(t *testing.T) {
	transport := &huangguoBrowserTransport{}
	for _, host := range []string{"huangguo.video", "missav.live", "hanime1.me"} {
		request, _ := http.NewRequest(http.MethodGet, "https://"+host, nil)
		if !transport.matches(request) {
			t.Error("required default browser fingerprint missing", host)
		}
	}
}

func TestSourceBrowser403AndErrorsDoNotDowngrade(t *testing.T) {
	for _, descriptor := range nativeSourceDescriptors {
		if !descriptor.BrowserFingerprint || len(descriptor.BrowserHosts) == 0 {
			continue
		}
		t.Run(descriptor.ID, func(t *testing.T) {
			var event diagnosticEvent
			calls := 0
			client := &sourcePolicyBrowserClient{do: func(request *fhttp.Request) (*fhttp.Response, error) {
				calls++
				return &fhttp.Response{StatusCode: 403, Status: "403 Forbidden", Proto: "HTTP/2.0",
					Header: fhttp.Header{"Cf-Mitigated": {"challenge"}}, Body: io.NopCloser(strings.NewReader("challenge"))}, nil
			}}
			transport := &huangguoBrowserTransport{
				base: sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
					t.Error("browser request downgraded to ordinary connection")
					return nil, errors.New("unexpected downgrade")
				}),
				router: &proxyRouter{mode: "direct"}, clients: map[string]browserHTTPClient{},
				newClient: func(string) (browserHTTPClient, error) { return client, nil },
				record:    func(record diagnosticEvent) { event = record },
			}
			defer transport.CloseIdleConnections()
			request, _ := http.NewRequest(http.MethodGet, "https://"+descriptor.BrowserHosts[0]+"/fixture", nil)
			response, err := transport.RoundTrip(request)
			if err != nil || response == nil || response.StatusCode != 403 || calls != 1 {
				t.Fatal("challenge response changed", err, calls)
			}
			response.Body.Close()
			if event.Source != descriptor.ID || !strings.Contains(event.Message, descriptor.Name) || event.Level != "warning" {
				t.Fatal("diagnostics used wrong source", event)
			}
			client.do = func(*fhttp.Request) (*fhttp.Response, error) { return nil, errors.New("fixture failure") }
			if _, err := transport.RoundTrip(request); err == nil || !strings.Contains(err.Error(), descriptor.Name) {
				t.Fatal("browser error missing source name", err)
			}
			transport.CloseIdleConnections()
			transport.newClient = func(string) (browserHTTPClient, error) { return nil, errors.New("fixture initialization") }
			if _, err := transport.RoundTrip(request); err == nil || !strings.Contains(err.Error(), descriptor.Name) {
				t.Fatal("initialization error missing source name", err)
			}
		})
	}
}

func TestSourceBrowserClientsIsolateOriginProxyAndLimit(t *testing.T) {
	var proxies []string
	var clients []*sourcePolicyBrowserClient
	router := &proxyRouter{mode: "direct"}
	transport := &huangguoBrowserTransport{
		router: router, clients: map[string]browserHTTPClient{},
		newClient: func(proxy string) (browserHTTPClient, error) {
			client := &sourcePolicyBrowserClient{}
			clients = append(clients, client)
			proxies = append(proxies, proxy)
			return client, nil
		},
	}
	request, _ := http.NewRequest(http.MethodGet, "https://first.fixture.invalid", nil)
	first, err := transport.client(request)
	if err != nil {
		t.Fatal(err)
	}
	same, _ := transport.client(request)
	if first != same || len(clients) != 1 {
		t.Fatal("same origin did not reuse browser session")
	}
	other, _ := http.NewRequest(http.MethodGet, "https://second.fixture.invalid", nil)
	second, _ := transport.client(other)
	if second == first {
		t.Fatal("origins share cookie/client state")
	}
	proxy, _ := url.Parse("http://fixture-proxy.invalid:8080")
	router.mu.Lock()
	router.mode, router.manual = "manual", proxy
	router.mu.Unlock()
	proxied, _ := transport.client(request)
	if proxied == first || proxies[len(proxies)-1] != proxy.String() {
		t.Fatal("proxy change reused direct cookie/client state")
	}
	router.mu.Lock()
	router.mode = "direct"
	router.mu.Unlock()
	again, _ := transport.client(request)
	if again != first {
		t.Fatal("direct client state unexpectedly replaced")
	}
	for index := 0; index < 12; index++ {
		request, _ := http.NewRequest(http.MethodGet, fmt.Sprintf("https://fixture-%d.invalid", index), nil)
		if _, err := transport.client(request); err != nil {
			t.Fatal(err)
		}
		if len(transport.clients) > 8 {
			t.Fatal("browser client limit exceeded")
		}
	}
	closed := 0
	for _, client := range clients {
		closed += client.closed
	}
	if closed != len(clients)-8 {
		t.Fatal("evicted clients leaked idle connections", closed, len(clients))
	}
	transport.CloseIdleConnections()
	for _, client := range clients {
		if client.closed != 1 {
			t.Fatal("browser client was not closed exactly once", client.closed)
		}
	}
}
