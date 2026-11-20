package core

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
)

const (
	nativeStreamCacheLimit     = 8 << 20
	nativeStreamCachePoolLimit = 24 << 20
	nativeStreamCacheChunk     = 64 << 10
)

// The pool includes allocated capacity, not just populated bytes. Retired blocks
// remain charged while a response leases them; cancelled writers keep their
// reservations until they actually discard the buffers. Never wait for budget.

var errNativeCacheBudget = errors.New("media cache budget unavailable")
var nativeMediaCachePool = nativeCachePool{}

type nativeCachePool struct {
	mu                  sync.Mutex
	committed, reserved int64
	clock               uint64
}

type nativeMediaCache struct {
	pool            *nativeCachePool
	entries         map[string]*nativeCacheEntry
	used            int64
	closed          bool
	epoch           uint64
	startupSegments int
}

type nativeCacheEntry struct {
	meta     nativeStreamAsset
	blocks   []*nativeCacheBlock
	busy     *nativeCacheWrite
	priority int
}

type nativeCacheBlock struct {
	start    int64
	data     []byte
	priority int
	used     uint64
	refs     int
	retired  bool
}

type nativeCacheWrite struct {
	cache     *nativeMediaCache
	id        string
	entry     *nativeCacheEntry
	blocks    []*nativeCacheBlock // Sorted, non-overlapping pending intervals.
	bytes     int64               // Populated bytes returned to prefetch callers.
	allocated int64               // Full capacities, including an unfinished chunk.
	end       int64               // Known response end, or the asset total as a bound.
	done      bool
}

func newNativeMediaCache() *nativeMediaCache {
	return &nativeMediaCache{pool: &nativeMediaCachePool, entries: map[string]*nativeCacheEntry{}}
}

func nativeCacheValidator(asset nativeStreamAsset) string {
	if asset.etag != "" && !strings.HasPrefix(asset.etag, "W/") {
		return asset.etag
	}
	return asset.modified
}

func (cache *nativeMediaCache) retireLocked(block *nativeCacheBlock) {
	block.retired = true
	if block.refs == 0 {
		n := int64(cap(block.data))
		cache.used -= n
		cache.pool.committed -= n
		block.data = nil
	}
}

func (cache *nativeMediaCache) removeLocked(id string) {
	if entry := cache.entries[id]; entry != nil {
		for _, block := range entry.blocks {
			cache.retireLocked(block)
		}
		delete(cache.entries, id) // In-flight writes can no longer commit this identity.
	}
}

func (cache *nativeMediaCache) remove(id string) {
	if cache == nil {
		return
	}
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	cache.epoch++
	cache.removeLocked(id)
}

func (cache *nativeMediaCache) close() {
	if cache == nil {
		return
	}
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	cache.closed = true
	for id := range cache.entries {
		cache.removeLocked(id)
	}
}

// Only this session's unleased, lower-priority/LRU body blocks are evicted.
// Neighbour preparation must never evict another episode's session or index.
func (cache *nativeMediaCache) reserveLocked(n int64, priority int) bool {
	if cache.closed || n <= 0 || n > nativeStreamCacheLimit {
		return false
	}
	for cache.used+n > nativeStreamCacheLimit || cache.pool.committed+cache.pool.reserved+n > nativeStreamCachePoolLimit {
		var victim *nativeCacheBlock
		var owner *nativeCacheEntry
		var pending *nativeCacheWrite
		var index int
		for _, entry := range cache.entries {
			for i, block := range entry.blocks {
				if block.refs != 0 || block.priority > priority {
					continue
				}
				if victim == nil || block.priority < victim.priority || block.priority == victim.priority && block.used < victim.used {
					victim, owner, pending, index = block, entry, nil, i
				}
			}
			if write := entry.busy; write != nil {
				for i, block := range write.blocks {
					if block.priority > priority {
						continue
					}
					if victim == nil || block.priority < victim.priority || block.priority == victim.priority && block.used < victim.used {
						victim, owner, pending, index = block, entry, write, i
					}
				}
			}
		}
		if victim == nil {
			return false
		}
		if pending != nil {
			n := int64(cap(victim.data))
			pending.blocks = append(pending.blocks[:index], pending.blocks[index+1:]...)
			pending.bytes -= int64(len(victim.data))
			pending.allocated -= n
			cache.used -= n
			cache.pool.reserved -= n
			victim.data = nil
		} else {
			owner.blocks = append(owner.blocks[:index], owner.blocks[index+1:]...)
			cache.retireLocked(victim)
		}
	}
	cache.used += n
	cache.pool.reserved += n
	return true
}

