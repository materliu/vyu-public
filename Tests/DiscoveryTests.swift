import XCTest
@testable import VYu

final class DiscoveryTests: XCTestCase {
    private func context(token: String = "current", frame: String = "https://video.example/watch",
                         scheme: String = "https", host: String = "video.example", port: Int = 0) -> DiscoveryMessageContext {
        DiscoveryMessageContext(navigationToken: token, pageURL: URL(string: "https://site.example/page")!,
                                frameRequestURL: URL(string: frame), originScheme: scheme, originHost: host, originPort: port)
    }

    private func body(url: String = "https://cdn.example/movie.mp4", document: String = "https://video.example/watch",
                      token: String = "current", source: String = "video", event: String = "candidate", mime: String = "") -> [String: Any] {
        ["token": token, "documentURL": document, "url": url, "title": "视频", "source": source, "event": event, "mime": mime]
    }

    private func candidate(_ fields: [String: Any], context: DiscoveryMessageContext? = nil) throws -> MediaCandidate {
        guard case .candidate(let result) = try MediaMessageValidator.validate(fields, context: context ?? self.context()) else {
            throw DiscoveryValidationError.malformed
        }
        return result
    }

    func testAcceptsCrossOriginMediaWithoutTrustingClaimedPageURL() throws {
        let result = try candidate(body())
        XCTAssertEqual(result.url.host, "cdn.example")
        XCTAssertEqual(result.frameURL.host, "video.example")
        XCTAssertEqual(result.pageURL.host, "site.example")
        XCTAssertEqual(result.kind, .file)
    }

    func testCandidateIdentityKeepsFrameAndPageRequestContextsDistinct() throws {
        let first = try candidate(body())
        let secondFrame = "https://video.example/other-frame"
        let second = try candidate(body(document: secondFrame), context: context(frame: secondFrame))
        XCTAssertEqual(first.url, second.url)
        XCTAssertNotEqual(first.id, second.id)
        let anotherPage = MediaCandidate(url: first.url, pageURL: URL(string: "https://site.example/other-page")!,
            frameURL: first.frameURL, title: first.title, kind: first.kind, source: first.source)
        XCTAssertNotEqual(first.id, anotherPage.id)

        // Metadata and UA enrichment must not change the selected row's identity.
        let enriched = MediaCandidate(url: first.url, pageURL: first.pageURL, frameURL: first.frameURL,
            title: "Updated title", kind: first.kind, source: "fetch", mimeType: "video/mp4", userAgent: "Fixture Agent")
        XCTAssertEqual(first.id, enriched.id)
    }

    func testCandidateContextIdentityDoesNotChangeStoredSchema() throws {
        let legacy: [String: String] = [
            "url": "https://cdn.example/movie.mp4", "pageURL": "https://site.example/page",
            "frameURL": "https://video.example/watch", "title": "视频", "kind": "file", "source": "video"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(MediaCandidate.self, from: data)
        XCTAssertEqual(decoded.id, try candidate(body()).id)
        let encoded = try JSONEncoder().encode(decoded)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(legacy.keys), "Computed identity must not migrate saved download records.")
    }

    func testRejectsOldDocumentIncludingIframe() {
        XCTAssertThrowsError(try candidate(body(token: "previous"))) {
            XCTAssertEqual($0 as? DiscoveryValidationError, .staleNavigation)
        }
    }

    func testRejectsClaimedDocumentOriginMismatch() {
        XCTAssertThrowsError(try candidate(body(document: "https://other.example/watch"))) {
            XCTAssertEqual($0 as? DiscoveryValidationError, .originMismatch)
        }
    }

    func testRejectsWebKitSecurityOriginMismatch() {
        XCTAssertThrowsError(try candidate(body(), context: context(host: "attacker.example")))
        XCTAssertThrowsError(try candidate(body(), context: context(scheme: "http")))
        XCTAssertThrowsError(try candidate(body(), context: context(port: 8443)))
    }

    func testDefaultAndExplicitPortsMatch() throws {
        _ = try candidate(body(), context: context(port: 443))
        _ = try candidate(body(document: "https://video.example:443/watch"))
    }

    func testRejectsCredentialsEverywhere() {
        XCTAssertThrowsError(try candidate(body(url: "https://person:password@cdn.example/movie.mp4")))
        XCTAssertThrowsError(try candidate(body(document: "https://person:password@video.example/watch")))
        XCTAssertThrowsError(try candidate(body(), context: context(frame: "https://person:password@video.example/watch")))
    }

