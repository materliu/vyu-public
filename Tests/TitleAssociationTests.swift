import XCTest
import WebKit
@testable import VYu

@MainActor final class TitleAssociationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?

    override func setUp() async throws {
        continueAfterFailure = false
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("__health"))
    }

    override func tearDown() async throws { window?.isHidden = true; window = nil }

    private func browser(_ path: String) async throws -> BrowserModel {
        let browser = BrowserModel(websiteDataStore: .nonPersistent())
        let controller = UIViewController(); controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = controller
        window.makeKeyAndVisible(); self.window = window
        browser.open(base.appendingPathComponent(path).absoluteString)
        try await wait { browser.hasCurrentDocument && !browser.isLoading }
        return browser
    }

    private func wait(_ reason: String = "fixture condition", _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), reason)
    }

    func testContentInsideMetadataNamedWrapperIsNotDiscarded() async throws {
        let browser = try await browser("title-wrapper-mixed")
        try await wait { browser.candidates.filter { $0.url.query?.hasPrefix("wrapper=") == true }.count == 3 }
        XCTAssertEqual(browser.candidates.first { $0.url.query == "wrapper=one" }?.title, "山间清晨的散步")
        XCTAssertEqual(browser.candidates.first { $0.url.query == "wrapper=two" }?.title, "雨后花园的观察")
        XCTAssertEqual(browser.candidates.first { $0.url.query == "wrapper=three" }?.title, "链接里的完整标题")
    }

    func testPreparationReadsCurrentTitleInsteadOfCachedCandidate() async throws {
        let browser = try await browser("direct")
        try await wait("direct source after rescan") { !browser.candidates.isEmpty }
        let old = try XCTUnwrap(browser.candidates.first { $0.kind == .file })
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').title='点击时已经更新的名称'; true")
        let prepared = await browser.prepareForDownload(old)
        XCTAssertEqual(prepared?.title, "点击时已经更新的名称")
        XCTAssertEqual(prepared?.url, old.url)
        XCTAssertEqual(prepared?.id, old.id)
    }

    func testPreparationUsesExactDeclaredSourceForNetworkHLS() async throws {
        let browser = try await browser("direct")
        _ = try await browser.webView.evaluateJavaScript("""
            document.title='网络来源页面';
            document.body.innerHTML='<article><p>明确关联的分段视频</p><video data-hls-src="/media/hls-separate/master.m3u8" preload="none"></video></article>';
            fetch('/media/hls-separate/master.m3u8'); true;
            """)
        try await wait { browser.candidates.contains { $0.kind == .hls && $0.mimeType?.isEmpty == false } }
        let original = try XCTUnwrap(browser.candidates.first { $0.kind == .hls })
        let prepared = await browser.prepareForDownload(original)
        XCTAssertEqual(prepared?.title, "明确关联的分段视频")
        XCTAssertEqual(prepared?.url, original.url)
    }

    func testMIMEEnrichedNetworkCandidateStillAcceptsUpdatedTitle() async throws {
        let browser = try await browser("direct")
        _ = try await browser.webView.evaluateJavaScript("""
            const set=window.__vyuSetNavigationToken;
            window.__vyuSetNavigationToken=(token,reset)=>{window.fixtureToken=token; return set(token,reset);}; true;
            """)
        browser.refreshCandidates(resetHistory: true)
        try await wait { !browser.candidates.isEmpty }
        for name in ["最初的网络标题", "后来更新的网络标题"] {
            _ = try await browser.webView.callAsyncJavaScript("""
                window.webkit.messageHandlers.vyuMedia.postMessage({token:window.fixtureToken,documentURL:location.href,
                  event:'candidate',url:location.origin+'/media/hls-separate/master.m3u8',title:name,source:'fetch',mime:'application/vnd.apple.mpegurl'});
                return true;
                """, arguments: ["name": name], in: nil, contentWorld: .page)
            if name == "最初的网络标题" { try await wait("first injected MIME title") { browser.candidates.contains { $0.title == name } } }
        }
        try await wait("updated title on MIME-enriched source") { browser.candidates.first { $0.kind == .hls }?.title == "后来更新的网络标题" }
    }

    func testCrossOriginFrameTitleComesFromItsOuterCardAtPreparation() async throws {
        let browser = try await browser("title-frame-outer")
        // Two frames intentionally share their document and media URLs. Before
        // a real click distinguishes them, native preparation must stay neutral.
        try await wait("initial cross-origin frame discovered") { browser.candidates.contains { $0.frameURL.path == "/title-frame-inner" } }
        let ambiguous = try XCTUnwrap(browser.candidates.first { $0.frameURL.path == "/title-frame-inner" })
        let neutral = await browser.prepareForDownload(ambiguous)
        XCTAssertFalse(["第一张卡片的溪流", "第二张卡片的晚风"].contains(neutral?.title ?? ""))
        _ = try await browser.webView.evaluateJavaScript("document.querySelectorAll('iframe')[1].src += '?selected=two'; true")
        try await wait("navigated second frame discovered") { browser.candidates.contains { $0.frameURL.query == "selected=two" } }
        let selected = try XCTUnwrap(browser.candidates.first { $0.frameURL.query == "selected=two" })
        var prepared = await browser.prepareForDownload(selected)
        for _ in 0..<10 where prepared?.title != "第二张卡片的晚风" {
            try await Task.sleep(for: .milliseconds(100)); prepared = await browser.prepareForDownload(selected)
        }
        XCTAssertEqual(prepared?.title, "第二张卡片的晚风", "media=\(selected.url.path), source=\(selected.source)")
        XCTAssertEqual(prepared?.frameURL, selected.frameURL)
        XCTAssertEqual(prepared?.url, selected.url)
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('#outer-caption').textContent='外层刚刚更新的晚风'; true")
        let refreshed = await browser.prepareForDownload(selected)
        XCTAssertEqual(refreshed?.title, "外层刚刚更新的晚风")
        let visibleHelpers = try await browser.webView.evaluateJavaScript("typeof window.__vyuTitleForFrame + ',' + typeof window.__vyuTitleForMedia")
        XCTAssertEqual(visibleHelpers as? String, "undefined,undefined")
        _ = try await browser.webView.evaluateJavaScript("""
            window.fixtureBindingFields=[];
            window.addEventListener('message',event=>{
              if(event.data && Array.isArray(event.data.fixtureBindingFields)) window.fixtureBindingFields.push(event.data.fixtureBindingFields);
            });
            for(const frame of document.querySelectorAll('iframe')) frame.contentWindow.postMessage({fixtureInspectBindings:true},'*'); true;
            """)
        try await Task.sleep(for: .milliseconds(250))
        let leaked = try await browser.webView.evaluateJavaScript("window.fixtureBindingFields.flat(2).some(key=>['title','url','documentURL'].includes(key))")
        XCTAssertEqual(leaked as? Bool, false)
        let responses = try await browser.webView.evaluateJavaScript("window.fixtureBindingFields.length")
        XCTAssertEqual(responses as? Int, 2)
    }

    func testNestedFrameTitleFollowsOnlyItsLiveAncestry() async throws {
        let browser = try await browser("title-frame-nested")
        try await wait("nested video discovered") { browser.candidates.contains { $0.frameURL.path == "/title-frame-inner" } }
        let selected = try XCTUnwrap(browser.candidates.first { $0.frameURL.path == "/title-frame-inner" })
        var prepared = await browser.prepareForDownload(selected)
        for _ in 0..<10 where prepared?.title != "跨两层播放器的山谷" {
            try await Task.sleep(for: .milliseconds(100)); prepared = await browser.prepareForDownload(selected)
        }
        XCTAssertEqual(prepared?.title, "跨两层播放器的山谷", "media=\(selected.url.path), source=\(selected.source)")
        browser.refreshCandidates(resetHistory: true)
        let stale = await browser.prepareForDownload(selected)
        XCTAssertNil(stale, "Old iframe candidates must not survive a native navigation epoch reset")
    }

    func testUnmatchedNetworkURLDoesNotBorrowTheOnlyVideosCaption() async throws {
        let browser = try await browser("direct")
        _ = try await browser.webView.evaluateJavaScript("""
            document.title='来源不明时的回退';
            document.body.innerHTML='<article><p>不能借给旧签名来源的标题</p><video data-hls-src="/media/hls-separate/master.m3u8?signature=new" preload="none"></video></article>';
            fetch('/media/hls-separate/master.m3u8?signature=old'); true;
            """)
        try await wait { browser.candidates.contains { $0.kind == .hls } }
        let source = try XCTUnwrap(browser.candidates.first { $0.kind == .hls })
        let prepared = await browser.prepareForDownload(source)
        XCTAssertEqual(prepared?.title, "来源不明时的回退")
        XCTAssertEqual(prepared?.url, source.url)
    }
}
