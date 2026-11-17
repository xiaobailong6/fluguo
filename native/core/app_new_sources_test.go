package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

func TestNewSourcesNativePipelineAndEdition(t *testing.T) {
	var requests atomic.Int32
	d, server := newWebFixtureDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		base := "http://" + r.Host
		switch r.URL.Path {
		case "/cn/genres":
			io.WriteString(w, `<a href="/cn/genres/sample">Sample</a>`)
		case "/cn/new", "/cn/search/sample":
			io.WriteString(w, missavFixtureCard("/cn/sample", "Neutral sample"))
		case "/cn/sample":
			fmt.Fprintf(w, `<h1>Neutral sample</h1><meta property="og:image" content="%s/cover.jpg"><script>var source="%s/stream.m3u8";</script>`, base, base)
		case "/stream.m3u8":
			io.WriteString(w, "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n")
		case "/search":
			io.WriteString(w, `<a class="nav-desktop-items" href="/search?genre=Sample">Sample</a>`+hanime1FixtureScope(hanime1FixtureCard("101", "Neutral sample")))
		case "/watch":
			fmt.Fprintf(w, `<meta property="og:url" content="%s/watch?v=101"><meta property="og:title" content="Neutral sample"><meta property="og:image" content="%s/cover.jpg"><video id="player"><source src="/media.mp4" size="720" type="video/mp4"></video>`, base, base)
		default:
			t.Error("integration requested unexpected image/media resource", r.URL.Path)
			http.NotFound(w, r)
		}
	})
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer engine.downloads.close()
	engine.downloader = d
	for _, input := range []struct{ source, id string }{{"missav", "sample"}, {"hanime1", "101"}} {
		t.Run(input.source, func(t *testing.T) {
			query := nativeInput{Action: "catalog", Source: input.source, Page: 1, Force: true}
			if buildAllSources != "true" {
				if !errors.Is(nativeAuthorizeInput(query), errNativeBuildSource) {
					t.Fatal("standard edition accepted new source")
				}
				return
			}
			if err := nativeAuthorizeInput(query); err != nil {
				t.Fatal(err)
			}
			categories, err := engine.nativeCategories(context.Background(), input.source, true)
			if err != nil || len(categories) != 2 {
				t.Fatal("category integration failed", err)
			}
			catalog, err := engine.nativeCatalog(context.Background(), query)
			if err != nil || len(catalog.Items) != 1 || catalog.Items[0].ID != input.source+":"+input.id {
				t.Fatal("catalog integration failed", err)
			}
			query.Query = "sample"
			search, err := engine.nativeCatalog(context.Background(), query)
			if err != nil || len(search.Items) != 1 {
				t.Fatal("search integration failed", err)
			}
			detail, err := engine.nativeDetail(context.Background(), catalog.Items[0])
			if err != nil {
				t.Fatal("detail integration failed", err)
			}
			chapters := detail.(map[string]any)["chapters"].([]Chapter)
			if len(chapters) != 1 || chapters[0].Source != input.source {
				t.Fatal("chapter integration failed")
			}
			cover, err := d.nativeCoverAddress(context.Background(), catalog.Items[0])
			if err != nil || cover != server.URL+"/cover.jpg" {
				t.Fatal("cover integration failed", err)
			}
			media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: catalog.Items[0].ID, Chapter: chapters[0], Index: 1})
			if err != nil || !strings.HasPrefix(media.URL, server.URL+"/") {
				t.Fatal("media integration failed", err)
			}
			if input.source == "hanime1" {
				choice := nativePlaybackChoices(media, 720)
				if len(choice.qualities) != 1 || choice.qualities[0] != 720 {
					t.Fatal("quality selection integration failed")
				}
			}
		})
	}
	if buildAllSources != "true" && requests.Load() != 0 {
		t.Fatal("standard edition issued new-source requests")
	}
}
