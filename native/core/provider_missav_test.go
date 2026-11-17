package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/html"
)

type newWebFixtureTransport struct {
	origin    string
	transport http.RoundTripper
}

// 即使解析器发生回归，也不能让合成测试向真实站点、图片或媒体地址发出请求。
func (transport newWebFixtureTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if providerMediaOrigin(request.URL) != transport.origin {
		return nil, errors.New("fixture blocked nonlocal request")
	}
	return transport.transport.RoundTrip(request)
}

func newWebFixtureDownloader(t *testing.T, handler http.HandlerFunc) (*Downloader, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client := server.Client()
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = newWebFixtureTransport{origin: server.URL, transport: transport}
	d := &Downloader{cfg: Config{MissavURL: server.URL, Hanime1URL: server.URL, Retries: 1},
		client: client, limiter: newRequestLimiter(3, 0), providerHosts: map[string]string{}}
	return d, server
}

func newWebFixtureHTML(t *testing.T, body string) *html.Node {
	t.Helper()
	root, err := html.Parse(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func missavFixtureCard(href, title string) string {
	return `<div class="thumbnail group"><a href="` + href + `"><img src="data:image/gif;base64,AA" data-src="https://images.example.test/sample.jpg" alt="Fallback"></a><div class="my-2">` + title + `</div><span class="absolute">04:00</span></div>`
}

func TestMissavOfflineCatalogDetailPlayback(t *testing.T) {
	var pageRequests, playlistRequests atomic.Int32
	d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		base := "http://" + r.Host
		if r.Header.Get("User-Agent") != missavUserAgent {
			t.Error("missing provider user agent")
		}
		if r.URL.Path != "/stream.m3u8" && r.Header.Get("Referer") != base+"/" {
			t.Error("missing page referer")
		}
		switch r.URL.Path {
		case "/cn/genres":
			io.WriteString(w, `<a href="/cn/genres/sample">Sample category long</a><a href="/cn/genres/sample">Sample</a><a href="https://outside.example.test/cn/genres/foreign">Foreign</a>`)
		case "/cn/new", "/cn/search/neutral sample", "/cn/genres/sample":
			if r.URL.Query().Get("page") != "1" {
				t.Error("lost page query")
			}
			io.WriteString(w, missavFixtureCard("/dm12/cn/sample-1", "Neutral sample")+missavFixtureCard("/cn/sample-1", "Duplicate")+
				missavFixtureCard("https://outside.example.test/cn/foreign", "Foreign")+`<a href="?page=2">Next</a>`)
		case "/cn/search/absent":
			io.WriteString(w, `<main>No results</main>`)
		case "/cn/sample-1":
			if r.Header.Get("Cache-Control") != "no-cache" {
				t.Error("detail/playback must refresh")
			}
			version := pageRequests.Add(1)
			fmt.Fprintf(w, `<meta property="og:url" content="%s/cn/sample-1"><meta property="og:description" content="Neutral description"><meta property="og:image" content="https://images.example.test/sample.jpg"><meta property="og:video:release_date" content="2025-01-02T20:00:00Z"><h1>Neutral sample</h1><a href="/cn/genres/sample">Sample</a><script>eval(function(p,a,c,k,e,d){return p;}('"0"',2,1,'%s/stream.m3u8?version=%d&token=a%%2Fb'.split('|'),0,{}))</script>`, base, base, version)
		case "/stream.m3u8":
			playlistRequests.Add(1)
			if r.Header.Get("Referer") != base+"/cn/sample-1" {
				t.Error("missing media referer")
			}
			if r.URL.Query().Get("token") != "a/b" {
				t.Error("signed HLS query was changed")
			}
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n")
		default:
			t.Errorf("unexpected request path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	})
	ctx := context.Background()
	categories, err := d.fetchMissavCategories(ctx)
	if err != nil || len(categories) != 1 || categories[0].ID != "sample" || categories[0].Name != "Sample" {
		t.Fatalf("categories: %+v %v", categories, err)
	}
	for _, input := range []struct{ category, query string }{{"", ""}, {"sample", ""}, {"", "neutral sample"}} {
		items, more, err := d.fetchMissavCatalogPage(ctx, 1, input.category, input.query)
		if err != nil || !more || len(items) != 1 || items[0].ID != "missav:sample-1" || items[0].Title != "Neutral sample" {
			t.Fatalf("catalog: %+v %v %v", items, more, err)
		}
	}
	if items, more, err := d.fetchMissavCatalogPage(ctx, 1, "", "absent"); err != nil || more || len(items) != 0 {
		t.Fatalf("empty search: %v %v %v", items, more, err)
	}
	drama, chapters, err := d.fetchMissavDetail(ctx, "sample-1")
	if err != nil || len(chapters) != 1 || drama.OnlineDate != "2025-01-03" || len(drama.Tags) != 1 || drama.Desc != "Neutral description" {
		t.Fatalf("detail: %+v %+v %v", drama, chapters, err)
	}
	if chapters[0].ID != "missav:sample-1:sample-1" || chapters[0].PageURL != server.URL+"/cn/sample-1" {
		t.Fatal("chapter identity lost")
	}
	task := Task{DramaID: drama.ID, Chapter: chapters[0]}
	first, err := d.resolveMissavMedia(ctx, task)
	if err != nil || first.Duration != 4*time.Second || !strings.HasPrefix(first.Playlist, "#EXTM3U") || first.credentials == nil {
		t.Fatalf("media: %+v %v", first, err)
	}
	second, err := d.resolveMissavMedia(ctx, task)
	if err != nil || first.URL == second.URL || pageRequests.Load() != 3 || playlistRequests.Load() != 2 {
		t.Fatalf("stale playback: %+v %v", second, err)
	}
}

func TestMissavPackedLiteralAndBounds(t *testing.T) {
	ctx := context.Background()
	base := "https://media.example.test"
	packed := `eval(function(p,a,c,k,e,d){throw new Error('must not execute');}('"0"',2,1,'https:\/\/media.example.test\/playlist.m3u8?token=a%2Fb&mode=one'.split('|'),0,{}))`
	address, err := missavMediaAddress(ctx, newWebFixtureHTML(t, "<script>"+packed+"</script>"), base)
	if err != nil || address != base+"/playlist.m3u8?token=a%2Fb&mode=one" {
		t.Fatalf("packed URL: %q %v", address, err)
	}
	words := make([]string, 37)
	words[36] = "Neutral"
	decoded, err := unpackMissav(ctx, []string{"", "A", "62", "37", strings.Join(words, "|")})
	if err != nil || decoded != "Neutral" {
		t.Fatalf("base62: %q %v", decoded, err)
	}
	for name, match := range map[string][]string{
		"radix":        {"", "0", "1", "1", "sample"},
		"count":        {"", "0", "62", "1025", "sample"},
		"escape":       {"", `\q`, "2", "1", "sample"},
		"literal":      {"", strings.Repeat("x", missavMaxScriptBytes+1), "2", "1", "sample"},
		"expansion":    {"", strings.Repeat("0 ", 1000), "2", "1", strings.Repeat("x", 2000)},
		"replacements": {"", strings.Repeat("0 ", missavMaxReplacements+1), "2", "1", "x"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := unpackMissav(ctx, match); err == nil {
				t.Fatal("accepted unsafe packed input")
			}
		})
	}
	oversized := newWebFixtureHTML(t, "<script>"+strings.Repeat("x", missavMaxScriptBytes+1)+"</script>")
	if _, err := missavMediaAddress(ctx, oversized, base); err == nil {
		t.Fatal("accepted oversized script")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := unpackMissav(cancelled, []string{"", "0", "2", "1", "sample"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel: %v", err)
	}
	for _, raw := range []string{"https://user@media.example.test/a.m3u8", "https://outside.example.test/a.m3u8", "ftp://media.example.test/a.m3u8", "https://media.example.test/a.mp4"} {
		if missavMediaURL(strconv.Quote(raw), base) != "" {
			t.Fatal("accepted unsafe media URL")
		}
	}
}

func TestMissavInputAndWrongChapterRejectedBeforeNetwork(t *testing.T) {
	var requests atomic.Int32
	d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) { requests.Add(1); io.WriteString(w, "<h1>Sample</h1>") })
	for _, category := range []string{"../sample", "a?b", "a#b", "a\\b", "\x00", strings.Repeat("x", 97)} {
		if validMissavCategory(category) {
			t.Fatal("invalid category accepted")
		}
	}
	for _, page := range []int{0, -1, 1000001} {
		if _, _, err := d.fetchMissavCatalogPage(context.Background(), page, "", ""); err == nil {
			t.Fatal("invalid page accepted")
		}
	}
	if _, _, err := d.fetchMissavCatalogPage(context.Background(), 1, "", strings.Repeat("x", 257)); err == nil {
		t.Fatal("long query accepted")
	}
	for _, id := range []string{"../sample", "https://outside.example.test/cn/sample", "sample/other", strings.Repeat("x", 129)} {
		if _, _, err := d.fetchMissavDetail(context.Background(), id); err == nil {
			t.Fatal("invalid id accepted")
		}
	}
	task := Task{DramaID: "missav:sample", Chapter: Chapter{ID: "missav:sample:other"}}
	if _, err := d.resolveMissavMedia(context.Background(), task); err == nil {
		t.Fatal("wrong chapter accepted")
	}
	task.Chapter.ID, task.Chapter.VideoURL = "missav:sample:sample", "https://outside.example.test/cn/sample"
	if _, err := d.resolveMissavMedia(context.Background(), task); err == nil {
		t.Fatal("external chapter accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := d.fetchMissavDetail(ctx, "sample"); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel: %v", err)
	}
	if requests.Load() != 0 {
		t.Fatal("invalid input triggered requests")
	}
}

func TestMissavEmptyMalformedAndInvalidHLS(t *testing.T) {
	for _, body := range []string{"<main>Neutral page</main>", `<a href="?page=2">Next</a>`} {
		d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, body) })
		if _, _, err := d.fetchMissavCatalogPage(context.Background(), 1, "", ""); err == nil {
			t.Fatal("missing catalog accepted")
		}
		if _, _, err := d.fetchMissavDetail(context.Background(), "sample"); err == nil {
			t.Fatal("missing title accepted")
		}
	}
	d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/cn/sample" {
			fmt.Fprintf(w, `<script>var source="http://%s/invalid.m3u8";</script>`, r.Host)
		} else {
			io.WriteString(w, "not a playlist")
		}
	})
	if _, err := d.resolveMissavMedia(context.Background(), Task{DramaID: "missav:sample", Chapter: Chapter{ID: "missav:sample:sample"}}); err == nil {
		t.Fatal("invalid HLS accepted")
	}
}

