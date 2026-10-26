import XCTest
@testable import VYu

final class HLSInspectionTests: XCTestCase {
    private let master = URL(string: "https://media.example/master.m3u8?token=private-value")!
    private let vod = "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"

    private func url(_ path: String) -> URL { URL(string: path, relativeTo: master)!.absoluteURL }
    private func source(_ text: String, at url: URL) throws -> (HLSManifest, URL) {
        (try HLSManifest.parse(text, relativeTo: url), url)
    }
    private func variant(_ path: String, audio: String? = nil) -> String {
        "#EXT-X-STREAM-INF:BANDWIDTH=1200000" + (audio.map { ",AUDIO=\"\($0)\"" } ?? "") + "\n\(path)\n"
    }
    private func track(_ path: String, group: String) -> String {
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(group)\",NAME=\"\(group)\",URI=\"\(path)\"\n"
    }

    func testMainRequestFailureReportsStageAndDoesNotExposeURL() async throws {
        do {
            _ = try await HLSPreflight.inspect(master) { _ in throw DownloadIssue.http(403) }
            XCTFail("A rejected main playlist cannot start a download.")
        } catch {
            guard case DownloadIssue.playlistHTTP(.main, 403) = error else { return XCTFail("Wrong request stage.") }
            XCTAssertTrue(error.localizedDescription.contains("主清单"))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
            XCTAssertFalse(error.localizedDescription.contains("private-value"))
            XCTAssertFalse(error.localizedDescription.contains("media.example"))
        }
    }

    func testRejectedAlternativeKeepsValidatedMuxedVariantAndNeverDownloadsMaster() async throws {
        let text = "#EXTM3U\n" + variant("blocked.m3u8") + variant("usable.m3u8")
        var requested: [URL] = []
        let result = try await HLSPreflight.inspect(master) { target in
            requested.append(target)
            if target == self.master { return try self.source(text, at: target) }
            if target == self.url("blocked.m3u8") { throw DownloadIssue.http(403) }
            return try self.source(self.vod, at: target)
        }
        XCTAssertTrue(result.downloadable)
        XCTAssertEqual(result.variants.map(\.url), [url("usable.m3u8")])
        XCTAssertEqual(result.hlsDownloadURL, url("usable.m3u8"))
        XCTAssertEqual(result.expectedDuration, 4)
        XCTAssertTrue(result.summary.contains("另有 1 种画质不可用"))
        XCTAssertEqual(requested.count, 3)
    }

    func testUnreferencedAudioGroupIsNotRequestedOrRequired() async throws {
        let text = "#EXTM3U\n" + track("unrelated.m3u8", group: "unused") + variant("video.m3u8")
        var requested: [URL] = []
        let result = try await HLSPreflight.inspect(master) { target in
            requested.append(target)
            if target == self.url("unrelated.m3u8") { throw DownloadIssue.http(403) }
            return try self.source(target == self.master ? text : self.vod, at: target)
        }
        XCTAssertTrue(result.downloadable)
        XCTAssertTrue(result.audioTracks.isEmpty)
        XCTAssertFalse(requested.contains(url("unrelated.m3u8")))
        XCTAssertEqual(result.hlsDownloadURL, url("video.m3u8"))
    }

    func testSelectedLeafUsesItsOwnDurationInsteadOfAnotherQuality() async throws {
        let text = "#EXTM3U\n" + variant("first.m3u8") + variant("second.m3u8")
        for durations in [[12.166, 18.0], [18.0, 12.166]] {
            let result = try await HLSPreflight.inspect(master) { target in
                if target == self.master { return try self.source(text, at: target) }
                let duration = target == self.url("first.m3u8") ? durations[0] : durations[1]
                return try self.source("#EXTM3U\n#EXTINF:\(duration),\nsegment.ts\n#EXT-X-ENDLIST\n", at: target)
            }
            XCTAssertEqual(result.variants.map(\.url), [url("first.m3u8"), url("second.m3u8")])
            XCTAssertEqual(result.hlsDownloadURL, url("first.m3u8"))
            XCTAssertEqual(try XCTUnwrap(result.expectedDuration), durations[0], accuracy: 0.0001,
                "The selected rendition must not inherit the longest alternative's duration.")
        }
    }

