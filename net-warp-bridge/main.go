// net-warp-bridge —— 本地 HTTP 代理 -> Cloudflare WARP SOCKS5 桥
//
// 为什么需要它：
//
//	Chromium/Edge 用 --proxy-server=socks5:// 时是「远程解析」（把域名交给代理去解析），
//	而 WARP 自己的解析器对个别域名（gist.github.com / twitter.com / www.reddit.com 等）
//	会给出连不通的地址。实测同样的域名用「本地解析 + 把 IP 交给 WARP」就 100% 可用。
//
// 本程序做法：
//  1. 自己解析域名（默认走 Cloudflare DoH @1.1.1.1，经 WARP 隧道出去；失败再退回本机解析）
//  2. 优先取 IPv4 —— 目的是绕开 ISP 对墙名单域名伪造的 AAAA「2001::1」。
//     （WARP 自身的 IPv6 出口实测是正常的，这里只作兜底，不要误以为是「本机没有 v6」）
//  3. 把解析到的 IP 交给 WARP SOCKS5 出网
//  4. 国内域名默认直连、不进隧道（否则访问国内站点会绕道国外变慢），失败自动回退隧道
//  5. 带 5 分钟 DNS 缓存
//
// 纯标准库，零外部依赖，可直接 go build。
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	listenAddr = flag.String("listen", "127.0.0.1:7890", "本地 HTTP 代理监听地址")
	socksAddr  = flag.String("socks", "127.0.0.1:40000", "上游 WARP SOCKS5 地址")
	dohServer  = flag.String("doh", "1.1.1.1:443", "DoH 服务器 (IP:port，避免解析自己)")
	dohHost    = flag.String("doh-host", "cloudflare-dns.com", "DoH 的 SNI / Host 主机名")
	logPath    = flag.String("log", "", "日志文件路径（留空则只输出到 stderr）")
	noDoH      = flag.Bool("no-doh", false, "禁用 DoH，直接用本机解析")
	directOn   = flag.Bool("direct", true, "国内域名直连（不走隧道）；false 则全部走 WARP")
)

const dnsTTL = 5 * time.Minute

// directSuffixes：命中则直连（不走 WARP）。
// 保守清单 —— 只放明确的国内站点；判定错误只会「该走代理的走了直连」，
// 且直连失败会自动回退隧道，所以宁可少放也不要多放。
// 以 "." 开头的项按纯后缀匹配（覆盖所有 .cn 域名）。
var directSuffixes = []string{
	".cn",
	"baidu.com", "qq.com", "tencent.com", "weixin.qq.com", "taobao.com", "tmall.com",
	"alipay.com", "alicdn.com", "aliyun.com", "dingtalk.com", "aliyuncs.com",
	"jd.com", "jd.hk", "bilibili.com", "hdslb.com", "douyin.com", "kuaishou.com",
	"xiaohongshu.com", "zhihu.com", "douban.com", "weibo.com", "sina.com", "sina.com.cn",
	"163.com", "126.com", "netease.com", "youdao.com", "sohu.com", "iqiyi.com", "youku.com",
	"csdn.net", "cnblogs.com", "oschina.net", "gitee.com", "51cto.com", "jianshu.com",
	"meituan.com", "dianping.com", "ele.me", "pinduoduo.com", "ximalaya.com",
	"mi.com", "xiaomi.com", "huawei.com", "huaweicloud.com", "bytedance.com",
	"wps.cn", "kingsoft.com", "unionpay.com", "cmbchina.com", "icbc.com.cn",
}

type cacheEnt struct {
	ip  string
	exp time.Time
}

// ---------- 访问日志（使用分析用） ----------
//
// 每个经过桥的请求记一行：时间 host:port 路径(direct/warp/direct->warp) 上行 下行 耗时。
// 覆盖面 = 所有指向桥的流量（便携 Chrome + git 经桥转发）；
// 桥内直连白名单的国内流量也记账（标 direct），故能看出分流比例。
// 不覆盖：Edge 直连、未指向桥的其他软件 —— 那是全机口径，需外部监控工具。