func TestNewWebURLAndPaginationIsolation(t *testing.T) {
	base := "https://source.example.test"
	for _, raw := range []string{"javascript:alert(1)", "data:text/plain,neutral", "https://user:pass@source.example.test/watch?v=1", "https://outside.example.test/watch?v=1", "//outside.example.test/watch?v=1", "/watch?v=%zz"} {
		if newWebSiteURL(raw, base) != nil {
			t.Fatal("unsafe site URL accepted")
		}
	}
	if !newWebSamePage(base+"/search?page=1", base+"/search", base) {
		t.Fatal("default page rejected")
	}
	for _, actual := range []string{"/search?page=2", "/search?page=1&page=1", "/search?genre=other", "/login", "https://outside.example.test/search"} {
		if newWebSamePage(base+"/search?page=1", actual, base) {
			t.Fatal("wrong final page accepted")
		}
	}
	root := newWebFixtureHTML(t, `<a class="page-link" href="https://outside.example.test/search?page=2&amp;query=sample">External</a><a class="page-link" href="/search?page=2&amp;query=other">Other</a>`)
	if newWebMorePages(root, base+"/search?page=1&query="+url.QueryEscape("sample"), base, 1, 100000, "page-link") {
		t.Fatal("foreign pagination accepted")
	}
}

