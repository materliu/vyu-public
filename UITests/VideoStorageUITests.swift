import XCTest

final class VideoStorageUITests: XCTestCase {
    func testOptimizationEvictsSyntheticLocalVideoAndCloudRowRestoresPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        // The tiny budget is honored only in DEBUG inside this dedicated fixture library.
        app.launchArguments = ["--fixture-cloud-sync", fixtureID, "--fixture-storage-budget", "1",
                               "--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launch()
        defer { app.terminate() }
        let download = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        app.tabBars.buttons["离线"].tap()
        let localRow = app.buttons["offlineVideoRow"]
        XCTAssertTrue(localRow.waitForExistence(timeout: 60))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "1 个视频已同步"),
                    evaluatedWith: app.staticTexts["cloudSyncStatus"])
        waitForExpectations(timeout: 20)

        openStorageSettings(app)
        let toggle = app.switches["optimizeLocalStorageToggle"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitForToggle(toggle, value: "1")
        app.buttons["closeStorageSettings"].tap()
        let cloudRow = app.buttons["cloudVideoRow"]
        XCTAssertTrue(cloudRow.waitForExistence(timeout: 30))
        XCTAssertTrue(localRow.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "cloudVideoRow").count, 1)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists,
                       "Reclaiming a local copy must not launch the player.")
        let cloudPreview = XCTAttachment(screenshot: app.screenshot())
        cloudPreview.name = "优化后的云端视频及保留封面（合成视频）"
        cloudPreview.lifetime = .keepAlways
        add(cloudPreview)

        cloudRow.tap()
        let playback = app.staticTexts["offlinePlaybackLabel"]
        XCTAssertTrue(playback.waitForExistence(timeout: 30))
        let clock = app.staticTexts["playbackClock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        // The deliberately tiny budget remains enabled. Playback must retain its
        // restored file long enough to advance, rather than immediately evicting it.
        expectation(for: NSPredicate(format: "label MATCHES %@", "播放 [1-9][0-9]*\\.[0-9]+ 秒"),
                    evaluatedWith: clock)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(playback.label, "本机视频 · 离线播放")
        let restoredPlayback = XCTAttachment(screenshot: app.screenshot())
        restoredPlayback.name = "从模拟云端恢复后播放进度前进"
        restoredPlayback.lifetime = .keepAlways
        add(restoredPlayback)
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(playback.waitForNonExistence(timeout: 5))
        // Once playback releases its lease, the over-budget copy is replaceable again.
        XCTAssertTrue(cloudRow.waitForExistence(timeout: 30))
        XCTAssertTrue(localRow.waitForNonExistence(timeout: 10))
    }

    func testLocalStorageSwitchUsageAndPreferenceSurviveRelaunchWithoutInterruptingPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = ["--fixture-cloud-sync", fixtureID,
                               "--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launch()
        defer { app.terminate() }
        let download = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        app.tabBars.buttons["离线"].tap()
        let row = app.buttons["offlineVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))

        openStorageSettings(app)
        let toggle = app.switches["optimizeLocalStorageToggle"]
        XCTAssertEqual(toggle.value as? String, "0")
        let usage = app.descendants(matching: .any).matching(identifier: "storageUsage").firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1 GB")).firstMatch.exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitForToggle(toggle, value: "1")
        let optimize = app.buttons["optimizeLocalStorageNow"]
        XCTAssertTrue(optimize.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: optimize)
        waitForExpectations(timeout: 15)
        optimize.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "本地缓存优化（合成视频及模拟云端）"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["closeStorageSettings"].tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists)
        app.terminate()

        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        openStorageSettings(app)
        XCTAssertEqual(toggle.value as? String, "1", "Enabling optimization must survive restarting the app.")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitForToggle(toggle, value: "0")
        app.buttons["closeStorageSettings"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["离线"].tap()
        openStorageSettings(app)
        XCTAssertEqual(toggle.value as? String, "0", "Disabling optimization must also survive restarting the app.")
        app.buttons["closeStorageSettings"].tap()
        row.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
    }

    private func openStorageSettings(_ app: XCUIApplication) {
        let manage = app.buttons["manageLocalStorage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.tap()
        XCTAssertTrue(app.switches["optimizeLocalStorageToggle"].waitForExistence(timeout: 5))
    }

    private func waitForToggle(_ toggle: XCUIElement, value: String) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(toggle.value as? String, value)
    }
}