    func testRejectsBlobDataFileAndJavaScriptURLs() {
        for value in ["blob:https://video.example/id", "data:video/mp4;base64,AAAA", "file:///tmp/movie.mp4", "javascript:alert(1)"] {
            XCTAssertThrowsError(try candidate(body(url: value)))
        }
    }

    func testRejectsOversizedMessageAndBoundedFields() {
        var payload = body()
        payload["title"] = String(repeating: "x", count: 30_000)
        XCTAssertThrowsError(try candidate(payload)) { XCTAssertEqual($0 as? DiscoveryValidationError, .oversized) }
        payload["title"] = String(repeating: "字", count: 400)
        XCTAssertThrowsError(try candidate(payload))
        payload = body(url: "https://cdn.example/" + String(repeating: "a", count: 8_192) + ".mp4")
        XCTAssertThrowsError(try candidate(payload))
        payload = body(mime: String(repeating: "x", count: 257))
        XCTAssertThrowsError(try candidate(payload))
    }

    func testRejectsNestedAndUnexpectedFields() {
        var payload = body(); payload["title"] = ["nested": "value"]
        XCTAssertThrowsError(try candidate(payload))
        payload = body(); payload["cookies"] = "private"
        XCTAssertThrowsError(try candidate(payload))
    }

    func testClassifiesHLSAndDASHUsingPathOrMime() throws {
        XCTAssertEqual(try candidate(body(url: "https://cdn.example/master.m3u8?signature=abc")).kind, .hls)
        XCTAssertEqual(try candidate(body(url: "https://cdn.example/playlist", source: "fetch", mime: "application/vnd.apple.mpegurl; charset=utf-8")).kind, .hls)
        XCTAssertEqual(try candidate(body(url: "https://cdn.example/manifest.mpd")).kind, .dash)
        XCTAssertEqual(try candidate(body(url: "https://cdn.example/manifest", source: "xhr", mime: "application/dash+xml")).kind, .dash)
    }

    func testRejectsUnrelatedPerformanceRequests() {
        XCTAssertThrowsError(try candidate(body(url: "https://cdn.example/api", source: "performance")))
        XCTAssertThrowsError(try candidate(body(url: "https://cdn.example/segment.m4s", source: "performance")))
    }

    func testAllowsExtensionlessVideoElementAndMediaMime() throws {
        XCTAssertEqual(try candidate(body(url: "https://cdn.example/play?id=1")).kind, .file)
        XCTAssertEqual(try candidate(body(url: "https://cdn.example/play?id=1", source: "fetch", mime: "video/mp4")).kind, .file)
    }

    func testSignalsAreNotDownloadableBlobURLs() throws {
        let mse = try MediaMessageValidator.validate(body(url: "", event: "mse"), context: context())
        XCTAssertEqual(mse, .signal(.mediaSource))
        let protected = try MediaMessageValidator.validate(body(url: "", source: "encrypted", event: "protected"), context: context())
        XCTAssertEqual(protected, .signal(.protectedContent))
    }

    func testSignalStillRequiresCurrentNavigationAndOrigin() {
        XCTAssertThrowsError(try MediaMessageValidator.validate(body(token: "old", event: "protected"), context: context()))
        XCTAssertThrowsError(try MediaMessageValidator.validate(body(document: "https://wrong.example", event: "mse"), context: context()))
    }

    func testRejectsControlCharactersAndInvalidPorts() {
        XCTAssertNil(MediaMessageValidator.networkURL("https://example.org/path\n.mp4"))
        XCTAssertNil(MediaMessageValidator.networkURL("https://example.org:70000/file.mp4"))
        XCTAssertNil(MediaMessageValidator.networkURL("https://user@example.org/file.mp4"))
    }

    func testInlineDownloadReturnsOnlyTheRequestedElementSource() throws {
        let fields = body(url: "https://cdn.example/play?id=selected&signature=fresh", event: "download")
        guard case .downloadRequested(let result) = try MediaMessageValidator.validate(fields, context: context()) else {
            return XCTFail("Expected the single video requested from the page")
        }
        XCTAssertEqual(result.url.absoluteString, "https://cdn.example/play?id=selected&signature=fresh")
        XCTAssertEqual(result.frameURL.host, "video.example")
        XCTAssertEqual(result.pageURL.host, "site.example")
        XCTAssertEqual(result.source, "video")
        XCTAssertEqual(result.kind, .file)
    }

    func testInlineDownloadAcceptsVideoSourceHLS() throws {
        let fields = body(url: "https://cdn.example/current.m3u8", source: "source", event: "download")
        guard case .downloadRequested(let result) = try MediaMessageValidator.validate(fields, context: context()) else {
            return XCTFail("Expected the source belonging to this video")
        }
        XCTAssertEqual(result.kind, .hls)
    }

