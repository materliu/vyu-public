#!/usr/bin/env python3
"""Loopback fixture server. Pages intentionally provide no download buttons."""
import argparse
from collections import Counter
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
from pathlib import Path
import re
import threading
import time
from urllib.parse import parse_qs, urlsplit

MEDIA = Path(__file__).resolve().parent / "media"
STATE = {"offline": False}
REQUESTS = Counter()
PLAYBACK_CONTEXT_RUNS = {}
LOCK = threading.Lock()
PEER_PORT = 8766


def page(title, body, script=""):
    return f'''<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title><style>body{{font-family:system-ui;background:#f1f3f5;color:#1d2630;margin:24px}}video,iframe{{width:100%;max-width:720px;min-height:180px;background:#111}}a{{display:block;margin:16px 0}}button{{padding:12px}}p{{line-height:1.6}}</style><h1>{title}</h1>{body}<script>{script}</script></html>'''.encode()


def player(src):
    return f'<video controls controlslist="nodownload" playsinline preload="metadata" src="{src}"></video><p>本页只有播放控件。V语会在视频旁显示下载入口。</p>'


def title_card(identifier, title, src):
    # Neutral synthetic content only. Neither the author row nor the tags/actions
    # should become the video's title; the title intentionally has no heading tag.
    caption = f'<div id="{identifier}-title"><span>{title}</span></div>' if title else ""
    return f'''<article class="video-card" id="{identifier}">
        <header class="card-meta"><span class="avatar" aria-label="作者头像"></span>
            <a rel="author" href="/fixture-author">示例作者</a><time datetime="2026-01-01">7 小时前</time>
            <a href="/fixture-tools">站点下载入口</a></header>
        {caption}
        <div class="tags"><a rel="tag" href="/fixture-tag">#自然</a><a href="/fixture-source">来源链接</a></div>
        <div class="player-shell"><video controls playsinline preload="metadata" src="{src}"></video></div>
        <footer class="engagement"><button>赞 30</button><button>评论 0</button><button>分享给朋友</button></footer>
        </article>'''


def title_cards_page(title, cards, script=""):
    return page(title, '''<style>
        body{margin:12px}h1{font-size:18px}.video-card{border:1px solid #ccc;margin:12px 0;padding:10px}
        .card-meta,.tags,.engagement{font-size:12px}.card-meta a,.tags a{display:inline;margin-right:8px}
        .video-card video{height:120px;min-height:120px;max-width:100%}.engagement button{padding:4px 10px}
        .avatar{display:inline-block;width:14px;height:14px;background:#ddd;border-radius:50%}
        </style>''' + cards, script)


def popup_page(method="GET", marker_received=False):
    # Only a fixed, synthetic marker is acknowledged; never reflect request data.
    marker = "fixture-marker" if marker_received else "fixture-get"
    return page("登录弹窗测试", f'''<p id="popup-method">请求方法：{method}</p>
        <p id="popup-marker">{"合成表单已收到" if marker_received else "独立窗口已打开"}</p>
        <button id="popup-complete" onclick="finishFixture()">完成合成登录</button>''', f'''
        document.body.dataset.requestMethod = {json.dumps(method)};
        document.body.dataset.postMarker = {json.dumps(marker)};
        document.body.dataset.openerAvailable = String(window.opener !== null);
        function finishFixture() {{
            if (window.opener) window.opener.postMessage({{type:"vyu-popup-fixture", marker:{json.dumps(marker)}}}, location.origin);
            window.close();
        }}''')


