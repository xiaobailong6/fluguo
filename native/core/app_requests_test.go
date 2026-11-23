package core

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNativeExploreReadMarker(t *testing.T) {
	for _, tc := range []struct {
		name, session string
		sequence      int64
		valid         bool
	}{
		{"explore", "1795310000000000:catalog-explore-2147483647-123:", 1, true},
		{"max_length", strings.Repeat("a", 128), 1, true},
		{"old_slash_separator", "1795310000000000:catalog-explore-2147483647-123/", 1, false},
		{"empty", "", 1, false},
		{"too_long", strings.Repeat("a", 129), 1, false},
		{"non_ascii", "catalog-推荐", 1, false},
		{"zero_sequence", "catalog-explore-42-1:", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := nativeInput{Session: tc.session, Sequence: tc.sequence}
			if got := validNativeRead(input); got != tc.valid {
				t.Fatalf("validNativeRead = %v, want %v", got, tc.valid)
			}
			engine := &nativeEngine{}
			_, finish, err := engine.beginRead(context.Background(), input)
			if tc.valid {
				if err != nil {
					t.Fatal(err)
				}
				finish()
			} else if err == nil || err.Error() != "请求标记无效" {
				t.Fatalf("invalid marker error = %v", err)
			}
		})
	}
}

func TestNativeExploreReadLanesRemainIndependent(t *testing.T) {
	engine := &nativeEngine{}
	first := nativeInput{Session: "1795310000000000:catalog-explore-42-1:", Sequence: 1}
	neighbor := nativeInput{Session: "1795310000000000:catalog-explore-42-10:", Sequence: 2}
	ctx, finish, err := engine.beginRead(context.Background(), first)
	if err != nil {
		t.Fatal(err)
	}
	defer finish()
	other, finishOther, err := engine.beginRead(context.Background(), neighbor)
	if err != nil {
		t.Fatal(err)
	}
	defer finishOther()
	engine.cancelRead(first)
	if !errors.Is(ctx.Err(), context.Canceled) || other.Err() != nil {
		t.Fatalf("cancellation crossed lane boundary: first=%v, neighbor=%v", ctx.Err(), other.Err())
	}
	// 刷新同一通道递增序号，旧取消请求不能停止新请求。
	refreshed := first
	refreshed.Sequence = 3
	fresh, finishFresh, err := engine.beginRead(context.Background(), refreshed)
	if err != nil {
		t.Fatal(err)
	}
	defer finishFresh()
	engine.cancelRead(first)
	if fresh.Err() != nil || other.Err() != nil {
		t.Fatalf("stale cancellation stopped an active read: fresh=%v, neighbor=%v", fresh.Err(), other.Err())
	}
}

func TestNativeRankingDispatchCancellation(t *testing.T) {
	firstBoard, _ := findRankingBoard("hongguo-hot")
	otherBoard, _ := findRankingBoard("hongguo-real")
	firstStarted, otherStarted := make(chan struct{}), make(chan struct{})
	firstCanceled, otherCanceled := make(chan struct{}), make(chan struct{})
	unblock := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		board := firstBoard
		started, canceled := firstStarted, firstCanceled
		if r.URL.Path == "/rank/"+otherBoard.path {
			board, started, canceled = otherBoard, otherStarted, otherCanceled
		}
		close(started)
		select {
		case <-r.Context().Done():
			close(canceled)
			return
		case <-unblock:
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(rankingFixture(board, 1, rankingRows(1))))
	}))
	defer upstream.Close()
	defer func() {
		select {
		case <-unblock:
		default:
			close(unblock)
		}
	}()
	engine := &nativeEngine{downloader: &Downloader{
		cfg: Config{HongguoURL: upstream.URL}, client: upstream.Client(), limiter: newRequestLimiter(3, 0),
	}}
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	defer func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
	}()
	first := nativeInput{Action: "rankings", Board: firstBoard.ID, Page: 1, Session: "probe:rankings-1:", Sequence: 1}
	other := nativeInput{Action: "rankings", Board: otherBoard.ID, Page: 1, Session: "probe:rankings-10:", Sequence: 1}
	firstDone, otherDone := make(chan error, 1), make(chan error, 1)
	go func() { _, err := nativeDispatch(first); firstDone <- err }()
	select {
	case <-firstStarted:
	case err := <-firstDone:
		t.Fatalf("first ranking ended before upstream: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("ranking dispatcher did not reach upstream")
	}
	// 同站源 limiter 会串行发送 HTTP；邻 lane 可先排队，取消后继续完成。
	go func() { _, err := nativeDispatch(other); otherDone <- err }()
	if _, err := nativeDispatch(nativeInput{Action: "cancelRead", Session: first.Session, Sequence: first.Sequence}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-firstCanceled:
	case <-time.After(5 * time.Second):
		t.Fatal("cancelRead did not cancel ranking HTTP context")
	}
	select {
	case err := <-firstDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled ranking error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled ranking dispatcher did not finish")
	}
	select {
	case <-otherStarted:
	case err := <-otherDone:
		t.Fatalf("neighbor ranking ended before upstream: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("neighbor ranking did not reach upstream after cancellation")
	}
	if _, err := nativeDispatch(nativeInput{Action: "cancelRead", Session: first.Session, Sequence: first.Sequence}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-otherCanceled:
		t.Fatal("cancelRead crossed the neighboring ranking lane")
	case err := <-otherDone:
		t.Fatalf("neighbor finished before upstream was released: %v", err)
	default:
	}
	close(unblock)
	select {
	case err := <-otherDone:
		if err != nil {
			t.Fatalf("neighbor ranking failed: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("neighbor ranking did not finish")
	}
	// 无 session 的旧接口仍可读取榜单，不能强制要求新通道标记。
	if _, err := nativeDispatch(nativeInput{Action: "rankings", Board: other.Board, Page: 1}); err != nil {
		t.Fatalf("legacy ranking dispatch failed: %v", err)
	}
	engine.readMu.Lock()
	defer engine.readMu.Unlock()
	if engine.readCount != 0 {
		t.Fatalf("dispatcher leaked %d active reads", engine.readCount)
	}
}
