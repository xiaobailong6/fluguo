package core

import (
	"context"
	"errors"
	"math"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/html"
)

const (
	sourceHanime1    = "hanime1"
	hanime1BaseURL   = "https://hanime1.me"
	hanime1UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

var hanime1IDPattern = regexp.MustCompile(`^[1-9][0-9]{0,19}$`)
var hanime1QualityPattern = regexp.MustCompile(`^[1-9][0-9]{1,3}$`)

func hanime1Genre(category string) string {
	if len(category) > 800 || !strings.HasPrefix(category, "genre:") {
		return ""
	}
	genre, err := url.PathUnescape(strings.TrimPrefix(category, "genre:"))
	if err != nil || genre == "" || len([]rune(genre)) > 80 || newWebControls(genre) || "genre:"+newWebComponent(genre) != category {
		return ""
	}
	return genre
}

func validHanime1Category(category string) bool {
	return category == "" || hanime1Genre(category) != ""
}

func hanime1VideoID(raw, base string) string {
	address := newWebSiteURL(raw, base)
	if address == nil || address.Path != "/watch" || address.Fragment != "" || len(address.Query()["v"]) != 1 {
		return ""
	}
	id := address.Query().Get("v")
	if !hanime1IDPattern.MatchString(id) {
		return ""
	}
	return id
}

func (d *Downloader) fetchHanime1Categories(ctx context.Context) ([]nativeCategory, error) {
	base := d.providerBaseURL(sourceHanime1)
	root, err := d.fetchNewWebPage(ctx, base+"/search", base, hanime1UserAgent, false)
	if err != nil {
		return nil, err
	}
	categories := make([]nativeCategory, 0)
	seen := map[string]bool{}
	for _, anchor := range newWebNodes(root, "a") {
		if !providerHTMLClass(anchor, "nav-desktop-items") && !providerHTMLClass(anchor, "home-genre-tabs") {
			continue
		}
		address := newWebSiteURL(providerHTMLAttr(anchor, "href"), base+"/")
		if address == nil || address.Path != "/search" || len(address.Query()["genre"]) != 1 {
			continue
		}
		genre := address.Query().Get("genre")
		id := "genre:" + newWebComponent(genre)
		if !validHanime1Category(id) || seen[id] {
			continue
		}
		categories = append(categories, nativeCategory{ID: id, Name: genre})
		seen[id] = true
		if len(categories) >= 200 {
			break
		}
	}
	if len(categories) == 0 {
		return nil, errors.New("Hanime1 未返回可识别的分类")
	}
	return categories, ctx.Err()
}

func hanime1Portrait(node *html.Node) bool {
	if node.Data != "a" {
		return false
	}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if providerHTMLClass(child, "home-rows-videos-div") && providerHTMLClass(child, "search-videos") {
			return true
		}
	}
	return false
}

func parseHanime1Cards(root *html.Node, base string) ([]Drama, *html.Node, error) {
	scope := newWebFirstID(root, "home-rows-wrapper")
	if scope == nil || !providerHTMLClass(scope, "search-rows-wrapper") {
		return nil, nil, errors.New("Hanime1 未返回搜索列表")
	}
	cards := providerHTMLNodes(scope, func(node *html.Node) bool {
		return providerHTMLClass(node, "video-item-container") || hanime1Portrait(node)
	})
	items := make([]Drama, 0)
	seen := map[string]bool{}
	for _, card := range cards {
		portrait := hanime1Portrait(card)
		anchor := card
		if !portrait {
			anchor = nil
			for _, candidate := range newWebNodes(card, "a") {
				if providerHTMLClass(candidate, "video-link") && hanime1VideoID(providerHTMLAttr(candidate, "href"), base+"/") != "" {
					anchor = candidate
					break
				}
			}
		}
		id := hanime1VideoID(providerHTMLAttr(anchor, "href"), base+"/")
		if id == "" || seen[id] {
			continue
		}
		titleClass := "title"
		if portrait {
			titleClass = "home-rows-videos-title"
		}
		title := firstNonEmpty(providerHTMLText(providerHTMLFirstClass(anchor, titleClass)), providerHTMLAttr(card, "title"))
		if title == "" {
			return nil, scope, errors.New("Hanime1 视频卡片缺少标题")
		}
		cover := ""
		for _, image := range newWebNodes(anchor, "img") {
			if portrait || providerHTMLClass(image, "main-thumb") {
				cover = firstNonEmpty(newWebAddress(providerHTMLAttr(image, "data-src"), base+"/"),
					newWebAddress(providerHTMLAttr(image, "data-original"), base+"/"), newWebAddress(providerHTMLAttr(image, "src"), base+"/"))
				break
			}
		}
		items = append(items, newWebDrama(sourceHanime1, "Hanime1", id, title, cover, ""))
		seen[id] = true
		if len(items) >= 500 {
			break
		}
	}
	return items, scope, nil
}