// 按天分文件：net-warp-bridge-access-YYYY-MM-DD.log（惰性打开，跨天自动切换），
// 自动删除 N 天前的旧文件 —— 大小可控且保留近期完整历史。

var (
	accessMu  sync.Mutex
	accessF   *os.File
	accessDay string // 当前文件对应日期 2006-01-02
	accessDir string // 日志目录，main 里赋值；空 = 访问日志关闭
)

const accessKeepDays = 30

func accessLogf(format string, args ...any) {
	accessMu.Lock()
	defer accessMu.Unlock()
	if accessDir == "" {
		return
	}
	today := time.Now().Format("2006-01-02")
	if accessF == nil || today != accessDay {
		if accessF != nil {
			accessF.Close()
		}
		f, err := os.OpenFile(accessDir+string(os.PathSeparator)+"net-warp-bridge-access-"+today+".log",
			os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			accessF = nil
			return
		}
		accessF = f
		accessDay = today
		cleanOldAccess()
	}
	fmt.Fprintf(accessF, format+"\n", args...)
}

// cleanOldAccess 删除超过保留期的按天日志文件。
func cleanOldAccess() {
	cutoff := time.Now().AddDate(0, 0, -accessKeepDays)
	ents, err := os.ReadDir(accessDir)
	if err != nil {
		return
	}
	for _, e := range ents {
		name := e.Name()
		if !strings.HasPrefix(name, "net-warp-bridge-access-") || !strings.HasSuffix(name, ".log") {
			continue
		}
		t, err := time.Parse("2006-01-02", strings.TrimSuffix(strings.TrimPrefix(name, "net-warp-bridge-access-"), ".log"))
		if err != nil || !t.Before(cutoff) {
			continue
		}
		_ = os.Remove(accessDir + string(os.PathSeparator) + name)
	}
}

// countConn 包装客户端连接，统计经桥的字节数：
//   - Read  = 客户端→桥→目标 = 上行 up（调用处须以 io.MultiReader(br, cc) 传入，
//     否则 bufio 预读的字节绕过计数）
//   - Write = 目标→桥→客户端 = 下行 down
type countConn struct {
	net.Conn
	up, down int64
}

func (c *countConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.up += int64(n)
	return n, err
}

func (c *countConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.down += int64(n)
	return n, err
}

var (
	cacheMu sync.Mutex
	cache   = map[string]cacheEnt{}
)

func cacheGet(h string) (string, bool) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	e, ok := cache[h]
	if !ok || time.Now().After(e.exp) {
		return "", false
	}
	return e.ip, true
}

func cacheSet(h, ip string, ttl time.Duration) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	cache[h] = cacheEnt{ip: ip, exp: time.Now().Add(ttl)}
}

// ---------- 直连判定 ----------

func isDirectHost(host string) bool {
	h := strings.ToLower(host)
	for _, s := range directSuffixes {
		if strings.HasPrefix(s, ".") {
			if strings.HasSuffix(h, s) {
				return true
			}
			continue
		}
		if h == s || strings.HasSuffix(h, "."+s) {
			return true
		}
	}
	return false
}

// dialUpstream 决定走直连还是 WARP 隧道；直连失败自动回退隧道（可用性优先）。
// 返回路径标签：direct=白名单直连；warp=WARP 隧道；direct->warp=直连失败回退隧道。
func dialUpstream(host string, port int) (net.Conn, string, error) {
	if *directOn && isDirectHost(host) {
		c, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 8*time.Second)
		if err == nil {
			return c, "direct", nil
		}
		log.Printf("DIRECT-FAIL %s:%d: %v (fallback to tunnel)", host, port, err)
		ip, err2 := resolveHost(host)
		if err2 != nil {
			return nil, "direct->fail", err2
		}
		c2, err3 := socks5Connect(ip, port)
		if err3 != nil {
			return nil, "direct->fail", err3
		}
		return c2, "direct->warp", nil
	}
	ip, err := resolveHost(host)
	if err != nil {
		log.Printf("RESOLVE-FAIL %s: %v", host, err)
		return nil, "warp->fail", err
	}
	c, err := socks5Connect(ip, port)
	if err != nil {
		return nil, "warp->fail", err
	}
	return c, "warp", nil
}

