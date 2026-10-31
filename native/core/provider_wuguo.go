package core

import (
 "context"
 "encoding/json"
 "errors"
 "net/url"
 "regexp"
 "sort"
 "strconv"
 "strings"

 xhtml "golang.org/x/net/html"
)

var wuguoDetailID = regexp.MustCompile(`/index\.php/vod/detail/id/([1-9][0-9]*)\.html`)

// 伍果单独适配，不能为匹配它的模板而修改已有站源的解析行为。
func parseWuguoCatalog(body string) []Drama {
 result := []Drama{}
 seen := map[string]bool{}
 importedWalk(importedDOM(body), func(node *xhtml.Node) {
  if node.Type != xhtml.ElementNode || node.Data != "a" { return }
  match := wuguoDetailID.FindStringSubmatch(importedAttr(node, "href"))
  if len(match) != 2 { return }
  title, cover := importedAttr(node, "title"), ""
  importedWalk(node, func(child *xhtml.Node) {
   if child.Data != "img" { return }
   cover = firstNonEmpty(importedAttr(child,"data-original"), importedAttr(child,"data-src"), importedAttr(child,"src"))
   title = firstNonEmpty(title, importedAttr(child,"alt"))
  })
  title = firstNonEmpty(title, importedNodeText(node))
  if title == "" || seen[match[1]] { return }
  seen[match[1]] = true
  result = append(result, Drama{ID: providerDramaID("wuguo",match[1]), Source:"wuguo",SourceID:match[1],
   Title:title, Cover:importedAbsolute(importedBase("wuguo"),cover), ChannelName:"伍果"})
 })
 return result
}

func (d *Downloader) wuguoCatalog(ctx context.Context, page int, category, query string) ([]Drama,bool,error) {
 if page < 1 { page = 1 }
 base := importedBase("wuguo")
 path := "/index.php/vod/type/id/1/page/"+strconv.Itoa(page)+".html"
 if query != "" {
  path = "/index.php/vod/search/page/"+strconv.Itoa(page)+"/wd/"+url.PathEscape(strings.TrimSpace(query))+".html"
 } else if category != "" { return nil,false,errors.New("伍果分类无效") }
 body,err := d.fetchProviderText(ctx,base+path,base+"/")
 if err != nil { return nil,false,err }
 result := parseWuguoCatalog(body)
 if len(result)==0 && page==1 && query=="" {return nil,false,errors.New("伍果未返回可识别剧集")}
 return result,len(result)>=20,nil
}

func parseWuguoDetail(id,body string) (Drama,[]Chapter,error) {
 if !webProviderNumericID.MatchString(id) {return Drama{},nil,errors.New("伍果剧集编号无效")}
 base:=importedBase("wuguo")
 drama:=Drama{ID:providerDramaID("wuguo",id),Source:"wuguo",SourceID:id,ChannelName:"伍果"}
 pattern:=regexp.MustCompile(`/index\.php/vod/play/id/`+regexp.QuoteMeta(id)+`/sid/([0-9]+)/nid/([0-9]+)\.html`)
 type candidate struct {line,number int; name,page string}
 entries:=[]candidate{}
 importedWalk(importedDOM(body),func(node *xhtml.Node){
  if node.Type!=xhtml.ElementNode{return}
  if node.Data=="h1" && drama.Title=="" {drama.Title=importedNodeText(node)}
  if node.Data=="meta" && importedAttr(node,"property")=="og:image"{drama.Cover=importedAbsolute(base,importedAttr(node,"content"))}
  if node.Data!="a"{return}
  link:=importedAttr(node,"href");m:=pattern.FindStringSubmatch(link)
  if len(m)!=3{return};line,_:=strconv.Atoi(m[1]);number,_:=strconv.Atoi(m[2]);if number<1{return}
  entries=append(entries,candidate{line,number,importedNodeText(node),importedAbsolute(base,link)})
 })
 sort.SliceStable(entries,func(i,j int)bool{if entries[i].line!=entries[j].line{return entries[i].line<entries[j].line};return entries[i].number<entries[j].number})
 chapters:=[]Chapter{};seen:=map[int]bool{}
 if len(entries)>0 {line:=entries[0].line;for _,entry:=range entries{if entry.line!=line||seen[entry.number]{continue};seen[entry.number]=true;chapters=append(chapters,importedChapter("wuguo",id,entry.number,entry.name,"",entry.page))}}
 if len(chapters)==0{return drama,nil,errors.New("伍果未返回可播放分集")}
 drama.EpisodeCount=json.Number(strconv.Itoa(len(chapters)))
 return drama,chapters,nil
}

func(d *Downloader) wuguoDetail(ctx context.Context,id string)(Drama,[]Chapter,error){
 if !webProviderNumericID.MatchString(id){return Drama{},nil,errors.New("伍果剧集编号无效")}
 base:=importedBase("wuguo");body,err:=d.fetchProviderText(ctx,base+"/index.php/vod/detail/id/"+id+".html",base+"/")
 if err!=nil{return Drama{},nil,err};return parseWuguoDetail(id,body)
}