    func testSharedRejectedAudioOnlyDisablesAssociatedBranchesWithoutRetryStorm() async throws {
        let text = "#EXTM3U\n" + track("audio.m3u8", group: "sound")
            + variant("video-one.m3u8", audio: "sound") + variant("video-two.m3u8", audio: "sound")
            + variant("muxed.m3u8")
        var audioRequests = 0
        let result = try await HLSPreflight.inspect(master) { target in
            if target == self.url("audio.m3u8") { audioRequests += 1; throw DownloadIssue.http(403) }
            return try self.source(target == self.master ? text : self.vod, at: target)
        }
        XCTAssertEqual(audioRequests, 1)
        XCTAssertEqual(result.variants.map(\.url), [url("muxed.m3u8")])
        XCTAssertEqual(result.hlsDownloadURL, url("muxed.m3u8"))
        XCTAssertTrue(result.audioTracks.isEmpty)
    }

    func testCompleteSeparateAudioPlanKeepsMasterAndDoesNotOfferSilentLeaf() async throws {
        let text = "#EXTM3U\n" + track("audio.m3u8", group: "sound")
            + variant("video.m3u8", audio: "sound")
        let result = try await HLSPreflight.inspect(master) { target in
            try self.source(target == self.master ? text : self.vod, at: target)
        }
        XCTAssertTrue(result.downloadable)
        XCTAssertTrue(result.variants.isEmpty)
        XCTAssertEqual(result.hlsDownloadURL, master)
        XCTAssertEqual(result.audioTracks, ["sound"])
        XCTAssertEqual(result.expectedDuration, 4, "A duration shared by every selectable rendition remains usable.")
    }

    func testMasterWithDifferentRenditionDurationsDoesNotAssignOneQualityToSystemSelection() async throws {
        let text = "#EXTM3U\n" + track("audio.m3u8", group: "sound")
            + variant("short.m3u8", audio: "sound") + variant("long.m3u8", audio: "sound")
        var requested: [URL] = []
        let result = try await HLSPreflight.inspect(master) { target in
            requested.append(target)
            if target == self.master { return try self.source(text, at: target) }
            let duration = target == self.url("long.m3u8") ? 18.0 : 12.166
            return try self.source("#EXTM3U\n#EXTINF:\(duration),\nsegment.ts\n#EXT-X-ENDLIST\n", at: target)
        }
        XCTAssertTrue(result.downloadable)
        XCTAssertTrue(result.variants.isEmpty)
        XCTAssertEqual(result.hlsDownloadURL, master)
        XCTAssertNil(result.expectedDuration,
            "The system may select either validated rendition; the longest is not an authoritative expectation.")
        XCTAssertEqual(result.audioTracks, ["sound"])
        XCTAssertEqual(requested.filter { $0 == url("audio.m3u8") }.count, 1,
            "Required audio remains inspected once even when rendition durations differ.")
        XCTAssertTrue(requested.contains(url("short.m3u8")))
        XCTAssertTrue(requested.contains(url("long.m3u8")))
    }

    func testIncompleteMasterCannotOfferVideoOnlyLeafOrUncheckedMaster() async throws {
        let text = "#EXTM3U\n" + track("audio.m3u8", group: "sound")
            + variant("video.m3u8", audio: "sound") + variant("blocked.m3u8")
        do {
            _ = try await HLSPreflight.inspect(master) { target in
                if target == self.url("blocked.m3u8") { throw DownloadIssue.http(403) }
                return try self.source(target == self.master ? text : self.vod, at: target)
            }
            XCTFail("An unchecked master or a silent video-only leaf must not be offered.")
        } catch {
            guard case DownloadIssue.playlistHTTP(.variant, 403) = error else { return XCTFail("Wrong failure stage.") }
        }
    }

