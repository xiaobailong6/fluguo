package core

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/html"
)

const (
	sourceMissav          = "missav"
	missavBaseURL         = "https://missav.live"
	missavUserAgent       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
	missavMaxScriptBytes  = 1 << 20
	missavMaxUnpackWork   = 16 << 20
	missavMaxReplacements = 65536
)

var (
	missavSlugPattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,127}$`)
	missavCardPattern   = regexp.MustCompile(`^/(?:dm[0-9]+/)?cn/([a-z0-9][a-z0-9._-]{0,127})/?$`)
	missavGenrePattern  = regexp.MustCompile(`^/(?:dm[0-9]+/)?cn/genres/([^/]+?)/?$`)
	missavPackedPattern = regexp.MustCompile(`(?s)eval\(function\(p,a,c,k,e,d\)\{.*?\}\(\s*'((?:[^'\\]|\\.)*)'\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*'((?:[^'\\]|\\.)*)'\.split\('\|'\)`)
	missavMediaPattern  = regexp.MustCompile(`https?://[^\s"'<>\\]+`)
	missavMediaPath     = regexp.MustCompile(`^/[0-9a-f-]{36}/playlist\.m3u8$`)
)

func validMissavCategory(category string) bool {
	return len(category) <= 384 && len([]rune(category)) <= 96 && category != "." && category != ".." &&
		!newWebControls(category) && !strings.ContainsAny(category, "/\\?#")
}

func missavPathID(raw, base string, pattern *regexp.Regexp) string {
	address := newWebSiteURL(raw, base)
	if address == nil || address.RawQuery != "" || address.Fragment != "" {
		return ""
	}
	match := pattern.FindStringSubmatch(address.Path)
	if len(match) != 2 {
		return ""
	}
	return match[1]
}

func (d *Downloader) fetchMissavCategories(ctx context.Context) ([]nativeCategory, error) {
	base := d.providerBaseURL(sourceMissav)
	root, err := d.fetchNewWebPage(ctx, base+"/cn/genres", base, missavUserAgent, false)
	if err != nil {
		return nil, err
	}
	categories := make([]nativeCategory, 0)
	seen := map[string]int{}
	for _, anchor := range newWebNodes(root, "a") {
		id := missavPathID(providerHTMLAttr(anchor, "href"), base+"/", missavGenrePattern)
		name := providerHTMLText(anchor)
		if id == "" || !validMissavCategory(id) || name == "" {
			continue
		}
		if index, found := seen[id]; found {
			if len([]rune(name)) < len([]rune(categories[index].Name)) {
				categories[index].Name = truncate(name, 48)
			}
		} else if len(categories) < 200 {
			seen[id] = len(categories)
			categories = append(categories, nativeCategory{ID: id, Name: truncate(name, 48)})
		}
	}
	return categories, nil
}

func parseMissavCards(root *html.Node, base string) []Drama {
	cards := providerHTMLNodes(root, func(node *html.Node) bool {
		return node.Data == "div" && providerHTMLClass(node, "thumbnail") && providerHTMLClass(node, "group")
	})
	items := make([]Drama, 0)
	seen := map[string]bool{}
	for _, card := range cards {
		id := ""
		for _, anchor := range newWebNodes(card, "a") {
			id = missavPathID(providerHTMLAttr(anchor, "href"), base+"/", missavCardPattern)
			if id != "" {
				break
			}
		}
		if id == "" || seen[id] {
			continue
		}
		var selected *html.Node
		cover := ""
		for _, image := range newWebNodes(card, "img") {
			lazy := newWebAddress(providerHTMLAttr(image, "data-src"), base+"/")
			if lazy != "" {
				selected, cover = image, lazy
				break
			}
			if selected == nil {
				if plain := newWebAddress(providerHTMLAttr(image, "src"), base+"/"); plain != "" {
					selected, cover = image, plain
				}
			}
		}
		title := firstNonEmpty(providerHTMLText(providerHTMLFirstClass(card, "my-2")), providerHTMLAttr(selected, "alt"), strings.ToUpper(id))
		drama := newWebDrama(sourceMissav, "MissAV", id, title, cover, "")
		for _, badge := range newWebNodes(card, "span") {
			if providerHTMLClass(badge, "absolute") {
				drama.Remark = truncate(providerHTMLText(badge), 32)
				break
			}
		}
		items = append(items, drama)
		seen[id] = true
		if len(items) >= 500 {
			break
		}
	}
	return items
}

func (d *Downloader) fetchMissavCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > 1000000 || len(query) > 1024 || len([]rune(query)) > 256 || newWebControls(query) || !validMissavCategory(category) {
		return nil, false, errors.New("MissAV 目录查询参数无效")
	}
	base := d.providerBaseURL(sourceMissav)
	path := "/cn/new"
	if query != "" {
		query = strings.TrimSpace(query)
		if query == "" || query == "." || query == ".." {
			return nil, false, errors.New("MissAV 搜索关键词无效")
		}
		path = "/cn/search/" + url.PathEscape(query)
	} else if category != "" {
		path = "/cn/genres/" + url.PathEscape(category)
	}
	address := base + path + "?page=" + strconv.Itoa(page)
	root, err := d.fetchNewWebPage(ctx, address, base, missavUserAgent, false)
	if err != nil {
		return nil, false, err
	}
	items := parseMissavCards(root, base)
	more := newWebMorePages(root, address, base, page, 1000000, "")
	if len(items) == 0 && (more || page == 1 && category == "" && query == "") {
		return nil, false, errors.New("MissAV 未返回应有的目录页")
	}
	return items, more, ctx.Err()
}

func (d *Downloader) fetchMissavDetail(ctx context.Context, id string) (Drama, []Chapter, error) {
	if !missavSlugPattern.MatchString(id) {
		return Drama{}, nil, errors.New("MissAV 视频 ID 无效")
	}
	base := d.providerBaseURL(sourceMissav)
	address := base + "/cn/" + id
	root, err := d.fetchNewWebPage(ctx, address, base, missavUserAgent, true)
	if err != nil {
		return Drama{}, nil, err
	}
	metadata := newWebMetadata(root)
	title := ""
	for _, heading := range newWebNodes(root, "h1") {
		if title = providerHTMLText(heading); title != "" {
			break
		}
	}
	title = firstNonEmpty(title, metadata["og:title"], metadata["twitter:title"])
	if title == "" {
		return Drama{}, nil, errors.New("MissAV 详情缺少视频标题")
	}
	if canonical := metadata["og:url"]; canonical != "" && missavPathID(canonical, base+"/", missavCardPattern) != id {
		return Drama{}, nil, errors.New("MissAV 详情与视频 ID 不一致")
	}
	cover := firstNonEmpty(newWebAddress(metadata["og:image"], base+"/"), newWebAddress(metadata["twitter:image"], base+"/"))
	if cover == "" {
		for _, player := range newWebNodes(root, "video") {
			cover = newWebAddress(providerHTMLAttr(player, "data-poster"), base+"/")
			if cover != "" {
				break
			}
		}
	}
	drama := newWebDrama(sourceMissav, "MissAV", id, title, cover, firstNonEmpty(metadata["og:description"], metadata["description"]))
	date := metadata["og:video:release_date"]
	if stamp, err := time.Parse(time.RFC3339Nano, date); err == nil {
		date = stamp.In(time.FixedZone("UTC+8", 8*3600)).Format("2006-01-02")
	}
	if normalized := normalizeDate(date); normalized != "" {
		if stamp, err := time.Parse("2006-01-02", normalized); err == nil && stamp.Year() >= 2000 && stamp.Year() <= 2100 {
			drama.OnlineDate = normalized
		}
	}
	seen := map[string]bool{}
	for _, anchor := range newWebNodes(root, "a") {
		tag := providerHTMLText(anchor)
		if missavPathID(providerHTMLAttr(anchor, "href"), base+"/", missavGenrePattern) != "" && tag != "" && len([]rune(tag)) <= 48 && !seen[tag] {
			drama.Tags = append(drama.Tags, tag)
			seen[tag] = true
			if len(drama.Tags) >= 16 {
				break
			}
		}
	}
	chapter := newWebChapter(sourceMissav, id, id, "missav-play://"+id, address)
	return drama, []Chapter{chapter}, ctx.Err()
}

// 只解码字符串字面量的转义，不接受表达式、函数调用或任意 JS 执行。
func missavLiteral(value string) (string, error) {
	if len(value) > missavMaxScriptBytes {
		return "", errors.New("MissAV 脚本文字过大")
	}
	var decoded strings.Builder
	for value != "" {
		if strings.HasPrefix(value, `\"`) {
			decoded.WriteByte('"')
			value = value[2:]
			continue
		}
		if strings.HasPrefix(value, `\/`) {
			decoded.WriteByte('/')
			value = value[2:]
			continue
		}
		character, _, tail, err := strconv.UnquoteChar(value, '\'')
		if err != nil {
			return "", errors.New("MissAV 脚本文字转义无效")
		}
		decoded.WriteRune(character)
		value = tail
	}
	return decoded.String(), nil
}

func missavSymbol(index, radix int) string {
	const digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ[\\"
	if index < radix {
		return string(digits[index])
	}
	return missavSymbol(index/radix, radix) + string(digits[index%radix])
}

// 限制字典、累计扫描字节、替换次数和展开大小；倒序替换与参考 packed 算法一致。
func unpackMissav(ctx context.Context, match []string) (string, error) {
	if len(match) != 5 {
		return "", errors.New("MissAV packed 参数无效")
	}
	radix, radixErr := strconv.Atoi(match[2])
	count, countErr := strconv.Atoi(match[3])
	if radixErr != nil || countErr != nil || radix < 2 || radix > 64 || count < 1 || count > 1024 {
		return "", errors.New("MissAV packed 参数超限")
	}
	payload, err := missavLiteral(match[1])
	if err != nil {
		return "", err
	}
	dictionary, err := missavLiteral(match[4])
	if err != nil || strings.Count(dictionary, "|") >= 1024 {
		return "", errors.New("MissAV packed 字典无效")
	}
	words := strings.Split(dictionary, "|")
	work, replacements := 0, 0
	for index := count - 1; index >= 0; index-- {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if index >= len(words) || words[index] == "" {
			continue
		}
		work += len(payload)
		if work > missavMaxUnpackWork {
			return "", errors.New("MissAV packed 扫描超限")
		}
		pattern := regexp.MustCompile(`\b` + regexp.QuoteMeta(missavSymbol(index, radix)) + `\b`)
		positions := pattern.FindAllStringIndex(payload, missavMaxReplacements-replacements+1)
		replacements += len(positions)
		if replacements > missavMaxReplacements {
			return "", errors.New("MissAV packed 替换次数超限")
		}
		var result strings.Builder
		previous := 0
		for _, position := range positions {
			if result.Len()+position[0]-previous+len(words[index]) > missavMaxScriptBytes {
				return "", errors.New("MissAV packed 展开超限")
			}
			result.WriteString(payload[previous:position[0]])
			result.WriteString(words[index])
			previous = position[1]
		}
		if result.Len()+len(payload)-previous > missavMaxScriptBytes {
			return "", errors.New("MissAV packed 展开超限")
		}
		result.WriteString(payload[previous:])
		payload = result.String()
	}
	return payload, nil
}

func missavMediaURL(text, base string) string {
	text = strings.ReplaceAll(text, `\/`, "/")
	for _, raw := range missavMediaPattern.FindAllString(text, 256) {
		address := newWebHTTPURL(raw, "")
		if address == nil || address.Fragment != "" || !strings.HasSuffix(strings.ToLower(address.Path), ".m3u8") {
			continue
		}
		// CDN 域名按已校验参考源码限定；自定义站源仅额外允许自身同源，便于离线 fixture 和自托管。
		cdn := strings.EqualFold(address.Hostname(), "surrit.com") &&
			(address.Port() == "" || address.Scheme == "https" && address.Port() == "443" || address.Scheme == "http" && address.Port() == "80") && missavMediaPath.MatchString(address.Path)
		if cdn || base != missavBaseURL && newWebSiteURL(raw, base) != nil {
			return address.String()
		}
	}
	return ""
}

func missavMediaAddress(ctx context.Context, root *html.Node, base string) (string, error) {
	packedCount := 0
	for _, script := range newWebNodes(root, "script") {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		var body strings.Builder
		for node := script.FirstChild; node != nil; node = node.NextSibling {
			if body.Len()+len(node.Data) > missavMaxScriptBytes {
				return "", errors.New("MissAV 播放脚本过大")
			}
			body.WriteString(node.Data)
		}
		text := body.String()
		matches := missavPackedPattern.FindAllStringSubmatch(text, 17)
		packedCount += len(matches)
		if packedCount > 16 {
			return "", errors.New("MissAV packed 脚本数量超限")
		}
		for _, match := range matches {
			decoded, err := unpackMissav(ctx, match)
			if err != nil {
				return "", err
			}
			if address := missavMediaURL(decoded, base); address != "" {
				return address, nil
			}
		}
		if address := missavMediaURL(text, base); address != "" {
			return address, nil
		}
	}
	return "", errors.New("MissAV 页面里未解析到播放地址")
}

func (d *Downloader) resolveMissavMedia(ctx context.Context, task Task) (providerMedia, error) {
	id, err := newWebTaskID(task, sourceMissav, "")
	if err != nil || !missavSlugPattern.MatchString(id) || (task.Chapter.VideoURL != "" && task.Chapter.VideoURL != "missav-play://"+id) {
		return providerMedia{}, errors.New("MissAV 播放分集信息无效，请刷新详情")
	}
	base := d.providerBaseURL(sourceMissav)
	pageURL := base + "/cn/" + id
	root, err := d.fetchNewWebPage(ctx, pageURL, base, missavUserAgent, true)
	if err != nil {
		return providerMedia{}, err
	}
	if canonical := newWebMetadata(root)["og:url"]; canonical != "" && missavPathID(canonical, base+"/", missavCardPattern) != id {
		return providerMedia{}, errors.New("MissAV 播放页与视频 ID 不一致")
	}
	address, err := missavMediaAddress(ctx, root, base)
	if err != nil {
		return providerMedia{}, err
	}
	media := providerMedia{URL: address, Referer: pageURL, credentials: newWebCredentials(address, pageURL, missavUserAgent)}
	return d.prepareWebProviderMedia(ctx, media, "MissAV")
}
