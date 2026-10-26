import XCTest

final class BrowserPopupUITests: XCTestCase {
    func testRealTapOpensPopupAndNativeCloseKeepsParentVideo() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.webViews.staticTexts["弹窗通信测试"].waitForExistence(timeout: 20))
        app.webViews.buttons["打开 GET 弹窗"].tap()
        XCTAssertTrue(app.buttons["closeBrowserPopup"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["独立窗口已打开"].waitForExistence(timeout: 10))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "独立登录弹窗（本机合成测试页）"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["closeBrowserPopup"].tap()
        XCTAssertTrue(app.buttons["closeBrowserPopup"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["弹窗通信测试"].waitForExistence(timeout: 5))
        assertParentVideoAvailable(in: app)
    }

    func testRealFormSubmissionPreservesPOSTAndReturnsThenClosesPopup() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.webViews.staticTexts["弹窗通信测试"].waitForExistence(timeout: 20))
        app.webViews.buttons["提交 POST 弹窗"].tap()
        XCTAssertTrue(app.buttons["closeBrowserPopup"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["请求方法：POST"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["合成表单已收到"].exists)
        let popup = app.webViews["browserPopupWebView"]
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        let complete = popup.buttons["完成合成登录"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        // The child WebView exposes correct bounds, but XCTest cannot compute its
        // hit point on this simulator. Send a real touch and verify the result.
        complete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.buttons["closeBrowserPopup"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["弹窗返回：fixture-marker"].waitForExistence(timeout: 5))
        assertParentVideoAvailable(in: app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/popup-parent"]
        app.launch()
        return app
    }

    private func assertParentVideoAvailable(in app: XCUIApplication,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["showCandidates"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
        button.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.buttons.matching(identifier: "candidate-file").firstMatch.waitForExistence(timeout: 10), file: file, line: line)
    }


}