func (cache *nativeMediaCache) begin(id string, meta nativeStreamAsset) *nativeCacheWrite {
	if cache == nil {
		return nil
	}
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	if cache.closed || meta.cacheEpoch != cache.epoch {
		return nil
	}
	entry := cache.entries[id]
	if entry != nil && entry.busy != nil && nativeCacheValidator(meta) == "" {
		return nil
	}
	if entry != nil {
		// Without a strong validator, independent responses cannot be combined.
		v := nativeCacheValidator(meta)
		if v == "" || v != nativeCacheValidator(entry.meta) || meta.total != entry.meta.total ||
			meta.etag != entry.meta.etag || meta.modified != entry.meta.modified || meta.address != entry.meta.address || meta.contentType != entry.meta.contentType {
			cache.removeLocked(id)
			entry = nil
		}
	}
	if entry == nil {
		entry = &nativeCacheEntry{meta: meta}
		if meta.kind == "segment" && cache.startupSegments < 4 {
			entry.priority = 1
			cache.startupSegments++
		}
		cache.entries[id] = entry
	}
	if entry.busy != nil {
		return nil
	} // Duplicate readers forward without a second allocation.
	write := &nativeCacheWrite{cache: cache, id: id, entry: entry, end: meta.total}
	entry.busy = write
	return write
}

func nativeCachePriority(meta nativeStreamAsset, start int64) int {
	if strings.Contains(meta.contentType, "mpegurl") || meta.kind == "key" || meta.kind == "map" {
		return 2
	}
	if meta.kind == "media" || meta.kind == "entry_playlist" {
		if start < 1<<20 || meta.total > 0 && start >= meta.total-(512<<10) {
			return 2
		}
	}
	return 0
}

