package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
)

const newWebMaxPageBytes = 4 << 20

// URL 只在解析成功后使用；先拒绝凭据、控制字符和反斜杠，避免浏览器与 Go 对地址产生不同解释。
func newWebHTTPURL(raw, base string) *url.URL {
	if strings.TrimSpace(raw) == "" || len(raw) > 8192 || strings.Contains(raw, "\\") || newWebControls(raw) {
		return nil
	}
	address, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || address.User != nil {
		return nil
	}
	if base != "" {
		parent, err := url.Parse(base)
		if err != nil || parent.User != nil {
			return nil
		}
		address = parent.ResolveReference(address)
	}
	if (address.Scheme != "http" && address.Scheme != "https") || address.Hostname() == "" || address.User != nil || address.Opaque != "" {
		return nil
	}
	if _, err := url.ParseQuery(address.RawQuery); err != nil {
		return nil
	}
	return address
}

func newWebControls(value string) bool {
	if !utf8.ValidString(value) {
		return true
	}
	for _, character := range value {
		if character < 32 || character == 127 {
			return true
		}
	}
	return false
}

func newWebSiteURL(raw, base string) *url.URL {
	address, site := newWebHTTPURL(raw, base), newWebHTTPURL(base, "")
	if address == nil || site == nil || providerMediaOrigin(address) != providerMediaOrigin(site) {
		return nil
	}
	return address
}

func newWebAddress(raw, base string) string {
	if address := newWebHTTPURL(raw, base); address != nil {
		return address.String()
	}
	return ""
}

// 身份参数必须唯一；允许服务端省略默认 page=1，但不允许跳到登录页、其他视频或其他搜索结果。
func newWebSamePage(expected, actual, base string) bool {
	want, got := newWebSiteURL(expected, base), newWebSiteURL(actual, base)
	if want == nil || got == nil || want.Path != got.Path {
		return false
	}
	for _, key := range []string{"v", "query", "genre", "page"} {
		left, right := want.Query()[key], got.Query()[key]
		if len(left) > 1 || len(right) > 1 {
			return false
		}
		a, b := want.Query().Get(key), got.Query().Get(key)
		if key == "page" {
			a, b = firstNonEmpty(a, "1"), firstNonEmpty(b, "1")
		}
		if a != b {
			return false
		}
	}
	return true
}

type newWebPageTransport struct {
	base, expected string
	transport      http.RoundTripper
}

func (transport newWebPageTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if !newWebSamePage(transport.expected, request.URL.String(), transport.base) {
		return nil, errors.New("站源请求地址不匹配")
	}
	return transport.transport.RoundTrip(request)
}

// 创建只共享不可变配置和限流器的临时抓取器，绝不复制 Downloader 的 mutex，也不修改共享 http.Client。
func (d *Downloader) newWebPageClient(address, base string) (*Downloader, error) {
	if !newWebSamePage(address, address, base) {
		return nil, errors.New("站源页面地址无效")
	}
	client := *d.client
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = newWebPageTransport{base: base, expected: address, transport: transport}
	previous := client.CheckRedirect
	client.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		if len(via) >= 10 || !newWebSamePage(address, next.URL.String(), base) {
			return errors.New("站源页面发生不匹配的跳转")
		}
		if previous != nil {
			return previous(next, via)
		}
		return nil
	}
	return &Downloader{cfg: d.cfg, client: &client, limiter: d.limiter, providerHosts: map[string]string{}, diagnostics: d.diagnostics}, nil
}

