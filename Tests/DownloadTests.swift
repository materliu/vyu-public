import XCTest
@testable import VYu

final class CookiePolicyTests: XCTestCase {
    func cookie(_ name: String = "session", domain: String, path: String = "/", secure: Bool = false, expiry: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "test-value", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expiry { properties[.expires] = expiry }
        return HTTPCookie(properties: properties)!
    }
    func testDomainBoundaryAndHostOnlyCookie() {
        let cookies = [cookie("host", domain: "video.example"), cookie("domain", domain: ".video.example")]
        XCTAssertEqual(MediaCookiePolicy.matching(cookies, for: URL(string: "https://video.example/movie")!).count, 2)
        XCTAssertEqual(MediaCookiePolicy.matching(cookies, for: URL(string: "https://cdn.video.example/movie")!).map(\.name), ["domain"])
        XCTAssertTrue(MediaCookiePolicy.matching(cookies, for: URL(string: "https://evilvideo.example/movie")!).isEmpty)
        XCTAssertTrue(MediaCookiePolicy.matching(cookies, for: URL(string: "https://video.example.evil.test/movie")!).isEmpty)
    }
    func testPathBoundarySecureAndExpiry() {
        let now = Date()
        let cookies = [cookie("path", domain: "video.example", path: "/private"),
                       cookie("secure", domain: "video.example", secure: true),
                       cookie("expired", domain: "video.example", expiry: now.addingTimeInterval(-10))]
        XCTAssertEqual(Set(MediaCookiePolicy.matching(cookies, for: URL(string: "https://video.example/private/movie")!, now: now).map(\.name)), ["path", "secure"])
        XCTAssertEqual(MediaCookiePolicy.matching(cookies, for: URL(string: "http://video.example/private-other")!, now: now).count, 0)
        XCTAssertEqual(MediaCookiePolicy.matching(cookies, for: URL(string: "http://video.example/private")!, now: now).map(\.name), ["path"])
    }
    func testRequestDoesNotLeakPageQueryOrOtherSiteCookies() {
        let request = MediaCookiePolicy.request(url: URL(string: "https://cdn.example/movie.mp4")!,
            cookies: [cookie(domain: "page.example"), cookie("media", domain: "cdn.example")],
            pageURL: URL(string: "https://page.example/watch?token=secret#private")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "media=test-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://page.example/")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }
    func testSameOriginReferrerKeepsFramePathWithoutPrivateQuery() {
        let request = MediaCookiePolicy.request(url: URL(string: "https://video.example:443/media/movie.mp4")!, cookies: [],
            pageURL: URL(string: "https://video.example/player/embed?id=private#position")!, userAgent: "WebKit fixture agent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://video.example/player/embed")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WebKit fixture agent")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        let crossPort = MediaCookiePolicy.request(url: URL(string: "https://video.example:8443/movie.mp4")!, cookies: [],
            pageURL: URL(string: "https://video.example/player/embed")!)
        XCTAssertEqual(crossPort.value(forHTTPHeaderField: "Referer"), "https://video.example/")
    }
    func testReferrerIsNotSentOnTransportDowngrade() {
        let request = MediaCookiePolicy.request(url: URL(string: "http://video.example/movie.mp4")!, cookies: [],
            pageURL: URL(string: "https://video.example/private/player")!)
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    }
    func testRequestHonorsObservedReferrerPolicyWithoutSendingPageSecrets() {
        let frame = URL(string: "https://video.example/embed/player?private=value#position")!
        let sameOrigin = URL(string: "https://video.example/movie.m3u8")!
        let crossOrigin = URL(string: "https://cdn.example/movie.m3u8")!
        let downgrade = URL(string: "http://cdn.example/movie.m3u8")!
        let full = "https://video.example/embed/player", origin = "https://video.example/"
        let cases: [(MediaRequestContext.ReferrerPolicy, String?, String?, String?)] = [
            (.noReferrer, nil, nil, nil),
            (.sameOrigin, full, nil, nil),
            (.strictOrigin, origin, origin, nil),
            (.origin, origin, origin, origin),
            (.strictOriginWhenCrossOrigin, full, origin, nil),
            (.originWhenCrossOrigin, full, origin, origin),
            (.noReferrerWhenDowngrade, full, full, nil),
            (.unsafeURL, full, full, full)
        ]
        for (policy, same, cross, downgraded) in cases {
            for (url, expected) in [(sameOrigin, same), (crossOrigin, cross), (downgrade, downgraded)] {
                let request = MediaCookiePolicy.request(url: url, cookies: [], pageURL: frame,
                    context: MediaRequestContext(corsMode: .none, referrerPolicy: policy))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), expected, "\(policy) for \(url)")
                XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            }
        }
    }
    func testAnonymousMediaOnlySendsCookiesToTheOwningFrameOrigin() {
        let frame = URL(string: "https://video.example/player")!
        let context = MediaRequestContext(corsMode: .anonymous, referrerPolicy: .noReferrer)
        let cookies = [cookie(domain: ".video.example")]
        let sameOrigin = MediaCookiePolicy.request(url: URL(string: "https://video.example:443/movie.m3u8")!,
            cookies: cookies, pageURL: frame, context: context)
        XCTAssertEqual(sameOrigin.value(forHTTPHeaderField: "Cookie"), "session=test-value")
        XCTAssertEqual(sameOrigin.value(forHTTPHeaderField: "Origin"), "https://video.example")
        XCTAssertNil(sameOrigin.value(forHTTPHeaderField: "Referer"))
        for url in ["https://cdn.video.example/movie.m3u8", "https://video.example:8443/movie.m3u8"] {
            let crossOrigin = MediaCookiePolicy.request(url: URL(string: url)!, cookies: cookies, pageURL: frame, context: context)
            XCTAssertNil(crossOrigin.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(crossOrigin.value(forHTTPHeaderField: "Origin"), "https://video.example")
        }
        let unknownFrame = MediaCookiePolicy.request(url: frame, cookies: cookies, context: context)
        XCTAssertNil(unknownFrame.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(unknownFrame.value(forHTTPHeaderField: "Origin"))
    }
    func testCredentialedMediaUsesActualFrameOriginAndOnlyTargetCookies() {
        let request = MediaCookiePolicy.request(url: URL(string: "https://cdn.example/movie.m3u8")!,
            cookies: [cookie("page", domain: "frame.example"), cookie("media", domain: "cdn.example")],
            pageURL: URL(string: "https://frame.example:8443/embed?private=value")!,
            context: MediaRequestContext(corsMode: .useCredentials, referrerPolicy: .sameOrigin))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "media=test-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://frame.example:8443")
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    }
    func testClientRedirectRetainsContextAndDropsAnonymousCrossOriginCookies() {
        var candidate = MediaCandidate(url: URL(string: "https://media.example/private/master.m3u8")!,
            pageURL: URL(string: "https://outer.example/watch")!, frameURL: URL(string: "https://media.example/embed")!,
            title: "test", kind: .hls, source: "test")
        candidate.userAgent = "WebKit fixture agent"
        candidate.requestContext = MediaRequestContext(corsMode: .anonymous, referrerPolicy: .noReferrer)
        let client = MediaHTTPClient(candidate: candidate, cookies: [cookie(domain: ".media.example")])
        XCTAssertEqual(client.request(candidate.url).value(forHTTPHeaderField: "Cookie"), "session=test-value")
        let task = client.session.dataTask(with: candidate.url)
        var redirect = URLRequest(url: URL(string: "https://cdn.media.example/private/master.m3u8")!)
        redirect.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        redirect.setValue("https://untrusted.example/", forHTTPHeaderField: "Referer")
        redirect.setValue("https://untrusted.example", forHTTPHeaderField: "Origin")
        redirect.setValue("injected=secret", forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(url: candidate.url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        client.urlSession(client.session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { result in
            XCTAssertNotNil(result)
            XCTAssertNil(result?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(result?.value(forHTTPHeaderField: "Referer"))
            XCTAssertEqual(result?.value(forHTTPHeaderField: "Origin"), "https://media.example")
            XCTAssertEqual(result?.value(forHTTPHeaderField: "User-Agent"), "WebKit fixture agent")
            XCTAssertEqual(result?.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
        }
        client.close()
    }
    func testAnonymousClientNeverAddsCookiesExcludedFromInitialRequest() {
        var candidate = MediaCandidate(url: URL(string: "https://cdn.media.example/master.m3u8")!,
            pageURL: URL(string: "https://media.example/watch")!, frameURL: URL(string: "https://media.example/watch")!,
            title: "test", kind: .hls, source: "test")
        candidate.requestContext = MediaRequestContext(corsMode: .anonymous, referrerPolicy: .strictOriginWhenCrossOrigin)
        let client = MediaHTTPClient(candidate: candidate, cookies: [cookie(domain: ".media.example")])
        XCTAssertTrue(client.cookies.isEmpty)
        XCTAssertNil(client.request(candidate.url).value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(client.request(URL(string: "https://media.example/redirected.m3u8")!).value(forHTTPHeaderField: "Cookie"))
        client.close()
    }
    func testCredentialedClientDoesNotBroadenInitialCookieScopeOnRedirect() {
        var candidate = MediaCandidate(url: URL(string: "https://media.example/master.m3u8")!,
            pageURL: URL(string: "https://frame.example/watch")!, frameURL: URL(string: "https://frame.example/watch")!,
            title: "test", kind: .hls, source: "test")
        candidate.requestContext = MediaRequestContext(corsMode: .useCredentials, referrerPolicy: .noReferrer)
        let client = MediaHTTPClient(candidate: candidate,
            cookies: [cookie("initial", domain: "media.example"), cookie("other", domain: "other.example")])
        XCTAssertEqual(client.cookies.map(\.name), ["initial"])
        let request = client.request(URL(string: "https://other.example/redirected.m3u8")!)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://frame.example")
        client.close()
    }
    func testUserAgentRejectsControlCharactersAndOversizeInput() {
        for invalid in ["", "browser\r\nCookie: secret", "browser\0", String(repeating: "a", count: 1_025)] {
            XCTAssertNil(MediaCookiePolicy.validUserAgent(invalid))
        }
        XCTAssertEqual(MediaCookiePolicy.validUserAgent("Mozilla/5.0 (iPhone) AppleWebKit/605.1.15"),
            "Mozilla/5.0 (iPhone) AppleWebKit/605.1.15")
    }
    func testClientUsesOwningFrameAndRetainsUserAgentAcrossRedirects() {
        var candidate = MediaCandidate(url: URL(string: "https://media.example/private/video.mp4")!,
            pageURL: URL(string: "https://outer.example/watch")!, frameURL: URL(string: "https://media.example/embed/player?secret=value")!,
            title: "test", kind: .file, source: "test")
        candidate.userAgent = "WebKit fixture agent"
        let client = MediaHTTPClient(candidate: candidate, cookies: [])
        XCTAssertEqual(client.request(candidate.url).value(forHTTPHeaderField: "Referer"), "https://media.example/embed/player")
        let task = client.session.dataTask(with: candidate.url)
        var redirected = URLRequest(url: URL(string: "https://cdn.example/video.mp4")!)
        redirected.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let response = HTTPURLResponse(url: candidate.url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        client.urlSession(client.session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { result in
            XCTAssertEqual(result?.value(forHTTPHeaderField: "Referer"), "https://media.example/")
            XCTAssertEqual(result?.value(forHTTPHeaderField: "User-Agent"), "WebKit fixture agent")
            XCTAssertEqual(result?.value(forHTTPHeaderField: "Range"), "bytes=0-0")
            XCTAssertNil(result?.value(forHTTPHeaderField: "Origin"))
        }
        client.close()
    }
    func testRejectsNonHTTPAndEmbeddedCredentials() {
        for raw in ["file:///private/secret", "blob:https://video.example/id", "https://user:pass@video.example/movie", "javascript:alert(1)"] {
            XCTAssertFalse(MediaCookiePolicy.validHTTPURL(URL(string: raw)!))
        }
    }
    func testRedirectDropsCredentialsAndRescopesCookie() {
        let candidate = MediaCandidate(url: URL(string: "https://media.example/private/video.mp4")!,
            pageURL: URL(string: "https://page.example/watch")!, frameURL: URL(string: "https://page.example/watch")!, title: "test", kind: .file, source: "test")
        let client = MediaHTTPClient(candidate: candidate, cookies: [cookie(domain: "media.example", path: "/private"), cookie("other", domain: "elsewhere.example")])
        let task = client.session.dataTask(with: candidate.url)
        var redirected = URLRequest(url: URL(string: "https://elsewhere.example/video.mp4")!)
        redirected.setValue("secret", forHTTPHeaderField: "Authorization")
        redirected.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(url: candidate.url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        client.urlSession(client.session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { result in
            XCTAssertNotNil(result)
            XCTAssertNil(result?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(result?.value(forHTTPHeaderField: "Authorization"))
        }
        client.close()
    }
}

final class MediaFileResponseTests: XCTestCase {
    private func response(_ status: Int = 200, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://media.example/video.mp4")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
    func testRangeProbeUsesTotalSizeInsteadOfOneByteContentLength() {
        XCTAssertEqual(MediaFileResponse.expectedBytes(response(206, headers: ["Content-Length": "1", "Content-Range": "bytes 0-0/123456"])), 123456)
        XCTAssertEqual(MediaFileResponse.expectedBytes(response(headers: ["Content-Length": "123456"])), 123456)
    }
    func testInvalidOrUnknownContentRangeCannotBecomeExpectedTotal() {
        for range in ["bytes 0-0/*", "bytes 0-0/0", "bytes 5-2/10", "bytes 0-12/10", "items 0-0/123456", "123456"] {
            XCTAssertNil(MediaFileResponse.expectedBytes(response(206, headers: ["Content-Length": "1", "Content-Range": range])))
        }
        XCTAssertNil(MediaFileResponse.expectedBytes(response(206, headers: ["Content-Length": "1"])))
    }
    func testLoginAndErrorDocumentsAreNotOfferedAsVideoFiles() {
        for type in ["text/html; charset=utf-8", "application/xhtml+xml", "application/json", "application/problem+json"] {
            XCTAssertTrue(MediaFileResponse.isWebPage(response(headers: ["Content-Type": type])))
        }
        for type in ["video/mp4", "application/octet-stream", "binary/octet-stream"] {
            XCTAssertFalse(MediaFileResponse.isWebPage(response(headers: ["Content-Type": type])))
        }
    }
    func testForbiddenMessageReportsStatusWithoutClaimingExpiry() {
        let message = DownloadIssue.http(403).localizedDescription
        XCTAssertTrue(message.contains("HTTP 403"))
        XCTAssertFalse(message.contains("过期"))
    }
}

final class HLSManifestTests: XCTestCase {
    let base = URL(string: "https://cdn.example/media/master.m3u8?token=parent")!
    func testMasterVariantsAndSeparateAudioResolveRelativeURLs() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="中文, 原声",LANGUAGE="zh",URI="audio/main.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,AUDIO="a"
        video/720.m3u8?token=variant
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080,AUDIO="a"
        /video/1080.m3u8
        """
        let manifest = try HLSManifest.parse(text, relativeTo: base)
        XCTAssertTrue(manifest.isMaster)
        XCTAssertEqual(manifest.variants.count, 2)
        XCTAssertEqual(manifest.variants[0].url.absoluteString, "https://cdn.example/media/video/720.m3u8?token=variant")
        XCTAssertEqual(manifest.variants[1].resolution, "1920x1080")
        XCTAssertEqual(manifest.audioTracks.first?.name, "中文, 原声")
        XCTAssertEqual(manifest.audioTracks.first?.url?.absoluteString, "https://cdn.example/media/audio/main.m3u8")
    }
    func testVODDurationAndLiveAreDifferent() throws {
        let text = "#EXTM3U\n#EXTINF:4.0,\n1.ts\n#EXTINF:3.5,\n2.ts\n"
        let live = try HLSManifest.parse(text, relativeTo: base)
        let vod = try HLSManifest.parse(text + "#EXT-X-ENDLIST\n", relativeTo: base)
        XCTAssertFalse(live.isVOD); XCTAssertTrue(vod.isVOD)
        XCTAssertEqual(vod.duration, 7.5)
        XCTAssertFalse(vod.encrypted)
    }
    func testKeyAndSessionKeyDetectProtection() throws {
        for key in ["#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"", "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key.bin\""] {
            let manifest = try HLSManifest.parse("#EXTM3U\n" + key, relativeTo: base)
            XCTAssertTrue(manifest.encrypted)
        }
        XCTAssertFalse(try HLSManifest.parse("#EXTM3U\n#EXT-X-KEY:METHOD=NONE", relativeTo: base).encrypted)
    }
    func testRejectsExcessVariantsAndAudioBeforePreflightFanout() {
        let variants = "#EXTM3U\n" + (0..<13).map { "#EXT-X-STREAM-INF:BANDWIDTH=100000\nvariant-\($0).m3u8" }.joined(separator: "\n")
        let audio = "#EXTM3U\n" + (0..<17).map { "#EXT-X-MEDIA:TYPE=AUDIO,NAME=\"track-\($0)\",URI=\"audio-\($0).m3u8\"" }.joined(separator: "\n")
        XCTAssertThrowsError(try HLSManifest.parse(variants, relativeTo: base))
        XCTAssertThrowsError(try HLSManifest.parse(audio, relativeTo: base))
    }
    func testRejectsNonPlaylistAndLocalMediaReferences() {
        for text in ["<html>login</html>", "#EXTM3U\n#EXTINF:4,\nfile:///etc/passwd\n#EXT-X-ENDLIST", "#EXTM3U\n#EXT-X-MAP:URI=\"file:///secret\"\n#EXT-X-ENDLIST"] {
            XCTAssertThrowsError(try HLSManifest.parse(text, relativeTo: base))
        }
    }
}

@MainActor final class DownloadLifecycleTests: XCTestCase {
    private func seeded(phase: DownloadPhase = .complete, path: String? = "Media/test.mp4", createFile: Bool = true) throws -> (DownloadManager, URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        if createFile { try Data("local-test-data".utf8).write(to: root.appendingPathComponent("Media/test.mp4")) }
        let url = URL(string: "https://fixture.invalid/test.mp4")!
        let candidate = MediaCandidate(url: url, pageURL: url, frameURL: url, title: "Test", kind: .file, source: "test")
        let id = UUID()
        let record = DownloadRecord(id: id, candidate: candidate, phase: phase, progress: 1, bytesWritten: 15,
            expectedBytes: 15, localRelativePath: path, failure: nil, duration: 8, hasAudio: true, createdAt: Date())
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("downloads.json"))
        return (DownloadManager(rootDirectory: root), root, id)
    }
    private func persistedRecords(_ root: URL) throws -> [DownloadRecord] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("downloads.json"))) as? [String: Any])
        return try JSONDecoder().decode([DownloadRecord].self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object["records"])))
    }
    func testCacheRemovalPreservesRecordAndPersistsCancellation() throws {
        let (manager, root, id) = try seeded()
        manager.removeCache(id: id)
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertNil(manager.records.first?.localRelativePath)
        XCTAssertEqual(manager.records.first?.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Media/test.mp4").path))
        let stored = try persistedRecords(root)
        XCTAssertEqual(stored.first?.phase, .cancelled)
    }
    func testRecordRemovalDeletesItsCache() throws {
        let (manager, root, id) = try seeded()
        manager.removeRecord(id: id)
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Media/test.mp4").path))
    }
    func testMissingCompleteCacheBecomesFailure() throws {
        let (manager, _, _) = try seeded(createFile: false)
        XCTAssertEqual(manager.records.first?.phase, .failed)
        XCTAssertNil(manager.localURL(for: manager.records[0]))
    }
    func testStoredPathCannotEscapeLibrary() throws {
        let (manager, _, _) = try seeded(path: "../../private.txt")
        XCTAssertNil(manager.localURL(for: manager.records[0]))
        XCTAssertEqual(manager.records.first?.phase, .failed)
    }
    func testCancelIsDurableAndLeavesRecord() throws {
        let (manager, root, id) = try seeded(phase: .paused, path: nil)
        manager.cancel(id: id)
        XCTAssertEqual(manager.records.first?.phase, .cancelled)
        let stored = try persistedRecords(root)
        XCTAssertEqual(stored.count, 1); XCTAssertEqual(stored[0].phase, .cancelled)
    }
    func testUnsupportedCandidateFailsWithoutCreatingCache() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-unsupported-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: root)
        let url = URL(string: "https://fixture.invalid/video.mpd")!
        let candidate = MediaCandidate(url: url, pageURL: url, frameURL: url, title: "DASH", kind: .dash, source: "test")
        await manager.start(candidate: candidate, cookies: [])
        XCTAssertEqual(manager.records.first?.phase, .failed)
        XCTAssertNil(manager.records.first?.localRelativePath)
        XCTAssertTrue(manager.records.first?.failure?.contains("DASH") ?? false)
    }
}

final class HLSLocalAssetLocationTests: XCTestCase {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().appendingPathComponent("HLSPathTests")
    func testNoFollowLocationRoundTripsWithoutLosingKernelPrefix() throws {
        let location = URL(fileURLWithPath: "/.nofollow" + home.path + "/Library/Assets/movie.movpkg")
        let relative = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: home))
        XCTAssertEqual(relative, "system-original/raw-nofollow/Library/Assets/movie.movpkg")
        XCTAssertEqual(HLSLocalAssetLocation.url(for: relative, home: home)?.path, "/.nofollow" + home.path + "/Library/Assets/movie.movpkg")
    }
    func testPlainLocationRoundTrips() throws {
        let location = home.appendingPathComponent("Library/Assets/movie.movpkg")
        let relative = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: home))
        XCTAssertEqual(relative, "system-original/raw/Library/Assets/movie.movpkg")
        XCTAssertEqual(HLSLocalAssetLocation.url(for: relative, home: home)?.pathExtension, "movpkg")
    }
    func testDirectoryHintSurvivesBeforePackageCreationForPlainAndNoFollowURLs() throws {
        for prefix in ["", "/.nofollow"] {
            let location = URL(fileURLWithPath: prefix + home.path + "/Library/Assets/not-created.movpkg", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
            let relative = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: home))
            XCTAssertTrue(relative.hasSuffix(".movpkg/"))
            let restored = try XCTUnwrap(HLSLocalAssetLocation.url(for: relative, home: home))
            XCTAssertTrue(restored.hasDirectoryPath)
            XCTAssertEqual(restored.absoluteString, location.absoluteString)
        }
    }
    func testExplicitNonDirectoryHintIsNotChangedWhenPackageAlreadyExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-HLS-location-" + UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("movie.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = root.resolvingSymlinksInPath()
        for prefix in ["", "/.nofollow"] {
            let location = URL(fileURLWithPath: prefix + canonicalRoot.path + "/movie.movpkg", isDirectory: false)
            let relative = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: root))
            let restored = try XCTUnwrap(HLSLocalAssetLocation.url(for: relative, home: root))
            XCTAssertFalse(restored.hasDirectoryPath)
            XCTAssertEqual(restored.absoluteString, location.absoluteString)
        }
    }
    func testRestorationRejectsSymlinkThatEscapesTheOwnedContainer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-HLS-scope-" + UUID().uuidString, isDirectory: true)
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let outside = root.appendingPathComponent("outside.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = owned.appendingPathComponent("escape.movpkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(HLSLocalAssetLocation.relativePath(for: link, home: owned))
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system/escape.movpkg", home: owned))
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system-nofollow/escape.movpkg/", home: owned))
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system-original/raw/escape.movpkg/", home: owned))
    }
    func testOriginalLocationRetainsContainerAliasAndEscapedNamesAfterReconstruction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-HLS-alias-" + UUID().uuidString, isDirectory: true)
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        let relative = "Library/Assets/movie #100%.movpkg"
        try FileManager.default.createDirectory(at: physical.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = alias.appendingPathComponent(relative, isDirectory: true)
        let saved = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: alias))
        XCTAssertTrue(saved.hasPrefix("system-original/bookmark/"))
        let restored = try XCTUnwrap(HLSLocalAssetLocation.url(for: saved, home: alias))
        XCTAssertEqual(restored.absoluteString, location.absoluteString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertTrue(restored.hasDirectoryPath)

        // A system callback can instead use the physical container root even
        // while NSHomeDirectory names an alias. Preserve that form too.
        let resolvedLocation = physical.resolvingSymlinksInPath().appendingPathComponent(relative, isDirectory: true)
        let resolvedSaved = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: resolvedLocation, home: alias))
        XCTAssertTrue(resolvedSaved.hasPrefix("system-original/bookmark/"))
        XCTAssertEqual(HLSLocalAssetLocation.url(for: resolvedSaved, home: alias)?.absoluteString, resolvedLocation.absoluteString)
    }
    func testOriginalLocationRemainsRelativeWhenContainerRootChanges() throws {
        let previous = URL(fileURLWithPath: "/synthetic/old-container", isDirectory: true)
        let current = URL(fileURLWithPath: "/synthetic/new-container", isDirectory: true)
        let location = URL(fileURLWithPath: "/.nofollow" + previous.path + "/Library/Assets/movie.movpkg", isDirectory: true)
        let saved = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: previous))
        XCTAssertFalse(saved.contains("old-container"))
        let restored = try XCTUnwrap(HLSLocalAssetLocation.url(for: saved, home: current))
        XCTAssertEqual(restored.absoluteString, "file:///.nofollow/synthetic/new-container/Library/Assets/movie.movpkg/")
    }
    func testExternalSystemAliasPreservesOriginalURLAndRechecksContainment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-HLS-system-alias-" + UUID().uuidString, isDirectory: true)
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let assets = owned.appendingPathComponent("Library/Assets", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let alias = root.appendingPathComponent("system-alias", isDirectory: true)
        let name = "movie #100%.movpkg"
        try FileManager.default.createDirectory(at: assets.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: assets)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = URL(fileURLWithPath: alias.appendingPathComponent(name).path, isDirectory: false)
        // Read the previously released absolute format as well as bookmarks.
        let saved = "system-original/absolute/" + Data(location.absoluteString.utf8).base64EncodedString()
        XCTAssertTrue(HLSLocalAssetLocation.isSystemPath(saved))
        let restored = try XCTUnwrap(HLSLocalAssetLocation.url(for: saved, home: owned))
        XCTAssertEqual(restored.absoluteString, location.absoluteString)
        XCTAssertFalse(restored.hasDirectoryPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))

        let noFollow = URL(fileURLWithPath: "/.nofollow" + location.path, isDirectory: false)
        let noFollowSaved = "system-original/absolute/" + Data(noFollow.absoluteString.utf8).base64EncodedString()
        XCTAssertEqual(HLSLocalAssetLocation.url(for: noFollowSaved, home: owned)?.absoluteString, noFollow.absoluteString)
        XCTAssertNil(HLSLocalAssetLocation.url(for: saved, home: outside), "An alias to another container must never be restored.")

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertNil(HLSLocalAssetLocation.url(for: saved, home: owned), "A changed alias must be checked on every restoration.")
        XCTAssertNil(HLSLocalAssetLocation.url(for: noFollowSaved, home: owned))
    }
    func testBookmarkRestoresPackageAfterContainerMoves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-HLS-bookmark-" + UUID().uuidString, isDirectory: true)
        let previous = root.appendingPathComponent("previous", isDirectory: true)
        let current = root.appendingPathComponent("current", isDirectory: true)
        let alias = root.appendingPathComponent("system-alias", isDirectory: true)
        let suffix = "Library/Assets/movie.movpkg"
        try FileManager.default.createDirectory(at: previous.appendingPathComponent(suffix, isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: previous)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = alias.appendingPathComponent(suffix, isDirectory: true)
        let saved = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: location, home: previous))
        XCTAssertTrue(saved.hasPrefix("system-original/bookmark/"))
        XCTAssertEqual(HLSLocalAssetLocation.url(for: saved, home: previous)?.absoluteString, location.absoluteString)
        try FileManager.default.moveItem(at: previous, to: current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        let restored = try XCTUnwrap(HLSLocalAssetLocation.url(for: saved, home: current))
        XCTAssertEqual(restored.resolvingSymlinksInPath().path, current.appendingPathComponent(suffix).resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertNil(HLSLocalAssetLocation.url(for: saved, home: previous))
    }
    func testBookmarkRejectsPackageMovedOutsideCurrentContainer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-HLS-bookmark-scope-" + UUID().uuidString, isDirectory: true)
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let package = owned.appendingPathComponent("movie.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try XCTUnwrap(HLSLocalAssetLocation.relativePath(for: package, home: owned))
        XCTAssertTrue(saved.hasPrefix("system-original/bookmark/"))
        try FileManager.default.moveItem(at: package, to: root.appendingPathComponent("outside.movpkg", isDirectory: true))
        XCTAssertNil(HLSLocalAssetLocation.url(for: saved, home: owned))
    }
    func testBookmarkRejectsMalformedOrOversizedPayload() {
        for encoded in ["invalid-base64", Data("{}".utf8).base64EncodedString(), String(repeating: "A", count: 196_609)] {
            XCTAssertNil(HLSLocalAssetLocation.url(for: "system-original/bookmark/" + encoded, home: home))
        }
    }
    func testAbsoluteSystemFormatRejectsInvalidAndUnownedURLs() {
        for invalid in ["https://example.org/movie.movpkg", "file:///tmp/outside/movie.movpkg", "relative.movpkg",
                        home.appendingPathComponent("movie.movpkg").absoluteString + "?query=1",
                        home.appendingPathComponent("movie.movpkg").absoluteString + "#fragment"] {
            let saved = "system-original/absolute/" + Data(invalid.utf8).base64EncodedString()
            XCTAssertNil(HLSLocalAssetLocation.url(for: saved, home: home))
        }
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system-original/absolute/invalid-base64", home: home))
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system-original/absolute/" + Data([0xff]).base64EncodedString(), home: home))
    }
    func testLegacyFormatsStillRestoreAndOriginalFormatRejectsEscapes() throws {
        XCTAssertNotNil(HLSLocalAssetLocation.url(for: "system/Library/Assets/movie.movpkg", home: home))
        XCTAssertNotNil(HLSLocalAssetLocation.url(for: "system-nofollow/Library/Assets/movie.movpkg", home: home))
        for invalid in ["system-original/raw/../../escape.movpkg", "system-original/raw/%2E%2E/%2E%2E/escape.movpkg",
                        "system-original/raw//outside.movpkg", "system-original/raw/movie.movpkg?query=1",
                        "system-original/raw/movie.movpkg#fragment", "system-original/invalid/movie.movpkg"] {
            XCTAssertNil(HLSLocalAssetLocation.url(for: invalid, home: home), invalid)
        }
    }
    func testRejectsContainerEscapesAndNonFileURLs() {
        XCTAssertNil(HLSLocalAssetLocation.relativePath(for: URL(fileURLWithPath: "/.nofollow/tmp/another-app/asset.movpkg"), home: home))
        XCTAssertNil(HLSLocalAssetLocation.relativePath(for: URL(string: "https://example.org/asset.movpkg")!, home: home))
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system-nofollow/../../another-app/asset.movpkg", home: home))
        XCTAssertNil(HLSLocalAssetLocation.url(for: "system/Library/records.json", home: home))
    }
}

final class HLSPreflightBoundaryTests: XCTestCase {
    private let root = URL(string: "https://fixture.invalid/master.m3u8")!

    func testLiveAlternativeIsExcludedWhileCompleteVODRemainsAvailable() async throws {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nlive.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nvod.m3u8\n"
        let result = try await HLSPreflight.inspect(root) { target in
            let text = target == self.root ? master : "#EXTM3U\n#EXTINF:8,\nsegment.ts\n" + (target.lastPathComponent == "vod.m3u8" ? "#EXT-X-ENDLIST\n" : "")
            return (try HLSManifest.parse(text, relativeTo: target), target)
        }
        XCTAssertEqual(result.variants.map(\.url.lastPathComponent), ["vod.m3u8"])
        XCTAssertEqual(result.hlsDownloadURL?.lastPathComponent, "vod.m3u8")
        XCTAssertEqual(result.expectedDuration, 8)
    }

    func testLiveMainPlaylistCannotBecomeDownloadable() async throws {
        do {
            _ = try await HLSPreflight.inspect(root) { target in
                (try HLSManifest.parse("#EXTM3U\n#EXTINF:8,\nsegment.ts\n", relativeTo: target), target)
            }
            XCTFail("A live playlist must remain unsupported.")
        } catch {
            guard case DownloadIssue.playlistProblem(.main, .live) = error else { return XCTFail("Wrong live failure.") }
        }
    }

    func testEndListWithoutPositiveFiniteDurationCannotPassInspection() async throws {
        for duration in ["0", "-8", "nan", "inf"] {
            do {
                _ = try await HLSPreflight.inspect(root) { target in
                    (try HLSManifest.parse("#EXTM3U\n#EXTINF:\(duration),\nsegment.ts\n#EXT-X-ENDLIST\n", relativeTo: target), target)
                }
                XCTFail("An invalid duration must not become a validated offline expectation: \(duration)")
            } catch {
                guard case DownloadIssue.playlistProblem(.main, .invalid) = error else { return XCTFail("Wrong duration failure.") }
            }
        }
    }

    func testCancelledInspectionDoesNotContinueToAnotherVariant() async throws {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nfirst.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nsecond.m3u8\n"
        let task = Task {
            try await HLSPreflight.inspect(root) { target in
                if target == self.root { return (try HLSManifest.parse(master, relativeTo: target), target) }
                XCTAssertEqual(target.lastPathComponent, "first.m3u8", "Cancellation must stop before any later variant request.")
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not become a downloadable result.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Cancellation must not be rewritten as a network failure.")
        }
    }
}
