package core

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"
)

type nativeStreamAsset struct {
	kind        string
	address     string
	data        []byte
	contentType string
	total       int64
	etag        string
	modified    string
	cacheEpoch  uint64
	resolvedKey bool
}

type nativeStreamSession struct {
	credentials  *providerMediaCredentials
	mu           sync.Mutex
	assets       map[string]nativeStreamAsset
	index        nativeStreamAssetIndex
	referer      string
	key          []byte
	ctx          context.Context
	cancel       context.CancelFunc
	lastUsed     time.Time
	diagnosticID string
	cache        *nativeMediaCache
	managed      bool // Playback owner, not the stream LRU, decides its lifetime.
}

type nativeStreamServer struct {
	mu          sync.Mutex
	downloader  *Downloader
	address     string
	sessions    map[string]*nativeStreamSession
	server      *http.Server
	readTimeout time.Duration // 零值使用生产默认值；测试可为每个 server 单独配置。
}

func (stream *nativeStreamServer) nativeRequest(request *http.Request) (*http.Response, error) {
	client := *stream.downloader.client
	client.Timeout = 0
	base := client.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	timeout := stream.readTimeout
	if timeout <= 0 {
		timeout = mediaIdleReadTimeout
	}
	client.Transport = &idleReadTransport{base: base, timeout: timeout}
	info, _ := request.Context().Value(nativeStreamDiagnosticKey{}).(nativeStreamDiagnostic)
	response, err := stream.downloader.doMediaRequestWithClient(request, &client)
	if err != nil {
		stream.nativeLogError(info, "upstream_error", request.URL.String(), err, "")
		return response, err
	}
	address := request.URL.String()
	if response.Request != nil && response.Request.URL != nil {
		address = response.Request.URL.String()
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		stream.nativeLog(info, "upstream_status", address, "", response.StatusCode, response.Header.Get("Content-Type"))
	}
	response.Body = &nativeDiagnosticBody{ReadCloser: response.Body, stream: stream, info: info, address: address}
	return response, nil
}

func newNativeStreamServer(d *Downloader) (*nativeStreamServer, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("无法初始化本机播放器")
	}
	stream := &nativeStreamServer{downloader: d, address: "http://" + listener.Addr().String(), sessions: map[string]*nativeStreamSession{}}
	server := &http.Server{Handler: http.HandlerFunc(stream.nativeServe), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.server = server
	go func() { _ = server.Serve(listener) }()
	return stream, nil
}

func (stream *nativeStreamServer) nativeOpen(media providerMedia) (string, string) {
	return stream.nativeOpenOwned(media, false)
}

func (stream *nativeStreamServer) nativeOpenOwned(media providerMedia, managed bool) (string, string) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(tokenBytes)
	ctx, cancel := context.WithCancel(providerMediaContext(context.Background(), media.credentials))
	session := &nativeStreamSession{assets: map[string]nativeStreamAsset{}, referer: media.Referer, key: media.HLSKey, ctx: ctx, cancel: cancel, lastUsed: time.Now(), credentials: media.credentials, diagnosticID: nativeStreamID(token), cache: newNativeMediaCache(), managed: managed}
	stream.mu.Lock()
	for id, old := range stream.sessions {
		if !old.managed && time.Since(old.lastUsed) > 10*time.Minute {
			stream.nativeCancel(old, "idle_expired")
			delete(stream.sessions, id)
		}
	}
	if !managed && len(stream.sessions) >= 8 {
		oldest := ""
		for id, old := range stream.sessions {
			if old.managed {
				continue
			}
			if oldest == "" || old.lastUsed.Before(stream.sessions[oldest].lastUsed) {
				oldest = id
			}
		}
		if oldest != "" {
			stream.nativeCancel(stream.sessions[oldest], "capacity_eviction")
			delete(stream.sessions, oldest)
		}
	}
	stream.sessions[token] = session
	stream.mu.Unlock()
	entry := nativeStreamAsset{kind: "media", address: media.URL, contentType: "video/mp4"}
	parsedURL, parseErr := url.Parse(media.URL)
	isHLS := media.Playlist != "" || (parseErr == nil && strings.HasSuffix(strings.ToLower(parsedURL.Path), ".m3u8"))
	if isHLS {
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if isHLS || strings.Contains(entry.contentType, "mpegurl") {
		entry.kind = "entry_playlist"
	}
	entryURL := stream.nativeAsset(token, session, entry)
	if media.Playlist != "" && len(media.Playlist) <= nativePlaylistLimit {
		if text, err := nativeStreamPlaylist([]byte(media.Playlist)); err == nil && nativePreloadPlaylistStable(text) {
			session.cache.put(nativeAssetID(entry), entry, []byte(text))
		}
	}
	return entryURL, token
}

