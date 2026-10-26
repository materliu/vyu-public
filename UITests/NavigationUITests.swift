import XCTest

final class NavigationUITests: XCTestCase {
    func testRedirectedFirstPageIsVisibleAndOpensDownloadCandidates() throws {
        continueAfterFailure = false
        let app = launch(url: "http://127.0.0.1:8765/navigation-redirect")
        defer { app.terminate() }

        XCTAssertTrue(app.webViews.staticTexts["直接视频 · 8 秒有声"].waitForExistence(timeout: 20),
                      "The redirected page must be mounted and visible, not hidden behind the home screen.")
        XCTAssertTrue(app.buttons["addressBar"].exists)
        let showCandidates = app.buttons["showCandidates"]
        waitUntilEnabled(showCandidates)
        showCandidates.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForExistence(timeout: 5))
        let candidate = app.buttons.matching(identifier: "candidate-file").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        waitUntilEnabled(candidate)
        candidate.tap()
        waitUntilEnabled(app.buttons["startDownload"], timeout: 20)
        XCTAssertTrue(app.staticTexts["inspectionSummary"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "重定向后的网页可选择视频（本机测试页）"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstConnectionFailureOffersRetryAndCanOpenAnotherAddress() throws {
        continueAfterFailure = false
        // A closed loopback port fails promptly without a timing-sensitive stop gesture.
        let app = launch(url: "http://127.0.0.1:1/")
        defer { app.terminate() }

        let retry = app.buttons["retryPage"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["showCandidates"].isEnabled)
        waitUntilEnabled(retry)
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        waitUntilEnabled(retry)
        XCTAssertTrue(app.buttons["修改网址"].exists)

        app.buttons["打开网址"].tap()
        let address = app.textFields["urlInput"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("http://127.0.0.1:8765/direct")
        app.buttons["navigate"].tap()
        XCTAssertTrue(app.webViews.staticTexts["直接视频 · 8 秒有声"].waitForExistence(timeout: 20))
        waitUntilEnabled(app.buttons["showCandidates"])
        XCTAssertFalse(retry.exists)
    }

    private func launch(url: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString, "--fixture-url", url]
        app.launch()
        return app
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected an enabled, tappable control.", file: file, line: line)
    }
}
