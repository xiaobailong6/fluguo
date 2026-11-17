package core

import (
	"context"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func hanime1FixtureCard(id, title string) string {
	return `<div class="video-item-container"><a class="video-link" href="/watch?v=` + id + `"><img class="main-thumb" data-original="https://images.example.test/sample.jpg"><div class="title">` + title + `</div></a></div>`
}

func hanime1FixtureScope(body string) string {
	return `<div id="home-rows-wrapper" class="search-rows-wrapper">` + body + `</div>`
}

func TestHanime1OfflineCatalogDetailVariants(t *testing.T) {
	var details atomic.Int32
	d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		base := "http://" + r.Host
		if r.Header.Get("Referer") != base+"/" || r.Header.Get("User-Agent") != hanime1UserAgent {
			t.Error("missing page headers")
		}
		switch r.URL.Path {
		case "/search":
			if r.URL.RawQuery == "" {
				io.WriteString(w, `<a class="nav-desktop-items" href="/search?genre=Sample%20A">Sample A</a><a class="home-genre-tabs" href="/search?genre=Sample%20A">Duplicate</a><a class="nav-desktop-items" href="https://outside.example.test/search?genre=Other">Foreign</a>`)
				return
			}
			query := r.URL.Query()
			if query.Get("page") != "1" {
				t.Error("lost page")
			}
			if query.Get("query") != "" && query.Get("query") != "neutral sample" {
				t.Error("lost search query")
			}
			if query.Get("genre") != "" && query.Get("genre") != "Sample A" {
				t.Error("lost genre")
			}
			query.Set("page", "2")
			io.WriteString(w, hanime1FixtureCard("999", "Outside scope")+hanime1FixtureScope(
				hanime1FixtureCard("101", "Neutral landscape")+hanime1FixtureCard("101", "Duplicate")+
					`<a href="/watch?v=102"><div class="home-rows-videos-div search-videos"><img data-src="https://images.example.test/portrait.jpg"><div class="home-rows-videos-title">Neutral portrait</div></div></a>`+
					`<div class="video-item-container"><a class="video-link" href="https://outside.example.test/watch?v=103"><div class="title">Foreign</div></a></div>`)+
				`<a class="page-link" href="/search?`+html.EscapeString(query.Encode())+`">Next</a>`)
		case "/watch":
			if r.URL.Query().Get("v") != "101" || r.Header.Get("Cache-Control") != "no-cache" {
				t.Error("detail identity/cache mismatch")
			}
			version := details.Add(1)
			fmt.Fprintf(w, `<meta property="og:url" content="%s/watch?v=101"><meta property="og:title" content="Fallback"><meta property="og:description" content="Neutral description"><meta property="og:image" content="https://images.example.test/cover.jpg"><meta property="og:video:duration" content="6.25"><div id="shareBtn-title">Neutral detail</div><video id="player"><source src="/low.mp4?version=%d" size="720" type="video/mp4"><source src="/high.mp4?version=%d" size="1080" type="video/mp4"><source src="/high.mp4?version=%d" size="1080" type="video/mp4"><source src="https://outside.example.test/foreign.mp4" size="2160" type="video/mp4"><source src="javascript:alert(1)" type="video/mp4"><source src="/ignored.webm" size="2160" type="video/webm"></video>`, base, version, version, version)
		default:
			t.Error("parser fetched an image or media body")
			http.NotFound(w, r)
		}
	})
	ctx := context.Background()
	categories, err := d.fetchHanime1Categories(ctx)
	if err != nil || len(categories) != 1 || categories[0].ID != "genre:Sample%20A" {
		t.Fatalf("categories: %+v %v", categories, err)
	}
	for _, input := range []struct{ category, query string }{{"", ""}, {categories[0].ID, ""}, {"", " neutral   sample "}} {
		items, more, err := d.fetchHanime1CatalogPage(ctx, 1, input.category, input.query)
		if err != nil || !more || len(items) != 2 || items[0].ID != "hanime1:101" || items[1].Title != "Neutral portrait" {
			t.Fatalf("catalog: %+v %v %v", items, more, err)
		}
	}
	drama, chapters, err := d.fetchHanime1Detail(ctx, "101")
	if err != nil || len(chapters) != 1 || drama.Title != "Neutral detail" || drama.Desc != "Neutral description" || chapters[0].ID != "hanime1:101:1" {
		t.Fatalf("detail: %+v %+v %v", drama, chapters, err)
	}
	task := Task{DramaID: drama.ID, Chapter: chapters[0]}
	media, err := d.resolveHanime1Media(ctx, task)
	if err != nil || len(media.Variants) != 2 || media.Quality != 1080 || media.Variants[1].Quality != 720 || media.Duration != 6250*time.Millisecond || media.Referer != server.URL+"/watch?v=101" {
		t.Fatalf("media: %+v %v", media, err)
	}
	for _, variant := range media.Variants {
		if variant.credentials == nil || variant.credentials.userAgent != hanime1UserAgent {
			t.Fatal("variant credentials lost")
		}
	}
	refreshed, err := d.resolveHanime1Media(ctx, task)
	if err != nil || refreshed.URL == media.URL || details.Load() != 3 {
		t.Fatalf("stale playback: %+v %v", refreshed, err)
	}
}

