package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func withUpdateServer(t *testing.T, handler http.HandlerFunc) *nativeEngine {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	previous := nativeUpdateServer
	nativeUpdateServer = server.URL
	t.Cleanup(func() { nativeUpdateServer = previous })
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	return engine
}

func TestNativeCheckUpdate(t *testing.T) {
	latest := `{"version":"1.0.2+102","url":"https://github.com/Xanerix/guoapp/releases/tag/app-v1.0.2-102"}`
	engine := withUpdateServer(t, func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.URL.Path != "/v1/latest" || request.URL.RawQuery != "" {
			http.Error(writer, "invalid", http.StatusBadRequest)
			return
		}
		writer.Write([]byte(latest))
	})

	update, err := engine.checkUpdate(context.Background(), "1.0.1+101")
	if err != nil || !update.Available || update.Version != "1.0.2+102" {
		t.Fatalf("update = %+v, err = %v", update, err)
	}
	if update, err = engine.checkUpdate(context.Background(), "1.0.2+102"); err != nil || update.Available {
		t.Fatalf("same build update = %+v, err = %v", update, err)
	}
	latest = `{"version":"9.0.0+900","url":"https://example.test/app.apk"}`
	if update, err = engine.checkUpdate(context.Background(), "1.0.1+101"); err != nil || update.Available {
		t.Fatalf("foreign url update = %+v, err = %v", update, err)
	}
	latest = `{}`
	if update, err = engine.checkUpdate(context.Background(), "1.0.1+101"); err != nil || update.Available {
		t.Fatalf("empty update = %+v, err = %v", update, err)
	}
	if _, err = engine.checkUpdate(context.Background(), "1.0.1"); err == nil {
		t.Fatal("version without build number was accepted")
	}
}

func TestNativeUpdateServerUnset(t *testing.T) {
	previous := nativeUpdateServer
	nativeUpdateServer = ""
	defer func() { nativeUpdateServer = previous }()
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if update, err := engine.checkUpdate(context.Background(), "1.0.1+101"); err != nil || update.Available {
		t.Fatalf("update = %+v, err = %v", update, err)
	}
}
