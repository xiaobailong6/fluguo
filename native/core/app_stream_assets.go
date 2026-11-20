package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/url"
	"path"
	"strings"
)

const (
	nativeStreamAssetLimit      = 8192
	nativeStreamPlaylistLimit   = 32
	nativeStreamGenerationLimit = 128
	nativeStreamReferenceLimit  = nativeStreamAssetLimit * 4
	nativeStreamKeepGenerations = 3 // 当前、前代及额外一代回看，不按分片 FIFO 淘汰。
)

var errNativeStreamCapacity = errors.New("播放列表资源索引容量不足，请重新打开播放或选择较短的播放列表")

type nativePlaylistGeneration struct {
	ids     map[string]struct{}
	active  int
	retired bool // 历史/不可达代次：只有最后一个租约释放才需要 GC。
}

// 所有索引和正文访问共用 session.mu。playlist 键使用本机资源 ID，
// 不用重定向后的签名 URL，避免每次续签产生一个永久保留的列表。
type nativeStreamAssetIndex struct {
	limit         int // 测试可在使用会话前设置较小容量；生产值仍有硬上限。
	roots         map[string]bool
	playlists     map[string][]*nativePlaylistGeneration
	active        map[string]int
	closed        bool
	pendingAssets map[string]bool
	pruneCount    uint64 // 确定性性能回归计数，不依赖机器耗时。
}

func (session *nativeStreamSession) assetLimit() int {
	if session.index.limit > 0 && session.index.limit < nativeStreamAssetLimit {
		return session.index.limit
	}
	return nativeStreamAssetLimit
}

func nativeAssetID(asset nativeStreamAsset) string {
	digest := sha256.Sum256([]byte(asset.address + "\x00" + asset.contentType))
	extension := ".ts"
	if parsed, err := url.Parse(asset.address); err == nil {
		switch candidate := strings.ToLower(path.Ext(parsed.Path)); candidate {
		case ".m3u8", ".ts", ".m4s", ".mp4", ".aac", ".m4a", ".mp3", ".vtt", ".webvtt", ".key":
			extension = candidate
		}
	}
	switch asset.contentType {
	case "application/vnd.apple.mpegurl":
		extension = ".m3u8"
	case "application/octet-stream":
		extension = ".key"
	case "video/mp4":
		extension = ".mp4"
	}
	return hex.EncodeToString(digest[:12]) + extension
}

// 仅入口/显式注册资源走此路径；playlist 的资源必须整批提交，不能逐条挤出旧资源。
func (stream *nativeStreamServer) nativeAsset(token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	id := nativeAssetID(asset)
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.index.closed {
		return ""
	}
	if _, found := session.assets[id]; !found && len(session.assets) >= session.assetLimit() {
		return ""
	}
	if session.assets == nil {
		session.assets = map[string]nativeStreamAsset{}
	}
	if session.index.roots == nil {
		session.index.roots = map[string]bool{}
	}
	session.index.roots[id] = true
	session.storeAssetLocked(id, asset)
	return stream.address + "/" + token + "/" + id
}

func (session *nativeStreamSession) storeAssetLocked(id string, asset nativeStreamAsset) {
	if previous, found := session.assets[id]; !found || len(previous.data) == 0 || len(asset.data) > 0 {
		session.assets[id] = asset
	}
}

func nativeRetainedGenerations(history []*nativePlaylistGeneration) []*nativePlaylistGeneration {
	kept := make([]*nativePlaylistGeneration, 0, len(history))
	for i, generation := range history {
		if i < nativeStreamKeepGenerations || generation.active > 0 {
			kept = append(kept, generation)
		}
	}
	return kept
}

func (session *nativeStreamSession) referencedAssetsLocked(playlists map[string][]*nativePlaylistGeneration) map[string]bool {
	keep := make(map[string]bool, len(session.assets))
	for id := range session.index.roots {
		keep[id] = true
	}
	for id := range session.index.active {
		keep[id] = true
	}
	for playlistID, history := range playlists {
		// 在途分片保留的旧子列表仍允许播放器重试获取正文。
		if _, found := session.assets[playlistID]; found {
			keep[playlistID] = true
		}
		for _, generation := range history {
			for id := range generation.ids {
				keep[id] = true
			}
		}
	}
	return keep
}

