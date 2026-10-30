import XCTest

final class VYuUITests: XCTestCase {
    func testOfflineVideoSearchFavoritesAndTagsPersistWithoutChangingPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = ["--fixture-cloud-sync", fixtureID,
                               "--fixture-url", "http://127.0.0.1:8765/video-card-titles"]
        app.launch()
        defer { app.terminate() }
        let inlineButtons = app.webViews.buttons.matching(NSPredicate(format: "label == %@", "下载此视频"))
        XCTAssertTrue(inlineButtons.element(boundBy: 1).waitForExistence(timeout: 20))
        for index in 0..<2 {
            let inline = inlineButtons.element(boundBy: index)
            for _ in 0..<4 where !inline.isHittable { app.webViews.firstMatch.swipeUp() }
            XCTAssertTrue(inline.isHittable)
            inline.tap()
        }
        app.tabBars.buttons["离线"].tap()
        let videos = app.buttons.matching(identifier: "offlineVideoRow")
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: videos)
        waitForExpectations(timeout: 60)
        let search = app.textFields["offlineVideoSearch"]
        search.tap(); search.typeText("雨后")
        XCTAssertEqual(videos.count, 1)
        let video = videos.firstMatch
        XCTAssertEqual(video.label, "雨后花园里的小路")
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["收藏视频"].tap()
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        XCTAssertTrue((video.value as? String)?.contains("已收藏") == true)
        app.buttons["clearOfflineSearch"].tap()
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(video.label, "雨后花园里的小路")

        app.buttons["manageOfflineVideo"].tap()
        app.buttons["编辑标签"].tap()
        let input = app.textViews["videoTagInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("旅行，ＳＵＭＭＥＲ\n学习")
        app.buttons["saveVideoTags"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        XCTAssertTrue((video.value as? String)?.contains("旅行") == true)
        XCTAssertEqual(video.label, "雨后花园里的小路", "Tags must not rename the video.")
        search.tap(); search.typeText("雨后 summer")
        XCTAssertEqual(videos.count, 1, "Title and tags must match the same video across width and case differences.")
        app.buttons["clearOfflineSearch"].tap()
        search.tap(); search.typeText("山间 summer")
        XCTAssertEqual(search.value as? String, "山间 summer")
        XCTAssertTrue(app.staticTexts["offlineSearchEmpty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
        XCTAssertTrue(app.buttons["clearOfflineFilters"].waitForExistence(timeout: 5))
        app.buttons["clearOfflineFilters"].tap()
        XCTAssertEqual(videos.count, 2)
        search.tap(); search.typeText("雨后")

        // Validation failure leaves both the persisted tags and editable draft intact.
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["编辑标签"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let original = input.value as? String ?? ""
        input.tap(); input.typeText("，" + String(repeating: "a", count: 31))
        app.buttons["saveVideoTags"].tap()
        XCTAssertTrue(app.alerts["标签未能保存"].waitForExistence(timeout: 5))
        app.alerts["标签未能保存"].buttons["好"].tap()
        XCTAssertTrue((input.value as? String)?.contains(String(repeating: "a", count: 31)) == true)
        app.buttons["cancelVideoTags"].tap()
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["编辑标签"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, original, "Cancelling must discard an unsaved draft.")
        app.buttons["cancelVideoTags"].tap()
        app.terminate()

        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(video.label, "雨后花园里的小路")
        XCTAssertTrue((video.value as? String)?.contains("旅行") == true)
        XCTAssertFalse((video.value as? String)?.contains(String(repeating: "a", count: 31)) == true)
        video.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
    }

    func testCloudOnlyVideoCanBeFavoritedTaggedAndSearchedBeforeRestoring() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = ["--fixture-cloud-sync", fixtureID,
                               "--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launch()
        defer { app.terminate() }
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20)); inline.tap()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 60))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "1 个视频已同步"),
                    evaluatedWith: app.staticTexts["cloudSyncStatus"])
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.cells.count, 1, "A local video and its cloud entry must share one row.")
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["删除本机缓存"].tap()
        let cloudVideo = app.buttons["cloudVideoRow"]
        XCTAssertTrue(cloudVideo.waitForExistence(timeout: 10))
        app.buttons["manageCloudVideo"].tap()
        app.buttons["收藏视频"].tap()
        app.buttons["manageCloudVideo"].tap()
        app.buttons["编辑标签"].tap()
        let input = app.textViews["videoTagInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("待看,教程")
        app.buttons["saveVideoTags"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        let search = app.textFields["offlineVideoSearch"]
        search.tap(); search.typeText("#待看")
        XCTAssertTrue(cloudVideo.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "cloudVideoRow").count, 1)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists,
                       "Filtering and organizing cloud-only videos must not restore their media.")
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "离线视频标题标签搜索与收藏（本机合成云端条目）"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        XCTAssertTrue(cloudVideo.waitForExistence(timeout: 15))
        XCTAssertTrue((cloudVideo.value as? String)?.contains("待看") == true)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
        cloudVideo.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 20))
    }

    func testInlineCardTitleReachesOfflineListAndPersistsAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = ["--fixture-cloud-sync", fixtureID,
                               "--fixture-url", "http://127.0.0.1:8765/video-card-titles"]
        app.launch()
        defer { app.terminate() }
        let buttons = app.webViews.buttons.matching(NSPredicate(format: "label == %@", "下载此视频"))
        let second = buttons.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        for _ in 0..<5 where !second.isHittable { app.webViews.firstMatch.swipeUp() }
        XCTAssertTrue(second.isHittable)
        second.tap()
        XCTAssertTrue(app.staticTexts["downloadToast"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected)
        XCTAssertFalse(app.navigationBars["下载到本机"].exists)
        app.tabBars.buttons["离线"].tap()
        let row = app.buttons["offlineVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        XCTAssertEqual(row.label, "雨后花园里的小路")
        XCTAssertEqual(app.buttons.matching(identifier: "offlineVideoRow").count, 1)
        XCTAssertNotEqual(row.label, "中性视频合集")
        XCTAssertFalse(app.staticTexts["晨光中的山间步道"].exists)
        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertEqual(row.label, "雨后花园里的小路")
        row.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
    }

    func testLooseInlineTitleReachesOfflineListForMP4AndHLSAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        for format in ["mp4", "hls"] {
            let fixtureID = UUID().uuidString
            app.launchArguments = ["--fixture-cloud-sync", fixtureID,
                                   "--fixture-url", "http://127.0.0.1:8765/video-card-inline-" + format]
            app.launch()
            let inline = app.webViews.buttons["下载此视频"]
            XCTAssertTrue(inline.waitForExistence(timeout: 20))
            for _ in 0..<4 where !inline.isHittable { app.webViews.firstMatch.swipeUp() }
            inline.tap()
            app.tabBars.buttons["离线"].tap()
            let row = app.buttons["offlineVideoRow"]
            XCTAssertTrue(row.waitForExistence(timeout: 90), format)
            XCTAssertEqual(row.label, "林间 散步 的记录", format)
            app.terminate()
            app.launchArguments = ["--fixture-cloud-sync", fixtureID]
            app.launch()
            app.tabBars.buttons["离线"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            XCTAssertEqual(row.label, "林间 散步 的记录", format)
            app.terminate()
        }
    }

    func testHLSCardTitleReachesConfirmationAndMatchingMP4OfflineRecord() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/video-card-title-hls"]
        app.launch()
        defer { app.terminate() }
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        for _ in 0..<3 where !inline.isHittable { app.webViews.firstMatch.swipeUp() }
        inline.tap()
        let resolve = app.buttons["resolveDownloadFromToast"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 20))
        resolve.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForExistence(timeout: 10))
        let hls = app.buttons["candidate-hls"]
        XCTAssertTrue(hls.waitForExistence(timeout: 10))
        XCTAssertTrue(hls.label.contains("湖畔黄昏的风景"), hls.label)
        XCTAssertFalse(hls.label.contains("分段视频合集"), hls.label)
        let alternate = app.buttons["selectMP4Alternative"]
        XCTAssertTrue(alternate.waitForExistence(timeout: 20))
        alternate.tap()
        let file = app.buttons["candidate-file"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        XCTAssertTrue(file.label.contains("湖畔黄昏的风景"), file.label)
        XCTAssertTrue(app.buttons["startDownload"].waitForExistence(timeout: 20))
        app.buttons["startDownload"].tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForNonExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        let completed = app.buttons.matching(identifier: "offlineVideoRow").matching(NSPredicate(format: "label == %@", "湖畔黄昏的风景")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 60))
    }

    func testRejectedHLSCanSwitchToMatchingMP4AndPlayOffline() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/hls-alternatives"]
        app.launch()
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        inline.tap()
        let resolve = app.buttons["resolveDownloadFromToast"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected)
        XCTAssertFalse(app.navigationBars["下载到本机"].exists)
        resolve.tap()
        let alternate = app.buttons["selectMP4Alternative"]
        XCTAssertTrue(alternate.waitForExistence(timeout: 20))
        let rejection = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "主清单", "403")
        expectation(for: rejection, evaluatedWith: app.staticTexts["inspectionSummary"])
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.buttons.matching(identifier: "selectMP4Alternative").count, 1)
        XCTAssertFalse(app.buttons["startDownload"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "HLS拒绝时提供同视频MP4（本机模拟）"
        attachment.lifetime = .keepAlways; add(attachment)
        alternate.tap()
        let start = app.buttons["startDownload"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons.matching(identifier: "candidate-file").count, 1)
        start.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForNonExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        let video = app.buttons["offlineVideoRow"]
        XCTAssertTrue(video.waitForExistence(timeout: 60))
        XCTAssertEqual(video.value as? String, "127.0.0.1 · 含音轨 · 8 秒")
        video.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testInlineDownloadSelectsSecondVideoWithoutOpeningFirst() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/multiple-videos"]
        app.launch()
        let buttons = app.webViews.buttons.matching(NSPredicate(format: "label == %@", "下载此视频"))
        XCTAssertTrue(buttons.element(boundBy: 1).waitForExistence(timeout: 20))
        let second = buttons.element(boundBy: 1)
        for _ in 0..<4 where !second.isHittable { app.webViews.firstMatch.swipeUp() }
        XCTAssertTrue(second.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "视频旁逐项下载"; attachment.lifetime = .keepAlways; add(attachment)
        second.tap()
        XCTAssertTrue(app.staticTexts["downloadToast"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected)
        XCTAssertFalse(app.navigationBars["下载到本机"].exists)
        XCTAssertFalse(app.buttons["startDownload"].exists)
        XCTAssertTrue(second.isHittable, "The original page must stay usable after starting its download.")
        second.tap()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 60))
        XCTAssertEqual(app.buttons.matching(identifier: "offlineVideoRow").count, 1,
                       "Repeated clicks on the same video must not create duplicate downloads.")
        XCTAssertFalse(app.staticTexts["downloadStatus"].exists, "The rejected first video's URL must not have been downloaded.")
        app.buttons["offlineVideoRow"].tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testBrowserSessionRetryFromInlineVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/browser-session"]
        app.launch()
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        inline.tap()
        let resolve = app.buttons["resolveDownloadFromToast"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 20))
        XCTAssertFalse(app.navigationBars["下载到本机"].exists)
        resolve.tap()
        let retry = app.buttons["startBrowserDownload"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["inspectionSummary"].label.contains("403"))
        XCTAssertFalse(app.buttons["startDownload"].exists)
        retry.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForNonExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 60))
        app.terminate()
    }

    /// Exercises the UI against an isolated local cloud fixture, not an Apple account.
    func testCloudOnlyRowDownloadsValidatesAndPlaysThenDeletesEverywhere() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = ["--fixture-cloud-sync", fixtureID, "--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launch()
        XCTAssertTrue(app.buttons["showCandidates"].waitForExistence(timeout: 20))
        app.buttons["showCandidates"].tap()
        XCTAssertTrue(app.buttons["startDownload"].waitForExistence(timeout: 20))
        app.buttons["startDownload"].tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForNonExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 60))
        let uploaded = NSPredicate(format: "label CONTAINS %@", "1 个视频已同步")
        expectation(for: uploaded, evaluatedWith: app.staticTexts["cloudSyncStatus"])
        waitForExpectations(timeout: 20)
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["删除本机缓存"].tap()
        let cloudRow = app.buttons["cloudVideoRow"]
        XCTAssertTrue(cloudRow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "云端视频待恢复（本机模拟）"; preview.lifetime = .keepAlways; add(preview)
        cloudRow.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 20))
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 5))
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["从所有设备删除"].tap()
        app.buttons["删除 iCloud 和所有设备的视频"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(cloudRow.exists)
        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.staticTexts["还没有离线视频"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testHLSDownloadContinuesWhileAppIsInBackground() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VYU_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["--fixture-url", "http://127.0.0.1:8765/background-hls"]
        app.launch()
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20)); inline.tap()
        XCTAssertTrue(app.staticTexts["downloadToast"].waitForExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        let status = app.cells.firstMatch.staticTexts["downloadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "正在下载 ·"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 12)
        app.activate()
        let video = app.buttons["offlineVideoRow"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        XCTAssertEqual(video.value as? String, "127.0.0.1 · 含音轨 · 8 秒")
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        app.terminate()
    }

    func testDownloadContinuesWhileAppIsInBackground() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VYU_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["--fixture-url", "http://127.0.0.1:8765/slow"]
        app.launch()
        let discover = app.buttons["showCandidates"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        discover.tap()
        let start = app.buttons["startDownload"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForNonExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        let activeStatus = app.cells.firstMatch.staticTexts["downloadStatus"]
        XCTAssertTrue(activeStatus.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "正在下载 ·"), evaluatedWith: activeStatus)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.cells.count, 1)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
        XCUIDevice.shared.press(.home)
        // A bounded background interval, while the fixture throttles its response.
        Thread.sleep(forTimeInterval: 9)
        app.activate()
        let newestVideo = app.cells.firstMatch.buttons["offlineVideoRow"]
        XCTAssertTrue(newestVideo.waitForExistence(timeout: 10))
        XCTAssertEqual(newestVideo.value as? String, "127.0.0.1 · 含音轨 · 8 秒")
        app.terminate()
    }

    func testBrowserDownloadAndPlayerFlow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // This isolated library also uses the local cloud fixture, never an Apple account.
        app.launchEnvironment["VYU_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launch()
        let discover = app.buttons["showCandidates"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["discoveryStatus"].waitForExistence(timeout: 10))
        discover.tap()
        let start = app.buttons["startDownload"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForNonExistence(timeout: 20))
        app.tabBars.buttons["离线"].tap()
        let video = app.cells.firstMatch.buttons["offlineVideoRow"]
        XCTAssertTrue(video.waitForExistence(timeout: 60))
        XCTAssertEqual(video.value as? String, "127.0.0.1 · 含音轨 · 8 秒")
        XCTAssertFalse(app.buttons["playOffline"].exists)
        let download = XCTAttachment(screenshot: app.screenshot()); download.name = "下载完成"; download.lifetime = .keepAlways; add(download)
        // The blank area below the text is part of the row's playback target.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.9)).tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
        let player = XCTAttachment(screenshot: app.screenshot()); player.name = "原生离线播放器"; player.lifetime = .keepAlways; add(player)
        app.buttons["closePlayer"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        // A tap on the preview image opens the same player after relaunch.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
        app.buttons["closePlayer"].tap()

        expectation(for: NSPredicate(format: "label CONTAINS %@", "1 个视频已同步"),
                    evaluatedWith: app.staticTexts["cloudSyncStatus"])
        waitForExpectations(timeout: 20)
        app.buttons["manageOfflineVideo"].firstMatch.tap()
        let removeCache = app.buttons["删除本机缓存"]
        XCTAssertTrue(removeCache.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        removeCache.tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cloudVideoRow"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells.count, 1, "Removing the local cache must preserve the synced video record.")
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        app.terminate()
    }

    func testInlineFailureStaysOnThePageAndRetainsItsReasonOffline() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/expired"]
        app.launch()
        defer { app.terminate() }
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        inline.tap()
        let failed = NSPredicate(format: "label CONTAINS %@", "下载失败")
        expectation(for: failed, evaluatedWith: app.staticTexts["downloadToast"])
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected)
        XCTAssertTrue(inline.exists)
        XCTAssertFalse(app.navigationBars["下载到本机"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["resolveDownloadFromToast"].exists,
                       "An expired link has no session-retry choice to confirm.")
        app.buttons["viewDownloadsFromToast"].tap()
        let status = app.staticTexts["downloadStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("410"), "The failed queued task must retain its actual cause.")
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
    }

    func testRealInlineClicksInSameAndCrossOriginFramesStartWithoutConfirmation() throws {
        continueAfterFailure = false
        for route in ["iframe", "cross-frame"] {
            let app = XCUIApplication()
            app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                                   "--fixture-url", "http://127.0.0.1:8765/" + route]
            app.launch()
            let inline = app.webViews.buttons["下载此视频"]
            XCTAssertTrue(inline.waitForExistence(timeout: 20), route)
            for _ in 0..<3 where !inline.isHittable { app.webViews.firstMatch.swipeUp() }
            inline.tap()
            XCTAssertTrue(app.staticTexts["downloadToast"].waitForExistence(timeout: 20), route)
            XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected, route)
            XCTAssertFalse(app.navigationBars["下载到本机"].exists, route)
            app.tabBars.buttons["离线"].tap()
            XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 60), route)
            XCTAssertEqual(app.buttons.matching(identifier: "offlineVideoRow").count, 1, route)
            app.terminate()
        }
    }
}