func TestMissavMasterPlaylistPreserved(t *testing.T) {
	master := "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1920x1080\nhigh/index.m3u8\n"
	d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/cn/sample":
			fmt.Fprintf(w, `<script>var source="http://%s/master.m3u8?token=neutral";</script>`, r.Host)
		case "/master.m3u8":
			io.WriteString(w, master)
		default:
			t.Error("resolver fetched segments or variant media unexpectedly")
			http.NotFound(w, r)
		}
	})
	media, err := d.resolveMissavMedia(context.Background(), Task{DramaID: "missav:sample", Chapter: Chapter{ID: "missav:sample:sample"}})
	if err != nil || media.URL != server.URL+"/master.m3u8?token=neutral" || strings.TrimSpace(media.Playlist) != strings.TrimSpace(master) {
		t.Fatalf("master playlist lost: %+v %v", media, err)
	}
}

func TestMissavMalformedScriptsAndLiteralEscapes(t *testing.T) {
	if value, err := missavLiteral(`\"neutral\"\x2f\u0041`); err != nil || value != `"neutral"/A` {
		t.Fatalf("literal escapes: %q %v", value, err)
	}
	for _, script := range []string{
		`eval(function(p,a,c,k,e,d){return p;}('0',62,999999,'sample'.split('|')))`,
		`eval(function(p,a,c,k,e,d){return p;}(getPayload(),62,1,'sample'.split('|')))`,
		`var source = getAddress();`,
	} {
		root := newWebFixtureHTML(t, "<script>"+script+"</script>")
		if _, err := missavMediaAddress(context.Background(), root, "https://source.example.test"); err == nil {
			t.Fatal("malformed or executable expression accepted")
		}
	}
	// 没有匹配项也需要扫描预算，避免字典乘以大 payload 的 CPU 放大。
	words := strings.Repeat("word|", 1023) + "word"
	if _, err := unpackMissav(context.Background(), []string{"", strings.Repeat("!", 32768), "62", "1024", words}); err == nil {
		t.Fatal("scan budget not enforced")
	}
}

func TestNewWebSingleEpisodeValidation(t *testing.T) {
	for _, raw := range []string{"2", "1.9", "null", `"2"`, `{"episode":1}`, "invalid"} {
		if newWebSingleEpisode([]byte(raw)) {
			t.Fatalf("invalid episode accepted: %s", raw)
		}
	}
	for _, raw := range []string{"1", "1.0", `"1"`} {
		if !newWebSingleEpisode([]byte(raw)) {
			t.Fatalf("valid episode rejected: %s", raw)
		}
	}
}