// Capture copies only uncovered intervals. Sequential short reads fill the same
// reserved chunk without reallocating; binary searches avoid rescanning the
// entire interval index while holding the shared pool lock on every Read.
func (write *nativeCacheWrite) capture(start int64, data []byte) {
	if write == nil {
		return
	}
	cache := write.cache
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	if write.done || cache.closed || cache.entries[write.id] != write.entry || write.entry.busy != write {
		return
	}
	for len(data) > 0 {
		end := start + int64(len(data))
		capacity := int64(nativeStreamCacheChunk)
		if write.end > start {
			capacity = min(capacity, write.end-start)
		}
		var covered int64
		var tail *nativeCacheBlock
		for which, blocks := range [][]*nativeCacheBlock{write.entry.blocks, write.blocks} {
			i := sort.Search(len(blocks), func(i int) bool {
				return blocks[i].start+int64(len(blocks[i].data)) > start
			})
			if which == 1 && i > 0 {
				previous := blocks[i-1]
				if previous.start+int64(len(previous.data)) == start && len(previous.data) < cap(previous.data) {
					tail = previous
				}
			}
			if i < len(blocks) {
				block := blocks[i]
				if block.start <= start {
					covered = max(covered, block.start+int64(len(block.data)))
				} else {
					end = min(end, block.start)
					capacity = min(capacity, block.start-start)
				}
			}
		}
		if covered > start {
			n := min(int64(len(data)), covered-start)
			data, start = data[n:], start+n
			continue
		}
		if tail != nil {
			// Only this writer's pending storage is mutable; leased/committed
			// snapshots remain untouched even when they have unused capacity.
			n := min(end-start, int64(cap(tail.data)-len(tail.data)))
			old := len(tail.data)
			tail.data = tail.data[:old+int(n)]
			copy(tail.data[old:], data[:n])
			write.bytes += n
			data, start = data[n:], start+n
			continue
		}
		// Keep the existing index ceiling; short reads no longer consume one
		// entry each, and failed admissions cannot allocate uncharged storage.
		if len(write.blocks)+len(write.entry.blocks) >= 2048 {
			return
		}
		priority := max(write.entry.priority, nativeCachePriority(write.entry.meta, start))
		if !cache.reserveLocked(capacity, priority) {
			return
		}
		n := min(end-start, capacity)
		cache.pool.clock++
		block := &nativeCacheBlock{start: start, data: make([]byte, int(n), int(capacity)), priority: priority, used: cache.pool.clock}
		copy(block.data, data[:n])
		// Reservation can evict pending blocks, so find the insertion point
		// afterwards. Sequential captures append without shifting old entries.
		i := sort.Search(len(write.blocks), func(i int) bool { return write.blocks[i].start > start })
		write.blocks = append(write.blocks, nil)
		copy(write.blocks[i+1:], write.blocks[i:])
		write.blocks[i] = block
		write.bytes += n
		write.allocated += capacity
		data, start = data[n:], start+n
	}
}

func (write *nativeCacheWrite) finish(valid bool, total int64) int64 {
	if write == nil {
		return 0
	}
	cache := write.cache
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	if write.done {
		return 0
	}
	write.done = true
	valid = valid && !cache.closed && cache.entries[write.id] == write.entry && write.entry.busy == write
	if write.entry.busy == write {
		write.entry.busy = nil
	}
	cache.pool.reserved -= write.allocated
	if !valid {
		cache.used -= write.allocated
		write.blocks = nil
		return 0
	}
	cache.pool.committed += write.allocated
	write.entry.meta.total = total
	for _, block := range write.blocks {
		cache.pool.clock++
		block.used = cache.pool.clock
		write.entry.blocks = append(write.entry.blocks, block)
	}
	sort.Slice(write.entry.blocks, func(i, j int) bool { return write.entry.blocks[i].start < write.entry.blocks[j].start })
	write.blocks = nil
	return write.bytes
}

// A hit pins the original storage, never concatenates/copies media bytes. The
// release callback must run after the HTTP write, even if the session is closed.
func (cache *nativeMediaCache) lease(id, byteRange, ifRange string) (nativeStreamAsset, [][]byte, int64, int64, func(), bool) {
	if cache == nil {
		return nativeStreamAsset{}, nil, 0, 0, nil, false
	}
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	entry := cache.entries[id]
	if cache.closed || entry == nil || entry.meta.total <= 0 || ifRange != "" && ifRange != nativeCacheValidator(entry.meta) {
		return nativeStreamAsset{}, nil, 0, 0, nil, false
	}
	if strings.Contains(entry.meta.contentType, "mpegurl") {
		byteRange = ""
	}
	start, end, ok := nativeCacheRange(byteRange, entry.meta.total)
	if !ok {
		return nativeStreamAsset{}, nil, 0, 0, nil, false
	}
	position := start
	var blocks []*nativeCacheBlock
	var data [][]byte
	for _, block := range entry.blocks {
		if block.start > position {
			break
		}
		last := min(end+1, block.start+int64(len(block.data)))
		if last <= position {
			continue
		}
		data = append(data, block.data[position-block.start:last-block.start])
		blocks = append(blocks, block)
		position = last
		if position > end {
			break
		}
	}
	if position <= end {
		return nativeStreamAsset{}, nil, 0, 0, nil, false
	}
	for _, block := range blocks {
		block.refs++
		cache.pool.clock++
		block.used = cache.pool.clock
	}
	return entry.meta, data, start, end, func() {
		cache.pool.mu.Lock()
		defer cache.pool.mu.Unlock()
		for i, block := range blocks {
			data[i] = nil
			block.refs--
			if block.retired && block.refs == 0 {
				cache.retireLocked(block)
			}
		}
	}, true
}

