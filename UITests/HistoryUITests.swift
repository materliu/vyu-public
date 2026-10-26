import XCTest

final class HistoryUITests: XCTestCase {
    private let directTitle = "直接视频 · 8 秒有声"
    private let silentTitle = "无音轨视频 · 8 秒"

    func testClearHistoryCanCancelThenPersistsAndPreservesFavorite() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        launch(app, fixtureID: fixtureID, page: "direct")
        waitForPage(directTitle, in: app)
        app.buttons["收藏网页"].tap()

        openHistory(in: app)
        XCTAssertEqual(historyRows(in: app).count, 1)
        app.buttons["clearHistory"].tap()
        XCTAssertTrue(app.alerts.buttons.matching(identifier: "confirmClearHistory").firstMatch.waitForExistence(timeout: 5))
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "清空访问历史前确认（本机测试页）"
        confirmation.lifetime = .keepAlways
        add(confirmation)
        app.alerts.buttons.matching(identifier: "cancelClearHistory").firstMatch.tap()
        XCTAssertTrue(app.alerts.buttons.matching(identifier: "confirmClearHistory").firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(historyRows(in: app).count, 1)

        app.buttons["clearHistory"].tap()
        app.alerts.buttons.matching(identifier: "confirmClearHistory").firstMatch.tap()
        XCTAssertTrue(historyRows(in: app).firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["clearHistory"].isEnabled)
        let cleared = XCTAttachment(screenshot: app.screenshot())
        cleared.name = "访问历史已清空（本机测试页）"
        cleared.lifetime = .keepAlways
        add(cleared)
        app.buttons["closeHistory"].tap()

        app.buttons["打开网址"].tap()
        XCTAssertTrue(app.textFields["urlInput"].waitForExistence(timeout: 5))
        XCTAssertFalse(button(containing: directTitle, in: app).exists)
        app.buttons["取消"].tap()

        app.terminate()
        launch(app, fixtureID: fixtureID)
        XCTAssertTrue(app.buttons["openAddress"].waitForExistence(timeout: 10))
        XCTAssertFalse(button(containing: directTitle, in: app).exists)
        openHistory(in: app)
        XCTAssertEqual(historyRows(in: app).count, 0)
        app.buttons["closeHistory"].tap()

        app.tabBars.buttons["收藏"].tap()
        let favorite = button(containing: directTitle, in: app)
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
        waitForPage(directTitle, in: app)
        openHistory(in: app)
        XCTAssertTrue(historyRows(in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(historyRows(in: app).count, 1)
        app.terminate()
    }

    func testDeleteOneHistoryRowKeepsOtherVisitAndRecentManagementWorks() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        launch(app, fixtureID: fixtureID, page: "direct")
        waitForPage(directTitle, in: app)
        app.buttons["打开网址"].tap()
        let address = app.textFields["urlInput"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("http://127.0.0.1:8765/silent")
        app.buttons["navigate"].tap()
        waitForPage(silentTitle, in: app)

        openHistory(in: app)
        XCTAssertEqual(historyRows(in: app).count, 2)
        let removedRow = historyRows(in: app).matching(NSPredicate(format: "label CONTAINS %@", silentTitle)).firstMatch
        XCTAssertTrue(removedRow.exists)
        removedRow.swipeLeft()
        let remove = app.buttons["deleteHistoryRow"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(removedRow.waitForNonExistence(timeout: 5))
        XCTAssertEqual(historyRows(in: app).count, 1)
        XCTAssertTrue(historyRows(in: app).firstMatch.label.contains(directTitle))
        app.buttons["closeHistory"].tap()

        app.buttons["打开网址"].tap()
        let manage = app.buttons["manageRecent"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.buttons["closeHistory"].waitForExistence(timeout: 5))
        XCTAssertEqual(historyRows(in: app).count, 1)
        app.terminate()

        launch(app, fixtureID: fixtureID)
        XCTAssertTrue(app.buttons["openAddress"].waitForExistence(timeout: 10))
        XCTAssertTrue(button(containing: directTitle, in: app).exists)
        XCTAssertFalse(button(containing: silentTitle, in: app).exists)
        app.buttons["manageRecent"].tap()
        XCTAssertTrue(app.buttons["closeHistory"].waitForExistence(timeout: 5))
        XCTAssertEqual(historyRows(in: app).count, 1)
        XCTAssertTrue(historyRows(in: app).firstMatch.label.contains(directTitle))
        app.terminate()
    }

    private func launch(_ app: XCUIApplication, fixtureID: String, page: String? = nil) {
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        if let page { app.launchArguments += ["--fixture-url", "http://127.0.0.1:8765/\(page)"] }
        app.launch()
    }

    private func waitForPage(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["showCandidates"].waitForExistence(timeout: 5))
    }

    private func openHistory(in app: XCUIApplication) {
        let open = app.buttons["showHistory"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["closeHistory"].waitForExistence(timeout: 5))
    }

    private func historyRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "historyRow")
    }

    private func button(containing title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
}
