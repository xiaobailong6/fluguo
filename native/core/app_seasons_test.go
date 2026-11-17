package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func seasonFixture(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	body, err := os.ReadFile("testdata/backend_hongguo_seasons.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(body, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture
}

func TestNativeSeasonsOfficialOrderBatchAndCache(t *testing.T) {
	fixture := seasonFixture(t)
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Path != hongguoSeriesPackPath || request.Method != http.MethodPost {
			t.Fatal("unexpected endpoint", request.URL)
		}
		var payload struct {
			IDs     []json.Number `json:"req_ids"`
			Fields  []string      `json:"req_fields"`
			Channel string        `json:"book_pack_channel"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Channel != "inner_feed_detail" {
			t.Fatal("wrong pack channel")
		}
		if payload.Fields[0] == "album_id" {
			if !reflect.DeepEqual(payload.IDs, []json.Number{"101"}) {
				t.Fatal("wrong relation ids", payload.IDs)
			}
			return sourceFixtureResponse(request, 200, string(fixture["relation"])), nil
		}
		if !reflect.DeepEqual(payload.IDs, []json.Number{"303", "101", "202"}) {
			t.Fatal("lost official order", payload.IDs)
		}
		return sourceFixtureResponse(request, 200, string(fixture["metadata"])), nil
	})
	engine := &nativeEngine{downloader: d}
	drama := nativeDrama{ID: "hongguo:101", Source: sourceHongguo, SourceID: "101", Title: "同名短剧"}
	for iteration := range 2 {
		got, err := engine.nativeSeasons(context.Background(), drama)
		if err != nil {
			t.Fatal(err)
		}
		items := got["items"].([]nativeSeason)
		if len(items) != 3 {
			t.Fatal(items)
		}
		for index, id := range []string{"303", "101", "202"} {
			if items[index].Number != index+1 || items[index].Drama.SourceID != id {
				t.Fatal("wrong season order", items)
			}
		}
		if items[1].Drama.Views != "12345" || items[1].Drama.Episodes != 12 || items[1].Drama.Title != "同名短剧" || items[1].Drama.OnlineDate != "2023-11-15" {
			t.Fatal("metadata missing", items[1])
		}
		if items[0].Drama.Title != "官方前作" {
			t.Fatal("caller mutation escaped cache boundary")
		}
		items[0].Drama.Title = "caller mutation"
		if calls != 2 {
			t.Fatal("cache missed or N+1 requests", iteration, calls)
		}
	}
	engine.seasons["101"] = nativeSeasonCacheEntry{expires: time.Now().Add(-time.Second)}
	if _, err := engine.nativeSeasons(context.Background(), drama); err != nil || calls != 4 {
		t.Fatal("expired cache not rebuilt", err, calls)
	}
}

func TestHongguoOfficialSeasonRelationshipValidation(t *testing.T) {
	for _, check := range []struct {
		name, ids string
		count     int
		bad       bool
	}{
		{"ordered-dedup", `[303,"101","303",202]`, 3, false},
		{"same-title-not-membership", `[303,202]`, 0, false},
		{"single", `[101,101]`, 0, false},
		{"invalid", `[101,"../202"]`, 0, true},
		{"overflow", `[101,"9223372036854775808"]`, 0, true},
		{"fraction", `[101,2.5]`, 0, true},
		{"leading-zero", `[101,"0202"]`, 0, true},
		{"object", `{"101":true}`, 0, true},
		{"too-many", `[` + strings.Repeat(`101,`, 200) + `202]`, 0, true},
	} {
		t.Run(check.name, func(t *testing.T) {
			decoder := json.NewDecoder(strings.NewReader(`{"data":{"101":{"album_info":{"album_series_ids":` + check.ids + `}}}}`))
			decoder.UseNumber()
			var response map[string]any
			if err := decoder.Decode(&response); err != nil {
				t.Fatal(err)
			}
			ids, err := hongguoOfficialSeasonIDs(response, "101")
			if (err != nil) != check.bad || len(ids) != check.count {
				t.Fatal(ids, err)
			}
		})
	}
}

func TestNativeSeasonsBoundedFallbackAndCancellation(t *testing.T) {
	for _, cancelRequest := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		fallbacks := 0
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			body, _ := io.ReadAll(request.Body)
			if bytes.Contains(body, []byte("album_id")) {
				return sourceFixtureResponse(request, 200, `{"code":0,"data":{"101":{"album_info":{"album_series_ids":[101,202,303,404,505]}}}}`), nil
			}
			if request.URL.Path == hongguoSeriesPackPath {
				if cancelRequest {
					cancel()
				}
				return sourceFixtureResponse(request, 200, `{"code":0,"data":{}}`), nil
			}
			fallbacks++
			var payload map[string]string
			_ = json.Unmarshal(body, &payload)
			return sourceFixtureResponse(request, 200, `{"code":0,"data":{"video_data":{"series_id":"`+payload["series_id"]+`","series_title":"合成详情","episode_cnt":3}}}`), nil
		})
		engine := &nativeEngine{downloader: d}
		got, err := engine.nativeSeasons(ctx, nativeDrama{ID: "hongguo:101"})
		cancel()
		if cancelRequest {
			if !errors.Is(err, context.Canceled) || len(engine.seasons) != 0 {
				t.Fatal("cancelled seasons cached", got, err)
			}
		} else if err != nil || len(got["items"].([]nativeSeason)) != 2 || fallbacks != 2 {
			t.Fatal("unbounded fallback", got, err, fallbacks)
		}
	}
}

func TestNativeSeasonsBuildPermissionsAndUnsupportedSources(t *testing.T) {
	previous := buildAllSources
	t.Cleanup(func() { buildAllSources = previous })
	for _, mode := range []string{"false", "true"} {
		buildAllSources = mode
		engine := &nativeEngine{}
		for _, source := range []string{sourceHongguo, sourceMissav, sourceHuangdou} {
			input := nativeInput{Action: "seasons", Drama: nativeDrama{ID: source + ":101", Source: source}}
			err := nativeAuthorizeInput(input)
			if (err == nil) != nativeSourceAvailable(source) {
				t.Fatal("build permission mismatch", mode, source, err)
			}
			if source != sourceHongguo && err == nil {
				got, err := engine.nativeSeasons(context.Background(), input.Drama)
				if err != nil || len(got["items"].([]nativeSeason)) != 0 {
					t.Fatal(got, err)
				}
			}
		}
		if err := nativeAuthorizeInput(nativeInput{Action: "seasons", Drama: nativeDrama{ID: "hongguo:101", Source: sourceMissav}}); err == nil {
			t.Fatal("mixed source authorized")
		}
		for _, id := range []string{"0", "+101", "01", "9223372036854775808", "101/202"} {
			if _, err := engine.nativeSeasons(context.Background(), nativeDrama{ID: "hongguo:" + id}); err == nil {
				t.Fatal("invalid ID accepted", id)
			}
		}
		if got, err := engine.nativeSeasons(context.Background(), nativeDrama{ID: "hongguo:book-101"}); err != nil || len(got["items"].([]nativeSeason)) != 0 {
			t.Fatal(got, err)
		}
	}
}

func TestNativeSeasonCacheBound(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	engine := &nativeEngine{downloader: d, seasons: map[string]nativeSeasonCacheEntry{}}
	for id := 1; id <= nativeSeasonCacheLimit; id++ {
		engine.seasons[strconv.Itoa(id)] = nativeSeasonCacheEntry{expires: time.Now().Add(time.Hour)}
	}
	if _, err := engine.nativeSeasons(context.Background(), nativeDrama{ID: "hongguo:999"}); err != nil {
		t.Fatal(err)
	}
	if len(engine.seasons) != nativeSeasonCacheLimit {
		t.Fatal("season cache exceeded bound", len(engine.seasons))
	}
}

func TestNativeSeasonsDeadlineAndIntegerPrecision(t *testing.T) {
	body, err := json.Marshal(hongguoSeasonPackBody([]string{"9223372036854775807"}, []string{"album_series_ids"}))
	if err != nil || !bytes.Contains(body, []byte(`"req_ids":[9223372036854775807]`)) {
		t.Fatal("64-bit season ID lost precision", string(body), err)
	}
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	engine := &nativeEngine{downloader: d}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if got, err := engine.nativeSeasons(ctx, nativeDrama{ID: "hongguo:101"}); !errors.Is(err, context.DeadlineExceeded) || got != nil || len(engine.seasons) != 0 {
		t.Fatal("deadline did not stop season request", got, err)
	}
}