// 主列表换签名/换分支后，过期子列表不能永久占住一个槽。只保留入口可达、
// 最近代次可达或仍有租约的子图；标记遍历也能回收互相引用的废弃分支。
func (session *nativeStreamSession) prunePlaylistsLocked(playlists map[string][]*nativePlaylistGeneration, publishing string) {
	reachable := map[string]bool{}
	var pending []string
	add := func(id string) {
		if !reachable[id] {
			reachable[id] = true
			pending = append(pending, id)
		}
	}
	for id := range session.index.roots {
		add(id)
	}
	for id := range session.index.active {
		add(id)
	}
	if publishing != "" {
		add(publishing)
	}
	for id, history := range playlists {
		for _, generation := range history {
			if generation.active > 0 {
				add(id)
				break
			}
		}
	}
	for len(pending) > 0 {
		id := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		for _, generation := range playlists[id] {
			for reference := range generation.ids {
				if _, playlist := playlists[reference]; playlist {
					add(reference)
				}
			}
		}
	}
	for id := range playlists {
		if !reachable[id] {
			delete(playlists, id)
		}
	}
}

// 先预算再提交：超大 VOD/EVENT、过多分支或在途保留占满容量时返回错误，
// 旧列表和资源完全不变，绝不返回一个已被截断/淘汰的成功列表。
func (session *nativeStreamSession) commitPlaylist(playlistID string, assets map[string]nativeStreamAsset) (func(), error) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.index.closed {
		return nil, context.Canceled
	}
	ids := make(map[string]struct{}, len(assets))
	for id := range assets {
		ids[id] = struct{}{}
	}
	previous := session.index.playlists[playlistID]
	same := len(previous) > 0 && len(previous[0].ids) == len(ids)
	if same {
		for id := range ids {
			if _, found := previous[0].ids[id]; !found {
				same = false
				break
			}
		}
	}
	candidate := make(map[string][]*nativePlaylistGeneration, len(session.index.playlists)+1)
	for id, history := range session.index.playlists {
		candidate[id] = nativeRetainedGenerations(history)
	}
	if !same {
		history := append([]*nativePlaylistGeneration{{ids: ids}}, previous...)
		candidate[playlistID] = nativeRetainedGenerations(history)
	}
	session.prunePlaylistsLocked(candidate, playlistID)
	generations, references := 0, 0
	for _, history := range candidate {
		generations += len(history)
		for _, generation := range history {
			references += len(generation.ids)
		}
	}
	keep := session.referencedAssetsLocked(candidate)
	if len(keep) > session.assetLimit() || len(candidate) > nativeStreamPlaylistLimit ||
		generations > nativeStreamGenerationLimit || references > nativeStreamReferenceLimit {
		return nil, errNativeStreamCapacity
	}
	if session.assets == nil {
		session.assets = map[string]nativeStreamAsset{}
	}
	session.index.playlists = candidate
	for id := range session.assets {
		if !keep[id] {
			delete(session.assets, id)
		}
	}
	for id, asset := range assets {
		session.storeAssetLocked(id, asset)
	}
	// 写出列表期间也租用新代次，避免并发刷新淘汰尚未发完的 URI。
	generation := candidate[playlistID][0]
	generation.active++
	session.markRetiredLocked()
	return func() {
		session.mu.Lock()
		defer session.mu.Unlock()
		generation.active--
		if generation.retired && generation.active == 0 && !session.index.closed {
			session.pruneAssetsLocked()
		}
	}, nil
}