func (d *Downloader) fetchHanime1CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > 100000 || !validHanime1Category(category) || len(query) > 800 || len([]rune(query)) > 200 || newWebControls(query) {
		return nil, false, errors.New("Hanime1 目录查询参数无效")
	}
	params := url.Values{"page": {strconv.Itoa(page)}}
	if query != "" {
		query = strings.Join(strings.Fields(query), " ")
		if query == "" {
			return []Drama{}, false, ctx.Err()
		}
		params.Set("query", query)
	} else if category != "" {
		params.Set("genre", hanime1Genre(category))
	}
	base := d.providerBaseURL(sourceHanime1)
	address := base + "/search?" + params.Encode()
	root, err := d.fetchNewWebPage(ctx, address, base, hanime1UserAgent, false)
	if err != nil {
		return nil, false, err
	}
	items, scope, err := parseHanime1Cards(root, base)
	if err != nil {
		return nil, false, err
	}
	more := newWebMorePages(root, address, base, page, 100000, "page-link")
	if len(items) == 0 {
		unparsed := false
		for _, anchor := range newWebNodes(scope, "a") {
			if hanime1VideoID(providerHTMLAttr(anchor, "href"), base+"/") != "" {
				unparsed = true
				break
			}
		}
		if more || unparsed {
			return nil, false, errors.New("Hanime1 列表有视频或下一页，但未解析到有效卡片")
		}
	}
	return items, more, ctx.Err()
}

type hanime1DetailPage struct {
	player   *html.Node
	metadata map[string]string
	title    string
}

func (d *Downloader) fetchHanime1DetailPage(ctx context.Context, id string) (hanime1DetailPage, error) {
	if !hanime1IDPattern.MatchString(id) {
		return hanime1DetailPage{}, errors.New("Hanime1 视频 ID 无效")
	}
	base := d.providerBaseURL(sourceHanime1)
	root, err := d.fetchNewWebPage(ctx, base+"/watch?v="+id, base, hanime1UserAgent, true)
	if err != nil {
		return hanime1DetailPage{}, err
	}
	metadata := newWebMetadata(root)
	if hanime1VideoID(metadata["og:url"], base+"/") != id {
		return hanime1DetailPage{}, errors.New("Hanime1 详情与视频 ID 不一致")
	}
	player := newWebFirstID(root, "player")
	title := firstNonEmpty(providerHTMLText(newWebFirstID(root, "shareBtn-title")), metadata["og:title"])
	if player == nil || player.Data != "video" || title == "" {
		return hanime1DetailPage{}, errors.New("Hanime1 详情缺少播放器或标题")
	}
	return hanime1DetailPage{player: player, metadata: metadata, title: title}, nil
}

func (d *Downloader) fetchHanime1Detail(ctx context.Context, id string) (Drama, []Chapter, error) {
	page, err := d.fetchHanime1DetailPage(ctx, id)
	if err != nil {
		return Drama{}, nil, err
	}
	base := d.providerBaseURL(sourceHanime1)
	cover := firstNonEmpty(newWebAddress(page.metadata["og:image"], base+"/"), newWebAddress(providerHTMLAttr(page.player, "poster"), base+"/"))
	drama := newWebDrama(sourceHanime1, "Hanime1", id, page.title, cover, page.metadata["og:description"])
	address := base + "/watch?v=" + id
	return drama, []Chapter{newWebChapter(sourceHanime1, id, "1", address, address)}, ctx.Err()
}

func hanime1MediaURL(raw, base string) string {
	address := newWebHTTPURL(raw, base+"/")
	if address == nil || address.Fragment != "" || !strings.HasSuffix(strings.ToLower(address.Path), ".mp4") {
		return ""
	}
	cdn := address.Scheme == "https" && strings.EqualFold(address.Hostname(), "vdownload.hembed.com") && (address.Port() == "" || address.Port() == "443")
	if !cdn && (base == hanime1BaseURL || newWebSiteURL(address.String(), base) == nil) {
		return ""
	}
	return address.String()
}

func (d *Downloader) resolveHanime1Media(ctx context.Context, task Task) (providerMedia, error) {
	id, err := newWebTaskID(task, sourceHanime1, "1")
	base := d.providerBaseURL(sourceHanime1)
	if err != nil || !hanime1IDPattern.MatchString(id) || hanime1VideoID(task.Chapter.VideoURL, base+"/") != id {
		return providerMedia{}, errors.New("Hanime1 播放任务与视频 ID 不一致，请刷新详情")
	}
	page, err := d.fetchHanime1DetailPage(ctx, id)
	if err != nil {
		return providerMedia{}, err
	}
	duration := time.Duration(0)
	if seconds, err := strconv.ParseFloat(page.metadata["og:video:duration"], 64); err == nil && seconds > 0 && seconds <= 86400 {
		duration = time.Duration(math.Round(seconds*1000)) * time.Millisecond
	}
	referer := base + "/watch?v=" + id
	variants := make([]providerMedia, 0)
	seen := map[string]bool{}
	for _, source := range newWebNodes(page.player, "source") {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		address := hanime1MediaURL(providerHTMLAttr(source, "src"), base)
		if address == "" || seen[address] || !strings.EqualFold(strings.TrimSpace(providerHTMLAttr(source, "type")), "video/mp4") {
			continue
		}
		quality := 0
		if size := providerHTMLAttr(source, "size"); hanime1QualityPattern.MatchString(size) {
			quality, _ = strconv.Atoi(size)
		}
		variants = append(variants, providerMedia{URL: address, Referer: referer, Quality: quality, Duration: duration,
			credentials: newWebCredentials(address, referer, hanime1UserAgent)})
		seen[address] = true
		if len(variants) >= 32 {
			break
		}
	}
	if len(variants) == 0 {
		return providerMedia{}, errors.New("Hanime1 未返回支持的 MP4 地址")
	}
	sort.SliceStable(variants, func(left, right int) bool { return variants[left].Quality > variants[right].Quality })
	media, err := d.prepareWebProviderMedia(ctx, variants[0], "Hanime1")
	if err != nil {
		return providerMedia{}, err
	}
	media.Variants = variants
	return media, nil
}
