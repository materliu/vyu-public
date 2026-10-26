import XCTest

final class LocalVideoImportUITests: XCTestCase {
    func testOfflineImportExplainsSystemRecordingAndCanCancelWithoutPhotoAccess() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        let open = app.buttons["importOfflineVideo"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["chooseImportVideo"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["saveImportedVideo"].isEnabled)
        XCTAssertTrue(app.staticTexts["下载失败时，也可导入录屏"].exists)
        // No picker or photo-library access is opened merely by visiting the help sheet.
        app.buttons["cancelVideoImport"].tap()
        XCTAssertTrue(app.buttons["chooseImportVideo"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(open.exists)
        app.terminate()
    }
}