func TestHanime1ListingEmptyMalformedAndPagination(t *testing.T) {
	for _, fixture := range []struct {
		name, body      string
		wantError, more bool
	}{
		{"empty", hanime1FixtureScope("No results"), false, false},
		{"scope", hanime1FixtureCard("101", "Sample"), true, false},
		{"unparsed", hanime1FixtureScope(`<a href="/watch?v=101">Unknown layout</a>`), true, false},
		{"title", hanime1FixtureScope(hanime1FixtureCard("101", "")), true, false},
		{"next-empty", hanime1FixtureScope("") + `<a class="page-link" href="?page=2">Next</a>`, true, false},
		{"foreign-next", hanime1FixtureScope("") + `<a class="page-link" href="https://outside.example.test/search?page=2">Next</a>`, false, false},
		{"query-next", hanime1FixtureScope("") + `<a class="page-link" href="?page=2&amp;query=other">Next</a>`, false, false},
		{"genre-next", hanime1FixtureScope("") + `<a class="page-link" href="?page=2&amp;genre=other">Next</a>`, false, false},
		{"duplicate-page", hanime1FixtureScope("") + `<a class="page-link" href="?page=2&amp;page=3">Next</a>`, false, false},
		{"next", hanime1FixtureScope(hanime1FixtureCard("101", "Sample")) + `<a class="page-link" href="?page=2">Next</a>`, false, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, fixture.body) })
			_, more, err := d.fetchHanime1CatalogPage(context.Background(), 1, "", "")
			if (err != nil) != fixture.wantError || more != fixture.more {
				t.Fatalf("listing more=%v error=%v", more, err)
			}
		})
	}
}

func TestHanime1RejectsMalformedDetailAndMedia(t *testing.T) {
	for _, fixture := range []struct {
		name, body string
		detailOK   bool
	}{
		{"wrong-id", `<meta property="og:url" content="/watch?v=102"><h1>Sample</h1><video id="player"></video>`, false},
		{"external-id", `<meta property="og:url" content="https://outside.example.test/watch?v=101"><meta property="og:title" content="Sample"><video id="player"></video>`, false},
		{"player", `<meta property="og:url" content="/watch?v=101"><meta property="og:title" content="Sample">`, false},
		{"title", `<meta property="og:url" content="/watch?v=101"><video id="player"></video>`, false},
		{"media", `<meta property="og:url" content="/watch?v=101"><meta property="og:title" content="Sample"><video id="player"><source src="https://outside.example.test/a.mp4" type="video/mp4"></video>`, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, fixture.body) })
			_, _, err := d.fetchHanime1Detail(context.Background(), "101")
			if (err == nil) != fixture.detailOK {
				t.Fatalf("detail: %v", err)
			}
			task := Task{DramaID: "hanime1:101", Chapter: Chapter{ID: "hanime1:101:1", VideoURL: server.URL + "/watch?v=101"}}
			if _, err := d.resolveHanime1Media(context.Background(), task); err == nil {
				t.Fatal("bad media accepted")
			}
		})
	}
}