func (d *Downloader) fetchNewWebPage(ctx context.Context, address, base, agent string, noCache bool) (*html.Node, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	scoped, err := d.newWebPageClient(address, base)
	if err != nil {
		return nil, err
	}
	ctx = context.WithValue(ctx, providerTextNoCacheKey{}, noCache)
	document, actual, err := scoped.fetchProviderPage(ctx, address, base+"/", agent)
	if err != nil {
		return nil, err
	}
	if !newWebSamePage(address, actual, base) {
		return nil, errors.New("站源返回的页面与请求不一致")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return document, nil
}

func newWebNodes(root *html.Node, tag string) []*html.Node {
	return providerHTMLNodes(root, func(node *html.Node) bool { return node.Type == html.ElementNode && node.Data == tag })
}

func newWebFirstID(root *html.Node, id string) *html.Node {
	matches := providerHTMLNodes(root, func(node *html.Node) bool { return providerHTMLAttr(node, "id") == id })
	if len(matches) > 0 {
		return matches[0]
	}
	return nil
}

func newWebMetadata(root *html.Node) map[string]string {
	metadata := map[string]string{}
	for _, node := range newWebNodes(root, "meta") {
		key := firstNonEmpty(providerHTMLAttr(node, "property"), providerHTMLAttr(node, "name"))
		if metadata[key] == "" {
			metadata[key] = strings.TrimSpace(providerHTMLAttr(node, "content"))
		}
	}
	return metadata
}

func newWebDrama(source, channel, id, title, cover, description string) Drama {
	title, description = truncate(title, 512), truncate(description, 12000)
	return Drama{ID: providerDramaID(source, id), Source: source, SourceID: id, Title: title, Name: title,
		Cover: cover, CoverURL: cover, Desc: description, Intro: description, ChannelName: channel,
		CategoryName: "视频", TotalEpisode: 1, EpisodeCount: 1}
}

func newWebChapter(source, id, key, videoURL, pageURL string) Chapter {
	return Chapter{ID: providerChapterID(source, id, key), Source: source, Title: "正片",
		CurrentEpisode: json.RawMessage("1"), VideoURL: videoURL, PageURL: pageURL, Referer: pageURL}
}

func newWebSingleEpisode(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	var number float64
	if json.Unmarshal(raw, &number) == nil && number == 1 {
		return true
	}
	var text string
	return json.Unmarshal(raw, &text) == nil && strings.TrimSpace(text) == "1"
}

// 分集必须精确匹配，不能只验证 ID 前缀；旧任务携带的外站 URL 永远不能控制详情请求。
func newWebTaskID(task Task, source, chapterKey string) (string, error) {
	id, found := strings.CutPrefix(task.DramaID, source+":")
	if chapterKey == "" {
		chapterKey = id
	}
	if !found || task.Chapter.ID != providerChapterID(source, id, chapterKey) ||
		(task.Chapter.Source != "" && task.Chapter.Source != source) ||
		!newWebSingleEpisode(task.Chapter.CurrentEpisode) {
		return "", errors.New("播放分集信息无效，请刷新详情")
	}
	return id, nil
}

func newWebMorePages(root *html.Node, address, base string, page, maximum int, class string) bool {
	requested := newWebSiteURL(address, base)
	if requested == nil {
		return false
	}
	for _, anchor := range newWebNodes(root, "a") {
		if class != "" && !providerHTMLClass(anchor, class) {
			continue
		}
		next := newWebSiteURL(providerHTMLAttr(anchor, "href"), address)
		if next == nil || next.Path != requested.Path || len(next.Query()["page"]) != 1 {
			continue
		}
		query := next.Query()
		number, err := strconv.Atoi(query.Get("page"))
		if err != nil || query.Get("page") != strconv.Itoa(number) {
			continue
		}
		query.Set("page", strconv.Itoa(page))
		next.RawQuery = query.Encode()
		if err == nil && number > page && number <= maximum && newWebSamePage(address, next.String(), base) {
			return true
		}
	}
	return false
}

func newWebCredentials(address, referer, agent string) *providerMediaCredentials {
	parsed := newWebHTTPURL(address, "")
	return &providerMediaCredentials{origin: providerMediaOrigin(parsed), referer: referer, userAgent: agent}
}

// 参考脚本使用 encodeURIComponent；保留其规范编码以便分类 ID 可往返校验。
func newWebComponent(value string) string {
	const hexadecimal = "0123456789ABCDEF"
	var result strings.Builder
	for index := 0; index < len(value); index++ {
		character := value[index]
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || strings.ContainsRune("-_.!~*'()", rune(character)) {
			result.WriteByte(character)
		} else {
			result.WriteByte('%')
			result.WriteByte(hexadecimal[character>>4])
			result.WriteByte(hexadecimal[character&15])
		}
	}
	return result.String()
}