// ---------- SOCKS5 客户端（手写握手，免外部依赖） ----------

func socks5Connect(targetHost string, targetPort int) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", *socksAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial socks: %w", err)
	}
	// greeting: VER=5, NMETHODS=1, NOAUTH
	if _, err := c.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		c.Close()
		return nil, err
	}
	rep := make([]byte, 2)
	if _, err := io.ReadFull(c, rep); err != nil {
		c.Close()
		return nil, err
	}
	if rep[0] != 0x05 || rep[1] != 0x00 {
		c.Close()
		return nil, fmt.Errorf("socks5: no acceptable auth method")
	}
	// request
	req := []byte{0x05, 0x01, 0x00}
	if ip := net.ParseIP(targetHost); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			req = append(req, 0x01)
			req = append(req, v4...)
		} else {
			req = append(req, 0x04)
			req = append(req, ip.To16()...)
		}
	} else {
		if len(targetHost) > 255 {
			c.Close()
			return nil, fmt.Errorf("hostname too long")
		}
		req = append(req, 0x03, byte(len(targetHost)))
		req = append(req, []byte(targetHost)...)
	}
	portBuf := make([]byte, 2)
	binary.BigEndian.PutUint16(portBuf, uint16(targetPort))
	req = append(req, portBuf...)
	if _, err := c.Write(req); err != nil {
		c.Close()
		return nil, err
	}
	// reply
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(c, hdr); err != nil {
		c.Close()
		return nil, err
	}
	if hdr[1] != 0x00 {
		c.Close()
		return nil, fmt.Errorf("socks5 connect failed (rep=%d)", hdr[1])
	}
	var skip int
	switch hdr[3] {
	case 0x01:
		skip = 4
	case 0x04:
		skip = 16
	case 0x03:
		l := make([]byte, 1)
		if _, err := io.ReadFull(c, l); err != nil {
			c.Close()
			return nil, err
		}
		skip = int(l[0])
	default:
		c.Close()
		return nil, fmt.Errorf("socks5: bad atyp %d", hdr[3])
	}
	if _, err := io.ReadFull(c, make([]byte, skip+2)); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

// ---------- DoH ----------

var dohHTTP *http.Client

// initDoH 必须在 flag.Parse() 之后调用 ——
// TLSClientConfig.ServerName 需要运行时读取 -doh-host，不能在包级变量初始化时取值。
func initDoH() {
	dohHTTP = &http.Client{
		Timeout: 8 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				h, p, err := net.SplitHostPort(addr)
				if err != nil {
					return nil, err
				}
				port, err := strconv.Atoi(p)
				if err != nil {
					return nil, err
				}
				return socks5Connect(h, port)
			},
			// 真正设置 SNI（此前只设了 HTTP Host 头，靠 Cloudflare 证书的 IP SAN 侥幸通过）
			TLSClientConfig:     &tls.Config{ServerName: *dohHost},
			MaxIdleConns:        4,
			IdleConnTimeout:     90 * time.Second,
			DisableCompression:  true,
			TLSHandshakeTimeout: 8 * time.Second,
		},
	}
}

func dohLookup(host, qtype string) ([]string, error) {
	u := "https://" + *dohServer + "/dns-query?name=" + url.QueryEscape(host) + "&type=" + qtype
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("accept", "application/dns-json")
	req.Host = *dohHost
	resp, err := dohHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	var js struct {
		Status int `json:"Status"`
		Answer []struct {
			Type int    `json:"type"`
			Data string `json:"data"`
		} `json:"Answer"`
	}
	if err := json.Unmarshal(body, &js); err != nil {
		return nil, err
	}
	want := 1
	if qtype == "AAAA" {
		want = 28
	}
	var out []string
	for _, a := range js.Answer {
		if a.Type == want {
			out = append(out, a.Data)
		}
	}
	return out, nil
}

