import XCTest
import UIKit

final class IPadLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires the dedicated VYu iPad simulator.")
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testSidebarBrowserFavoritesAddressAndRotation() throws {
        let app = launch()
        defer { app.terminate() }
        let page = app.webViews.staticTexts["直接视频 · 8 秒有声"]
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        sidebar("sidebarBrowser", in: app)
        app.buttons["收藏网页"].tap()
        sidebar("sidebarFavorites", in: app)
        let favorite = app.buttons.containing(.staticText, identifier: "直接视频 · 8 秒有声").firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 20))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        app.buttons["addressBar"].tap()
        let address = app.textFields["urlInput"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(address.isHittable)
        XCTAssertTrue(app.buttons["navigate"].isHittable)
        app.buttons["clearURLInput"].tap()
        XCTAssertFalse(app.buttons["navigate"].isEnabled)
        address.typeText("http://127.0.0.1:8765/direct")
        app.buttons["navigate"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        let candidates = app.buttons["showCandidates"]
        waitForEnabled(candidates)
        candidates.tap()
        XCTAssertTrue(app.navigationBars["下载到本机"].waitForExistence(timeout: 5))
        capture(app, name: "iPad portrait download sources")
    }

    func testOfflineActionsSheetsAndPlaybackAcrossRotation() throws {
        let app = launch()
        defer { app.terminate() }
        let download = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        sidebar("sidebarDownloads", in: app)
        let row = app.buttons["offlineVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        capture(app, name: "iPad landscape offline library")

        app.buttons["manageLocalStorage"].tap()
        XCTAssertTrue(app.switches["optimizeLocalStorageToggle"].waitForExistence(timeout: 5))
        app.buttons["closeStorageSettings"].tap()
        app.buttons["importOfflineVideo"].tap()
        XCTAssertTrue(app.buttons["chooseImportVideo"].waitForExistence(timeout: 5))
        app.buttons["cancelVideoImport"].tap()

        app.buttons["manageOfflineVideo"].tap()
        app.buttons["renameVideo"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "videoNameInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        let original = input.value as? String ?? ""
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)).tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + "iPad Sample")
        app.buttons["saveVideoName"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.label, "iPad Sample")

        let search = app.textFields["offlineVideoSearch"]
        search.tap()
        search.typeText("iPad\n")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(search.value as? String, "iPad")
        XCTAssertTrue(row.isHittable)
        row.tap()
        let clock = app.staticTexts["playbackClock"]
        expectation(for: NSPredicate(format: "exists == true AND NOT (label CONTAINS %@)", "0.0"), evaluatedWith: clock)
        waitForExpectations(timeout: 20)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["closePlayer"].waitForExistence(timeout: 5))
        capture(app, name: "iPad portrait offline playback")
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        sidebar("sidebarBrowser", in: app)
        XCTAssertTrue(app.webViews.staticTexts["直接视频 · 8 秒有声"].waitForExistence(timeout: 10))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/direct"]
        app.launchAndUnlock()
        return app
    }

    private func sidebar(_ identifier: String, in app: XCUIApplication) {
        let item = app.cells.containing(.any, identifier: identifier).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isHittable)
        item.tap()
    }

    private func waitForEnabled(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), evaluatedWith: element)
        waitForExpectations(timeout: 15)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
