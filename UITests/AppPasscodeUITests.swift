import XCTest

extension XCUIApplication {
    func launchAndUnlock() {
        launch()
        unlockApp()
    }

    func unlockApp(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(buttons["appPasscodeDigit6"].waitForExistence(timeout: 10), file: file, line: line)
        enterAppPasscode("654321")
        XCTAssertTrue(buttons["appPasscodeDigit6"].waitForNonExistence(timeout: 5), file: file, line: line)
    }

    func enterAppPasscode(_ digits: String) {
        for digit in digits { buttons["appPasscodeDigit\(digit)"].tap() }
    }
}

final class AppPasscodeUITests: XCTestCase {
    func testColdLaunchWrongPasscodeDeleteAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["appPasscodeDigit6"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["浏览"].isHittable)
        app.enterAppPasscode("000000")
        XCTAssertEqual(app.staticTexts["appPasscodeError"].label, "密码错误，请重新输入")
        XCTAssertEqual(app.otherElements["appPasscodeProgress"].value as? String, "已输入 0 位，共 6 位")
        app.enterAppPasscode("60")
        app.buttons["appPasscodeDelete"].tap()
        XCTAssertEqual(app.otherElements["appPasscodeProgress"].value as? String, "已输入 1 位，共 6 位")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "V语六位密码盘"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.enterAppPasscode("54321")
        XCTAssertTrue(app.buttons["appPasscodeDigit6"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["浏览"].isHittable)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["appPasscodeDigit6"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["浏览"].isHittable)
        app.unlockApp()
    }

    func testBackgroundLockCoversPresentedSheetAndPreservesItAfterUnlock() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString]
        app.launchAndUnlock()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.buttons["打开网址"].tap()
        XCTAssertTrue(app.textFields["urlInput"].waitForExistence(timeout: 5))
        app.textFields["urlInput"].tap()
        app.textFields["urlInput"].typeText("https://example.com")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.buttons["appPasscodeDigit6"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["urlInput"].isHittable, "The gate must also cover presented sheets.")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.unlockApp()
        XCTAssertTrue(app.textFields["urlInput"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["urlInput"].value as? String, "https://example.com")
    }
}
