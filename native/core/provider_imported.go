package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"

	xhtml "golang.org/x/net/html"
)

// Only sources whose catalog, detail and media endpoints were verified are registered.
var importedSites = map[string]struct{ Name, Base string }{
	"fanguo":    {"饭果", "https://xifan-api-cn.youlishipin.com"},
	"shuangguo": {"爽果", "https://www.duanju2.com"},
	"wuguo": {"伍果", "https://www.duanju55.com"},
}

func isImportedSource(source string) bool { _, ok := importedSites[source]; return ok }
func importedBase(source string) string   { return importedSites[source].Base }

var importedTopics = []string{"都市", "甜宠", "逆袭", "古装", "穿越", "萌宝", "重生", "复仇", "家庭", "短剧"}

func importedCategories(source string) []nativeCategory {
	result := []nativeCategory{{Name: "全部"}}
	var topics []string
	if source == "shuangguo" {
		topics = []string{"女频恋爱", "脑洞悬疑", "年代穿越", "古装仙侠", "现代都市", "反转", "爽文", "短剧"}
	} else if source == "fanguo" {
		topics = importedTopics
	}
	for _, name := range topics {
		result = append(result, nativeCategory{ID: name, Name: name})
	}
	return result
}

func validImportedCategory(source, category string) bool {
	if category == "" {
		return true
	}
	for _, entry := range importedCategories(source) {
		if entry.ID == category {
			return true
		}
	}
	return false
}

func importedMap(value any) map[string]any { result, _ := value.(map[string]any); return result }
func importedList(value any) []any         { result, _ := value.([]any); return result }
func importedText(node map[string]any, fields ...string) string {
	for _, field := range fields {
		if text := nativeText(node[field]); text != "" {
			return text
		}
	}
	return ""
}
func importedNumber(value any) int { result, _ := strconv.Atoi(nativeText(value)); return result }
func importedAbsolute(base, value string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	root, err := url.Parse(base)
	if err != nil {
		return ""
	}
	relative, err := url.Parse(html.UnescapeString(value))
	if err != nil {
		return ""
	}
	resolved := root.ResolveReference(relative)
	if resolved.Scheme != "https" && resolved.Scheme != "http" {
		return ""
	}
	return resolved.String()
}

func (d *Downloader) importedJSON(ctx context.Context, address string) (map[string]any, error) {
	body, err := d.fetchProviderText(ctx, address, address)
	if err != nil {
		return nil, err
	}
	var data map[string]any
	if json.Unmarshal([]byte(body), &data) != nil {
		return nil, errors.New("站源接口数据格式异常")
	}
	return data, nil
}

func importedDrama(source string, node map[string]any) Drama {
	id := importedText(node, "duanjuId", "bookId", "id")
	if source == "fanguo" {
		payload := importedText(node, "source")
		id += "~" + base64.RawURLEncoding.EncodeToString([]byte(payload))
	}
	return Drama{ID: providerDramaID(source, id), Source: source, SourceID: id,
		Title:        importedText(node, "title", "bookName", "name"),
		Intro:        importedText(node, "description", "introduction", "intro"),
		Cover:        importedAbsolute(importedBase(source), importedText(node, "coverImageUrl", "coverWap", "cover")),
		EpisodeCount: node[firstImportedKey(node, "total", "totalChapterNum")], ChannelName: importedSites[source].Name}
}
func firstImportedKey(node map[string]any, fields ...string) string {
	for _, field := range fields {
		if node[field] != nil {
			return field
		}
	}
	return ""
}
func importedChapter(source, id string, number int, title, media, page string) Chapter {
	return Chapter{ID: providerChapterID(source, id, strconv.Itoa(number)), Source: source,
		Title: firstNonEmpty(title, fmt.Sprintf("第 %d 集", number)), VideoURL: media,
		PageURL: page, Referer: importedBase(source) + "/", CurrentEpisode: json.RawMessage(strconv.Itoa(number))}
}