    func testInlineDownloadCannotClaimUnrelatedNetworkDiscovery() {
        for source in ["fetch", "xhr", "performance", "encrypted"] {
            XCTAssertThrowsError(try MediaMessageValidator.validate(body(source: source, event: "download"), context: context())) {
                XCTAssertEqual($0 as? DiscoveryValidationError, .malformed)
            }
        }
    }

    func testInlineDownloadStillChecksNavigationOriginAndURL() {
        let payloads = [
            body(token: "previous", event: "download"),
            body(document: "https://different.example/watch", event: "download"),
            body(url: "https://user:secret@cdn.example/movie.mp4", event: "download"),
            body(url: "blob:https://video.example/id", event: "download"),
            body(url: "file:///tmp/movie.mp4", event: "download")
        ]
        for fields in payloads {
            XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        }
    }

    func testInlineUnavailableReasonsDoNotBecomeCandidates() throws {
        let cases: [(String, InlineDownloadIssue)] = [
            ("download-mse", .mediaSource), ("download-protected", .protectedContent), ("download-unavailable", .noSource)
        ]
        for (event, issue) in cases {
            XCTAssertEqual(try MediaMessageValidator.validate(body(url: "", event: event), context: context()),
                           .downloadUnavailable(issue))
            XCTAssertThrowsError(try MediaMessageValidator.validate(body(event: event), context: context()))
            XCTAssertThrowsError(try MediaMessageValidator.validate(body(url: "", token: "old", event: event), context: context()))
            XCTAssertThrowsError(try MediaMessageValidator.validate(body(url: "", source: "fetch", event: event), context: context()))
        }
    }

    func testVideoAndInlineRequestsRejectPartialSegmentsEvenWithVideoMime() {
        for event in ["candidate", "download"] {
            for ext in ["m4s", "cmfv", "cmfa", "ts"] {
                XCTAssertThrowsError(try MediaMessageValidator.validate(
                    body(url: "https://cdn.example/segment.\(ext)", event: event, mime: "video/mp4"), context: context())) {
                        XCTAssertEqual($0 as? DiscoveryValidationError, .unsupportedMedia)
                    }
            }
        }
    }

