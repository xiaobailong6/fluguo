package core

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type nativePreloadKey struct{}

// 仅缓存紧邻下一集的起播数据，内存预算与播放列表体积限制分开。
const nativePreloadLimit = 8 << 20

// 调用者超时/取消不代表 worker 已退出。跨页面和请求池共享实际执行槽，
// 只由真正执行完毕的调用归还；等待者仍可及时响应自己的取消。
func (engine *nativeEngine) acquirePreload(ctx context.Context) (func(), error) {
	engine.preloadOnce.Do(func() { engine.preloadSlot = make(chan struct{}, 1) })
	select {
	case engine.preloadSlot <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-engine.preloadSlot
			return nil, err
		}
		return func() { <-engine.preloadSlot }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (engine *nativeEngine) nativePreload(ctx context.Context, input nativeInput) (nativePlan, error) {
	release, err := engine.acquirePreload(ctx)
	if err != nil {
		return nativePlan{}, err
	}
	defer release()
	ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
	ctx = context.WithValue(ctx, nativePreloadKey{}, true)
	plan, err := engine.nativeResolve(ctx, input)
	if err != nil || plan.Local {
		return plan, err
	}
	engine.mu.Lock()
	choice, exists := engine.playbacks[plan.Session]
	stream := engine.stream
	engine.mu.Unlock()
	if exists && stream != nil && choice.streamSession != "" {
		warming, cancel := context.WithTimeout(ctx, 6*time.Second)
		plan.PrefetchedBytes = stream.nativePrefetch(warming, choice.streamSession, plan.URL, input.Quality)
		cancel()
	}
	// 预取不持有监听锁；上游完成时必须重新确认计划仍属于当前有效监听。
	if err := engine.nativeValidatePlayback(ctx, plan.Session); err != nil {
		engine.nativeReleasePlayback(plan.Session)
		return nativePlan{}, err
	}
	return plan, nil
}

func (stream *nativeStreamServer) nativePrefetch(ctx context.Context, token, entry string, quality int) int64 {
	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	if session == nil {
		return 0
	}
	if session.credentials != nil && !session.credentials.expires.IsZero() && !time.Now().Before(session.credentials.expires) {
		session.clearAssets()
		return 0
	}
	ctx, cancel := context.WithCancel(providerMediaContext(withProxySource(ctx, session.source), session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	remaining, requests := int64(nativePreloadLimit), 0
	var prefetched int64
	visited := map[string]bool{}
	var warm func(string, int) bool
	warm = func(local string, depth int) bool {
		if ctx.Err() != nil || remaining <= 0 || requests >= 8 || depth > 2 || visited[local] {
			return false
		}
		visited[local] = true
		parsed, err := url.Parse(local)
		if err != nil || !strings.HasPrefix(local, session.origin+"/"+token+"/") {
			return false
		}
		id := strings.TrimPrefix(parsed.Path, "/"+token+"/")
		asset, releaseAsset, exists := session.acquireAsset(id)
		if !exists {
			return false
		}
		defer releaseAsset()
		if asset.resolvedKey && len(session.key) == 16 {
			return true
		}
		playlist := strings.Contains(asset.contentType, "mpegurl")
		meta, chunks, _, _, releaseCache, cached := session.cache.lease(id, "", "")
		if cached {
			defer releaseCache()
			asset = meta
			playlist = strings.Contains(meta.contentType, "mpegurl")
			if !playlist {
				return true
			}
			var body strings.Builder
			for _, chunk := range chunks {
				body.Write(chunk)
			}
			asset.data = []byte(body.String())
		} else {
			requests++
			request, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.address, nil)
			if err != nil {
				return false
			}
			request.Header.Set("Referer", session.referer)
			request.Header.Set("Accept-Encoding", "identity")
			if !playlist {
				request.Header.Set("Range", fmt.Sprintf("bytes=0-%d", remaining-1))
			}
			response, err := stream.nativeRequest(request)
			if err != nil {
				return false
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
				return false
			}
			reader := bufio.NewReader(response.Body)
			peek, _ := reader.Peek(512)
			meta, start, expected, valid := nativeCacheResponse(request, response, asset)
			if !valid {
				return false
			}
			playlist = nativeStreamIsPlaylist(meta.contentType, meta.address, peek, playlist)
			if !playlist {
				if nativePreloadErrorBody(meta.contentType, peek) || expected > remaining {
					return false
				}
				count := &nativePreloadCounter{}
				n, err := nativeCacheCopy(ctx, count, reader, session.cache, id, meta, start, expected, remaining)
				remaining -= count.bytes // Overlap/deduplication must not refill the network allowance.
				prefetched += n
				return err == nil && n > 0
			}
			body, releaseBody, err := session.cache.readPlaylist(reader, expected, min(remaining, nativePlaylistLimit))
			defer releaseBody()
			if err != nil || ctx.Err() != nil || len(body) == 0 || int64(len(body)) > remaining ||
				expected >= 0 && int64(len(body)) != expected || start != 0 || meta.total > 0 && meta.total != int64(len(body)) {
				return false
			}
			text, err := nativeStreamPlaylist(body)
			if err != nil {
				return false
			}
			remaining -= int64(len(body))
			prefetched += int64(len(body))
			asset = meta
			asset.contentType, asset.data = "application/vnd.apple.mpegurl", body
			session.cacheAsset(id, asset, true)
			asset.data = []byte(text)
			body = nil
			releaseBody() // Do not hold a 4 MiB unknown-length reservation through recursive warming.
			response.Body.Close()
		}
		if !playlist {
			return true
		}
		lines, _, master := nativeHLSSelect(strings.Split(string(asset.data), "\n"), quality)
		rewritten, releasePlaylist, err := stream.nativeRewrite(token, session, id, strings.Join(lines, "\n"), asset.address)
		if err != nil {
			return false
		}
		defer releasePlaylist()
		segments := 0
		seconds := 0.0
		for _, raw := range strings.Split(rewritten, "\n") {
			line := strings.TrimSpace(raw)
			if strings.HasPrefix(line, "#EXT-X-BYTERANGE:") {
				break
			}
			if strings.HasPrefix(line, "#EXTINF:") {
				value := strings.SplitN(strings.TrimPrefix(line, "#EXTINF:"), ",", 2)[0]
				duration, _ := strconv.ParseFloat(value, 64)
				seconds += duration
			}
			if strings.HasPrefix(line, "#EXT-X-KEY:") || strings.HasPrefix(line, "#EXT-X-MAP:") {
				for _, match := range nativePlaylistURI.FindAllStringSubmatch(line, -1) {
					if !strings.HasPrefix(match[1], "data:") && !warm(match[1], depth+1) {
						return false
					}
				}
			}
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if !warm(line, depth+1) {
				break
			}
			segments++
			if master || segments >= 4 || seconds >= 16 {
				break
			}
		}
		return true
	}
	warm(entry, 0)
	return prefetched
}

func nativePreloadPlaylistStable(text string) bool {
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "#EXT-X-ENDLIST" || strings.HasPrefix(line, "#EXT-X-STREAM-INF:") {
			return true
		}
	}
	return false
}

var nativeContentRangePattern = regexp.MustCompile(`^bytes ([0-9]+)-([0-9]+)/([0-9]+)$`)

func nativeContentRange(value string) (int64, int64, int64, bool) {
	match := nativeContentRangePattern.FindStringSubmatch(value)
	if match == nil {
		return 0, 0, 0, false
	}
	start, first := strconv.ParseInt(match[1], 10, 64)
	end, second := strconv.ParseInt(match[2], 10, 64)
	total, third := strconv.ParseInt(match[3], 10, 64)
	return start, end, total, first == nil && second == nil && third == nil && start >= 0 && end >= start && total > end
}

// 仅限制预取缓存准入，不能把一次 200 错误正文永久变成该播放会话的媒体。
// text/plain 也用于部分分片/密钥，故只拒绝短小且带明确错误标识的文本。
func nativePreloadErrorBody(contentType string, body []byte) bool {
	contentType = strings.TrimSpace(strings.SplitN(strings.ToLower(contentType), ";", 2)[0])
	if nativeStreamErrorPage(contentType) || strings.HasSuffix(contentType, "+json") ||
		contentType == "application/xml" || contentType == "text/xml" || strings.HasSuffix(contentType, "+xml") {
		return true
	}
	// Some gateways falsely label a 200 login/error page as video/mp4.
	prefix := strings.ToLower(strings.TrimSpace(string(body[:min(len(body), 512)])))
	if strings.HasPrefix(prefix, "<!doctype html") || strings.HasPrefix(prefix, "<html") ||
		strings.HasPrefix(prefix, "<?xml") || strings.HasPrefix(prefix, `{"error"`) {
		return true
	}
	if contentType != "text/plain" || len(body) > 4096 {
		return false
	}
	text := strings.ToLower(strings.TrimSpace(string(body)))
	return strings.HasPrefix(text, "access denied") || strings.HasPrefix(text, "forbidden") ||
		strings.HasPrefix(text, "unauthorized") || strings.HasPrefix(text, "token expired")
}

type nativePreloadCounter struct{ bytes int64 }

func (counter *nativePreloadCounter) Write(body []byte) (int, error) {
	counter.bytes += int64(len(body))
	return len(body), nil
}