// ---------- 域名解析：DoH 优先，失败退回本机（hosts / 系统 DNS） ----------

func localLookup(host string) (string, error) {
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return "", fmt.Errorf("local lookup failed: %v", err)
	}
	for _, ip := range ips { // 优先 IPv4：绕开伪造 AAAA 的污染
		if v4 := ip.To4(); v4 != nil {
			return v4.String(), nil
		}
	}
	return ips[0].String(), nil
}

func resolveHost(host string) (string, error) {
	if ip := net.ParseIP(host); ip != nil {
		return host, nil
	}
	if ip, ok := cacheGet(host); ok {
		return ip, nil
	}

	if !*noDoH {
		if ips, err := dohLookup(host, "A"); err == nil && len(ips) > 0 {
			cacheSet(host, ips[0], dnsTTL)
			return ips[0], nil
		}
		if ips, err := dohLookup(host, "AAAA"); err == nil && len(ips) > 0 {
			cacheSet(host, ips[0], dnsTTL)
			return ips[0], nil
		}
	}

	ip, err := localLookup(host)
	if err != nil {
		return "", err
	}
	cacheSet(host, ip, dnsTTL)
	return ip, nil
}

// ---------- 代理 ----------

func readHeaders(br *bufio.Reader) ([]string, error) {
	var hs []string
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return hs, err
		}
		t := strings.TrimRight(line, "\r\n")
		if t == "" {
			return hs, nil
		}
		hs = append(hs, t)
	}
}

func fail(conn net.Conn, msg string) {
	fmt.Fprintf(conn, "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s", len(msg), msg)
}

// copyAndHalfClose 单向复制后对「写端」半关闭，让对方知道数据发完了。
func copyAndHalfClose(dst net.Conn, src io.Reader) {
	_, _ = io.Copy(dst, src)
	if cw, ok := dst.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
		return
	}
	_ = dst.Close()
}

// tunnel 双向转发，两个方向都结束后才返回。
// 之前只等一个方向就 return，会在「客户端半关闭、服务端仍在回包」时截断响应。
// upSrc 是已缓冲的 reader —— 直接传原始 conn 会丢掉 bufio 里预读的字节；
// 调用处传 io.MultiReader(br, conn) 保证上行字节计数完整（预读部分也计入）。
func tunnel(local net.Conn, upSrc io.Reader, remote net.Conn) {
	done := make(chan struct{}, 2)
	go func() { copyAndHalfClose(remote, upSrc); done <- struct{}{} }()
	go func() { copyAndHalfClose(local, remote); done <- struct{}{} }()
	<-done
	<-done
}