    func testInlineDownloadRetainsMessageSizeAndUnknownFieldLimits() {
        var fields = body(event: "download")
        fields["title"] = String(repeating: "x", count: 30_000)
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context())) {
            XCTAssertEqual($0 as? DiscoveryValidationError, .oversized)
        }
        fields = body(event: "download")
        fields["trusted"] = "true"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context())) {
            XCTAssertEqual($0 as? DiscoveryValidationError, .malformed)
        }
    }

    private func alternativeBody(url: String = "https://cdn.example/video.mp4?tag=one",
                                 relatedURL: String = "https://cdn.example/video.m3u8?tag=one") -> [String: Any] {
        var fields = body(url: url, source: "metadata", event: "alternative", mime: "video/mp4")
        fields["relatedURL"] = relatedURL
        return fields
    }

    func testAlternativeRetainsExactPlaylistAndVideoAssociation() throws {
        guard case .alternative(let result, let relatedURL) = try MediaMessageValidator.validate(alternativeBody(), context: context()) else {
            return XCTFail("Expected a same-video MP4 alternative")
        }
        XCTAssertEqual(relatedURL.absoluteString, "https://cdn.example/video.m3u8?tag=one")
        XCTAssertEqual(result.url.absoluteString, "https://cdn.example/video.mp4?tag=one")
        XCTAssertEqual(result.frameURL.host, "video.example")
        XCTAssertEqual(result.pageURL.host, "site.example")
        XCTAssertEqual(result.source, "metadata")
        XCTAssertEqual(result.kind, .file)
    }

    func testAlternativeAcceptsExtensionlessMP4ButRequiresPlaylistExtension() throws {
        _ = try MediaMessageValidator.validate(alternativeBody(url: "https://cdn.example/play?id=1"), context: context())
        XCTAssertThrowsError(try MediaMessageValidator.validate(
            alternativeBody(relatedURL: "https://cdn.example/unknown?id=1"), context: context())) {
                XCTAssertEqual($0 as? DiscoveryValidationError, .unsupportedMedia)
            }
    }

    func testAlternativeRejectsPartialSegmentsAndOtherMediaTypes() {
        for ext in ["m4s", "cmfv", "cmfa", "ts", "m3u8", "mpd", "webm", "mov", "m4v"] {
            XCTAssertThrowsError(try MediaMessageValidator.validate(
                alternativeBody(url: "https://cdn.example/media.\(ext)"), context: context())) {
                    XCTAssertEqual($0 as? DiscoveryValidationError, .unsupportedMedia)
                }
        }
        for mime in ["video/webm", "video/quicktime", "application/vnd.apple.mpegurl", ""] {
            var fields = alternativeBody(); fields["mime"] = mime
            XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        }
    }

    func testAlternativeRejectsInvalidURLsOnBothSides() {
        for url in ["https://user:secret@cdn.example/master.m3u8", "file:///tmp/master.m3u8",
                    "blob:https://cdn.example/id", "javascript:alert(1)", "https://cdn.example/a\n.m3u8",
                    "https://cdn.example:99999/master.m3u8"] {
            XCTAssertThrowsError(try MediaMessageValidator.validate(alternativeBody(relatedURL: url), context: context()))
            XCTAssertThrowsError(try MediaMessageValidator.validate(alternativeBody(url: url), context: context()))
        }
    }

    func testAlternativeStillRequiresCurrentDocumentAndFrameOrigin() {
        var fields = alternativeBody(); fields["token"] = "previous"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context())) {
            XCTAssertEqual($0 as? DiscoveryValidationError, .staleNavigation)
        }
        fields = alternativeBody(); fields["documentURL"] = "https://different.example/watch"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context())) {
            XCTAssertEqual($0 as? DiscoveryValidationError, .originMismatch)
        }
        XCTAssertThrowsError(try MediaMessageValidator.validate(alternativeBody(), context: context(host: "different.example")))
    }

    func testAlternativeSourceAndRelatedURLCannotLeakIntoOtherEventKinds() {
        for source in ["video", "source", "fetch", "xhr", "performance", "encrypted"] {
            var fields = alternativeBody(); fields["source"] = source
            XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context())) {
                XCTAssertEqual($0 as? DiscoveryValidationError, .malformed)
            }
        }
        for event in ["candidate", "download", "protected", "mse", "download-unavailable"] {
            var fields = body(event: event); fields["relatedURL"] = "https://cdn.example/master.m3u8"
            XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
            XCTAssertThrowsError(try MediaMessageValidator.validate(body(source: "metadata", event: event), context: context()))
        }
    }

    func testAlternativeRequiresBoundedStringAssociationAndRejectsPayloadExtras() {
        var fields = alternativeBody(); fields.removeValue(forKey: "relatedURL")
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        fields = alternativeBody(); fields["relatedURL"] = ["url": "https://cdn.example/master.m3u8"]
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        fields = alternativeBody(relatedURL: "https://cdn.example/" + String(repeating: "x", count: 8_192) + ".m3u8")
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        fields = alternativeBody(); fields["response"] = "private body"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
    }

    func testPartialResourceEvidenceUsesValidatedFrameAndNavigation() throws {
        var fields = body(url: "https://cdn.example/init.mp4", source: "fetch", event: "partial", mime: "application/vnd.apple.mpegurl")
        fields["relatedURL"] = "https://cdn.example/video.m3u8"
        let expected = MediaCandidate.ID(url: URL(string: "https://cdn.example/init.mp4")!,
            pageURL: URL(string: "https://site.example/page")!, frameURL: URL(string: "https://video.example/watch")!)
        XCTAssertEqual(try MediaMessageValidator.validate(fields, context: context()), .partialResource(expected))
        fields["token"] = "old"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        fields["token"] = "current"; fields["documentURL"] = "https://wrong.example/"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
    }

    func testPartialResourceEvidenceRequiresReadableResponseSourceAndValidURLs() throws {
        var fields = body(url: "https://cdn.example/init.mp4", source: "fetch", event: "partial", mime: "application/vnd.apple.mpegurl")
        fields["relatedURL"] = "https://cdn.example/video.m3u8"
        for source in ["video", "source", "performance", "encrypted", "metadata"] {
            fields["source"] = source
            XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        }
        fields["source"] = "xhr"
        XCTAssertNoThrow(try MediaMessageValidator.validate(fields, context: context()))
        for url in ["file:///tmp/video.m3u8", "https://user:secret@cdn.example/video.m3u8", "https://cdn.example/a\n.m3u8"] {
            fields["relatedURL"] = url
            XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        }
        fields["relatedURL"] = "https://cdn.example/playlist"; fields["mime"] = "video/mp4"
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
        fields["mime"] = "application/vnd.apple.mpegurl"
        XCTAssertNoThrow(try MediaMessageValidator.validate(fields, context: context()))
        fields["url"] = "https://cdn.example/" + String(repeating: "a", count: 8192)
        XCTAssertThrowsError(try MediaMessageValidator.validate(fields, context: context()))
    }
}