func nativeCacheRange(value string, total int64) (int64, int64, bool) {
	if value == "" {
		return 0, total - 1, total > 0
	}
	if !strings.HasPrefix(value, "bytes=") || strings.Contains(value, ",") {
		return 0, 0, false
	}
	parts := strings.Split(strings.TrimPrefix(value, "bytes="), "-")
	if len(parts) != 2 {
		return 0, 0, false
	}
	if parts[0] == "" {
		n, err := strconv.ParseInt(parts[1], 10, 64)
		return max(0, total-n), total - 1, err == nil && n > 0 && total > 0
	}
	start, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || start < 0 || start >= total {
		return 0, 0, false
	}
	end := total - 1
	if parts[1] != "" {
		end, err = strconv.ParseInt(parts[1], 10, 64)
		if err != nil || end < start {
			return 0, 0, false
		}
	}
	return start, min(end, total-1), true
}

// Validate the returned interval against the request before admitting any bytes.
func nativeCacheResponse(request *http.Request, response *http.Response, asset nativeStreamAsset) (nativeStreamAsset, int64, int64, bool) {
	asset.data = nil
	asset.contentType = response.Header.Get("Content-Type")
	asset.etag, asset.modified = response.Header.Get("ETag"), response.Header.Get("Last-Modified")
	if response.Request != nil && response.Request.URL != nil {
		asset.address = response.Request.URL.String()
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		return asset, 0, 0, false
	}
	if response.StatusCode == http.StatusOK {
		if response.Header.Get("Content-Range") != "" {
			return asset, 0, 0, false
		}
		asset.total = response.ContentLength
		return asset, 0, response.ContentLength, true
	}
	if response.StatusCode != http.StatusPartialContent {
		return asset, 0, 0, false
	}
	start, end, total, ok := nativeContentRange(response.Header.Get("Content-Range"))
	if !ok || response.ContentLength >= 0 && response.ContentLength != end-start+1 {
		return asset, 0, 0, false
	}
	if value := request.Header.Get("If-Range"); value != "" && value != nativeCacheValidator(asset) {
		return asset, 0, 0, false
	}
	a, b, valid := nativeCacheRange(request.Header.Get("Range"), total)
	if !valid || a != start || b != end {
		return asset, 0, 0, false
	}
	asset.total = total
	return asset, start, end - start + 1, true
}