func (d *Downloader) importedCatalog(ctx context.Context, source string, page int, category, query string) ([]Drama, bool, error) {
	if source == "wuguo" {
		return d.wuguoCatalog(ctx, page, category, query)
	}
	base := importedBase(source)
	if source == "fanguo" {
		keyword := firstNonEmpty(query, category, "都市")
		address := base + "/xifan/search/getSearchList?" + url.Values{"reqType": {"search"}, "offset": {"0"},
			"keyword": {keyword}, "quickEngineVersion": {"-1"}, "pageIndex": {strconv.Itoa(page)}}.Encode()
		data, err := d.importedJSON(ctx, address)
		if err != nil {
			return nil, false, err
		}
		result := importedMap(data["result"])
		var dramas []Drama
		seen := map[string]bool{}
		for _, raw := range importedList(result["elements"]) {
			for _, child := range importedList(importedMap(raw)["contents"]) {
				node := importedMap(importedMap(child)["duanjuVo"])
				if importedText(node, "duanjuId", "id") == "" {
					continue
				}
				drama := importedDrama(source, node)
				if !seen[drama.ID] && drama.Title != "" {
					seen[drama.ID] = true
					dramas = append(dramas, drama)
				}
			}
		}
		return dramas, result["hasMore"] == true, nil
	}
	// 搜索页有安全验证，仅匹配精选目录；分类与翻页使用站内实际路由。
	if query != "" && page > 1 {
		return nil, false, nil
	}
	path := "/show/duanju---" + url.PathEscape(category) + "--------.html"
	if page > 1 {
		path = "/show/duanju---" + url.PathEscape(category) + "-----" + strconv.Itoa(page) + "---.html"
	}
	address := base + path
	body, err := d.fetchProviderText(ctx, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	result := parseImportedWebCatalog(source, body)
	if len(result) == 0 && page == 1 {
		return nil, false, errors.New("站源未返回可识别剧集")
	}
	if query != "" {
		filtered := make([]Drama, 0, len(result))
		for _, item := range result {
			if strings.Contains(item.Title, query) {
				filtered = append(filtered, item)
			}
		}
		return filtered, false, nil
	}
	return result, len(result) >= 20, nil
}

func importedDOM(body string) *xhtml.Node {
	node, _ := xhtml.Parse(strings.NewReader(body))
	return node
}
func importedWalk(root *xhtml.Node, visit func(*xhtml.Node)) {
	if root == nil {
		return
	}
	visit(root)
	for child := root.FirstChild; child != nil; child = child.NextSibling {
		importedWalk(child, visit)
	}
}
func importedAttr(node *xhtml.Node, key string) string {
	for _, attr := range node.Attr {
		if attr.Key == key {
			return html.UnescapeString(attr.Val)
		}
	}
	return ""
}
func importedNodeText(node *xhtml.Node) string {
	var text strings.Builder
	importedWalk(node, func(child *xhtml.Node) {
		if child.Type == xhtml.TextNode {
			text.WriteString(child.Data)
		}
	})
	return strings.Join(strings.Fields(text.String()), " ")
}

var importedShuangguoID = regexp.MustCompile(`/vod/(\d+)\.html`)

func parseImportedWebCatalog(source, body string) []Drama {
	var result []Drama
	positions := map[string]int{}
	pattern := importedShuangguoID
	importedWalk(importedDOM(body), func(node *xhtml.Node) {
		if node.Type != xhtml.ElementNode || node.Data != "a" {
			return
		}
		link := importedAttr(node, "href")
		id := pattern.FindStringSubmatch(link)
		if len(id) < 2 {
			return
		}
		title := importedAttr(node, "title")
		cover := ""
		importedWalk(node, func(child *xhtml.Node) {
			if child.Type == xhtml.ElementNode && child.Data == "img" {
				cover = firstNonEmpty(importedAttr(child, "data-original"), importedAttr(child, "data-src"), importedAttr(child, "src"))
				if title == "" {
					title = importedAttr(child, "alt")
				}
			}
		})
		if title == "" {
			title = importedNodeText(node)
		}
		if title == "" || title == "立即播放" {
			return
		}
		drama := Drama{ID: providerDramaID(source, id[1]), Source: source, SourceID: id[1], Title: title,
			Cover: importedAbsolute(importedBase(source), cover), ChannelName: importedSites[source].Name}
		if index, ok := positions[drama.ID]; ok {
			if nativeText(result[index].Cover) == "" && cover != "" {
				result[index].Cover = drama.Cover
			}
			return
		}
		positions[drama.ID] = len(result)
		result = append(result, drama)
	})
	return result
}

func (d *Downloader) importedDetail(ctx context.Context, source, id string) (Drama, []Chapter, error) {
	if source == "wuguo" {
		return d.wuguoDetail(ctx, id)
	}
	base := importedBase(source)
	if source == "fanguo" {
		raw, payload, _ := strings.Cut(id, "~")
		decoded, err := base64.RawURLEncoding.DecodeString(payload)
		if err != nil || raw == "" {
			return Drama{}, nil, errors.New("饭果剧集编号无效")
		}
		address := base + "/xifan/drama/getDuanjuInfo?" + url.Values{"duanjuId": {raw}, "source": {string(decoded)}}.Encode()
		data, err := d.importedJSON(ctx, address)
		if err != nil {
			return Drama{}, nil, err
		}
		node := importedMap(data["result"])
		drama := importedDrama(source, node)
		drama.ID, drama.SourceID = providerDramaID(source, id), id
		var chapters []Chapter
		for index, entry := range importedList(node["episodeList"]) {
			episode := importedMap(entry)
			link := importedText(episode, "playUrl", "play_url", "videoUrl")
			if !isProviderHTTPMediaURL(link) {
				continue
			}
			number := importedNumber(episode["index"])
			if number <= 0 {
				number = index + 1
			}
			chapters = append(chapters, importedChapter(source, id, number, importedText(episode, "title", "name"), link, ""))
		}
		if len(chapters) == 0 {
			return drama, nil, errors.New("饭果暂未返回可播放分集")
		}
		return drama, chapters, nil
	}
	if !webProviderNumericID.MatchString(id) {
		return Drama{}, nil, errors.New("剧集编号无效")
	}
	path := "/vod/" + id + ".html"
	body, err := d.fetchProviderText(ctx, base+path, base+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	drama := Drama{ID: providerDramaID(source, id), Source: source, SourceID: id, ChannelName: importedSites[source].Name}
	var chapters []Chapter
	seen := map[int]bool{}
	pattern := regexp.MustCompile(`/play/` + regexp.QuoteMeta(id) + `-\d+-(\d+)\.html`)
	importedWalk(importedDOM(body), func(node *xhtml.Node) {
		if node.Type != xhtml.ElementNode {
			return
		}
		if (node.Data == "h1" || node.Data == "h2") && drama.Title == "" {
			drama.Title = importedNodeText(node)
		}
		if node.Data == "meta" && importedAttr(node, "property") == "og:image" {
			drama.Cover = importedAbsolute(base, importedAttr(node, "content"))
		}
		if node.Data == "meta" && importedAttr(node, "name") == "description" {
			drama.Intro = importedAttr(node, "content")
		}
		if node.Data != "a" {
			return
		}
		path := importedAttr(node, "href")
		match := pattern.FindStringSubmatch(path)
		if len(match) < 2 {
			return
		}
		number, _ := strconv.Atoi(match[1])
		if number < 1 || seen[number] {
			return
		}
		seen[number] = true
		chapters = append(chapters, importedChapter(source, id, number, importedNodeText(node), "", importedAbsolute(base, path)))
	})
	if len(chapters) == 0 {
		return drama, nil, errors.New("站源暂未返回可播放分集")
	}
	sort.SliceStable(chapters, func(i, j int) bool {
		return importedNumber(string(chapters[i].CurrentEpisode)) < importedNumber(string(chapters[j].CurrentEpisode))
	})
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

var importedPlayerStart = regexp.MustCompile(`var\s+player_[A-Za-z0-9_]+\s*=`)

func importedJSONObject(body string, start int) map[string]any {
	for start < len(body) && body[start] != '{' {
		start++
	}
	if start >= len(body) {
		return nil
	}
	depth := 0
	quoted, escaped := false, false
	for i := start; i < len(body); i++ {
		c := body[i]
		if quoted {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				quoted = false
			}
			continue
		}
		if c == '"' {
			quoted = true
		} else if c == '{' {
			depth++
		} else if c == '}' {
			depth--
			if depth == 0 {
				var node map[string]any
				if json.Unmarshal([]byte(body[start:i+1]), &node) == nil {
					return node
				}
				return nil
			}
		}
	}
	return nil
}

func (d *Downloader) resolveImportedMedia(ctx context.Context, task Task) (providerMedia, error) {
	source := task.Chapter.Source
	media := providerMedia{URL: task.Chapter.VideoURL, Referer: firstNonEmpty(task.Chapter.Referer, importedBase(source)+"/")}
	if source == "fanguo" {
		// Redirect endpoint emits an MP4 response; let the player/proxy follow it without downloading the body here.
		if !isProviderHTTPMediaURL(media.URL) {
			return media, errors.New("饭果播放地址无效")
		}
		return media, nil
	}
	page := task.Chapter.PageURL
	if providerSourceForURL(page) != source {
		return media, errors.New("新增站源播放页身份不匹配")
	}
	body, err := d.fetchProviderText(ctx, page, media.Referer)
	if err != nil {
		return media, err
	}
	media.Referer = page
	match := importedPlayerStart.FindStringIndex(body)
	if match != nil {
		node := importedJSONObject(body, match[1])
		media.URL = importedText(node, "url")
		switch importedNumber(node["encrypt"]) {
		case 1:
			media.URL, _ = url.QueryUnescape(media.URL)
		case 2:
			decoded, decodeErr := base64.StdEncoding.DecodeString(media.URL)
			if decodeErr != nil {
				return media, errors.New("站源播放配置解码失败")
			}
			media.URL, _ = url.QueryUnescape(string(decoded))
		}
	}
	if !isProviderHTTPMediaURL(media.URL) {
		return media, errors.New("新增站源暂未返回有效媒体地址")
	}
	return d.prepareWebProviderMedia(ctx, media, importedSites[source].Name)
}