// 请求在取出资源时同时租用所属代次；整个代次（包括 KEY/MAP）保留到
// 请求结束。暂停中的请求也持有租约，不会在刷新时变成孤立分片。
func (session *nativeStreamSession) acquireAsset(id string) (nativeStreamAsset, func(), bool) {
	session.mu.Lock()
	defer session.mu.Unlock()
	asset, found := session.assets[id]
	if !found || session.index.closed {
		return nativeStreamAsset{}, nil, false
	}
	if session.index.active == nil {
		session.index.active = map[string]int{}
	}
	session.index.active[id]++
	var leased []*nativePlaylistGeneration
	for _, history := range session.index.playlists {
		for _, generation := range history {
			if _, contains := generation.ids[id]; contains {
				generation.active++
				leased = append(leased, generation)
			}
		}
	}
	return asset, func() {
		session.mu.Lock()
		defer session.mu.Unlock()
		collect := false
		for _, generation := range leased {
			generation.active--
			collect = collect || generation.retired && generation.active == 0
		}
		if session.index.active[id] > 1 {
			session.index.active[id]--
		} else {
			delete(session.index.active, id)
			collect = collect || len(leased) == 0 && session.index.pendingAssets[id]
		}
		if collect && !session.index.closed {
			session.pruneAssetsLocked()
		}
	}, true
}

func (session *nativeStreamSession) pruneAssetsLocked() {
	session.index.pruneCount++
	for id, history := range session.index.playlists {
		session.index.playlists[id] = nativeRetainedGenerations(history)
	}
	session.prunePlaylistsLocked(session.index.playlists, "")
	keep := session.referencedAssetsLocked(session.index.playlists)
	for id := range session.assets {
		if !keep[id] {
			delete(session.assets, id)
		}
	}
	session.markRetiredLocked()
}

// 发布/GC 时计算不依赖租约的可达图。稳定 VOD 的普通释放不再扫描资源表；
// 旧代次仍整代保留 KEY/MAP，在途子列表也由 active 与 retired 标志配合保活。
func (session *nativeStreamSession) markRetiredLocked() {
	reachable := map[string]bool{}
	keep := map[string]bool{}
	var pending []string
	for id := range session.index.roots {
		pending = append(pending, id)
	}
	for len(pending) > 0 {
		id := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		keep[id] = true
		if reachable[id] {
			continue
		}
		reachable[id] = true
		history := session.index.playlists[id]
		for _, generation := range history[:min(len(history), nativeStreamKeepGenerations)] {
			for reference := range generation.ids {
				keep[reference] = true
				if _, playlist := session.index.playlists[reference]; playlist {
					pending = append(pending, reference)
				}
			}
		}
	}
	for id, history := range session.index.playlists {
		for index, generation := range history {
			generation.retired = !reachable[id] || index >= nativeStreamKeepGenerations
		}
	}
	session.index.pendingAssets = map[string]bool{}
	for id := range session.index.active {
		if !keep[id] {
			session.index.pendingAssets[id] = true
		}
	}
}

// 预取回包不能复活已释放/已淘汰的资源，缓存正文仍沿用原先的稳定列表规则。
func (session *nativeStreamSession) cacheAsset(id string, asset nativeStreamAsset, playlist bool) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if _, found := session.assets[id]; !found || session.index.closed {
		return
	}
	if playlist && !nativePreloadPlaylistStable(string(asset.data)) {
		asset.data, asset.total = nil, 0
	}
	session.assets[id] = asset
}

func (session *nativeStreamSession) invalidate(address string) {
	session.mu.Lock()
	defer session.mu.Unlock()
	for id, asset := range session.assets {
		if asset.address == address {
			asset.data, asset.total, asset.etag, asset.modified = nil, 0, "", ""
			session.assets[id] = asset
		}
	}
	// 刷新正文不删除最近代次；播放器可能还在使用上次返回的本机 URL。
	session.pruneAssetsLocked()
}

func (session *nativeStreamSession) clearAssets() {
	session.mu.Lock()
	defer session.mu.Unlock()
	session.assets = nil
	session.index = nativeStreamAssetIndex{closed: true}
}
