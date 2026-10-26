import XCTest

final class VideoCoverUITests: XCTestCase {
    func testChooseFrameCancelPersistAndRestoreAutomaticCover() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = ["--fixture-cloud-sync", fixtureID,
                               "--fixture-url", "http://127.0.0.1:8765/cover-timeline"]
        app.launch()
        defer { app.terminate() }
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        inline.tap()
        app.tabBars.buttons["离线"].tap()
        let row = app.buttons["offlineVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        XCTAssertFalse((row.value as? String)?.contains("自选封面") == true)

        openPicker(app)
        let slider = app.sliders["videoCoverSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        waitForPreview(app, containing: "0.800 秒")
        slider.adjust(toNormalizedSliderPosition: 0.75)
        let draggedValue = try XCTUnwrap(slider.value as? String)
        waitForPreview(app, containing: draggedValue)
        app.buttons["cancelVideoCover"].tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
        XCTAssertFalse((row.value as? String)?.contains("自选封面") == true,
                       "Cancelling must not persist the dragged frame.")

        openPicker(app)
        waitForPreview(app, containing: "0.800 秒")
        // The synthetic video is black/red/green/blue in two-second intervals.
        // Rapid adjustments must leave the final 5.8-second green frame visible.
        for _ in 0..<5 { app.buttons["nextVideoCoverSecond"].tap() }
        waitForPreview(app, containing: "5.800 秒")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "选择视频封面（本机合成绿帧）"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["saveVideoCover"].tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
        waitForCustomCover(row)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists,
                       "Choosing a cover must not start video playback.")
        app.terminate()

        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        waitForCustomCover(row)
        openPicker(app)
        waitForPreview(app, containing: "5.800 秒")
        app.buttons["useAutomaticVideoCover"].tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "NOT (value CONTAINS %@)", "自选封面"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
        app.terminate()
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertFalse((row.value as? String)?.contains("自选封面") == true)
        row.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
    }

    private func openPicker(_ app: XCUIApplication) {
        app.buttons["manageOfflineVideo"].tap()
        let choose = app.buttons["chooseVideoCover"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
    }

    private func waitForPreview(_ app: XCUIApplication, containing seconds: String) {
        let preview = app.descendants(matching: .any).matching(identifier: "videoCoverPreview").firstMatch
        expectation(for: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", seconds, "已载入"),
                    evaluatedWith: preview)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["saveVideoCover"].isEnabled)
    }

    private func waitForCustomCover(_ row: XCUIElement) {
        expectation(for: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "自选封面", "5.800 秒"),
                    evaluatedWith: row)
        waitForExpectations(timeout: 10)
    }
}