def html_for(path):
    if path == "/cover-timeline":
        return page("封面选帧 · 黑红绿蓝", player("/media/cover-timeline.mp4"))
    if path == "/batch":
        return page("批量下载测试", '<p>本页只用于隔离资料中的合成任务回归。</p>')
    direct = {"/background-hls": ("后台 HLS · 独立音轨", "/background-hls-media/master.m3u8"), "/direct": ("直接视频 · 8 秒有声", "/media/direct.mp4"), "/hls": ("HLS · 两档画质", "/media/hls/master.m3u8"), "/hls-separate": ("HLS · 独立音轨", "/media/hls-separate/master.m3u8"), "/expired": ("已过期的链接", "/expired.mp4?expires=1"), "/forbidden": ("服务器拒绝访问", "/forbidden.mp4"), "/head-denied": ("只拒绝 HEAD 请求", "/head-denied.mp4"), "/context-frame": ("需要播放器请求上下文", "/context-required.mp4"), "/silent": ("无音轨视频 · 8 秒", "/media/silent.mp4"), "/corrupt": ("损坏的视频", "/media/corrupt.mp4"), "/slow": ("慢速传输 · 可测试取消与恢复", "/slow.mp4"), "/protected": ("受保护标记 · 仅识别测试", "/media/protected/index.m3u8")}
    if path in direct:
        title, src = direct[path]
        return page(title, player(src))
    if path == "/head-unsupported":
        return page("HEAD 不受支持，GET 被拒绝", player("/head-unsupported.mp4"))
    if path == "/browser-session":
        return page("网页会话重试 · 合成兼容性测试", player("/browser-session.mp4"))
    if path == "/video-card-titles":
        return title_cards_page("中性视频合集", title_card("card-one", "晨光中的山间步道", "/media/direct.mp4?card=one")
                                + title_card("card-two", "雨后花园里的小路", "/media/direct.mp4?card=two"))
    if path == "/video-card-title-inner":
        return title_cards_page("内嵌页面的通用标题", title_card("frame-card", "窗边的盆栽观察", "/media/direct.mp4?card=frame"))
    if path == "/video-card-title-frame":
        return page("外层页面标题不应被保存", '<iframe src="/video-card-title-inner" title="合成视频卡片"></iframe>')
    if path == "/video-card-title-hls":
        return title_cards_page("分段视频合集", title_card("hls-card", "湖畔黄昏的风景", "/hls-denied/master.m3u8"),
                                'fetch("/hls-alternatives.json").then(response=>response.json());')
    if path == "/hls-alternatives":
        return page("HLS 被拒绝，同一视频有 MP4 备选", player("/hls-denied/master.m3u8"), 'fetch("/hls-alternatives.json").then(response=>response.json()).then(()=>document.body.dataset.variantsReady="true");')
    if path == "/hls-partial":
        return page("HLS 部分画质不可用", player("/hls-partial/master.m3u8"))
    if path == "/popup-parent":
        return page("弹窗通信测试", '''
            <p id="popup-result">等待弹窗返回</p>
            <button id="popup-get" onclick="window.open('/popup-child','fixtureGet')">打开 GET 弹窗</button>
            <button id="popup-blank" onclick="openBlankPopup()">打开空白后跳转</button>
            <form method="POST" action="/popup-post" target="fixturePost">
                <input type="hidden" name="marker" value="fixture-marker">
                <button id="popup-post-submit" type="submit">提交 POST 弹窗</button>
            </form>''' + player("/media/direct.mp4"), '''
            document.body.dataset.parentState = "preserved";
            function openBlankPopup() {
                const popup = window.open('about:blank', 'fixtureBlank');
                if (popup) setTimeout(() => popup.location.href = '/popup-child', 120);
            }
            window.addEventListener('message', event => {
                if (event.origin !== location.origin || event.data?.type !== 'vyu-popup-fixture') return;
                const marker = event.data.marker;
                if (marker !== 'fixture-marker' && marker !== 'fixture-get') return;
                document.body.dataset.popupResult = marker;
                document.getElementById('popup-result').textContent = '弹窗返回：' + marker;
            });''')
    if path == "/popup-child":
        return popup_page()
    if path == "/":
        links = [("direct", "直接 MP4"), ("iframe", "同源 iframe"), ("cross-frame", "跨源 iframe"), ("dynamic", "动态插入 video"), ("multiple-videos", "分别选择两个视频"), ("head-denied", "HEAD 被拒绝、GET 正常"), ("context-required", "播放器请求上下文"), ("hls", "HLS 两档画质"), ("hls-separate", "HLS 独立音轨"), ("hls-alternatives", "HLS 被拒绝时的同视频 MP4 备选"), ("hls-partial", "HLS 部分画质不可用"), ("blob", "Blob 播放"), ("mse", "MediaSource 播放"), ("dash", "DASH 清单"), ("expired", "过期链接"), ("forbidden", "HTTP 403"), ("silent", "无音轨"), ("corrupt", "坏文件"), ("slow", "慢速下载"), ("protected", "FairPlay 标记")]
        return page("V语受控测试页", "<p>媒体由 FFmpeg 本地合成，每段 8 秒。页面没有下载按钮。</p>" + "".join(f'<a href="/{slug}">{title}</a>' for slug, title in links))
    if path == "/iframe":
        return page("同源 iframe", '<iframe src="/direct" title="视频帧"></iframe>')
    if path == "/context-required":
        return page("播放器请求上下文", '<iframe src="/context-frame" title="需要请求上下文的视频帧"></iframe>')
    if path == "/multiple-videos":
        return page("分别选择两个视频", '<h2>第一个：不可用视频</h2><video id="first-video" controls controlslist="nodownload" playsinline preload="metadata" src="/forbidden.mp4"></video><h2>第二个：可下载视频</h2><video id="second-video" controls controlslist="nodownload" playsinline preload="metadata" src="/media/direct.mp4?second=1"></video>')
    if path == "/clipped-video":
        return page("固定高度播放器", '<div class="player" style="position:relative;height:180px;overflow:hidden"><video controls controlslist="nodownload" playsinline preload="metadata" src="/media/direct.mp4" style="position:absolute;inset:0;width:100%;height:100%"></video></div>')
    if path == "/cross-frame":
        return page("跨源 iframe", f'<iframe id="frame" title="跨源视频帧"></iframe>', f'document.querySelector("iframe").src=location.protocol+"//"+location.hostname+":{PEER_PORT}/direct";')
    if path == "/dynamic":
        return page("动态插入 video", '<p id="status">1 秒后插入播放器。</p><div id="host"></div>', 'setTimeout(()=>{const v=document.createElement("video");v.controls=true;v.playsInline=true;v.setAttribute("controlslist","nodownload");const s=document.createElement("source");s.src="/media/direct.mp4?dynamic=1";s.type="video/mp4";v.append(s);document.querySelector("#host").append(v);document.querySelector("#status").textContent="播放器已插入。";},1000);')
    if path == "/blob":
        return page("Blob 播放 · 追踪源请求", '<video controls controlslist="nodownload" playsinline></video><p id="status">正在读取源视频。</p>', 'fetch("/media/blob-source.json").then(r=>r.json()).then(m=>fetch(m.url)).then(r=>r.blob()).then(b=>{document.querySelector("video").src=URL.createObjectURL(b);document.querySelector("#status").textContent="播放器使用 blob URL，原始 MP4 已通过 fetch 读取。";}).catch(e=>document.querySelector("#status").textContent=e.message);')
    if path == "/mse":
        return page("MediaSource 播放", '<video controls controlslist="nodownload" playsinline></video><p id="status">正在读取分片 MP4。</p>', 'const v=document.querySelector("video");v.disableRemotePlayback=true;const MS=window.ManagedMediaSource||window.MediaSource;async function start(){if(!MS)throw Error("此浏览器没有 MediaSource API");const m=await (await fetch("/media/mse-source.json")).json();if(!MS.isTypeSupported(m.mime))throw Error("不支持测试编码 "+m.mime);const source=new MS();v.src=URL.createObjectURL(source);source.addEventListener("sourceopen",async()=>{try{const buffer=source.addSourceBuffer(m.mime);const bytes=await(await fetch(m.url)).arrayBuffer();buffer.addEventListener("updateend",()=>{if(source.readyState==="open")source.endOfStream();document.querySelector("#status").textContent="分片已加入 SourceBuffer。";},{once:true});buffer.appendBuffer(bytes);}catch(e){document.querySelector("#status").textContent=e.message;}},{once:true});}start().catch(e=>document.querySelector("#status").textContent=e.message);')
    if path == "/dash":
        return page("DASH 音画分离清单", '<p id="status">正在通过 XHR 读取 MPD。此页不包含 DASH 播放器。</p>', 'const x=new XMLHttpRequest();x.open("GET","/media/dash/manifest.mpd");x.onload=()=>document.querySelector("#status").textContent="MPD 已读取（"+x.status+"）。客户端应报告支持边界，不能把 MPD 文本标为离线视频。";x.send();')
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Log only the method, path and status: no query values, headers or cookies.
        print(f"{self.command} {urlsplit(self.path).path} {args[1] if len(args)>1 else ''}", flush=True)

    def send_response_headers(self, status, size, content_type, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()

    def body(self, status, data, content_type="application/json; charset=utf-8", extra=None):
        try:
            self.send_response_headers(status, len(data), content_type, extra)
            if self.command != "HEAD":
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            # Stop/timeout tests intentionally disconnect before delayed replies.
            self.close_connection = True

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        if urlsplit(self.path).path == "/__playback-context":
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 512:
                    raise ValueError()
                value = json.loads(self.rfile.read(size))
                if set(value) != {"run", "phase"} or value["phase"] not in ("playback", "legacy-inspection", "inspection", "asset-download", "offline-check"):
                    raise ValueError()
                with LOCK:
                    run = PLAYBACK_CONTEXT_RUNS.get(value["run"])
                    if run is None:
                        raise ValueError()
                    run["phase"] = value["phase"]
                return self.body(200, b'{"ok":true}')
            except (TypeError, ValueError, json.JSONDecodeError):
                return self.body(400, b'{"error":"invalid playback-context control"}')
        if urlsplit(self.path).path == "/popup-post":
            with LOCK:
                REQUESTS["POST /popup-post"] += 1
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 1024:
                    raise ValueError("invalid synthetic form body size")
                form = parse_qs(self.rfile.read(size).decode("utf-8"), strict_parsing=True)
                if form != {"marker": ["fixture-marker"]}:
                    raise ValueError("synthetic marker missing")
                return self.body(200, popup_page("POST", marker_received=True), "text/html; charset=utf-8")
            except (ValueError, UnicodeDecodeError):
                return self.body(400, b'{"error":"invalid synthetic popup form"}')
        if urlsplit(self.path).path != "/__control":
            return self.body(404, b'{"error":"unknown endpoint"}')
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 1024:
                raise ValueError("control body must contain 1 to 1024 bytes")
            value = json.loads(self.rfile.read(size))
            if not isinstance(value, dict) or type(value.get("offline")) is not bool:
                raise ValueError("offline must be boolean")
            with LOCK:
                STATE["offline"] = value["offline"]
            self.body(200, json.dumps(STATE).encode())
        except (ValueError, json.JSONDecodeError) as error:
            self.body(400, json.dumps({"error": str(error)}).encode())

    def do_GET(self):
        path = urlsplit(self.path).path
        with LOCK:
            REQUESTS[f"{self.command} {path}"] += 1
            offline = STATE["offline"]
        if path == "/__health":
            return self.body(200, json.dumps({"ready": (MEDIA / "direct.mp4").exists(), "offline": offline}).encode())
        if path == "/__stats":
            with LOCK:
                stats = dict(REQUESTS)
            return self.body(200, json.dumps(stats).encode())
        if path.startswith(("/background-hls-media/", "/background-hls-session-media/")):
            if offline:
                return self.body(503, b'{"error":"fixture media offline"}')
            session_required = path.startswith("/background-hls-session-media/")
            prefix = "/background-hls-session-media/" if session_required else "/background-hls-media/"
            relative = path.removeprefix(prefix)
            if session_required and relative.endswith(".m4s") and not self.headers.get("Referer"):
                return self.body(403, b"<html>synthetic session required</html>", "text/html")
            candidate = (MEDIA / "hls-fmp4-separate" / relative).resolve()
            if not candidate.is_relative_to((MEDIA / "hls-fmp4-separate").resolve()) or not candidate.is_file():
                return self.body(404, b'{}')
            if candidate.suffix == ".m3u8":
                text = candidate.read_text().replace("/media/hls-fmp4-separate/", prefix)
                return self.body(200, text.encode(), "application/vnd.apple.mpegurl")
            if candidate.suffix == ".m4s" and not session_required:
                time.sleep(8)  # All resources are queued before the app leaves foreground.
            return self.file(candidate, False)
        if path.startswith("/hls-relay-wire/"):
            if offline:
                return self.body(503, b'{"error":"fixture media offline"}')
            return self.relay_wire(path)
        if path == "/playback-context":
            query = parse_qs(urlsplit(self.path).query)
            run_id = query.get("run", [""])[0]
            mode = query.get("mode", ["same"])[0]
            enforce = query.get("enforce", ["0"])[0]
            if (not re.fullmatch(r"[0-9a-fA-F-]{36}", run_id)
                    or mode not in ("same", "cross", "cross-anonymous", "no-referrer") or enforce not in ("0", "1")):
                return self.body(400, b'{"error":"invalid synthetic playback-context input"}')
            frame_origin = f'http://{self.headers.get("Host", "127.0.0.1:8765")}'
            # Only the local fixture's known ports and generated run ID enter media URLs.
            media_origin = frame_origin if mode in ("same", "no-referrer") else f"http://127.0.0.1:{PEER_PORT}"
            with LOCK:
                if len(PLAYBACK_CONTEXT_RUNS) >= 64:
                    del PLAYBACK_CONTEXT_RUNS[next(iter(PLAYBACK_CONTEXT_RUNS))]
                PLAYBACK_CONTEXT_RUNS[run_id] = {
                    "phase": "playback", "frameOrigin": frame_origin, "events": [],
                    "mode": mode, "enforce": enforce == "1",
                }
            cross_origin = ' crossorigin="anonymous"' if mode == "cross-anonymous" else ""
            referrer_meta = '<meta name="referrer" content="no-referrer">' if mode == "no-referrer" else ""
            body = referrer_meta + f'<video id="context-video" controls playsinline muted preload="metadata"{cross_origin} src="{media_origin}/playback-context-media/{run_id}/master.m3u8"></video>'
            headers = {"Referrer-Policy": "no-referrer"} if mode == "no-referrer" else None
            return self.body(200, page("HLS 播放与下载请求对照", body), "text/html; charset=utf-8", headers)
        if path == "/__playback-context":
            run_id = parse_qs(urlsplit(self.path).query).get("run", [""])[0]
            with LOCK:
                run = PLAYBACK_CONTEXT_RUNS.get(run_id)
                events = list(run["events"]) if run else []
            # No raw URL, header value, Cookie, or credential leaves this endpoint.
            return self.body(200, json.dumps({"events": events}).encode())
        if path.startswith("/playback-context-media/"):
            parts = path.split("/", 3)
            run_id, relative = (parts[2], parts[3]) if len(parts) == 4 else ("", "")
            candidate = (MEDIA / "hls" / relative).resolve()
            if not candidate.is_relative_to((MEDIA / "hls").resolve()) or not candidate.is_file():
                return self.body(404, b'{"error":"synthetic HLS resource missing"}')
            # Reduce synthetic traffic to fixed labels immediately; never retain raw headers.
            ua = self.headers.get("User-Agent", "")
            referer = urlsplit(self.headers.get("Referer", ""))
            origin_value = self.headers.get("Origin", "")
            with LOCK:
                run = PLAYBACK_CONTEXT_RUNS.get(run_id)
                if run is None:
                    return self.body(404, b'{"error":"synthetic playback run missing"}')
                frame_origin = urlsplit(run["frameOrigin"])
                referer_matches = (referer.scheme, referer.netloc) == (frame_origin.scheme, frame_origin.netloc)
                referer_mode = ("none" if not referer.netloc else "framePath" if referer_matches and referer.path == "/playback-context"
                                else "origin" if referer_matches and referer.path in ("", "/") else "other")
                event = {
                    "phase": run["phase"], "method": self.command,
                    "resource": "master" if relative == "master.m3u8" else "playlist" if candidate.suffix == ".m3u8" else "segment",
                    "uaClass": "AppleCoreMedia" if "AppleCoreMedia/" in ua else "WebKit" if "AppleWebKit/" in ua else "other",
                    "refererMode": referer_mode, "originPresent": bool(origin_value),
                    "originMatchesFrame": origin_value == run["frameOrigin"],
                    "rangePresent": bool(self.headers.get("Range")), "cookiePresent": bool(self.headers.get("Cookie")),
                }
                if len(run["events"]) < 256:
                    run["events"].append(event)
                expected_referrer = ("none" if run["mode"] == "no-referrer" else
                                     "framePath" if run["mode"] == "same" else "origin")
                expected_origin = run["mode"] == "cross-anonymous"
                context_matches = (
                    event["uaClass"] == "WebKit" and event["refererMode"] == expected_referrer
                    and event["originPresent"] == expected_origin
                    and (not expected_origin or event["originMatchesFrame"])
                    and not event["cookiePresent"]
                )
                denied = run["enforce"] and not context_matches
            if offline:
                return self.body(503, b'{"error":"fixture media offline"}')
            if denied:
                return self.body(403, b'{"error":"synthetic player request context required"}')
            return self.file(candidate, False)
        if path == "/history-delayed":
            # Leave a deterministic window between navigation start and commit.
            time.sleep(0.8)
            return self.body(200, page("延迟提交的访问记录", "<p>用于验证清理后迟到的导航不会恢复历史。</p>"), "text/html; charset=utf-8")
        if path in ("/navigation-redirect", "/navigation-redirect-final"):
            destination = "/navigation-redirect-final" if path == "/navigation-redirect" else "/direct"
            return self.body(302, b"", "text/plain; charset=utf-8", {"Location": destination})
        if path == "/navigation-delayed":
            time.sleep(3)
            return self.body(200, page("延迟打开的网页", '<p id="navigation-delayed-ready">导航响应已到达。</p>'), "text/html; charset=utf-8")
        if path == "/navigation-slow-resources":
            return self.body(200, page("网页已显示，图片仍在加载", '<p id="navigation-ready">网页内容已到达。</p><img src="/navigation-slow-image" width="16" height="16" alt="延迟图片">'), "text/html; charset=utf-8")
        if path == "/navigation-slow-image":
            time.sleep(3)
            image = b'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="green"/></svg>'
            return self.body(200, image, "image/svg+xml")
        if path == "/hls-alternatives.json":
            # Both groups are already delivered to the page. Only the group whose
            # HLS URL matches the selected player may supply its MP4 alternative.
            origin = f'http://{self.headers.get("Host", "127.0.0.1:8765")}'
            groups = [
                {"type": "video", "video_info": {"variants": [
                    {"content_type": "application/x-mpegURL", "url": origin + "/hls-denied/master.m3u8"},
                    {"content_type": "video/mp4", "bitrate": 1000000, "url": origin + "/media/direct.mp4?matched=1"}]}},
                {"type": "video", "video_info": {"variants": [
                    {"content_type": "application/x-mpegURL", "url": origin + "/hls-denied/unrelated.m3u8"},
                    {"content_type": "video/mp4", "bitrate": 2000000, "url": origin + "/forbidden.mp4?unrelated=1"}]}}
            ]
            return self.body(200, json.dumps({"data": {"media": groups}}).encode())
        if path.startswith("/hls-denied/") or path.startswith("/hls-partial/"):
            if offline:
                return self.body(503, b'{"error":"fixture media offline"}')
            if path.startswith("/hls-denied/") or path == "/hls-partial/denied.m3u8":
                return self.body(403, b'{"error":"fixture playlist denied"}')
            if path == "/hls-partial/master.m3u8":
                origin = f'http://{self.headers.get("Host", "127.0.0.1:8765")}'
                manifest = ("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-INDEPENDENT-SEGMENTS\n"
                            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401e,mp4a.40.2"\n'
                            + origin + "/hls-partial/denied.m3u8\n"
                            '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"\n'
                            + origin + "/media/hls/360p/index.m3u8\n")
                return self.body(200, manifest.encode(), "application/vnd.apple.mpegurl")
            return self.body(404, b'{"error":"fixture playlist not found"}')
        if path.startswith("/media/") or path.endswith(".mp4"):
            if offline:
                return self.body(503, b'{"error":"fixture media offline"}')
            if path in ("/media/hls-failures/main-denied.m3u8", "/media/hls-failures/denied.m3u8"):
                return self.body(403, b'{"error":"fixture HLS request denied"}')
            if path in ("/media/hls-failures/partial.m3u8", "/media/hls-failures/all-denied.m3u8"):
                # One rendition can be unavailable while another complete rendition is public.
                good = "/media/hls/180p/index.m3u8" if path.endswith("partial.m3u8") else "/media/hls-failures/denied.m3u8?second=1"
                manifest = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360\n/media/hls-failures/denied.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180\n' + good + '\n'
                return self.body(200, manifest.encode(), "application/vnd.apple.mpegurl")
            if path == "/media/hls-failures/audio-denied.m3u8":
                manifest = (MEDIA / "hls-separate/master.m3u8").read_text()
                manifest = manifest.replace('URI="audio/index.m3u8"', 'URI="/media/hls-failures/denied.m3u8"')
                manifest = manifest.replace("360p/index.m3u8", "/media/hls-separate/360p/index.m3u8").replace("180p/index.m3u8", "/media/hls-separate/180p/index.m3u8")
                return self.body(200, manifest.encode(), "application/vnd.apple.mpegurl")
            if path == "/forbidden.mp4":
                return self.body(403, b'{"error":"fixture access denied"}')
            if path == "/head-unsupported.mp4":
                return self.body(405 if self.command == "HEAD" else 403, b'{"error":"fixture video unavailable"}')
            if path == "/browser-session.mp4":
                # Synthetic compatibility case for the explicit WebKit retry UI.
                # It models different probe/playback responses, not a real site.
                if self.command == "HEAD" or self.headers.get("Range") == "bytes=0-0":
                    return self.body(403, b'{"error":"fixture probe rejected"}')
                path = "/media/direct.mp4"
            if path == "/head-denied.mp4":
                if self.command == "HEAD":
                    return self.body(403, b'{"error":"fixture accepts GET only"}')
                path = "/media/direct.mp4"
            if path == "/context-required.mp4":
                # This fixture requires the same context as its own WebKit player.
                # Never report the actual request headers or Cookie in a failure.
                referer = urlsplit(self.headers.get("Referer", ""))
                expected = urlsplit(f'http://{self.headers.get("Host", "")}/context-frame')
                same_frame = (referer.scheme, referer.netloc, referer.path) == (expected.scheme, expected.netloc, expected.path)
                webkit = "AppleWebKit/" in self.headers.get("User-Agent", "")
                session = "vyu_fixture_session=ready" in [part.strip() for part in self.headers.get("Cookie", "").split(";")]
                if not (same_frame and webkit and session):
                    return self.body(403, b'{"error":"fixture player context required"}')
                path = "/media/direct.mp4"
            if path == "/expired.mp4":
                query = parse_qs(urlsplit(self.path).query)
                try:
                    expired = int(query.get("expires", ["0"])[0]) < int(time.time())
                except ValueError:
                    expired = True
                if expired:
                    return self.body(410, b'{"error":"fixture signed URL expired"}')
                path = "/media/direct.mp4"
            slow = path in ("/slow.mp4", "/batch-slow.mp4")
            relative = "direct.mp4" if slow else path.removeprefix("/media/")
            candidate = (MEDIA / relative).resolve()
            if not candidate.is_relative_to(MEDIA.resolve()) or not candidate.is_file():
                return self.body(404, b'{"error":"media not found"}')
            return self.file(candidate, slow, slow_delay=2.0 if path == "/batch-slow.mp4" else 0.15)
        html = html_for(path)
        if html is None:
            return self.body(404, b'{"error":"page not found"}')
        extra = {"Set-Cookie": "vyu_fixture_session=ready; Path=/; HttpOnly; SameSite=Lax"} if path == "/context-frame" else None
        self.body(200, html, "text/html; charset=utf-8", extra=extra)

    def relay_wire(self, path):
        # Fixed binary payloads exercise HTTP transport integrity, not decoding.
        parts = path.split("/")
        modes = ("complete", "truncated", "close-delimited", "range", "range-wrong",
                 "range-short", "range-long", "range-length-mismatch", "range-ignored", "redirect")
        if len(parts) != 4 or parts[2] not in modes or parts[3] not in ("index.m3u8", "segment.bin"):
            return self.body(404, b'{"error":"synthetic relay resource missing"}')
        mode, name = parts[2:]
        if name == "index.m3u8":
            manifest = b"#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:8,\nsegment.bin\n#EXT-X-ENDLIST\n"
            return self.body(200, manifest, "application/vnd.apple.mpegurl")
        if mode == "redirect":
            return self.body(302, b"", "application/octet-stream", {"Location": "/hls-relay-wire/complete/segment.bin"})
        payload = bytes(range(256)) * 512
        status, content_range = 200, None
        if mode.startswith("range") and mode != "range-ignored":
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
            if not match or not (match[1] or match[2]):
                return self.body(416, b"", extra={"Content-Range": f"bytes */{len(payload)}"})
            start = int(match[1]) if match[1] else max(0, len(payload) - int(match[2]))
            end = min(int(match[2]) if match[1] and match[2] else len(payload) - 1, len(payload) - 1)
            if start > end or start >= len(payload):
                return self.body(416, b"", extra={"Content-Range": f"bytes */{len(payload)}"})
            if mode == "range-wrong":
                start, end = 0, end - start
            status, content_range = 206, f"bytes {start}-{end}/{len(payload)}"
            payload = payload[start:end + 1]
            if mode == "range-short":
                payload = payload[:len(payload) // 2]
            elif mode == "range-long":
                payload += b"x"
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        if content_range:
            self.send_header("Content-Range", content_range)
        if mode == "range-length-mismatch":
            self.send_header("Content-Length", str(len(payload) + 1))
        elif mode != "close-delimited":
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.close_connection = True
        if self.command == "HEAD":
            return
        try:
            if mode in ("close-delimited", "range-length-mismatch"):
                self.wfile.write(payload)
            else:
                for offset in range(0, len(payload), 32768):
                    chunk = payload[offset:offset + 32768]
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                # This case simulates an upstream connection lost before its
                # declared chunk has arrived, after complete chunks were sent.
                self.wfile.write(b"1000\r\npartial" if mode == "truncated" else b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def file(self, path, slow, slow_delay=0.15):
        size = path.stat().st_size
        start, end, status = 0, size - 1, 200
        etag = f'"vyu-{size}-{int(path.stat().st_mtime)}"'
        range_value = self.headers.get("Range")
        if_range = self.headers.get("If-Range")
        last_modified = formatdate(path.stat().st_mtime, usegmt=True)
        if range_value and (not if_range or if_range in (etag, last_modified)):
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_value)
            if not match or not (match[1] or match[2]):
                return self.body(416, b"", extra={"Content-Range": f"bytes */{size}"})
            if not match[1]:
                length = int(match[2])
                start = max(0, size - length)
            else:
                start = int(match[1])
                end = min(int(match[2]) if match[2] else size - 1, size - 1)
            if start > end or start >= size:
                return self.body(416, b"", extra={"Content-Range": f"bytes */{size}"})
            status = 206
        mime = {".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".mpd": "application/dash+xml", ".m4s": "video/iso.segment"}.get(path.suffix, mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        if "hls-fmp4-separate" in path.parts and path.suffix == ".m4s":
            mime = "video/mp4"  # Matches the public Twitter fMP4 segment responses.
        extra = {"Accept-Ranges": "bytes", "ETag": etag, "Last-Modified": last_modified}
        if status == 206:
            extra["Content-Range"] = f"bytes {start}-{end}/{size}"
        self.send_response_headers(status, end - start + 1, mime, extra)
        if self.command == "HEAD":
            return
        try:
            with path.open("rb") as stream:
                stream.seek(start)
                remaining = end - start + 1
                while remaining:
                    with LOCK:
                        offline = STATE["offline"]
                    if offline:
                        self.close_connection = True
                        return
                    data = stream.read(min(16 * 1024, remaining))
                    if not data:
                        return
                    self.wfile.write(data)
                    self.wfile.flush()
                    remaining -= len(data)
                    if slow:
                        time.sleep(slow_delay)
        except (BrokenPipeError, ConnectionResetError):
            pass

def main():
    global PEER_PORT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--peer-port", type=int, default=8766)
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()
    PEER_PORT = args.peer_port
    if not (MEDIA / "direct.mp4").exists():
        raise SystemExit("Run python3 scripts/fixture_generate.py first.")
    main_server = ThreadingHTTPServer((args.bind, args.port), Handler)
    peer_server = ThreadingHTTPServer((args.bind, args.peer_port), Handler)
    threading.Thread(target=peer_server.serve_forever, daemon=True).start()
    print(f"VYu fixtures: http://{args.bind}:{args.port} (iframe peer {args.peer_port})", flush=True)
    try:
        main_server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        peer_server.shutdown()
        peer_server.server_close()
        main_server.server_close()


if __name__ == "__main__":
    main()