    func testAssociatedAudioFailureReportsAudioStage() async throws {
        let text = "#EXTM3U\n" + track("audio.m3u8", group: "sound") + variant("video.m3u8", audio: "sound")
        do {
            _ = try await HLSPreflight.inspect(master) { target in
                if target == self.url("audio.m3u8") { throw DownloadIssue.http(403) }
                return try self.source(target == self.master ? text : self.vod, at: target)
            }
            XCTFail("A required audio playlist failed.")
        } catch {
            guard case DownloadIssue.playlistHTTP(.audio, 403) = error else { return XCTFail("Wrong failure stage.") }
            XCTAssertTrue(error.localizedDescription.contains("音轨清单"))
        }
    }

    func testEncryptedAlternativeIsNeverOfferedOrLeftSelectableInMaster() async throws {
        let text = "#EXTM3U\n" + variant("encrypted.m3u8") + variant("clear.m3u8")
        let result = try await HLSPreflight.inspect(master) { target in
            let content = target == self.master ? text : (target == self.url("encrypted.m3u8")
                ? "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST" : self.vod)
            return try self.source(content, at: target)
        }
        XCTAssertEqual(result.variants.map(\.url), [url("clear.m3u8")])
        XCTAssertEqual(result.hlsDownloadURL, url("clear.m3u8"))
    }

    func testMasterSessionKeyStopsBeforeAnyChildRequest() async throws {
        let text = "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key.bin\"\n" + variant("video.m3u8")
        var requests = 0
        do {
            _ = try await HLSPreflight.inspect(master) { target in
                requests += 1
                return try self.source(text, at: target)
            }
            XCTFail("Master session encryption must remain blocked.")
        } catch {
            guard case DownloadIssue.playlistProblem(.main, .protectedContent) = error else { return XCTFail("Wrong protection failure.") }
        }
        XCTAssertEqual(requests, 1)
    }

    func testMissingAudioGroupDoesNotFallBackToPotentiallySilentLeaf() async throws {
        let text = "#EXTM3U\n" + variant("video.m3u8", audio: "missing")
        do {
            _ = try await HLSPreflight.inspect(master) { target in
                try self.source(target == self.master ? text : self.vod, at: target)
            }
            XCTFail("An unresolved audio group must not be dropped.")
        } catch {
            guard case DownloadIssue.playlistProblem(.audio, .missingAudioGroup) = error else { return XCTFail("Wrong audio-group failure.") }
        }
    }

    func testNestedAudioPlaylistIsNotAcceptedAsValidatedMedia() async throws {
        let text = "#EXTM3U\n" + track("audio.m3u8", group: "sound") + variant("video.m3u8", audio: "sound")
        do {
            _ = try await HLSPreflight.inspect(master) { target in
                let content = target == self.master ? text : (target == self.url("audio.m3u8")
                    ? "#EXTM3U\n" + self.variant("nested.m3u8") : self.vod)
                return try self.source(content, at: target)
            }
            XCTFail("Nested audio is not validated by checking only its outer playlist.")
        } catch {
            guard case DownloadIssue.playlistProblem(.audio, .nested) = error else { return XCTFail("Wrong nested-playlist failure.") }
        }
    }

    func testNetworkFailureDoesNotIncludeUnderlyingSignedURL() async throws {
        do {
            _ = try await HLSPreflight.inspect(master) { _ in
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: "Failed https://media.example/master.m3u8?token=private-value"])
            }
            XCTFail("A timeout cannot be inspected.")
        } catch {
            guard case DownloadIssue.playlistProblem(.main, .network(NSURLErrorTimedOut)) = error else { return XCTFail("Wrong network failure.") }
            XCTAssertFalse(error.localizedDescription.contains("private-value"))
            XCTAssertFalse(error.localizedDescription.contains("https://"))
        }
    }
}
