import XCTest
import AVFoundation
import Combine
import WebKit
@testable import VYu

/// These integration tests use only locally generated media. See fixtures/README.md.
@MainActor final class LiveWebDownloadTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?

    override func setUp() async throws {
        continueAfterFailure = false
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"; request.httpBody = Data("{\"offline\":false}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start fixtures/server.py before running live integration tests") }
    }

    override func tearDown() async throws {
        await setOffline(false)
        window?.isHidden = true; window = nil
    }

    func testNoDownloadButtonToOfflinePlayback() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("direct").absoluteString)
        try await waitUntil("direct video recognized") { !browser.candidates.isEmpty }
        let candidate = try XCTUnwrap(browser.candidates.first { $0.kind == .file })
        XCTAssertEqual(candidate.url.lastPathComponent, "direct.mp4")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-test-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: root)
        let inspection = await manager.inspect(candidate: candidate, cookies: [])
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        await manager.start(candidate: candidate, cookies: [])
        try await waitUntil("download and file validation", timeout: 60) {
            manager.records.first?.phase == .complete || manager.records.first?.phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.2)
        XCTAssertEqual(record.hasAudio, true)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertTrue(local.isFileURL)
        await setOffline(true)
        // The origin refuses every media request; the player receives a file URL only.
        let (_, response) = try await URLSession.shared.data(from: candidate.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let asset = AVURLAsset(url: local)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset)); player.play()
        try await waitUntil("local playback clock advances without origin", timeout: 15) { player.currentTime().seconds > 1.5 }
        player.pause()
        XCTAssertNotEqual(player.currentItem?.status, .failed)
        manager.removeCache(id: record.id)
        XCTAssertNil(manager.localURL(for: manager.records[0]))
        XCTAssertEqual(manager.records.count, 1)
    }

    func testIframesDynamicAndBlobManifestDiscovery() async throws {
        let browser = mountBrowser()
        for route in ["iframe", "cross-frame", "dynamic"] {
            browser.open(base.appendingPathComponent(route).absoluteString)
            try await waitUntil("\(route) committed") { browser.url?.path == "/" + route }
            try await waitUntil("\(route) discovers media") { browser.candidates.contains { $0.kind == .file } }
            XCTAssertTrue(browser.candidates.allSatisfy { $0.pageURL.path == "/" + route })
        }
        browser.open(base.appendingPathComponent("blob").absoluteString)
        try await waitUntil("blob network source discovered") { browser.url?.path == "/blob" && browser.candidates.contains { $0.kind == .file } }
        XCTAssertFalse(browser.candidates.contains { $0.url.scheme == "blob" })
    }

    func testVideoTitlesUseExplicitLabelsAndLocalCaptionsWithoutCrossingVideos() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("title fixture committed") { browser.hasCurrentDocument && !browser.isLoading }
        _ = try await browser.webView.callAsyncJavaScript("""
            document.title = '通用网页标题';
            document.body.innerHTML = html;
            window.__vyuRescan(); return true;
            """, arguments: ["html": """
            <figure><h2 id="label-one">关联标签</h2><video preload="none" title="明确的视频标题" aria-labelledby="label-one" aria-label="通用播放器" src="/media/direct.mp4?title=explicit"></video><figcaption>第一段说明</figcaption></figure>
            <figure><h2 id="label-two">标签中的第二个视频</h2><video preload="none" aria-labelledby="label-two" aria-label="通用播放器" src="/media/direct.mp4?title=labelled"></video><figcaption>第二段说明</figcaption></figure>
            <figure><video preload="none" aria-label="第三个视频的名称" src="/media/direct.mp4?title=aria"></video><figcaption>第三段说明</figcaption></figure>
            <figure><video preload="none" aria-label="Embedded video" src="/media/direct.mp4?title=caption"></video><figcaption>晚霞下的海边散步</figcaption></figure>
            <article><h2>另一篇文章里的做饭视频</h2><div><video preload="none"><source src="/media/direct.mp4?title=heading" type="video/mp4"></video></div></article>
            <section><video preload="none" src="/media/direct.mp4?title=unlabelled"></video><h3>只属于后一个视频</h3><video preload="none" src="/media/direct.mp4?title=second"></video></section>
            <article><p>\(String(repeating: "这是一段很长的页面正文。", count: 50))</p><video preload="none" src="/media/direct.mp4?title=body"></video></article>
            """], in: nil, contentWorld: .page)
        try await waitUntil("all titled videos discovered") { browser.candidates.filter { $0.url.query?.hasPrefix("title=") == true }.count == 8 }
        let titles = Dictionary(uniqueKeysWithValues: browser.candidates.compactMap { candidate -> (String, String)? in
            guard let query = candidate.url.query, query.hasPrefix("title=") else { return nil }
            return (query, candidate.title)
        })
        XCTAssertEqual(titles["title=explicit"], "明确的视频标题")
        XCTAssertEqual(titles["title=labelled"], "标签中的第二个视频")
        XCTAssertEqual(titles["title=aria"], "第三个视频的名称")
        XCTAssertEqual(titles["title=caption"], "晚霞下的海边散步")
        XCTAssertEqual(titles["title=heading"], "另一篇文章里的做饭视频")
        XCTAssertEqual(titles["title=unlabelled"], "通用网页标题")
        XCTAssertEqual(titles["title=second"], "只属于后一个视频")
        XCTAssertEqual(titles["title=body"], "通用网页标题")
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('label-two').textContent = '更新后的视频名称'; true")
        try await waitUntil("dynamic label updates its candidate") {
            browser.candidates.first { $0.url.query == "title=labelled" }?.title == "更新后的视频名称"
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "title=explicit" }?.title, "明确的视频标题")
    }

    func testGenericPlayerLabelsDoNotOverrideTheVideoCaption() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("generic title fixture committed") { browser.hasCurrentDocument && !browser.isLoading }
        let labels = ["播放视频", "Play video", "Pause video", "YouTube video player", "Embedded video", "  PLAY VIDEO  "]
        _ = try await browser.webView.callAsyncJavaScript("""
            document.body.replaceChildren();
            for (let index = 0; index < labels.length; index++) {
              const figure = document.createElement('figure');
              const video = document.createElement('video'); video.preload = 'none';
              video.src = '/media/direct.mp4?generic=' + index; video.setAttribute('aria-label', labels[index]);
              const caption = document.createElement('figcaption'); caption.textContent = '视频内容 ' + index;
              figure.append(video, caption); document.body.append(figure);
            }
            const video = document.createElement('video'); video.preload = 'none';
            video.src = '/media/direct.mp4?generic=meaningful';
            video.setAttribute('aria-label', 'Play video games in the park'); document.body.append(video);
            window.__vyuRescan(); return true;
            """, arguments: ["labels": labels], in: nil, contentWorld: .page)
        try await waitUntil("captions replace generic player labels") {
            labels.indices.allSatisfy { index in
                browser.candidates.first { $0.url.query == "generic=\(index)" }?.title == "视频内容 \(index)"
            }
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "generic=meaningful" }?.title, "Play video games in the park")
    }

    func testVideoTitleWalksAreBoundedAndDoNotScanWholeSharedContainers() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("bounded title fixture committed") { browser.hasCurrentDocument && !browser.isLoading }
        _ = try await browser.webView.evaluateJavaScript("""
            document.title = '大型页面';
            document.body.innerHTML = '<main>' + Array.from({length:25}, (_, index) =>
              '<figure><video preload="none" src="/media/direct.mp4?bounded=' + index + '"></video><figcaption>独立内容 ' + index + '</figcaption></figure>').join('') +
              '<section><div><video preload="none" src="/media/direct.mp4?bounded=ambiguous"></video></div><div>' +
              '<span></span>'.repeat(1500) + '</div><h3>后一个视频自己的标题</h3><video preload="none" src="/media/direct.mp4?bounded=last"></video></section></main>';
            window.titleWalkStats = {fullVideoQueries:0, maxWalk:0, boundaryWalks:0};
            for (const name of ['querySelector', 'querySelectorAll']) {
              const original = Element.prototype[name];
              Element.prototype[name] = function(selector) {
                if (selector === 'video') window.titleWalkStats.fullVideoQueries++;
                return Reflect.apply(original, this, arguments);
              };
            }
            const createWalker = document.createTreeWalker.bind(document);
            document.createTreeWalker = function(root, ...args) {
              if (root === document.body || root === document.documentElement || root.tagName === 'MAIN') window.titleWalkStats.boundaryWalks++;
              const walker = createWalker(root, ...args), next = walker.nextNode.bind(walker);
              let steps = 0;
              walker.nextNode = function() {
                window.titleWalkStats.maxWalk = Math.max(window.titleWalkStats.maxWalk, ++steps);
                return next();
              };
              return walker;
            };
            window.__vyuRescan(); true;
            """)
        try await waitUntil("bounded title fixtures discovered") {
            browser.candidates.filter { $0.url.query?.hasPrefix("bounded=") == true }.count == 27
        }
        for index in 0..<25 {
            XCTAssertEqual(browser.candidates.first { $0.url.query == "bounded=\(index)" }?.title, "独立内容 \(index)")
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "bounded=ambiguous" }?.title, "大型页面")
        XCTAssertEqual(browser.candidates.first { $0.url.query == "bounded=last" }?.title, "后一个视频自己的标题")
        let statsValue = try await browser.webView.evaluateJavaScript("window.titleWalkStats")
        let stats = try XCTUnwrap(statsValue as? [String: Int])
        XCTAssertEqual(stats["fullVideoQueries"], 0)
        XCTAssertEqual(stats["boundaryWalks"], 0)
        XCTAssertGreaterThan(stats["maxWalk"] ?? 0, 0)
        XCTAssertLessThanOrEqual(stats["maxWalk"] ?? 0, 257)
    }

    func testRepeatedTitleUpdatesAreCoalescedWithoutUsingNewCandidateBudget() async throws {
        let messages = DiscoveryMessageRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messages, name: "vyuMedia")
        let view = WKWebView(frame: .zero, configuration: configuration)
        let controller = UIViewController(); controller.view = view
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        view.load(URLRequest(url: base))
        try await waitUntil("title update fixture loaded") { view.url != nil && !view.isLoading }
        _ = try await view.evaluateJavaScript("""
            document.body.innerHTML = '<figure><video preload="none" title="初始标题" src="/media/direct.mp4?updates=repeated"></video><figcaption>说明</figcaption></figure>';
            true;
            """)
        _ = try await view.evaluateJavaScript(DiscoveryScript.source(token: UUID().uuidString))
        try await waitUntil("first video title received") {
            messages.bodies.contains { $0["title"] == "初始标题" && $0["event"] == "candidate" }
        }
        messages.bodies.removeAll()
        _ = try await view.evaluateJavaScript("""
            const video = document.getElementsByTagName('video')[0];
            for (let index = 0; index < 240; index++) {
              video.title = '变化标题 ' + index;
              video.dispatchEvent(new Event('loadedmetadata'));
            }
            const second = document.createElement('video'); second.preload = 'none';
            second.title = '新发现视频'; second.src = '/media/direct.mp4?updates=new';
            document.body.append(second); true;
            """)
        try await waitUntil("new URL survives repeated title changes") {
            messages.bodies.contains { $0["url"]?.hasSuffix("updates=new") == true && $0["event"] == "candidate" }
        }
        try await waitUntil("last changed title is eventually delivered") {
            messages.bodies.contains { $0["title"] == "变化标题 239" && $0["event"] == "candidate" }
        }
        let repeated = messages.bodies.filter { $0["url"]?.hasSuffix("updates=repeated") == true && $0["event"] == "candidate" }
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated.first?["title"], "变化标题 239")
    }

    func testVideoTitleStaysInIframeAndPreservesLongExplicitLabelBounds() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("iframe").absoluteString)
        try await waitUntil("title iframe video recognized") { !browser.isLoading && browser.candidates.contains { $0.frameURL.path == "/direct" } }
        _ = try await browser.webView.evaluateJavaScript("""
            document.title = '外层网页标题';
            const frame = document.querySelector('iframe').contentWindow;
            const innerVideo = frame.document.querySelector('video');
            const figure = frame.document.createElement('figure');
            const caption = frame.document.createElement('figcaption'); caption.textContent = '内嵌视频自己的说明';
            innerVideo.parentElement.insertBefore(figure, innerVideo); figure.append(innerVideo, caption);
            frame.__vyuRescan(); true;
            """)
        try await waitUntil("iframe caption used") {
            browser.candidates.first { $0.frameURL.path == "/direct" }?.title == "内嵌视频自己的说明"
        }
        _ = try await browser.webView.evaluateJavaScript("""
            document.querySelector('iframe').contentDocument.querySelector('video').setAttribute('title', '星'.repeat(500)); true;
            """)
        try await waitUntil("bounded explicit title received") {
            browser.candidates.first { $0.frameURL.path == "/direct" }?.title == String(repeating: "星", count: 240)
        }
        let candidate = try XCTUnwrap(browser.candidates.first { $0.frameURL.path == "/direct" })
        XCTAssertLessThanOrEqual(candidate.title.utf8.count, 1024)
        XCTAssertEqual(candidate.pageURL.path, "/iframe")
    }

    func testVideoTitleUpdatesMatchedMP4Alternatives() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("hls-alternatives").absoluteString)
        try await waitUntil("paired HLS and MP4 discovered") {
            guard !browser.isLoading, let candidate = browser.candidates.first(where: { $0.kind == .hls }) else { return false }
            return !browser.alternatives(for: candidate).isEmpty
        }
        _ = try await browser.webView.evaluateJavaScript("""
            document.querySelector('video').setAttribute('title', '这个视频的具体内容'); true;
            """)
        try await waitUntil("title reaches both HLS and matching MP4") {
            guard let candidate = browser.candidates.first(where: { $0.kind == .hls }), candidate.title == "这个视频的具体内容" else { return false }
            let alternatives = browser.alternatives(for: candidate)
            return !alternatives.isEmpty && alternatives.allSatisfy { $0.title == "这个视频的具体内容" }
        }
    }

    func testPlainCardTitlesSkipMetadataAndTrackDynamicChangesWithoutCrossingCards() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("video-card-titles").absoluteString)
        try await waitUntil("plain card titles discovered") {
            browser.candidates.first { $0.url.query == "card=one" }?.title == "晨光中的山间步道" &&
            browser.candidates.first { $0.url.query == "card=two" }?.title == "雨后花园里的小路"
        }
        _ = try await browser.webView.evaluateJavaScript("""
            document.querySelector('#card-two header').innerHTML = '<h3 class="author">示例作者乙</h3><time>刚刚</time>';
            document.querySelector('#card-two-title span').textContent = '溪边的新视角';
            true;
            """)
        try await waitUntil("changed card title ignores author heading") {
            browser.candidates.first { $0.url.query == "card=two" }?.title == "溪边的新视角"
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "card=one" }?.title, "晨光中的山间步道")

        _ = try await browser.webView.evaluateJavaScript("""
            document.querySelector('#card-two-title').remove();
            const card = document.createElement('article'); card.id = 'card-three';
            card.innerHTML = '<header><a rel="author" href="/fixture-author">示例作者丙</a><time>1 分钟前</time></header>' +
              '<div><span>慢慢舒展的叶片</span></div><div class="tags"><a rel="tag" href="/fixture-tag">#植物</a></div>' +
              '<div><video controls playsinline preload="none" src="/media/direct.mp4?card=three"></video></div>' +
              '<footer><button>点赞</button><button>评论</button><button>分享</button></footer>';
            document.body.append(card); true;
            """)
        try await waitUntil("dynamic card and untitled fallback are independent") {
            browser.candidates.first { $0.url.query == "card=three" }?.title == "慢慢舒展的叶片" &&
            browser.candidates.first { $0.url.query == "card=two" }?.title == "中性视频合集"
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "card=one" }?.title, "晨光中的山间步道")
    }

    func testUnmarkedCardMetadataCannotReplaceMultiSpanOrMissingTitle() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("unmarked card fixture committed") { browser.hasCurrentDocument && !browser.isLoading }
        _ = try await browser.webView.callAsyncJavaScript("""
            document.title = '中性卡片页面';
            document.body.innerHTML = html;
            window.__vyuRescan(); return true;
            """, arguments: ["html": """
            <section>
              <div><img alt="合成作者头像" width="16" height="16"><span>示例作者甲</span><time datetime="2026-01-01">7 小时前</time></div>
              <div id="split-card-title"><span>清晨 </span><span>步道 </span><span>观察记录</span></div>
              <p>#自然 #步道</p>
              <div><video controls playsinline preload="none" src="/media/direct.mp4?plain-card=split"></video></div>
              <div><button>赞 30</button><button>评论 0</button><button>分享</button></div>
            </section>
            <section>
              <div><img alt="合成作者头像" width="16" height="16"><span>示例作者乙</span><time datetime="2026-01-02">刚刚</time></div>
              <p>#花园 #日常</p>
              <div><video controls playsinline preload="none" src="/media/direct.mp4?plain-card=untitled"></video></div>
              <div><button>赞 12</button><button>评论 0</button><button>分享</button></div>
            </section>
            <section>
              <div><img alt="合成作者头像" width="16" height="16"><span>示例作者丙</span><time datetime="2026-01-03">1 分钟前</time></div>
              <div><span>另一张卡片的独立标题</span></div><p>#远景</p>
              <div><video controls playsinline preload="none" src="/media/direct.mp4?plain-card=next"></video></div>
            </section>
            <section>
              <div class="related"><article><h2>另一张纯文字卡片</h2><p>这段内容没有视频。</p></article></div>
              <div><video controls playsinline preload="none" src="/media/direct.mp4?plain-card=article-neighbor"></video></div>
            </section>
            <section>
              <div class="related"><div class="card"><h2>另一张通用文字卡片</h2><p>这也是独立的文字内容。</p></div></div>
              <div><video controls playsinline preload="none" src="/media/direct.mp4?plain-card=generic-neighbor"></video></div>
            </section>
            """], in: nil, contentWorld: .page)
        try await waitUntil("whole multi-span title and isolated fallbacks discovered") {
            browser.candidates.first { $0.url.query == "plain-card=split" }?.title == "清晨 步道 观察记录" &&
            browser.candidates.first { $0.url.query == "plain-card=untitled" }?.title == "中性卡片页面" &&
            browser.candidates.first { $0.url.query == "plain-card=next" }?.title == "另一张卡片的独立标题" &&
            browser.candidates.first { $0.url.query == "plain-card=article-neighbor" }?.title == "中性卡片页面" &&
            browser.candidates.first { $0.url.query == "plain-card=generic-neighbor" }?.title == "中性卡片页面"
        }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('#split-card-title').remove(); true")
        try await waitUntil("removed title does not expose unmarked author or tag rows") {
            browser.candidates.first { $0.url.query == "plain-card=split" }?.title == "中性卡片页面"
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "plain-card=next" }?.title, "另一张卡片的独立标题")
        XCTAssertEqual(browser.candidates.first { $0.url.query == "plain-card=article-neighbor" }?.title, "中性卡片页面")
        XCTAssertEqual(browser.candidates.first { $0.url.query == "plain-card=generic-neighbor" }?.title, "中性卡片页面")
    }

    func testMixedInlineCaptionExcludesLinksMetadataHiddenAndOversizedText() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("mixed caption fixture committed") { browser.hasCurrentDocument && !browser.isLoading }
        _ = try await browser.webView.callAsyncJavaScript("""
            document.title = '混排标题回退'; document.body.innerHTML = html;
            window.__vyuRescan(); return true;
            """, arguments: ["html": """
            <article><header><a rel="author">示例作者</a><time>7 小时前</time></header>
              <p>清晨 <strong>花园</strong> 观察<br><a href="/fixture-tag" rel="tag">自然</a> (source.example)</p>
              <video preload="none" src="/media/direct.mp4?mixed=caption"></video></article>
            <article><div><a rel="author">示例作者</a><time>7 小时前</time></div>
              <div style="display:none">隐藏的标题</div><p><a rel="tag">自然</a> (source.example)</p>
              <div><video preload="none" src="/media/direct.mp4?mixed=empty"></video></div></article>
            <article><p>\(String(repeating: "很长的正文", count: 100))<br><a rel="tag">自然</a> (source.example)</p>
              <video preload="none" src="/media/direct.mp4?mixed=long"></video></article>
            <article><div><video preload="none" src="/media/direct.mp4?mixed=after"></video>播放器之后的无关文字</div></article>
            """], in: nil, contentWorld: .page)
        try await waitUntil("mixed caption sources discovered") {
            browser.candidates.filter { $0.url.query?.hasPrefix("mixed=") == true }.count == 4
        }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "mixed=caption" }?.title, "清晨 花园 观察")
        for suffix in ["empty", "long", "after"] {
            XCTAssertEqual(browser.candidates.first { $0.url.query == "mixed=\(suffix)" }?.title, "混排标题回退")
        }
    }

    func testLooseInlineCardTitleSurvivesMP4AndHLSDownloadsAndPersistence() async throws {
        let browser = mountBrowser()
        for (route, kind) in [("video-card-inline-mp4", MediaKind.file), ("video-card-inline-hls", MediaKind.hls)] {
            browser.open(base.appendingPathComponent(route).absoluteString)
            try await waitUntil("inline card discovered") {
                !browser.isLoading && browser.candidates.contains { $0.pageURL.lastPathComponent == route && $0.kind == kind }
            }
            let candidate = try XCTUnwrap(browser.candidates.first { $0.kind == kind })
            XCTAssertEqual(candidate.title, "林间 散步 的记录")
            let preparedValue = await browser.prepareForDownload(candidate)
            let prepared = try XCTUnwrap(preparedValue)
            XCTAssertEqual(prepared.title, candidate.title)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-inline-title-" + UUID().uuidString)
            let manager = DownloadManager(rootDirectory: root)
            defer {
                for record in manager.records { manager.removeRecord(id: record.id) }
                try? FileManager.default.removeItem(at: root)
            }
            await manager.start(candidate: prepared, cookies: [])
            try await waitUntil("inline title download validated", timeout: 60) {
                manager.records.first?.phase == .complete || manager.records.first?.phase == .failed
            }
            let record = try XCTUnwrap(manager.records.first)
            XCTAssertEqual(record.phase, .complete, record.failure ?? "")
            XCTAssertEqual(record.candidate.title, "林间 散步 的记录")
            XCTAssertNotNil(manager.localURL(for: record))
            let restored = DownloadManager(rootDirectory: root)
            XCTAssertEqual(restored.records.first?.candidate.title, "林间 散步 的记录")
        }
    }

    func testPlainCardTitleUsesOwningIframeAndSurvivesPreparationAndPersistence() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("video-card-title-frame").absoluteString)
        try await waitUntil("iframe card title discovered") {
            browser.candidates.first { $0.url.query == "card=frame" }?.title == "窗边的盆栽观察"
        }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.url.query == "card=frame" })
        XCTAssertEqual(discovered.pageURL.path, "/video-card-title-frame")
        XCTAssertEqual(discovered.frameURL.path, "/video-card-title-inner")
        let preparedValue = await browser.prepareForDownload(discovered)
        let prepared = try XCTUnwrap(preparedValue)
        XCTAssertEqual(prepared.title, "窗边的盆栽观察")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-card-title-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(rootDirectory: root)
        await manager.start(candidate: prepared, cookies: [])
        try await waitUntil("card title download validated", timeout: 60) {
            manager.records.first?.phase == .complete || manager.records.first?.phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertEqual(record.candidate.title, "窗边的盆栽观察")
        let restored = DownloadManager(rootDirectory: root)
        XCTAssertEqual(restored.records.first?.candidate.title, "窗边的盆栽观察")
        XCTAssertEqual(restored.records.first?.phase, .complete)
    }

    func testExplicitSelectedTitleOverridesStaleMatchedMP4MetadataWithoutChangingRequest() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("hls-alternatives").absoluteString)
        try await waitUntil("HLS and cached MP4 alternatives discovered") {
            guard let candidate = browser.candidates.first(where: { $0.kind == .hls }) else { return false }
            return !browser.alternatives(for: candidate).isEmpty
        }
        let original = try XCTUnwrap(browser.candidates.first { $0.kind == .hls })
        let before = browser.alternatives(for: original)
        let clicked = MediaCandidate(url: original.url, pageURL: original.pageURL, frameURL: original.frameURL,
            title: "刚选中卡片的最新名称", kind: original.kind, source: "video", mimeType: original.mimeType,
            userAgent: original.userAgent, requestContext: original.requestContext)
        // Do not mutate the DOM or wait for coalesced metadata. An isolated-world
        // click may carry the new title before the observer's 500 ms update.
        let after = browser.alternatives(for: clicked)
        XCTAssertEqual(after.count, before.count)
        for (previous, current) in zip(before, after) {
            XCTAssertNotEqual(previous.title, clicked.title)
            XCTAssertEqual(current.title, clicked.title)
            XCTAssertEqual(current.id, previous.id)
            XCTAssertEqual(current.url, previous.url)
            XCTAssertEqual(current.kind, previous.kind)
            XCTAssertEqual(current.source, previous.source)
            XCTAssertEqual(current.mimeType, previous.mimeType)
            XCTAssertEqual(current.userAgent, previous.userAgent)
            XCTAssertEqual(current.requestContext, previous.requestContext)
        }
    }

    func testHEADRejectionFallsBackToGETAndDownloadsWholeVideo() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("head-denied").absoluteString)
        try await waitUntil("HEAD-rejected video discovered") { !browser.candidates.isEmpty }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.url.path == "/head-denied.mp4" })
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-head-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(rootDirectory: root)
        let inspection = await manager.inspect(candidate: candidate, cookies: [])
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        // A one-byte range response must still report the complete video's length.
        XCTAssertGreaterThan(inspection.expectedBytes ?? 0, 1_024)
        await manager.start(candidate: candidate, cookies: [])
        try await waitUntil("HEAD-rejected video fully downloaded", timeout: 60) {
            manager.records.first?.phase == .complete || manager.records.first?.phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertEqual(record.bytesWritten, inspection.expectedBytes)
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.2)
        XCTAssertNotNil(manager.localURL(for: record))
    }

    func testIframeDownloadUsesWebKitUserAgentFrameRefererAndCookies() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("context-required").absoluteString)
        try await waitUntil("context-required frame video discovered") {
            browser.candidates.contains { $0.url.path == "/context-required.mp4" && $0.frameURL.path == "/context-frame" }
        }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.url.path == "/context-required.mp4" })
        XCTAssertEqual(discovered.pageURL.path, "/context-required")
        XCTAssertEqual(discovered.frameURL.path, "/context-frame")
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let isolatedValue = try await browser.webView.evaluateJavaScript("navigator.userAgent", in: nil, contentWorld: .defaultClient)
        let isolatedUserAgent = try XCTUnwrap(isolatedValue as? String)
        XCTAssertEqual(candidate.userAgent, isolatedUserAgent)
        XCTAssertTrue(candidate.userAgent?.contains("AppleWebKit/") == true)
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            browser.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(cookies.contains { $0.name == "vyu_fixture_session" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-frame-context-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(rootDirectory: root)
        let missingSession = await manager.inspect(candidate: candidate, cookies: [])
        XCTAssertFalse(missingSession.downloadable)
        XCTAssertTrue(missingSession.summary.contains("403"), missingSession.summary)
        let inspection = await manager.inspect(candidate: candidate, cookies: cookies)
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        await manager.start(candidate: candidate, cookies: cookies)
        try await waitUntil("context-required video fully downloaded", timeout: 60) {
            manager.records.first?.phase == .complete || manager.records.first?.phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.2)
        XCTAssertNotNil(manager.localURL(for: record))
    }

    func testDownloadContextUsesOwningIframeMetaPolicyAndVideoCORSMode() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("iframe").absoluteString)
        try await waitUntil("owning iframe video discovered") {
            !browser.isLoading && browser.candidates.contains { $0.frameURL.path == "/direct" }
        }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.frameURL.path == "/direct" })
        _ = try await browser.webView.evaluateJavaScript("""
            const outerPolicy = document.createElement('meta');
            outerPolicy.name = 'referrer'; outerPolicy.content = 'unsafe-url'; document.head.appendChild(outerPolicy);
            const frame = document.querySelector('iframe').contentWindow;
            frame.eval(`
              const policy = document.createElement('meta');
              policy.name = 'referrer'; policy.content = 'no-referrer'; document.head.appendChild(policy);
              const invalid = document.createElement('meta');
              invalid.name = 'referrer'; invalid.content = 'not-a-policy'; document.head.appendChild(invalid);
              document.querySelector('video').crossOrigin = 'anonymous';
              Object.defineProperty(navigator, 'userAgent', {configurable: true, get: () => 'Untrusted fixture UA'});
            `);
            true;
            """)
        let firstPrepared = await browser.prepareForDownload(discovered)
        let first = try XCTUnwrap(firstPrepared)
        XCTAssertEqual(first.requestContext?.corsMode, .anonymous)
        XCTAssertEqual(first.requestContext?.referrerPolicy, .noReferrer)
        XCTAssertTrue(first.userAgent?.contains("AppleWebKit/") == true)
        XCTAssertNotEqual(first.userAgent, "Untrusted fixture UA")
        XCTAssertNil(first.requestContext?.referrer(from: first.frameURL, to: first.url))

        _ = try await browser.webView.evaluateJavaScript("""
            document.querySelector('iframe').contentWindow.eval(`
              const last = document.createElement('meta');
              last.name = 'REFERRER'; last.content = 'origin'; document.head.appendChild(last);
              document.querySelector('video').crossOrigin = 'use-credentials';
            `);
            true;
            """)
        let secondPrepared = await browser.prepareForDownload(discovered)
        let second = try XCTUnwrap(secondPrepared)
        XCTAssertEqual(second.requestContext?.corsMode, .useCredentials)
        XCTAssertEqual(second.requestContext?.referrerPolicy, .origin)
        XCTAssertEqual(second.requestContext?.referrer(from: second.frameURL, to: second.url), base.absoluteString + "/")
    }

    func testDownloadContextSourceOnlyVideoPreservesAnonymousCookieBoundary() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("source-only owner committed") { browser.hasCurrentDocument && !browser.isLoading }
        let target = URL(string: "http://127.0.0.1:8766/media/direct.mp4?source-only=1")!
        let hasOnlySource = try await browser.webView.callAsyncJavaScript("""
            const video = document.createElement('video'); video.id = 'source-only'; video.preload = 'none';
            video.setAttribute('crossorigin', 'anonymous');
            const empty = document.createElement('source'); empty.type = 'video/mp4'; video.appendChild(empty);
            const unsupported = document.createElement('source');
            unsupported.src = target + '&unsupported=1'; unsupported.type = 'application/x-vyu-unsupported';
            video.appendChild(unsupported);
            const selected = document.createElement('source'); selected.src = target; selected.type = 'video/mp4';
            video.appendChild(selected); document.body.appendChild(video); window.__vyuRescan();
            return !video.hasAttribute('src') && video.src === '' && !video.canPlayType(unsupported.type);
            """, arguments: ["target": target.absoluteString], in: nil, contentWorld: .page)
        XCTAssertEqual(hasOnlySource as? Bool, true)
        try await waitUntil("source-only candidate discovered") { browser.candidates.contains { $0.url == target } }
        let candidate = try XCTUnwrap(browser.candidates.first { $0.url == target })
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "synthetic_scope", .value: "fixture"
        ]))
        XCTAssertEqual(MediaCookiePolicy.matching([cookie], for: target).count, 1)

        // A source-only video can be clicked before WebKit selects currentSrc.
        // Keep that legitimate state deterministic while exercising the real DOM
        // and isolated-world preparation, independent of WebKit's preload timing.
        _ = try await browser.webView.evaluateJavaScript("""
            Object.defineProperty(document.getElementById('source-only'), 'currentSrc',
              {configurable: true, get: () => ''}); true;
            """, in: nil, contentWorld: .defaultClient)
        for value in ["anonymous", "", "invalid", " use-credentials ", "ANONYMOUS"] {
            _ = try await browser.webView.callAsyncJavaScript("""
                document.getElementById('source-only').setAttribute('crossorigin', value); return true;
                """, arguments: ["value": value], in: nil, contentWorld: .page)
            let preparedValue = await browser.prepareForDownload(candidate)
            let prepared = try XCTUnwrap(preparedValue)
            XCTAssertEqual(prepared.requestContext?.corsMode, .anonymous, "crossorigin=\(value)")
            let client = MediaHTTPClient(candidate: prepared, cookies: [cookie])
            XCTAssertTrue(client.cookies.isEmpty)
            let request = client.request(target)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), base.absoluteString)
        }

        // The two credential-bearing states still differ from an empty attribute.
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('source-only').removeAttribute('crossorigin'); true")
        let withoutAttribute = await browser.prepareForDownload(candidate)
        XCTAssertEqual(withoutAttribute?.requestContext?.corsMode, MediaRequestContext.CORSMode.none)
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('source-only').setAttribute('crossorigin', 'USE-CREDENTIALS'); true")
        let credentials = await browser.prepareForDownload(candidate)
        XCTAssertEqual(credentials?.requestContext?.corsMode, .useCredentials)
    }

    func testDownloadContextConflictingVideoModesDoNotWidenCookieScope() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("conflicting modes owner committed") { browser.hasCurrentDocument && !browser.isLoading }
        let target = URL(string: "http://127.0.0.1:8766/media/direct.mp4?shared-source=1")!
        _ = try await browser.webView.callAsyncJavaScript("""
            for (const mode of ['use-credentials', 'anonymous']) {
              const video = document.createElement('video'); video.preload = 'none';
              video.setAttribute('crossorigin', mode); video.src = target; document.body.appendChild(video);
            }
            window.__vyuRescan(); return true;
            """, arguments: ["target": target.absoluteString], in: nil, contentWorld: .page)
        try await waitUntil("shared source discovered") { browser.candidates.contains { $0.url == target } }
        let candidate = try XCTUnwrap(browser.candidates.first { $0.url == target })
        let preparedValue = await browser.prepareForDownload(candidate)
        let prepared = try XCTUnwrap(preparedValue)
        XCTAssertEqual(prepared.requestContext?.corsMode, .anonymous)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "synthetic_scope", .value: "fixture"
        ]))
        let request = MediaHTTPClient(candidate: prepared, cookies: [cookie]).request(target)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video[crossorigin=anonymous]').remove(); true")
        let credentials = await browser.prepareForDownload(candidate)
        XCTAssertEqual(credentials?.requestContext?.corsMode, .useCredentials)
    }

    func testDownloadContextRejectsFrameThatNavigatedAwayFromItsCandidate() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("iframe").absoluteString)
        try await waitUntil("initial frame source discovered") {
            !browser.isLoading && browser.candidates.contains { $0.frameURL.path == "/direct" && $0.frameURL.query == nil }
        }
        let old = try XCTUnwrap(browser.candidates.first { $0.frameURL.path == "/direct" && $0.frameURL.query == nil })
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('iframe').src = '/direct?replacement=1'")
        try await waitUntil("replacement frame source discovered") {
            browser.candidates.contains { $0.frameURL.query == "replacement=1" }
        }
        let stale = await browser.prepareForDownload(old)
        XCTAssertNil(stale, "An old candidate must not borrow the new frame document's CORS or referrer policy.")
        let fresh = try XCTUnwrap(browser.candidates.first { $0.frameURL.query == "replacement=1" })
        let prepared = await browser.prepareForDownload(fresh)
        XCTAssertEqual(prepared?.requestContext?.corsMode, MediaRequestContext.CORSMode.none)
        XCTAssertEqual(prepared?.requestContext?.referrerPolicy, .strictOriginWhenCrossOrigin)
    }

    func testDownloadContextKeepsHTTPReferrerPolicyDuringRescanAndAllowsMetaOverride() async throws {
        let browser = mountBrowser()
        var components = URLComponents(url: base.appendingPathComponent("playback-context"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "run", value: UUID().uuidString), URLQueryItem(name: "mode", value: "no-referrer")]
        components.fragment = "player"
        browser.open(components.url!.absoluteString)
        try await waitUntil("response policy fixture discovered") {
            !browser.isLoading && browser.candidates.contains { $0.kind == .hls }
        }
        _ = try await browser.webView.evaluateJavaScript("document.querySelectorAll('meta[name=referrer]').forEach(meta => meta.remove())")
        browser.refreshCandidates(resetHistory: true)
        try await waitUntil("same document rescanned") { browser.candidates.contains { $0.kind == .hls } }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.kind == .hls })
        let prepared = await browser.prepareForDownload(discovered)
        XCTAssertEqual(prepared?.requestContext?.referrerPolicy, .noReferrer,
                       "Rescanning a live document must retain its HTTP response policy.")
        _ = try await browser.webView.evaluateJavaScript("""
            const meta = document.createElement('meta'); meta.name = 'referrer'; meta.content = 'origin';
            document.head.appendChild(meta);
            true;
            """)
        let overridden = await browser.prepareForDownload(discovered)
        XCTAssertEqual(overridden?.requestContext?.referrerPolicy, .origin)
    }

    func testInlineDownloadControlsStayBesideEachVideoAfterSourceChanges() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("multiple-videos").absoluteString)
        try await waitUntil("both video sources discovered") { browser.candidates.count >= 2 }
        _ = try await browser.webView.evaluateJavaScript("window.__vyuRescan()", in: nil, contentWorld: .defaultClient)
        let paired = try await browser.webView.evaluateJavaScript("""
            (() => {
              const videos = Array.from(document.querySelectorAll('video'));
              return videos.length === 2 && document.querySelectorAll('[data-vyu-download]').length === 2 &&
                videos.every(video => video.nextElementSibling?.hasAttribute('data-vyu-download'));
            })()
            """) as? Bool
        XCTAssertEqual(paired, true)

        _ = try await browser.webView.evaluateJavaScript("""
            const video = document.querySelector('#second-video');
            video.src = '/media/direct.mp4?second=2'; video.load();
            window.__vyuRescan();
            """)
        try await waitUntil("replacement source discovered") {
            browser.candidates.contains { $0.url.query == "second=2" }
        }
        let refreshed = try await browser.webView.evaluateJavaScript("""
            document.querySelectorAll('[data-vyu-download]').length === 2 &&
            document.querySelector('#second-video').currentSrc.endsWith('?second=2')
            """) as? Bool
        XCTAssertEqual(refreshed, true)
        XCTAssertNil(browser.pendingDownload)

        _ = try await browser.webView.evaluateJavaScript("document.querySelector('#first-video').remove(); window.__vyuRescan(); true")
        _ = try await browser.webView.evaluateJavaScript("window.__vyuRescan()", in: nil, contentWorld: .defaultClient)
        let remaining = try await browser.webView.evaluateJavaScript("document.querySelectorAll('[data-vyu-download]').length") as? Int
        XCTAssertEqual(remaining, 1)
    }

    func testExplicitRescanDiscardsHistoricalIframeSources() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("iframe").absoluteString)
        try await waitUntil("iframe loaded") { !browser.isLoading && !browser.candidates.isEmpty }
        let old = try XCTUnwrap(browser.candidates.first { $0.url.path == "/media/direct.mp4" })
        _ = try await browser.webView.evaluateJavaScript("""
            const video = document.querySelector('iframe').contentDocument.querySelector('video');
            video.src = '/media/direct.mp4?fresh=1'; video.load();
            """)
        try await waitUntil("replacement iframe source") { browser.candidates.contains { $0.url.query == "fresh=1" } }
        let generation = browser.discoveryID
        browser.refreshCandidates(resetHistory: true)
        XCTAssertNotEqual(browser.discoveryID, generation)
        XCTAssertTrue(browser.candidates.isEmpty)
        let stale = await browser.prepareForDownload(old)
        XCTAssertNil(stale)
        try await waitUntil("new scan reaches iframe") { browser.candidates.contains { $0.url.query == "fresh=1" } }
        // An ordinary follow-up scan must not replay pre-reset Performance entries.
        browser.refreshCandidates(resetHistory: false)
        _ = try await browser.webView.evaluateJavaScript("document.readyState")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(browser.candidates.contains { $0.id == old.id })
        let current = try XCTUnwrap(browser.candidates.first { $0.url.query == "fresh=1" })
        let prepared = await browser.prepareForDownload(current)
        XCTAssertNotNil(prepared)
    }

    func testInlineSelectionKeepsOwningFrameWhenAnotherFrameReportsSameURL() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("iframe").absoluteString)
        try await waitUntil("first iframe video discovered") {
            !browser.isLoading && browser.candidates.contains {
                $0.url.path == "/media/direct.mp4" && $0.frameURL.path == "/direct"
            }
        }
        // Capture only this synthetic fixture's discovery epoch. The messages
        // below still pass through WebKit with their actual sending frameInfo.
        _ = try await browser.webView.evaluateJavaScript("""
            document.querySelector('iframe').id = 'first-fixture-frame';
            const originalSetToken = window.__vyuSetNavigationToken;
            window.__vyuSetNavigationToken = function(token, reset) {
              window.fixtureToken = token; return originalSetToken(token, reset);
            };
            true;
            """)
        browser.refreshCandidates(resetHistory: true)
        try await waitUntil("first frame rescanned") { !browser.candidates.isEmpty }
        let frames = FixtureDownloadFrameRecorder()
        let controller = browser.webView.configuration.userContentController
        controller.add(frames, contentWorld: .page, name: "fixtureDownloadFrame")
        defer { controller.removeScriptMessageHandler(forName: "fixtureDownloadFrame", contentWorld: .page) }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('#first-fixture-frame').contentWindow.webkit.messageHandlers.fixtureDownloadFrame.postMessage('frame'); true")
        try await waitUntil("test driver captures the real first frame") { frames.frame != nil }
        let firstFrame = try XCTUnwrap(frames.frame)
        let tokenValue = try await browser.webView.evaluateJavaScript("window.fixtureToken")
        let token = try XCTUnwrap(tokenValue as? String)
        // Only the native test driver can evaluate in the isolated action world.
        // Real user authorization is covered by the iframe UI click test.
        _ = try await browser.webView.callAsyncJavaScript("""
            window.webkit.messageHandlers.vyuDownloadAction.postMessage({token, documentURL: location.href,
              event:'download', url:location.origin + '/media/direct.mp4', title:'selected first frame', source:'video', mime:''});
            return true;
            """, arguments: ["token": token], in: firstFrame, contentWorld: .defaultClient)
        try await waitUntil("first frame explicitly selected") { browser.pendingDownload != nil }
        let selected = try XCTUnwrap(browser.pendingDownload)
        XCTAssertEqual(selected.frameURL.path, "/direct")
        XCTAssertNil(selected.frameURL.query)

        _ = try await browser.webView.evaluateJavaScript("""
            const secondFrame = document.createElement('iframe');
            secondFrame.id = 'second-fixture-frame'; secondFrame.src = '/direct?frame=second';
            document.body.appendChild(secondFrame);
            true;
            """)
        try await waitUntil("second frame reports the same media URL") {
            browser.candidates.contains { $0.url == selected.url && $0.frameURL.query == "frame=second" }
        }
        let shared = browser.candidates.filter { $0.url == selected.url }
        XCTAssertEqual(shared.count, 2, "One CDN URL must keep both frame request contexts.")
        XCTAssertEqual(Set(shared.map(\.id)).count, 2, "SwiftUI rows must also have separate identities.")
        XCTAssertTrue(browser.isCurrentCandidate(selected), "A later frame report must not invalidate the selected frame.")
        let prepared = await browser.prepareForDownload(selected)
        XCTAssertEqual(prepared?.frameURL, selected.frameURL)
        XCTAssertEqual(browser.pendingDownload?.frameURL, selected.frameURL)

        // A late resource report in that other frame must not replace either
        // the explicit selection or its frame-derived Referer.
        _ = try await browser.webView.evaluateJavaScript("""
            const second = document.querySelector('#second-fixture-frame');
            const report = {token: window.fixtureToken, documentURL: second.contentWindow.location.href,
              event: 'candidate', url: location.origin + '/media/direct.mp4', title: 'later resource',
              source: 'performance', mime: 'video/mp4'};
            const barrier = {...report, url: location.origin + '/media/direct.mp4?fixture-message-barrier=1'};
            second.contentWindow.eval('window.webkit.messageHandlers.vyuMedia.postMessage(' + JSON.stringify(report) + ');' +
              'window.webkit.messageHandlers.vyuMedia.postMessage(' + JSON.stringify(barrier) + ');');
            true;
            """)
        // Performance observations no longer overwrite an explicit video/source
        // candidate. A later message from this same frame confirms processing
        // without waiting for the metadata replacement that is now forbidden.
        try await waitUntil("second-frame late resource processed") {
            browser.candidates.contains { $0.url.query == "fixture-message-barrier=1" && $0.frameURL.query == "frame=second" }
        }
        let secondCandidate = try XCTUnwrap(browser.candidates.first { $0.url == selected.url && $0.frameURL.query == "frame=second" })
        XCTAssertTrue(["video", "source"].contains(secondCandidate.source), "A resource report must preserve explicit video provenance.")
        XCTAssertTrue(browser.isCurrentCandidate(selected))
        let finalPrepared = await browser.prepareForDownload(selected)
        let originalContext = try XCTUnwrap(finalPrepared)
        let downloadRequest = MediaCookiePolicy.request(url: originalContext.url, cookies: [], pageURL: originalContext.frameURL)
        XCTAssertEqual(downloadRequest.value(forHTTPHeaderField: "Referer"), base.appendingPathComponent("direct").absoluteString)
    }

    func testExplicitDownloadSurvivesFullCandidateListAndRejectsOldScanMessages() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("empty fixture loaded") { browser.url != nil && !browser.isLoading }
        _ = try await browser.webView.evaluateJavaScript("""
            const originalSetToken = window.__vyuSetNavigationToken;
            window.__vyuSetNavigationToken = function(token, reset) {
              window.fixtureToken = token; return originalSetToken(token, reset);
            };
            true;
            """)
        browser.refreshCandidates(resetHistory: true)
        let oldTokenValue = try await browser.webView.evaluateJavaScript("window.fixtureToken")
        let oldToken = try XCTUnwrap(oldTokenValue as? String)
        browser.refreshCandidates(resetHistory: true)
        let encodedOld = String(data: try JSONEncoder().encode(oldToken), encoding: .utf8)!
        _ = try await browser.webView.evaluateJavaScript("""
            window.webkit.messageHandlers.vyuMedia.postMessage({token: \(encodedOld), documentURL: location.href,
              event: 'candidate', url: location.origin + '/media/old-scan.mp4', title: 'old', source: 'video', mime: 'video/mp4'});
            for (let index = 0; index < 100; index++) {
              window.webkit.messageHandlers.vyuMedia.postMessage({token: window.fixtureToken, documentURL: location.href,
                event: 'candidate', url: location.origin + '/media/direct.mp4?budget=' + index,
                title: 'fixture', source: 'video', mime: 'video/mp4'});
            }
            true;
            """)
        try await waitUntil("candidate budget filled") { browser.candidates.count == 100 }
        XCTAssertFalse(browser.candidates.contains { $0.url.path == "/media/old-scan.mp4" })
        let tokenValue = try await browser.webView.evaluateJavaScript("window.fixtureToken")
        let token = try XCTUnwrap(tokenValue as? String)
        _ = try await browser.webView.callAsyncJavaScript("""
            window.webkit.messageHandlers.vyuDownloadAction.postMessage({token, documentURL: location.href,
              event: 'download', url: location.origin + '/media/direct.mp4?selected=1',
              title: 'explicit selection', source: 'video', mime: 'video/mp4'});
            return true;
            """, arguments: ["token": token], in: nil, contentWorld: .defaultClient)
        try await waitUntil("explicit video selected") { browser.pendingDownload?.url.query == "selected=1" }
        XCTAssertEqual(browser.candidates.count, 100)
        XCTAssertFalse(browser.candidates.contains { $0.url.query == "budget=0" })
        let selected = try XCTUnwrap(browser.pendingDownload)
        let prepared = await browser.prepareForDownload(selected)
        XCTAssertNotNil(prepared)
        XCTAssertTrue(browser.isCurrentCandidate(selected))
        browser.candidates.removeAll { $0.id == selected.id }
        XCTAssertFalse(browser.isCurrentCandidate(selected))
    }

    func testPageWorldForgeryCannotAuthorizeAutomaticDownloadsOrOpenActionUI() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("direct").absoluteString)
        try await waitUntil("forgery fixture loaded") { !browser.isLoading && !browser.candidates.isEmpty }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-untrusted-download-" + UUID().uuidString)
        let downloads = DownloadManager(rootDirectory: root)
        defer {
            downloads.records.map(\.id).forEach { downloads.removeRecord(id: $0) }
            try? FileManager.default.removeItem(at: root)
        }
        let automaticConsumer = browser.$pendingDownload.compactMap { $0 }.sink { candidate in
            Task { await downloads.start(candidate: candidate, cookies: []) }
        }
        defer { automaticConsumer.cancel() }
        _ = try await browser.webView.evaluateJavaScript("""
            const originalSetToken = window.__vyuSetNavigationToken;
            window.__vyuSetNavigationToken = function(token, reset) {
              window.fixtureToken = token; return originalSetToken(token, reset);
            }; true;
            """)
        browser.refreshCandidates(resetHistory: true)
        try await waitUntil("forgery fixture rescanned") { !browser.candidates.isEmpty }
        let isolatedHandlerHidden = try await browser.webView.evaluateJavaScript("typeof window.webkit.messageHandlers.vyuDownloadAction === 'undefined'") as? Bool
        XCTAssertEqual(isolatedHandlerHidden, true)
        _ = try await browser.webView.evaluateJavaScript("""
            const request = {token: window.fixtureToken, documentURL: location.href, event:'download',
              url:location.origin + '/media/direct.mp4', title:'forged transfer', source:'video', mime:'video/mp4'};
            window.webkit.messageHandlers.vyuMedia.postMessage(request);
            for (const event of ['download-unavailable', 'download-protected', 'download-mse']) {
              window.webkit.messageHandlers.vyuMedia.postMessage({...request, event, url:'', mime:''});
            }
            document.querySelector('[data-vyu-download]')?.click();
            window.webkit.messageHandlers.vyuMedia.postMessage({...request, event:'candidate',
              url:location.origin + '/media/direct.mp4?forgery-barrier=1'});
            true;
            """)
        try await waitUntil("all forged page messages delivered") {
            browser.candidates.contains { $0.url.query == "forgery-barrier=1" }
        }
        await Task.yield()
        XCTAssertNil(browser.pendingDownload)
        XCTAssertNil(browser.downloadNotice)
        XCTAssertFalse(browser.protectedContentDetected)
        XCTAssertTrue(downloads.records.isEmpty, "Discovery and forged page actions must not create automatic transfer tasks.")
    }

    func testRescanKeepsProtectedContentBlocked() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("direct").absoluteString)
        try await waitUntil("video loaded") { !browser.isLoading && !browser.candidates.isEmpty }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').dispatchEvent(new Event('encrypted'))")
        try await waitUntil("protected signal") { browser.protectedContentDetected }
        browser.refreshCandidates(resetHistory: true)
        XCTAssertTrue(browser.protectedContentDetected)
        try await waitUntil("protected source rediscovered") { !browser.candidates.isEmpty }
        XCTAssertTrue(browser.candidates.allSatisfy { $0.kind == .protected })
        let prepared = await browser.prepareForDownload(browser.candidates[0])
        XCTAssertNil(prepared)
    }

    func testRescanDropsJSONBodyThatFinishesInPreviousGeneration() async throws {
        // Exercise the real WebKit stream/clone implementation with controlled
        // bytes. No account or third-party request is involved.
        let messages = DiscoveryMessageRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messages, name: "vyuMedia")
        let view = WKWebView(frame: .zero, configuration: configuration)
        let controller = UIViewController(); controller.view = view
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        view.load(URLRequest(url: base))
        try await waitUntil("metadata fixture loaded") { view.url != nil && !view.isLoading }
        _ = try await view.evaluateJavaScript("""
            window.fetch = function() {
              const stream = new ReadableStream({start(controller) { window.fixtureBody = controller; }});
              const response = new Response(stream, {headers: {'Content-Type': 'application/json'}});
              Object.defineProperty(response, 'url', {value: location.origin + '/fixture.json'});
              return Promise.resolve(response);
            };
            true;
            """)
        _ = try await view.evaluateJavaScript(DiscoveryScript.source(token: UUID().uuidString))
        _ = try await view.evaluateJavaScript("fetch('/fixture.json'); true")
        let next = UUID().uuidString
        _ = try await view.evaluateJavaScript("""
            window.__vyuSetNavigationToken('\(next)', true);
            window.fixtureBody.enqueue(new TextEncoder().encode(JSON.stringify({video_info: {variants: [
              {content_type:'application/x-mpegurl', url:location.origin+'/old.m3u8'},
              {content_type:'video/mp4', url:location.origin+'/old.mp4'}
            ]}})));
            window.fixtureBody.close();
            """)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(messages.bodies.contains { $0["event"] == "alternative" })
        // The same metadata is accepted when its request belongs to the new scan.
        _ = try await view.evaluateJavaScript("fetch('/fixture.json'); true")
        _ = try await view.evaluateJavaScript("""
            window.fixtureBody.enqueue(new TextEncoder().encode(JSON.stringify({video_info: {variants: [
              {content_type:'application/x-mpegurl', url:location.origin+'/fresh.m3u8'},
              {content_type:'video/mp4', url:location.origin+'/fresh.mp4'}
            ]}})));
            window.fixtureBody.close();
            """)
        try await waitUntil("fresh metadata accepted") { messages.bodies.contains { $0["url"]?.hasSuffix("/fresh.mp4") == true } }
        XCTAssertFalse(messages.bodies.contains { $0["url"]?.hasSuffix("/old.mp4") == true })
    }

    func testReadableHLSRemovesInitializationCandidatesBeforeAndAfterManifest() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("empty page committed") { browser.hasCurrentDocument && !browser.isLoading }
        let partialPath = "/media/hls-fmp4-separate/video/180p/init.mp4"
        _ = try await browser.webView.callAsyncJavaScript("await (await fetch(path)).arrayBuffer(); return true;",
            arguments: ["path": partialPath], in: nil, contentWorld: .page)
        try await waitUntil("initialization initially observed as MP4") { browser.candidates.contains { $0.url.path == partialPath } }
        let stale = try XCTUnwrap(browser.candidates.first { $0.url.path == partialPath })
        _ = try await browser.webView.callAsyncJavaScript("await (await fetch('/media/hls-fmp4-separate/video/180p/index.m3u8')).text(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil("readable manifest removes its initialization") { !browser.candidates.contains { $0.url.path == partialPath } }
        XCTAssertFalse(browser.isCurrentCandidate(stale))
        let prepared = await browser.prepareForDownload(stale)
        XCTAssertNil(prepared)
        _ = try await browser.webView.callAsyncJavaScript("await (await fetch(path)).arrayBuffer(); return true;",
            arguments: ["path": partialPath], in: nil, contentWorld: .page)
        browser.refreshCandidates()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(browser.candidates.contains { $0.url.path == partialPath }, "Later network/performance observations must stay suppressed.")
        XCTAssertTrue(browser.candidates.contains { $0.kind == .hls })

        // Explicit DOM sources outrank evidence about their use in a playlist.
        // This also guards a late network MIME update replacing that source.
        _ = try await browser.webView.evaluateJavaScript("""
            const explicit = document.createElement('video'); explicit.preload = 'none';
            explicit.src = '\(partialPath)'; document.body.appendChild(explicit); window.__vyuRescan(); true;
            """)
        try await waitUntil("explicit video source retained") { browser.candidates.contains { $0.url.path == partialPath && $0.source == "video" } }
        _ = try await browser.webView.callAsyncJavaScript("await (await fetch(path)).arrayBuffer(); return true;",
            arguments: ["path": partialPath], in: nil, contentWorld: .page)
        browser.refreshCandidates()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(browser.candidates.contains { $0.url.path == partialPath && $0.source == "video" })
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').remove(); true")
        browser.refreshCandidates(resetHistory: true)
        _ = try await browser.webView.callAsyncJavaScript("await (await fetch(path)).arrayBuffer(); return true;",
            arguments: ["path": partialPath], in: nil, contentWorld: .page)
        try await waitUntil("new generation does not retain old manifest suppression") { browser.candidates.contains { $0.url.path == partialPath } }
    }

    func testReadableHLSPartialSuppressionStaysInOwningFrame() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("frame owner committed") { browser.hasCurrentDocument && !browser.isLoading }
        _ = try await browser.webView.callAsyncJavaScript("""
            const frame = document.createElement('iframe'); frame.id = 'partial-frame'; frame.src = '/?partial-frame=1';
            await new Promise(resolve => { frame.onload = resolve; document.body.appendChild(frame); });
            await (await frame.contentWindow.fetch('/media/hls-fmp4-separate/video/180p/init.mp4')).arrayBuffer();
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let partialPath = "/media/hls-fmp4-separate/video/180p/init.mp4"
        try await waitUntil("iframe initialization candidate observed") {
            browser.candidates.contains { $0.url.path == partialPath && $0.frameURL.query == "partial-frame=1" }
        }
        _ = try await browser.webView.callAsyncJavaScript("await (await fetch('/media/hls-fmp4-separate/video/180p/index.m3u8')).text(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(browser.candidates.contains { $0.url.path == partialPath && $0.frameURL.query == "partial-frame=1" })
        _ = try await browser.webView.callAsyncJavaScript("""
            const frame = document.getElementById('partial-frame');
            await (await frame.contentWindow.fetch('/media/hls-fmp4-separate/video/180p/index.m3u8')).text();
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil("owning iframe manifest removes its initialization") { !browser.candidates.contains { $0.url.path == partialPath } }
    }

    func testXHRPlaylistEvidencePreservesBodyAndSuppressesOnlyReferencedResources() async throws {
        let browser = mountBrowser()
        browser.open(base.absoluteString)
        try await waitUntil("XHR owner committed") { browser.hasCurrentDocument && !browser.isLoading }
        let body = try await browser.webView.callAsyncJavaScript("""
            return await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest(); xhr.open('GET', '/media/hls-fmp4-separate/video/180p/index.m3u8');
              xhr.responseType = 'arraybuffer';
              xhr.onload = () => resolve(new TextDecoder().decode(xhr.response));
              xhr.onerror = reject; xhr.send();
            });
            """, arguments: [:], in: nil, contentWorld: .page)
        let text = try XCTUnwrap(body as? String)
        XCTAssertTrue(text.hasPrefix("#EXTM3U"))
        XCTAssertTrue(text.contains("#EXT-X-MAP:"))
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
        _ = try await browser.webView.callAsyncJavaScript("""
            await (await fetch('/media/hls-fmp4-separate/video/180p/init.mp4')).arrayBuffer();
            await (await fetch('/media/direct.mp4')).arrayBuffer();
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil("unrelated MP4 remains discoverable") { browser.candidates.contains { $0.url.path == "/media/direct.mp4" } }
        XCTAssertFalse(browser.candidates.contains { $0.url.path == "/media/hls-fmp4-separate/video/180p/init.mp4" })
        XCTAssertTrue(browser.candidates.contains { $0.kind == .hls })
        _ = try await browser.webView.callAsyncJavaScript("""
            await (await fetch('/media/hls-fmp4/index.m3u8')).text();
            await (await fetch('/media/hls-fmp4/stream.mp4')).arrayBuffer();
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil("byte-ranged whole MP4 remains discoverable") { browser.candidates.contains { $0.url.path == "/media/hls-fmp4/stream.mp4" } }
        browser.refreshCandidates()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(browser.candidates.contains { $0.url.path == "/media/hls-fmp4/stream.mp4" })
    }

    func testRescanDropsHLSBodyThatFinishesInPreviousGeneration() async throws {
        let messages = DiscoveryMessageRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messages, name: "vyuMedia")
        let view = WKWebView(frame: .zero, configuration: configuration)
        let controller = UIViewController(); controller.view = view
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        view.load(URLRequest(url: base))
        try await waitUntil("playlist fixture loaded") { view.url != nil && !view.isLoading }
        _ = try await view.evaluateJavaScript("""
            window.fetch = function() {
              const stream = new ReadableStream({start(controller) { window.fixtureBody = controller; }});
              const response = new Response(stream, {headers: {'Content-Type': 'application/vnd.apple.mpegurl'}});
              Object.defineProperty(response, 'url', {value: location.origin + '/fixture.m3u8'});
              return Promise.resolve(response);
            }; true;
            """)
        _ = try await view.evaluateJavaScript(DiscoveryScript.source(token: UUID().uuidString))
        _ = try await view.evaluateJavaScript("fetch('/fixture.m3u8'); true")
        _ = try await view.evaluateJavaScript("""
            window.__vyuSetNavigationToken('\(UUID().uuidString)', true);
            window.fixtureBody.enqueue(new TextEncoder().encode('#EXTM3U\\n#EXT-X-MAP:URI="old-init.mp4"\\n#EXTINF:2,\\nold-segment.mp4\\n#EXT-X-ENDLIST\\n'));
            window.fixtureBody.close(); true;
            """)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(messages.bodies.contains { $0["event"] == "partial" })
        _ = try await view.evaluateJavaScript("fetch('/fixture.m3u8'); true")
        _ = try await view.evaluateJavaScript("""
            window.fixtureBody.enqueue(new TextEncoder().encode('#EXTM3U\\n#EXT-X-MAP:URI="fresh-init.mp4"\\n#EXTINF:2,\\nfresh-segment.mp4\\n#EXT-X-ENDLIST\\n'));
            window.fixtureBody.close(); true;
            """)
        try await waitUntil("fresh manifest reports partial resources") { messages.bodies.filter { $0["event"] == "partial" }.count == 2 }
        XCTAssertFalse(messages.bodies.contains { $0["event"] == "partial" && $0["url"]?.contains("old-") == true })
    }

    func testOrdinaryRefreshRetainsMetadataAlternativesUntilExplicitReset() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("hls-alternatives").absoluteString)
        try await waitUntil("metadata-only alternatives discovered") {
            guard !browser.isLoading, let candidate = browser.candidates.first(where: { $0.kind == .hls }) else { return false }
            return !browser.alternatives(for: candidate).isEmpty
        }
        let candidate = try XCTUnwrap(browser.candidates.first { $0.kind == .hls })
        let alternatives = browser.alternatives(for: candidate)
        let generation = browser.discoveryID
        // This is the same call used when opening the existing source list.
        browser.refreshCandidates()
        _ = try await browser.webView.evaluateJavaScript("true")
        XCTAssertEqual(browser.discoveryID, generation)
        XCTAssertEqual(browser.alternatives(for: candidate), alternatives)
        let prepared = await browser.prepareForDownload(alternatives[0])
        XCTAssertNotNil(prepared)

        browser.refreshCandidates(resetHistory: true)
        XCTAssertNotEqual(browser.discoveryID, generation)
        XCTAssertTrue(browser.alternatives(for: candidate).isEmpty)
        try await waitUntil("current HLS rediscovered after reset") { browser.candidates.contains { $0.id == candidate.id } }
        XCTAssertTrue(browser.alternatives(for: candidate).isEmpty,
                      "An explicit reset must not replay old JSON metadata.")
    }

    func testBrowserSessionDownloadUsesCookiesAndValidatesWholeFile() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("context-required").absoluteString)
        try await waitUntil("browser session video discovered") {
            browser.candidates.contains { $0.url.path == "/context-required.mp4" }
        }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.url.path == "/context-required.mp4" })
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-web-session-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(rootDirectory: root)
        // No Cookie is copied into the request: WKDownload uses this WebKit store.
        manager.startUsingBrowser(candidate: candidate, webView: browser.webView)
        let id = try XCTUnwrap(manager.records.first?.id)
        XCTAssertTrue(manager.isBrowserDownload(id: id))
        try await waitUntil("WebKit file downloaded and validated", timeout: 60) {
            manager.records.first?.phase == .complete || manager.records.first?.phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.2)
        XCTAssertEqual(record.hasAudio, true)
        XCTAssertNotNil(manager.localURL(for: record))
        XCTAssertFalse(manager.isBrowserDownload(id: id))
    }

    func testInlineDownloadControlRemainsVisibleOutsideClippedPlayer() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("clipped-video").absoluteString)
        try await waitUntil("clipped player video discovered") { !browser.candidates.isEmpty }
        _ = try await browser.webView.evaluateJavaScript("window.__vyuRescan()", in: nil, contentWorld: .defaultClient)
        let visible = try await browser.webView.evaluateJavaScript("""
            (() => {
              window.__vyuRescan();
              const player = document.querySelector('.player');
              const control = player.nextElementSibling;
              if (!control?.hasAttribute('data-vyu-download')) return false;
              const playerRect = player.getBoundingClientRect();
              const controlRect = control.getBoundingClientRect();
              return document.querySelectorAll('[data-vyu-download]').length === 1 &&
                player.contains(document.querySelector('video')) &&
                getComputedStyle(document.querySelector('video')).position === 'absolute' &&
                controlRect.top >= playerRect.bottom && controlRect.height > 0 &&
                controlRect.width > 0 && getComputedStyle(control).display !== 'none';
            })()
            """) as? Bool
        XCTAssertEqual(visible, true)
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').remove(); window.__vyuRescan(); true")
        _ = try await browser.webView.evaluateJavaScript("window.__vyuRescan()", in: nil, contentWorld: .defaultClient)
        let remaining = try await browser.webView.evaluateJavaScript("document.querySelectorAll('[data-vyu-download]').length") as? Int
        XCTAssertEqual(remaining, 0)
    }

    func testBrowserSessionRejectionNeverCreatesCompletedVideo() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("forbidden").absoluteString)
        try await waitUntil("rejected browser video discovered") { !browser.candidates.isEmpty }
        let discovered = try XCTUnwrap(browser.candidates.first)
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-web-rejected-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(rootDirectory: root)
        manager.startUsingBrowser(candidate: candidate, webView: browser.webView)
        try await waitUntil("WebKit denial reported", timeout: 30) { manager.records.first?.phase == .failed }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertTrue(record.failure?.contains("403") == true, record.failure ?? "missing failure")
        XCTAssertNil(record.localRelativePath)
        XCTAssertNil(manager.localURL(for: record))
        XCTAssertFalse(manager.isBrowserDownload(id: record.id))
    }

    func testBrowserSessionCancellationCannotCompleteLater() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("slow").absoluteString)
        try await waitUntil("slow browser video discovered") { !browser.candidates.isEmpty }
        let discovered = try XCTUnwrap(browser.candidates.first)
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-web-cancelled-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(rootDirectory: root)
        manager.startUsingBrowser(candidate: candidate, webView: browser.webView)
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitUntil("WebKit transfer starts receiving bytes", timeout: 20) {
            (manager.records.first?.bytesWritten ?? 0) > 0
        }
        manager.cancel(id: id)
        XCTAssertEqual(manager.records.first?.phase, .cancelled)
        // Allow queued delegate callbacks to arrive after cancellation.
        try await Task.sleep(for: .seconds(2))
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .cancelled)
        XCTAssertNil(record.localRelativePath)
        XCTAssertNil(manager.localURL(for: record))
        XCTAssertFalse(manager.isBrowserDownload(id: id))
    }

    func testHTTPFailureAndCorruptFileNeverComplete() async throws {
        for path in ["forbidden.mp4", "head-unsupported.mp4", "expired.mp4", "corrupt.mp4"] {
            let browser = mountBrowser()
            let route = path.replacingOccurrences(of: ".mp4", with: "")
            browser.open(base.appendingPathComponent(route).absoluteString)
            try await waitUntil("failure fixture discovered") { !browser.candidates.isEmpty }
            let candidate = try XCTUnwrap(browser.candidates.first)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let manager = DownloadManager(rootDirectory: root)
            if route == "forbidden" || route == "head-unsupported" {
                let inspection = await manager.inspect(candidate: candidate, cookies: [])
                XCTAssertFalse(inspection.downloadable)
                XCTAssertTrue(inspection.summary.contains("403"), inspection.summary)
                XCTAssertTrue(inspection.webSessionRetryAllowed)
            }
            await manager.start(candidate: candidate, cookies: [])
            try await waitUntil("failure terminal state", timeout: 30) { manager.records.first?.phase == .failed }
            XCTAssertNil(manager.records.first?.localRelativePath)
            XCTAssertFalse(manager.records.first?.failure?.isEmpty ?? true)
            if route == "corrupt" {
                XCTAssertTrue(manager.records.first?.failure?.contains("文件无法作为视频播放") == true, manager.records.first?.failure ?? "missing failure")
            } else if route == "expired" {
                XCTAssertTrue(manager.records.first?.failure?.contains("410") == true, manager.records.first?.failure ?? "missing failure")
            } else {
                XCTAssertTrue(manager.records.first?.failure?.contains("拒绝") == true, manager.records.first?.failure ?? "missing failure")
            }
        }
    }

    private func mountBrowser() -> BrowserModel {
        let browser = BrowserModel()
        let controller = UIViewController(); controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = controller; window.makeKeyAndVisible()
        self.window = window
        return browser
    }

    private func setOffline(_ value: Bool) async {
        var request = URLRequest(url: base.appendingPathComponent("__control")); request.httpMethod = "POST"
        request.httpBody = Data("{\"offline\":\(value)}".utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }
    private func waitUntil(_ reason: String, timeout: TimeInterval = 20, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), reason)
    }
}

@MainActor private final class DiscoveryMessageRecorder: NSObject, WKScriptMessageHandler {
    var bodies: [[String: String]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let fields = message.body as? [String: String] { bodies.append(fields) }
    }
}

@MainActor private final class FixtureDownloadFrameRecorder: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
