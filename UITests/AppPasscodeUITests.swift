import XCTest

extension XCUIApplication {
    func launchAndUnlock() {
        launch()
        unlockApp()
    }

    func openContentPhrase(file: StaticString = #filePath, line: UInt = #line) {
        let title = descendants(matching: .any).matching(identifier: "concealedTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), file: file, line: line)
        title.press(forDuration: 2.2)
        XCTAssertTrue(secureTextFields["contentPhraseInput"].waitForExistence(timeout: 5), file: file, line: line)
    }

    func selectConcealedTab(_ label: String) {
        // iPadOS floating tabs expose cells rather than a phone-style tab bar.
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.tap()
    }

    func unlockApp(file: StaticString = #filePath, line: UInt = #line) {
        openContentPhrase(file: file, line: line)
        secureTextFields["contentPhraseInput"].tap()
        secureTextFields["contentPhraseInput"].typeText("fixture-access")
        buttons["submitContentPhrase"].tap()
        XCTAssertTrue(secureTextFields["contentPhraseInput"].waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(buttons["hideContent"].waitForExistence(timeout: 5), file: file, line: line)
    }
}

final class AppPasscodeUITests: XCTestCase {
    func testEmptyTabsWrongPhraseCancelAndRelaunch() {
        continueAfterFailure = false
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["暂无内容"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["打开网址"].exists)
        XCTAssertFalse(app.buttons["appPasscodeDigit6"].exists)
        app.selectConcealedTab("收藏")
        XCTAssertTrue(app.staticTexts["暂无收藏"].exists)
        app.selectConcealedTab("离线")
        XCTAssertTrue(app.staticTexts["暂无视频"].exists)
        XCTAssertFalse(app.buttons["manageLocalStorage"].exists)
        XCTAssertFalse(app.buttons["importOfflineVideo"].exists)
        app.openContentPhrase()
        app.secureTextFields["contentPhraseInput"].typeText("654321")
        app.buttons["submitContentPhrase"].tap()
        XCTAssertEqual(app.staticTexts["contentPhraseError"].label, "未能打开，请重试")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["暂无视频"].waitForExistence(timeout: 5))
        app.unlockApp()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["暂无内容"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["hideContent"].exists)
    }

    func testBackgroundConcealsPresentedSheetAndRequiresPhraseAgain() {
        continueAfterFailure = false
        let app = isolatedApp()
        app.launchAndUnlock()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.buttons["打开网址"].tap()
        XCTAssertTrue(app.textFields["urlInput"].waitForExistence(timeout: 5))
        app.textFields["urlInput"].tap()
        app.textFields["urlInput"].typeText("https://example.com")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["暂无内容"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["urlInput"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.unlockApp()
        XCTAssertTrue(app.buttons["打开网址"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["urlInput"].exists)
    }

    func testHideKeepsRealFavoriteButRemovesItFromEmptySurface() {
        continueAfterFailure = false
        let app = isolatedApp()
        app.launchArguments += ["--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launchAndUnlock()
        defer { app.terminate() }
        XCTAssertTrue(app.webViews.staticTexts["直接视频 · 8 秒有声"].waitForExistence(timeout: 20))
        app.buttons["收藏网页"].tap()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.buttons["hideContent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["直接视频 · 8 秒有声"].waitForExistence(timeout: 5))
        app.buttons["hideContent"].tap()
        XCTAssertTrue(app.staticTexts["暂无内容"].waitForExistence(timeout: 5))
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["暂无收藏"].exists)
        XCTAssertFalse(app.staticTexts["直接视频 · 8 秒有声"].exists)
        XCTAssertFalse(app.buttons["hideContent"].exists)
        app.unlockApp()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["直接视频 · 8 秒有声"].waitForExistence(timeout: 5))
    }

    func testBackgroundClosesOfflinePlayerAndKeepsDownloadedVideo() {
        continueAfterFailure = false
        let app = isolatedApp()
        app.launchArguments += ["--fixture-url", "http://127.0.0.1:8765/direct", "--fixture-storage-budget", "1"]
        app.launchAndUnlock()
        defer { app.terminate() }
        let download = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        app.tabBars.buttons["离线"].tap()
        let row = app.buttons["offlineVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label MATCHES %@", "播放 [1-9][0-9]*\\.[0-9]+ 秒"),
                    evaluatedWith: app.staticTexts["playbackClock"])
        waitForExpectations(timeout: 10)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["暂无内容"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.staticTexts["暂无视频"].exists)
        XCTAssertFalse(row.exists)
        app.unlockApp()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        row.tap()
        XCTAssertTrue(app.staticTexts["offlinePlaybackLabel"].waitForExistence(timeout: 10))
        app.buttons["closePlayer"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "1 个视频已同步"),
                    evaluatedWith: app.staticTexts["cloudSyncStatus"])
        waitForExpectations(timeout: 20)
        app.buttons["manageLocalStorage"].tap()
        let optimize = app.switches["optimizeLocalStorageToggle"]
        XCTAssertTrue(optimize.waitForExistence(timeout: 5))
        optimize.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["closeStorageSettings"].tap()
        XCTAssertTrue(app.buttons["cloudVideoRow"].waitForExistence(timeout: 30),
                      "Concealing a player must release its old file lease so cache optimization can proceed.")
    }

    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString]
        return app
    }
}