// No media ReadAll: forward immediately from a small transfer buffer, capturing
// budgeted intervals on the side. Failed upstream responses commit none; a
// player cancelling a validated long read may retain completed chunks.
// Prefetch additionally rejects an oversized response atomically.
func nativeCacheCopy(ctx context.Context, writer io.Writer, reader io.Reader, cache *nativeMediaCache, id string, meta nativeStreamAsset, start, expected, preloadLimit int64) (int64, error) {
	write := cache.begin(id, meta)
	if write != nil && expected >= 0 {
		write.end = start + expected
	}
	defer write.finish(false, 0)
	var buffer [32 << 10]byte
	var read int64
	interrupted := func(err error) (int64, error) {
		if preloadLimit == 0 && expected > 0 && meta.total > 0 && nativeCacheValidator(meta) != "" && read >= nativeStreamCacheChunk {
			return write.finishInterrupted(start+read/nativeStreamCacheChunk*nativeStreamCacheChunk, meta.total), err
		}
		return 0, err
	}
	for {
		if err := ctx.Err(); err != nil {
			return interrupted(err)
		}
		n, err := reader.Read(buffer[:])
		if n > 0 {
			if preloadLimit > 0 && read+int64(n) > preloadLimit {
				return 0, io.ErrShortBuffer
			}
			if expected >= 0 && read+int64(n) > expected {
				return 0, io.ErrUnexpectedEOF
			}
			write.capture(start+read, buffer[:n])
			written, writeErr := writer.Write(buffer[:n])
			read += int64(n)
			if writeErr != nil {
				if err == nil || err == io.EOF {
					return interrupted(writeErr)
				}
				return 0, writeErr
			}
			if written != n {
				return 0, io.ErrShortWrite
			}
		}
		if err != nil {
			if err != io.EOF {
				if ctx.Err() != nil {
					return interrupted(ctx.Err())
				}
				return 0, err
			}
			break
		}
	}
	if ctx.Err() != nil {
		return interrupted(ctx.Err())
	}
	if expected >= 0 && read != expected {
		return 0, io.ErrUnexpectedEOF
	}
	total := meta.total
	if total < 0 {
		total = read
	}
	// 无 validator 的 CDN 仍可原样复用本次完整响应的区间。
	// begin 会替换旧响应，gap 禁止跨响应拼接；截断/取消仍不能提交。
	return write.finish(read > 0, total), nil
}

func (stream *nativeStreamServer) nativeServeCached(writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, token, id string) bool {
	meta, data, start, end, release, ok := session.cache.lease(id, request.Header.Get("Range"), request.Header.Get("If-Range"))
	if !ok {
		return false
	}
	defer release()
	if strings.Contains(meta.contentType, "mpegurl") {
		var text strings.Builder
		for _, part := range data {
			text.Write(part)
		}
		body, releasePlaylist, err := stream.nativeRewrite(token, session, id, nativePlaylistText([]byte(text.String())), meta.address)
		if err != nil {
			stream.nativeLog(nativeStreamDiagnostic{session: session.diagnosticID, asset: meta.kind}, "playlist_rewrite", meta.address, "kind="+nativePlaylistKind(text.String())+" error="+nativeStreamError(err), 0, "")
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return true
		}
		defer releasePlaylist()
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		if request.Method == http.MethodGet {
			_, _ = io.WriteString(writer, body)
		}
		return true
	}
	writer.Header().Set("Content-Type", meta.contentType)
	writer.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	writer.Header().Set("Accept-Ranges", "bytes")
	if meta.etag != "" {
		writer.Header().Set("ETag", meta.etag)
	}
	if meta.modified != "" {
		writer.Header().Set("Last-Modified", meta.modified)
	}
	if request.Header.Get("Range") != "" {
		writer.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, meta.total))
		writer.WriteHeader(http.StatusPartialContent)
	}
	if request.Method == http.MethodGet {
		for _, part := range data {
			if _, err := writer.Write(part); err != nil {
				break
			}
		}
	}
	return true
}

// Parsing/rewriting playlists needs a bounded contiguous working body. It is not
// retained: the separate cache copy below reserves before allocating its chunks.
func (cache *nativeMediaCache) put(id string, meta nativeStreamAsset, body []byte) int64 {
	meta.data, meta.total = nil, int64(len(body))
	write := cache.begin(id, meta)
	if write == nil {
		return 0
	}
	write.capture(0, body)
	return write.finish(true, meta.total)
}

