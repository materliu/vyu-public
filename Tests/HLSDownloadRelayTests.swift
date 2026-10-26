import XCTest
@testable import VYu

final class HLSDownloadRelayTests: XCTestCase {
    private let base = URL(string: "https://cdn.example/effective/path/master.m3u8?signature=fixture")!

    func testMasterAndAudioReferencesUseEffectiveURLAndKeepTheirOwnQueries() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Synthetic",URI="../audio/index.m3u8?token=synthetic"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="audio"
        360p/index.m3u8?quality=fixture
        """
        var resources: [(URL, Bool)] = []
        let rewritten = try HLSRelayManifest.rewrite(text, baseURL: base) { url, playlist in
            resources.append((url, playlist))
            return URL(string: "http://127.0.0.1:1234/token/\(resources.count).m3u8")!
        }
        XCTAssertEqual(resources.map { $0.0.absoluteString }, [
            "https://cdn.example/effective/audio/index.m3u8?token=synthetic",
            "https://cdn.example/effective/path/360p/index.m3u8?quality=fixture"
        ])
        XCTAssertTrue(resources.allSatisfy { $0.1 })
        XCTAssertFalse(rewritten.contains("cdn.example"))
        XCTAssertFalse(rewritten.contains("signature="))
        XCTAssertTrue(rewritten.contains("URI=\"http://127.0.0.1:1234/token/1.m3u8\""))
    }

    func testInitializationSegmentsAndByteRangesAreRewrittenWithoutChangingRanges() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="128@0"
        #EXTINF:8,
        #EXT-X-BYTERANGE:1024@128
        movie.mp4
        #EXT-X-ENDLIST
        """
        var resources: [(URL, Bool)] = []
        let rewritten = try HLSRelayManifest.rewrite(text, baseURL: base) { url, playlist in
            resources.append((url, playlist))
            return URL(string: "http://127.0.0.1:1234/token/\(resources.count).media")!
        }
        XCTAssertEqual(resources.map { $0.0.lastPathComponent }, ["init.mp4", "movie.mp4"])
        XCTAssertTrue(resources.allSatisfy { !$0.1 })
        XCTAssertTrue(rewritten.contains("BYTERANGE=\"128@0\""))
        XCTAssertTrue(rewritten.contains("#EXT-X-BYTERANGE:1024@128"))
        XCTAssertFalse(rewritten.contains("movie.mp4"))
    }

    func testEncryptedManifestIsRejectedBeforeRegisteringAnyResource() {
        for method in ["AES-128", "SAMPLE-AES"] {
            let text = "#EXTM3U\n#EXT-X-KEY:METHOD=\(method),URI=\"key.bin\"\n#EXTINF:8,\nsegment.ts\n#EXT-X-ENDLIST\n"
            var registrations = 0
            XCTAssertThrowsError(try HLSRelayManifest.rewrite(text, baseURL: base) { _, _ in
                registrations += 1; return self.base
            })
            XCTAssertEqual(registrations, 0)
        }
    }

    func testRemoteReferencesRejectDowngradesCredentialsAndNonHTTP() {
        for raw in ["http://cdn.example/segment.ts", "https://user:secret@cdn.example/segment.ts", "file:///private/segment.ts", "data:video/mp4,bytes", "{$unresolved}/segment.ts"] {
            let text = "#EXTM3U\n#EXTINF:8,\n\(raw)\n#EXT-X-ENDLIST\n"
            XCTAssertThrowsError(try HLSRelayManifest.rewrite(text, baseURL: base) { _, _ in self.base })
        }
    }

    func testUnsupportedExternalSteeringAndVariablesAreRejected() {
        for tag in ["#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://cdn.example/steer.json\"", "#EXT-X-DEFINE:NAME=\"token\",VALUE=\"fixture\""] {
            let text = "#EXTM3U\n\(tag)\n#EXTINF:8,\nsegment.ts\n#EXT-X-ENDLIST\n"
            XCTAssertThrowsError(try HLSRelayManifest.rewrite(text, baseURL: base) { _, _ in self.base })
        }
    }

    func testMalformedURIAttributesAndOversizedManifestAreRejected() {
        for text in ["#EXTM3U\n#EXT-X-MAP:URI=unquoted.mp4\n#EXTINF:8,\nsegment.ts\n#EXT-X-ENDLIST", "#EXTM3U\n" + String(repeating: "#", count: 2_000_000)] {
            XCTAssertThrowsError(try HLSRelayManifest.rewrite(text, baseURL: base) { _, _ in self.base })
        }
    }

    func testFetchedLeafMustStillBeFinishedAndHavePositiveFiniteDuration() {
        for text in [
            "#EXTM3U\n#EXTINF:8,\nsegment.ts\n",
            "#EXTM3U\n#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXTINF:0,\nsegment.ts\n#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXTINF:inf,\nsegment.ts\n#EXT-X-ENDLIST\n"
        ] {
            var registrations = 0
            XCTAssertThrowsError(try HLSRelayManifest.rewrite(text, baseURL: base) { _, _ in
                registrations += 1; return self.base
            })
            XCTAssertEqual(registrations, 0)
        }
    }

    func testChunkEncodingPreservesBinaryBytesAndOnlyExplicitEndTerminatesBody() {
        let binary = Data([0, 13, 10, 255])
        var expected = Data("4\r\n".utf8)
        expected.append(binary)
        expected.append(Data("\r\n".utf8))
        XCTAssertEqual(HLSRelayChunkEncoding.encode(binary), expected)
        XCTAssertTrue(HLSRelayChunkEncoding.encode(Data()).isEmpty)
        XCTAssertEqual(HLSRelayChunkEncoding.end, Data("0\r\n\r\n".utf8))
    }

    func testOnlyExplicitUndecodedContentLengthCanFixTheRelayedBodySize() throws {
        let url = URL(string: "https://media.example.test/segment")!
        func response(_ fields: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fields)!
        }
        XCTAssertEqual(try HLSRelayResponseLength.declared(response(["Content-Length": "123"])), 123)
        XCTAssertEqual(try HLSRelayResponseLength.declared(response(["Content-Length": "0"])), 0)
        XCTAssertNil(try HLSRelayResponseLength.declared(response([:])))
        for encoding in ["chunked", "Identity"] {
            XCTAssertNil(try HLSRelayResponseLength.declared(response(["Transfer-Encoding": encoding, "Content-Length": "0"])))
        }
        XCTAssertNil(try HLSRelayResponseLength.declared(response(["Content-Encoding": "gzip", "Content-Length": "123"])))
        for invalid in ["-1", "+1", "1, 1", "9223372036854775808"] {
            XCTAssertThrowsError(try HLSRelayResponseLength.declared(response(["Content-Length": invalid])))
        }
    }

    func testContentRangeMustMatchTheRequestedInterval() throws {
        let range = try XCTUnwrap(HLSRelayContentRange("bytes 128-1023/2048"))
        XCTAssertEqual(range.length, 896)
        XCTAssertTrue(range.matches("bytes=128-1023"))
        XCTAssertFalse(range.matches("bytes=0-1023"))
        XCTAssertFalse(range.matches("bytes=128-"))
        XCTAssertFalse(range.matches("bytes=-896"))
        let tail = try XCTUnwrap(HLSRelayContentRange("bytes 1024-2047/2048"))
        for requested in ["bytes=1024-", "bytes=1024-9999", "bytes=-1024"] {
            XCTAssertTrue(tail.matches(requested), requested)
        }
        XCTAssertFalse(tail.matches("bytes=2048-"))
        XCTAssertFalse(tail.matches("bytes=-2048"))
        let all = try XCTUnwrap(HLSRelayContentRange("bytes 0-2047/2048"))
        XCTAssertTrue(all.matches("bytes=-9999"))
        let maximum = try XCTUnwrap(HLSRelayContentRange("bytes 0-9223372036854775806/9223372036854775807"))
        XCTAssertEqual(maximum.length, Int64.max)
        XCTAssertTrue(maximum.matches("bytes=0-9223372036854775807"))
    }

    func testHTTPParserAcceptsOnlyOpaqueKnownPrefixAndSingleRange() {
        let request = parse("GET /synthetic-token/opaque.media HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nRange: bytes=128-1023\r\nAuthorization: ignored-synthetic\r\n\r\n")
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/synthetic-token/opaque.media")
        XCTAssertEqual(request?.range, "bytes=128-1023")
        XCTAssertNotNil(parse("HEAD /synthetic-token/opaque.m3u8 HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\n"))
        // The request model has no arbitrary header bag to forward upstream.
    }

    func testHTTPParserRejectsForeignHostTokenProxyURLsAndBodies() {
        for start in ["POST /synthetic-token/id", "CONNECT /synthetic-token/id", "GET /other-token/id", "GET /synthetic-token/id?url=https://remote.example", "GET http://remote.example/movie", "GET /synthetic-token/%2e%2e/id", "GET /synthetic-token/../id"] {
            XCTAssertNil(parse(start + " HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\n"))
        }
        for headers in ["Host: localhost:1234", "Host: 127.0.0.1:1235", "Host: remote.example", "Host: 127.0.0.1:1234\r\nContent-Length: 1", "Host: 127.0.0.1:1234\r\nTransfer-Encoding: chunked", "Host: 127.0.0.1:1234\r\nHost: 127.0.0.1:1234"] {
            XCTAssertNil(parse("GET /synthetic-token/id HTTP/1.1\r\n" + headers + "\r\n\r\n"))
        }
        XCTAssertNil(parse("GET /synthetic-token/id HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\nextra"))
        XCTAssertNil(parse(String(repeating: "a", count: 16_385)))
    }

    func testRangeBoundsAndContentRangeValidation() {
        for value in ["bytes=0-0", "bytes=128-", "bytes=-1024", "bytes=0-9223372036854775807"] {
            XCTAssertTrue(HLSRelayRequest.validRange(value), value)
        }
        for value in ["bytes=-", "bytes=2-1", "bytes=0-1,4-5", "items=0-1", "bytes=-0", "bytes=+1-2", "bytes=0-9223372036854775808"] {
            XCTAssertFalse(HLSRelayRequest.validRange(value), value)
        }
        XCTAssertTrue(HLSRelayRequest.validContentRange("bytes 128-1023/2048"))
        for value in ["bytes 3-2/10", "bytes 0-10/10", "bytes 0-1/*", "bytes +1-2/10", "bytes 0-1/10\r\nInjected: value"] {
            XCTAssertFalse(HLSRelayRequest.validContentRange(value), value)
        }
    }

    private func parse(_ raw: String) -> HLSRelayRequest? {
        HLSRelayRequest.parse(Data(raw.utf8), token: "synthetic-token", port: 1234)
    }
}