func handle(conn net.Conn) {
	start := time.Now()
	defer conn.Close()
	// 单个请求出问题不能拖垮整个桥进程
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC handled: %v", r)
		}
	}()
	cc := &countConn{Conn: conn}
	br := bufio.NewReader(cc) // br 底层必须是 cc：上行字节（含预读）才能全部计入

	line, err := br.ReadString('\n')
	if err != nil {
		return
	}
	parts := strings.Fields(strings.TrimSpace(line))
	if len(parts) < 3 {
		fail(conn, "bad request line")
		return
	}
	method, target := parts[0], parts[1]
	headers, err := readHeaders(br)
	if err != nil && len(headers) == 0 {
		return
	}

	if strings.EqualFold(method, "CONNECT") {
		host, portStr, err := net.SplitHostPort(target)
		if err != nil {
			fail(conn, "bad CONNECT target: "+target)
			return
		}
		port, err := strconv.Atoi(portStr)
		if err != nil {
			fail(conn, "bad CONNECT port")
			return
		}
		up, path, err := dialUpstream(host, port)
		if err != nil {
			log.Printf("CONNECT-FAIL %s:%d: %v", host, port, err)
			accessLogf("%s FAIL %s:%d %s %.2fs", time.Now().Format("01-02 15:04:05"), host, port, path, time.Since(start).Seconds())
			fail(conn, "upstream failed")
			return
		}
		defer up.Close()
		if _, err := conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
			return
		}
		tunnel(cc, br, up)
		accessLogf("%s %s:%d %s up=%d down=%d %.2fs", time.Now().Format("01-02 15:04:05"), host, port, path, cc.up, cc.down, time.Since(start).Seconds())
		return
	}

	// 明文 HTTP：把绝对 URI 改写成 path 形式，再隧道转发
	u, err := url.Parse(target)
	if err != nil || u.Host == "" {
		fail(conn, "only CONNECT and absolute-URI HTTP are supported")
		return
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		port = "80"
	}
	pn, err := strconv.Atoi(port)
	if err != nil {
		fail(conn, "bad port")
		return
	}
	up, path, err := dialUpstream(host, pn)
	if err != nil {
		log.Printf("CONNECT-FAIL %s:%s: %v", host, port, err)
		accessLogf("%s FAIL %s:%s %s %.2fs", time.Now().Format("01-02 15:04:05"), host, port, path, time.Since(start).Seconds())
		fail(conn, "upstream failed")
		return
	}
	defer up.Close()

	pathOnly := u.RequestURI()
	var sb strings.Builder
	sb.WriteString(method + " " + pathOnly + " HTTP/1.1\r\n")
	hasHost := false
	for _, h := range headers {
		lh := strings.ToLower(h)
		if strings.HasPrefix(lh, "proxy-connection:") {
			continue
		}
		if strings.HasPrefix(lh, "host:") {
			hasHost = true
		}
		sb.WriteString(h + "\r\n")
	}
	if !hasHost {
		sb.WriteString("Host: " + u.Host + "\r\n")
	}
	sb.WriteString("\r\n")
	if _, err := up.Write([]byte(sb.String())); err != nil {
		return
	}
	tunnel(cc, br, up)
	accessLogf("%s %s:%s %s %s up=%d down=%d %.2fs", time.Now().Format("01-02 15:04:05"), method, host, port, path, cc.up, cc.down, time.Since(start).Seconds())
}

func main() {
	flag.Parse()
	initDoH()

	if *logPath != "" {
		if err := os.MkdirAll(dirOf(*logPath), 0o755); err == nil {
			// 日志轮转：超过 2MB 就清空重开，避免长期常驻把磁盘写满
			if st, err := os.Stat(*logPath); err == nil && st.Size() > 2<<20 {
				_ = os.Remove(*logPath)
			}
			if f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
				log.SetOutput(f)
				defer f.Close()
			}
			// 访问日志与运行日志同目录，按天分文件（accessLogf 惰性打开 + 30 天清理）
			accessDir = dirOf(*logPath)
		}
	}
	log.SetFlags(log.LstdFlags)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		// 端口被占多为「上一次的桥还没退干净」，给一次重试机会
		log.Printf("listen %s failed: %v (retry in 3s)", *listenAddr, err)
		time.Sleep(3 * time.Second)
		ln, err = net.Listen("tcp", *listenAddr)
		if err != nil {
			log.Fatalf("listen %s failed after retry: %v", *listenAddr, err)
		}
	}
	log.Printf("net-warp-bridge listening on %s -> socks5 %s (doh=%s sni=%s, direct=%v, noDoh=%v)",
		*listenAddr, *socksAddr, *dohServer, *dohHost, *directOn, *noDoH)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			return
		}
		go handle(c)
	}
}

func dirOf(p string) string {
	i := strings.LastIndexAny(p, `\/`)
	if i < 0 {
		return "."
	}
	return p[:i]
}