// Playlist parsing needs a contiguous body, but the pending body is charged
// before allocation too. Growth never relies on append/ReadAll over-allocation.
func (cache *nativeMediaCache) readPlaylist(reader io.Reader, expected, limit int64) ([]byte, func(), error) {
	n := min(limit, int64(4<<10))
	if expected >= 0 {
		n = expected
	}
	if n <= 0 || n > limit {
		return nil, func() {}, io.ErrShortBuffer
	}
	cache.pool.mu.Lock()
	ok := cache.reserveLocked(n, 2)
	cache.pool.mu.Unlock()
	if !ok {
		return nil, func() {}, errNativeCacheBudget
	}
	body := make([]byte, int(n))
	var once sync.Once
	release := func() {
		once.Do(func() {
			body = nil
			cache.pool.mu.Lock()
			cache.used -= n
			cache.pool.reserved -= n
			cache.pool.mu.Unlock()
		})
	}
	count := 0
	var err error
	for {
		if count == len(body) {
			// Probe before growing: an exact-capacity body needs no second
			// allocation. Preserve a reader error accompanying the probe byte.
			var extra [1]byte
			var read int
			var nextErr error
			for read == 0 && nextErr == nil {
				read, nextErr = reader.Read(extra[:])
			}
			if read == 0 {
				err = nextErr
				break
			}
			if expected >= 0 || n == limit {
				err = io.ErrShortBuffer
				break
			}
			next := min(n*2, limit)
			cache.pool.mu.Lock()
			ok = cache.reserveLocked(next, 2)
			cache.pool.mu.Unlock()
			if !ok {
				err = errNativeCacheBudget
				break
			}
			// Reserve the entire new allocation while the old one is still
			// live, not merely the delta. Drop the old capacity only after copy.
			grown := make([]byte, int(next))
			copy(grown, body)
			body = grown
			cache.pool.mu.Lock()
			cache.used -= n
			cache.pool.reserved -= n
			cache.pool.mu.Unlock()
			n = next
			body[count] = extra[0]
			count++
			if nextErr != nil {
				err = nextErr
				break
			}
		}
		var read int
		read, err = reader.Read(body[count:])
		count += read
		if err != nil {
			break
		}
	}
	if err == io.EOF {
		if expected >= 0 && int64(count) != expected {
			err = io.ErrUnexpectedEOF
		} else {
			err = nil
		}
	}
	return body[:count], release, err
}

func (cache *nativeMediaCache) currentEpoch() uint64 {
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	return cache.epoch
}

type nativeCachePiece struct {
	start, end int64
	data       []byte // nil is the single upstream gap.
}

// The common MP4 shape is prefix + one missing interval + metadata tail.
// Lease both cached sides before opening the gap; validate the gap's version
// before sending even the first cached byte. Fragmented/multipart misses simply
// fall back to one upstream response, never a mixture of unchecked versions.
func (cache *nativeMediaCache) gap(id, byteRange, ifRange string) (nativeStreamAsset, []nativeCachePiece, func(), bool) {
	if cache == nil {
		return nativeStreamAsset{}, nil, nil, false
	}
	cache.pool.mu.Lock()
	defer cache.pool.mu.Unlock()
	entry := cache.entries[id]
	if cache.closed || entry == nil || nativeCacheValidator(entry.meta) == "" || strings.Contains(entry.meta.contentType, "mpegurl") ||
		ifRange != "" && ifRange != nativeCacheValidator(entry.meta) {
		return nativeStreamAsset{}, nil, nil, false
	}
	start, end, valid := nativeCacheRange(byteRange, entry.meta.total)
	if !valid {
		return nativeStreamAsset{}, nil, nil, false
	}
	position, gaps := start, 0
	var pieces []nativeCachePiece
	var blocks []*nativeCacheBlock
	for _, block := range entry.blocks {
		last := min(end+1, block.start+int64(len(block.data)))
		if last <= position || block.start > end {
			continue
		}
		if block.start > position {
			pieces = append(pieces, nativeCachePiece{start: position, end: block.start - 1})
			gaps++
			position = block.start
		}
		pieces = append(pieces, nativeCachePiece{start: position, end: last - 1, data: block.data[position-block.start : last-block.start]})
		blocks = append(blocks, block)
		position = last
		if position > end {
			break
		}
	}
	if position <= end {
		pieces = append(pieces, nativeCachePiece{start: position, end: end})
		gaps++
	}
	if gaps != 1 || len(blocks) == 0 {
		return nativeStreamAsset{}, nil, nil, false
	}
	for _, block := range blocks {
		block.refs++
		cache.pool.clock++
		block.used = cache.pool.clock
	}
	meta := entry.meta
	meta.cacheEpoch = cache.epoch
	return meta, pieces, func() {
		cache.pool.mu.Lock()
		defer cache.pool.mu.Unlock()
		for i := range pieces {
			pieces[i].data = nil
		}
		for _, block := range blocks {
			block.refs--
			if block.retired && block.refs == 0 {
				cache.retireLocked(block)
			}
		}
	}, true
}