func TestHanime1InputsAndWrongChapter(t *testing.T) {
	var requests atomic.Int32
	d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) { requests.Add(1) })
	for _, category := range []string{"genre:", "genre:Sample+A", "genre:%61", "genre:%zz", "genre:%00", "genre:" + strings.Repeat("x", 81)} {
		if validHanime1Category(category) {
			t.Fatal("invalid category accepted")
		}
	}
	if !validHanime1Category("genre:" + newWebComponent("样本 A")) {
		t.Fatal("unicode category rejected")
	}
	for _, id := range []string{"0", "01", "-1", "1/2", "1?v=2", strings.Repeat("1", 21)} {
		if _, _, err := d.fetchHanime1Detail(context.Background(), id); err == nil {
			t.Fatal("invalid id accepted")
		}
	}
	for _, page := range []int{0, -1, 100001} {
		if _, _, err := d.fetchHanime1CatalogPage(context.Background(), page, "", ""); err == nil {
			t.Fatal("invalid page accepted")
		}
	}
	for _, query := range []string{strings.Repeat("x", 201), "sample\x00"} {
		if _, _, err := d.fetchHanime1CatalogPage(context.Background(), 1, "", query); err == nil {
			t.Fatal("invalid query accepted")
		}
	}
	if items, more, err := d.fetchHanime1CatalogPage(context.Background(), 1, "", "   "); err != nil || len(items) != 0 || more {
		t.Fatal("blank search not empty")
	}
	for _, chapter := range []Chapter{
		{ID: "hanime1:101:2", VideoURL: server.URL + "/watch?v=101"},
		{ID: "hanime1:101:1", VideoURL: server.URL + "/watch?v=102"},
		{ID: "hanime1:101:1", VideoURL: "https://outside.example.test/watch?v=101"},
		{ID: "hanime1:101:1", VideoURL: server.URL + "/watch?v=101&v=102"},
		{ID: "hanime1:101:1", VideoURL: server.URL + "/watch?v=101", Source: sourceMissav},
	} {
		if _, err := d.resolveHanime1Media(context.Background(), Task{DramaID: "hanime1:101", Chapter: chapter}); err == nil {
			t.Fatal("wrong chapter accepted")
		}
	}
	for _, raw := range []string{"https://user@source.example.test/a.mp4", "javascript:alert(1)", "https://outside.example.test/a.mp4", "https://source.example.test/a.m3u8", "ftp://source.example.test/a.mp4"} {
		if hanime1MediaURL(raw, "https://source.example.test") != "" {
			t.Fatal("unsafe media accepted")
		}
	}
	if requests.Load() != 0 {
		t.Fatal("invalid input performed request")
	}
}

func TestNewWebRedirectsBlockedBeforeRequest(t *testing.T) {
	var foreignRequests atomic.Int32
	foreign := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { foreignRequests.Add(1) }))
	defer foreign.Close()
	for _, target := range []string{foreign.URL + "/watch?v=101", "/watch?v=102", "/watch?v=101&v=102", "/login", "/search?page=2"} {
		t.Run(target, func(t *testing.T) {
			var requests atomic.Int32
			d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				http.Redirect(w, r, target, http.StatusFound)
			})
			if _, _, err := d.fetchHanime1Detail(context.Background(), "101"); err == nil {
				t.Fatal("redirect accepted")
			}
			if requests.Load() != 1 {
				t.Fatalf("followed wrong same-site redirect: %d", requests.Load())
			}
		})
	}
	if foreignRequests.Load() != 0 {
		t.Fatal("followed foreign redirect")
	}
}

func TestNewWebCancellationAndBodyLimit(t *testing.T) {
	started := make(chan struct{})
	d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) { close(started); <-r.Context().Done() })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() { _, _, err := d.fetchHanime1Detail(ctx, "101"); finished <- err }()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("request did not start")
	}
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("request ignored cancellation")
	}
	large, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, strings.Repeat("x", newWebMaxPageBytes+1))
	})
	if _, _, err := large.fetchHanime1Detail(context.Background(), "101"); err == nil {
		t.Fatal("oversized page accepted")
	}
	if _, _, err := large.fetchMissavDetail(context.Background(), "sample"); err == nil {
		t.Fatal("oversized page accepted")
	}
}

func TestHanime1MissingCategoriesAndCancelledPlayback(t *testing.T) {
	d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `<a class="nav-desktop-items" href="https://outside.example.test/search?genre=Sample">Foreign</a>`)
	})
	if _, err := d.fetchHanime1Categories(context.Background()); err == nil {
		t.Fatal("missing categories accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	task := Task{DramaID: "hanime1:101", Chapter: Chapter{ID: "hanime1:101:1", VideoURL: server.URL + "/watch?v=101"}}
	if _, err := d.resolveHanime1Media(ctx, task); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled playback: %v", err)
	}
}

type newWebFinalFixtureTransport struct {
	transport         http.RoundTripper
	path, query, host string
}

func (transport newWebFinalFixtureTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := transport.transport.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	final := request.Clone(request.Context())
	final.URL.Path, final.URL.RawQuery = transport.path, transport.query
	if transport.host != "" {
		final.URL.Host = transport.host
	}
	response.Request = final
	return response, nil
}

func TestNewWebFinalResponseIdentity(t *testing.T) {
	for _, final := range []struct{ path, query, host string }{
		{"/login", "", ""}, {"/watch", "v=102", ""}, {"/watch", "v=101&v=102", ""}, {"/watch", "v=101", "outside.example.test"},
	} {
		d, _ := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
			io.WriteString(w, `<meta property="og:url" content="/watch?v=101"><meta property="og:title" content="Sample"><video id="player"></video>`)
		})
		d.client.Transport = newWebFinalFixtureTransport{transport: d.client.Transport, path: final.path, query: final.query, host: final.host}
		if _, _, err := d.fetchHanime1Detail(context.Background(), "101"); err == nil {
			t.Fatal("mismatched final response accepted")
		}
	}
}
