package core

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestNativePreloadSlotHoldsUntilExecutionReturns(t *testing.T) {
	engine := &nativeEngine{}
	ctx, cancel := context.WithCancel(context.Background())
	release, err := engine.acquirePreload(ctx)
	if err != nil {
		t.Fatal(err)
	}
	cancel() // 调用者已取消，但原执行尚未返回，不能提前让第二个请求占槽。
	waiting, stop := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer stop()
	if _, err := engine.acquirePreload(waiting); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("cancelled-but-running preload released its slot: %v", err)
	}
	release()
	next, err := engine.acquirePreload(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	next()
	// 等待时已取消的请求，即使槽可用也不能启动新解析。
	if _, err := engine.acquirePreload(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled waiter entered: %v", err)
	}
}