func (stream *nativeStreamServer) nativeServeCacheGap(ctx context.Context, writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, id string) bool {
	if request.Method != http.MethodGet {
		return false
	}
	meta, pieces, release, ok := session.cache.gap(id, request.Header.Get("Range"), request.Header.Get("If-Range"))
	if !ok {
		return false
	}
	defer release()
	var gap nativeCachePiece
	for _, piece := range pieces {
		if piece.data == nil {
			gap = piece
			break
		}
	}
	upstream, err := http.NewRequestWithContext(ctx, http.MethodGet, meta.address, nil)
	if err != nil {
		return false
	}
	upstream.Header.Set("Referer", session.referer)
	upstream.Header.Set("User-Agent", userAgent)
	upstream.Header.Set("Accept-Encoding", "identity")
	upstream.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", gap.start, gap.end))
	upstream.Header.Set("If-Range", nativeCacheValidator(meta))
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	updated, start, expected, valid := nativeCacheResponse(upstream, response, meta)
	reader := bufio.NewReader(response.Body)
	peek, _ := reader.Peek(512)
	if !valid || response.StatusCode != http.StatusPartialContent || updated.total != meta.total ||
		updated.etag != meta.etag || updated.modified != meta.modified || updated.address != meta.address ||
		updated.contentType != meta.contentType || nativePreloadErrorBody(updated.contentType, peek) {
		session.cache.remove(id)
		return false
	}
	first, last := pieces[0].start, pieces[len(pieces)-1].end
	writer.Header().Set("Content-Type", meta.contentType)
	writer.Header().Set("Content-Length", strconv.FormatInt(last-first+1, 10))
	writer.Header().Set("Accept-Ranges", "bytes")
	if meta.etag != "" {
		writer.Header().Set("ETag", meta.etag)
	}
	if meta.modified != "" {
		writer.Header().Set("Last-Modified", meta.modified)
	}
	if request.Header.Get("Range") != "" {
		writer.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, meta.total))
		writer.WriteHeader(http.StatusPartialContent)
	}
	for _, piece := range pieces {
		if piece.data != nil {
			if _, err := writer.Write(piece.data); err != nil {
				return true
			}
		} else if _, err := nativeCacheCopy(ctx, writer, reader, session.cache, id, updated, start, expected, 0); err != nil {
			return true
		}
	}
	return true
}

// Keep only fully read chunks on a downstream cancellation, not a truncated
// upstream response. Closing/invalidation still wins at finish's identity check.
func (write *nativeCacheWrite) finishInterrupted(end, total int64) int64 {
	if write == nil {
		return 0
	}
	cache := write.cache
	cache.pool.mu.Lock()
	if write.done {
		cache.pool.mu.Unlock()
		return 0
	}
	kept := write.blocks[:0]
	for _, block := range write.blocks {
		if block.start+int64(len(block.data)) <= end {
			kept = append(kept, block)
		} else {
			n := int64(cap(block.data))
			write.bytes -= int64(len(block.data))
			write.allocated -= n
			cache.used -= n
			cache.pool.reserved -= n
			block.data = nil
		}
	}
	write.blocks = kept
	cache.pool.mu.Unlock()
	return write.finish(true, total)
}
