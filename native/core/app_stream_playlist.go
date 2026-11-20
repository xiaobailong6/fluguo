package core

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

var nativePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

// 解析和 URL 改写不持有会话锁；只有全部有效且容量足够才提交索引。
// release 必须延迟到列表写完或预取递归结束，保护正在交付的这一代。
func (stream *nativeStreamServer) nativeRewrite(token string, session *nativeStreamSession, playlistID, body, base string) (string, func(), error) {
	if len(body) > nativePlaylistLimit {
		return "", nil, errors.New("播放列表过大或读取失败")
	}
	parsed, err := url.Parse(base)
	if err != nil {
		return "", nil, errors.New("播放列表地址无效")
	}
	assets := map[string]nativeStreamAsset{}
	var rewriteErr error
	rewrite := func(reference string, key bool, contentType string) string {
		if strings.HasPrefix(reference, "data:") {
			return reference
		}
		relative, err := url.Parse(reference)
		if err != nil {
			return ""
		}
		address := parsed.ResolveReference(relative).String()
		if !isProviderHTTPMediaURL(address) {
			return ""
		}
		kind := "segment"
		switch contentType {
		case "application/vnd.apple.mpegurl":
			kind = "child_playlist"
		case "application/octet-stream":
			kind = "key"
		case "video/mp4":
			kind = "map"
		}
		asset := nativeStreamAsset{kind: kind, address: address, contentType: contentType}
		if key && len(session.key) == 16 {
			asset.data = session.key // Immutable credential; cache storage reserves before copying.
			asset.resolvedKey = true
			asset.contentType = "application/octet-stream"
		}
		id := nativeAssetID(asset)
		if _, found := assets[id]; !found && len(assets) >= nativeStreamAssetLimit {
			rewriteErr = errNativeStreamCapacity
			return ""
		}
		assets[id] = asset
		return stream.address + "/" + token + "/" + id
	}
	var output []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		if text != "" && !strings.HasPrefix(text, "#") {
			contentType := ""
			if nextPlaylist {
				contentType = "application/vnd.apple.mpegurl"
			}
			line = rewrite(text, false, contentType)
			nextPlaylist = false
			if line == "" && rewriteErr == nil {
				rewriteErr = errors.New("播放列表中的媒体地址无效")
			}
		} else if strings.Contains(text, "URI=") {
			line = nativePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := nativePlaylistURI.FindStringSubmatch(match)[1]
				key := strings.HasPrefix(text, "#EXT-X-KEY:") || strings.HasPrefix(text, "#EXT-X-SESSION-KEY:")
				contentType := ""
				switch {
				case key:
					contentType = "application/octet-stream"
				case strings.HasPrefix(text, "#EXT-X-MAP:"):
					contentType = "video/mp4"
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"), strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"), strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					contentType = "application/vnd.apple.mpegurl"
				}
				updated := rewrite(reference, key, contentType)
				if updated == "" && rewriteErr == nil {
					rewriteErr = errors.New("播放列表中的附属地址无效")
				}
				return "URI=\"" + updated + "\""
			})
		}
		if rewriteErr != nil {
			return "", nil, rewriteErr
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	release, err := session.commitPlaylist(playlistID, assets)
	if err != nil {
		return "", nil, err
	}
	return strings.Join(output, "\n"), release, nil
}