func (stream *nativeStreamServer) nativeCancel(session *nativeStreamSession, reason string) {
	if reason != "release" {
		stream.nativeLog(nativeStreamDiagnostic{session: session.diagnosticID}, "session_cancel", "", "reason="+reason, 0, "")
	}
	session.cancel()
	session.clearAssets()
}

func (stream *nativeStreamServer) nativeRelease(token string) {
	stream.mu.Lock()
	if session := stream.sessions[token]; session != nil {
		stream.nativeCancel(session, "release")
		delete(stream.sessions, token)
	}
	stream.mu.Unlock()
}

const nativePlaylistLimit = 4 << 20

func nativePlaylistText(body []byte) string {
	// 部分站源在 BOM 前后都带空白；判别与重写必须使用同一份规范化正文。
	return strings.TrimSpace(strings.TrimLeftFunc(string(body), func(r rune) bool {
		return r == '\ufeff' || unicode.IsSpace(r)
	}))
}

func nativeStreamIsPlaylist(contentType, address string, body []byte, predicted bool) bool {
	if strings.HasPrefix(nativePlaylistText(body), "#EXTM3U") {
		return true
	}
	contentType = strings.ToLower(contentType)
	// URL 和预解析类型只是预测，真实 MP4 响应不能按播放列表缓存或重写。
	if strings.Contains(contentType, "video/mp4") {
		return false
	}
	parsed, _ := url.Parse(address)
	return predicted || strings.Contains(contentType, "mpegurl") ||
		(parsed != nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8"))
}

func nativeStreamPlaylist(body []byte) (string, error) {
	if len(body) > nativePlaylistLimit {
		return "", errors.New("播放列表过大或读取失败")
	}
	text := nativePlaylistText(body)
	if !strings.HasPrefix(text, "#EXTM3U") {
		return "", errors.New("播放列表无效")
	}
	return text, nil
}

func nativeStreamErrorPage(contentType string) bool {
	contentType = strings.ToLower(contentType)
	return strings.Contains(contentType, "text/html") || strings.Contains(contentType, "application/json")
}

func (stream *nativeStreamServer) nativeServe(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 2 {
		http.NotFound(writer, request)
		return
	}
	stream.mu.Lock()
	session := stream.sessions[parts[0]]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	asset, releaseAsset, found := session.acquireAsset(parts[1])
	info := nativeStreamDiagnostic{session: session.diagnosticID, asset: asset.kind}
	if !found {
		stream.nativeLog(info, "asset_missing", "", "", 0, "")
		http.NotFound(writer, request)
		return
	}
	defer releaseAsset()
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	ctx = context.WithValue(ctx, nativeStreamDiagnosticKey{}, info)
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	if session.credentials != nil && !session.credentials.expires.IsZero() && !time.Now().Before(session.credentials.expires) {
		session.clearAssets()
		http.Error(writer, "播放凭证已过期", http.StatusGone)
		return
	}
	// Resolved AES keys are credentials, not an optional upstream cache hit.
	// Budget pressure must never fall back to a different source key.
	if asset.resolvedKey && len(session.key) == 16 {
		writer.Header().Set("Content-Type", "application/octet-stream")
		http.ServeContent(writer, request, parts[1], time.Time{}, bytes.NewReader(session.key))
		return
	}
	if stream.nativeServeCached(writer, request, session, parts[0], parts[1]) {
		return
	}
	if stream.nativeServeCacheGap(ctx, writer, request, session, parts[1]) {
		return
	}
	asset.cacheEpoch = session.cache.currentEpoch()
	upstream, err := http.NewRequestWithContext(ctx, request.Method, asset.address, nil)
	if err != nil {
		http.Error(writer, "媒体地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", userAgent)
	upstream.Header.Set("Referer", session.referer)
	upstream.Header.Set("Accept-Encoding", "identity")
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		err := stream.downloader.catalogResponseError(upstream, response, body)
		http.Error(writer, err.Error(), response.StatusCode)
		return
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	finalURL := upstream.URL
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL
	}
	reader := bufio.NewReader(response.Body)
	var peek []byte
	if request.Method == http.MethodGet {
		peek, _ = reader.Peek(512)
	}
	playlist := nativeStreamIsPlaylist(contentType, finalURL.String(), peek, strings.Contains(asset.contentType, "mpegurl"))
	if playlist && request.Method == http.MethodHead {
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.WriteHeader(http.StatusOK)
		return
	}
	if playlist && request.Method == http.MethodGet {
		body, releaseBody, err := session.cache.readPlaylist(reader, response.ContentLength, nativePlaylistLimit)
		defer releaseBody()
		cacheable := !errors.Is(err, errNativeCacheBudget)
		if !cacheable {
			// Mandatory playlist parsing is transient working memory, not cache
			// storage. A full cache must not stop current playback; this body is
			// explicitly never admitted to the cache without a reservation.
			body, err = io.ReadAll(io.LimitReader(reader, nativePlaylistLimit+1))
		}
		if err != nil || len(body) > nativePlaylistLimit || response.ContentLength >= 0 && int64(len(body)) != response.ContentLength {
			stream.nativeLogError(info, "playlist_read_failed", finalURL.String(), err, contentType)
			http.Error(writer, "播放列表过大或读取失败", http.StatusBadGateway)
			return
		}
		if response.StatusCode == http.StatusPartialContent {
			start, end, total, valid := nativeContentRange(response.Header.Get("Content-Range"))
			if !valid || start != 0 || end+1 != int64(len(body)) || total != int64(len(body)) {
				http.Error(writer, "播放列表未接收完整", http.StatusBadGateway)
				return
			}
		}
		text, err := nativeStreamPlaylist(body)
		if err != nil {
			stream.nativeLog(info, "playlist_invalid", finalURL.String(), "", 0, contentType)
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		rewritten, releasePlaylist, err := stream.nativeRewrite(parts[0], session, parts[1], text, finalURL.String())
		if err != nil {
			stream.nativeLog(info, "playlist_rewrite", finalURL.String(), "kind="+nativePlaylistKind(text)+" error="+nativeStreamError(err), 0, contentType)
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		defer releasePlaylist()
		if cacheable && nativePreloadPlaylistStable(text) && ctx.Err() == nil {
			meta := asset
			meta.address, meta.contentType = finalURL.String(), "application/vnd.apple.mpegurl"
			meta.etag, meta.modified = response.Header.Get("ETag"), response.Header.Get("Last-Modified")
			meta.data = body
			session.cacheAsset(parts[1], meta, true)
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(writer, rewritten)
		return
	}
	if nativePreloadErrorBody(contentType, peek) {
		http.Error(writer, "媒体响应无效", http.StatusBadGateway)
		return
	}
	meta, start, expected, valid := nativeCacheResponse(upstream, response, asset)
	multipart := response.StatusCode == http.StatusPartialContent && strings.Contains(upstream.Header.Get("Range"), ",") && strings.HasPrefix(contentType, "multipart/byteranges;")
	if !valid && !multipart {
		http.Error(writer, "媒体区间响应无效", http.StatusBadGateway)
		return
	}
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		if multipart {
			// Multipart boundaries are transport framing, never media offsets.
			_, _ = io.Copy(writer, reader)
		} else {
			_, _ = nativeCacheCopy(ctx, writer, reader, session.cache, parts[1], meta, start, expected, 0)
		}
	}
}
