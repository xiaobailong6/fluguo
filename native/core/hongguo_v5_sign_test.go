package core

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"
)

func hongguoV5Fixture(t *testing.T, name string, out any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "hongguo", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, out); err != nil {
		t.Fatal(err)
	}
}

func hongguoV5TestHex(t *testing.T, value string) []byte {
	t.Helper()
	data, err := hex.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestHongguoV5IndependentHashVectors(t *testing.T) {
	var rows []struct {
		TS                  uint32
		Query, Body, Digest string
	}
	hongguoV5Fixture(t, "signing-v5-f13.json", &rows)
	if len(rows) != 32 {
		t.Fatal("expected 32 independent vectors")
	}
	for i, row := range rows {
		query, body := hongguoV5TestHex(t, row.Query), hongguoV5TestHex(t, row.Body)
		beforeQuery, beforeBody := bytes.Clone(query), bytes.Clone(body)
		got, err := hongguoV5Hash(query, body, row.TS)
		if err != nil || len(got) != 20 {
			t.Fatalf("vector %d: invalid hash: %v", i, err)
		}
		if hex.EncodeToString(got[:16]) != row.Digest || got[16]&0x24 != 0x24 {
			t.Fatalf("vector %d: digest mismatch", i)
		}
		if !bytes.Equal(query, beforeQuery) || !bytes.Equal(body, beforeBody) {
			t.Fatal("hash mutated inputs")
		}
	}
}

func TestHongguoV5IndependentCarrierVectors(t *testing.T) {
	var rows []struct {
		TS                         uint32
		Key, IV, Source, Encrypted string
	}
	hongguoV5Fixture(t, "signing-v5-carrier.json", &rows)
	if len(rows) != 4 {
		t.Fatal("expected all four carrier variants")
	}
	for i, row := range rows {
		key, iv, source := hongguoV5TestHex(t, row.Key), hongguoV5TestHex(t, row.IV), hongguoV5TestHex(t, row.Source)
		got, err := hongguoV5Carrier(key, iv, source, row.TS)
		if err != nil || hex.EncodeToString(got) != row.Encrypted {
			t.Fatalf("carrier %d mismatch: %v", i, err)
		}
		if hex.EncodeToString(source) != row.Source || hex.EncodeToString(key) != row.Key || hex.EncodeToString(iv) != row.IV {
			t.Fatal("carrier mutated inputs")
		}
	}
}

func TestHongguoV5FullHeaderReferenceVectors(t *testing.T) {
	var rows []struct {
		Now, Started         int64
		Body                 *string
		Values, Headers      map[string]string
		Nonce, Random, Query string
	}
	hongguoV5Fixture(t, "signing-v5-headers.json", &rows)
	if len(rows) != 4 {
		t.Fatal("expected four deterministic header vectors")
	}
	for i, row := range rows {
		params := url.Values{}
		for k, v := range row.Values {
			params.Set(k, v)
		}
		request, _ := http.NewRequest(http.MethodPost, "https://example.invalid/model?"+params.Encode(), nil)
		var body []byte
		if row.Body != nil {
			body = []byte(*row.Body)
		}
		var random [16]byte
		copy(random[:], hongguoV5TestHex(t, row.Random))
		err := hongguoV5Sign(request, body, time.UnixMilli(row.Now), hongguoV5Session{row.Nonce, row.Started}, random)
		if err != nil {
			t.Fatalf("vector %d: %v", i, err)
		}
		if request.URL.RawQuery != row.Query {
			t.Fatalf("vector %d: signed query mismatch", i)
		}
		if len(request.Header) != len(row.Headers) {
			t.Fatalf("vector %d: unexpected headers", i)
		}
		for name, want := range row.Headers {
			if request.Header.Get(name) != want {
				t.Fatalf("vector %d: %s mismatch", i, name)
			}
		}
		query := request.URL.Query()
		ticket, err := strconv.ParseInt(query.Get("_rticket"), 10, 64)
		if err != nil || ticket < row.Now || ticket >= row.Now+1024 {
			t.Fatal("ticket outside bounded search")
		}
		if ticket/1000 <= row.Now/1000 {
			t.Fatal("fixture must cross a second boundary")
		}
		if query.Has("ts") || request.Header.Get("X-Khronos") != strconv.FormatInt(row.Now/1000, 10) {
			t.Fatal("timestamp drift")
		}
		for k, v := range row.Values {
			if query.Get(k) != v {
				t.Fatal("input query changed")
			}
		}
	}
}

func TestHongguoV5RejectsInvalidInputsAndCancellation(t *testing.T) {
	if _, err := hongguoV5Hash(nil, make([]byte, 16), 1); err == nil {
		t.Fatal("short query hash accepted")
	}
	if _, err := hongguoV5Hash(make([]byte, 32), nil, 1); err == nil {
		t.Fatal("short body hash accepted")
	}
	var stamp uint32
	for hongguoV5IV(make([]byte, 32), make([]byte, 16), stamp)&15 == 12 {
		stamp++
	}
	if _, err := hongguoV5Hash(make([]byte, 32), make([]byte, 16), stamp); err == nil {
		t.Fatal("unsupported branch accepted")
	}
	for _, lengths := range [][3]int{{15, 16, 248}, {16, 15, 248}, {16, 16, 247}} {
		if _, err := hongguoV5Carrier(make([]byte, lengths[0]), make([]byte, lengths[1]), make([]byte, lengths[2]), 1); err == nil {
			t.Fatal("invalid carrier accepted")
		}
	}
	request, _ := http.NewRequest(http.MethodPost, "https://example.invalid/model", nil)
	if err := hongguoV5Sign(request, nil, time.Unix(1800000000, 0), hongguoV5Session{}, [16]byte{}); err == nil {
		t.Fatal("missing device fields accepted")
	}
	request.URL.RawQuery = hongguoPlaybackQuery("123", "456").Encode()
	before := request.URL.RawQuery
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	request = request.WithContext(ctx)
	if err := hongguoV5Sign(request, nil, time.Now(), hongguoV5Session{}, [16]byte{}); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation lost")
	}
	if len(request.Header) != 0 || request.URL.RawQuery != before {
		t.Fatal("failed signing partially mutated request")
	}
}

func TestHongguoV5ConcurrentProcessState(t *testing.T) {
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			request, _ := http.NewRequest(http.MethodPost, "https://example.invalid/model?"+hongguoPlaybackQuery("123", "456").Encode(), nil)
			body := []byte(`{"fixture":true}`)
			now := time.Unix(1800000000, 0)
			if err := signHongguoV5Request(request, body, now); err != nil {
				t.Error(err)
				return
			}
			queryHash, bodyHash := hongguoSM3([]byte(request.URL.RawQuery)), md5.Sum(body)
			if hongguoV5IV(queryHash[:], bodyHash[:], uint32(now.Unix()))&15 != 12 {
				t.Error("concurrent query/signature mismatch")
			}
		}()
	}
	wg.Wait()
}
