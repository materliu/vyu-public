import XCTest

/// Uses a fresh local library and loopback-only synthetic media for every launch.
final class OfflineBatchUITests: XCTestCase {
    private var launchedApp: XCUIApplication?
    private var capturingDiagnostics = false

    override func record(_ issue: XCTIssue) {
        if !capturingDiagnostics, let app = launchedApp, app.state != .notRunning {
            captureDiagnostics("failure-\(issue.compactDescription)", in: app, keepAlways: true)
        }
        super.record(issue)
    }

    private enum Title {
        static let mountain = "山间练习甲"
        static let garden = "花园练习乙"
        static let lake = "湖边练习丙"
        static let forest = "树林练习丁"
        static let window = "窗边练习戊"
        static let all: Set<String> = [mountain, garden, lake, forest, window]
    }

    private struct SelectionRowSnapshot {
        let id: String
        let title: String
        let value: String
    }

    func testMixedTasksCanResumePauseAndResumeAllWithoutDuplicatingRecords() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        openSeededOfflineLibrary(app)
        app.buttons["offlineSelectionMode"].tap()
        waitForSelectionCount(0, in: app)
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(5, in: app)
        captureDiagnostics("mixed-selection-all-before-button-assertions", in: app)
        let originalRows = collectAllSelectionRows(in: app)
        let originalIDs = Set(originalRows.keys)
        XCTAssertEqual(originalIDs.count, 5)
        XCTAssertEqual(Set(originalRows.values.map(\.title)), Title.all)
        let unchanged = originalRows.values.filter { [Title.lake, Title.forest, Title.window].contains($0.title) }
        XCTAssertEqual(unchanged.count, 3)
        XCTAssertTrue(app.buttons["resumeSelectedDownloads"].isEnabled)
        XCTAssertFalse(app.buttons["pauseSelectedDownloads"].isEnabled)

        app.buttons["resumeSelectedDownloads"].tap()
        waitForValue(containing: "正在下载", of: task(Title.mountain, in: app))
        waitForValue(containing: "正在下载", of: task(Title.garden, in: app))
        let activityProbe = app.staticTexts["downloadActivityProbe"]
        waitForValue(containing: "active=true;idle=true", of: activityProbe)
        let inactiveResets = inactiveResetCount(in: app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        waitForValue(containing: "active=true;idle=true", of: activityProbe)
        XCTAssertGreaterThan(inactiveResetCount(in: app), inactiveResets,
                             "Leaving the foreground must restore the actual system idle timer.")
        XCTAssertFalse(app.buttons["resumeSelectedDownloads"].isEnabled)
        XCTAssertTrue(app.buttons["pauseSelectedDownloads"].isEnabled)
        app.buttons["pauseSelectedDownloads"].tap()
        waitForValue(containing: "已暂停", of: task(Title.mountain, in: app))
        waitForValue(containing: "已暂停", of: task(Title.garden, in: app))
        waitForValue(containing: "active=false;idle=false", of: activityProbe)
        waitUntilEnabled(app.buttons["resumeAllDownloads"])

        let search = app.textFields["offlineVideoSearch"]
        search.tap(); search.typeText("山间\n")
        waitForSelectionCount(1, in: app)
        XCTAssertEqual(selectionRows(in: app).count, 1)

        // Actual repeated touches also cover the disabled state after the first tap.
        let resumeAll = app.buttons["resumeAllDownloads"]
        let repeatedTap = resumeAll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        resumeAll.tap()
        repeatedTap.tap()
        repeatedTap.tap()
        app.buttons["clearOfflineSearch"].tap()
        waitForSelectionCount(1, in: app)
        waitForValue(containing: "正在下载", of: task(Title.mountain, in: app))
        waitForValue(containing: "正在下载", of: task(Title.garden, in: app))
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(5, in: app)
        XCTAssertFalse(resumeAll.isEnabled)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)

        // Inspect the whole lazy list after pausing, outside the transfer timing window.
        app.buttons["pauseSelectedDownloads"].tap()
        waitForValue(containing: "已暂停", of: task(Title.mountain, in: app))
        waitForValue(containing: "已暂停", of: task(Title.garden, in: app))
        waitForValue(containing: "active=false;idle=false", of: activityProbe)
        let finalRows = collectAllSelectionRows(in: app)
        XCTAssertEqual(finalRows.count, 5)
        XCTAssertEqual(Set(finalRows.keys), originalIDs, "Batch actions must reuse the existing records.")
        for original in unchanged {
            XCTAssertEqual(finalRows[original.id]?.value, original.value,
                           "Completed, failed and cancelled items must not restart: \(original.title)")
        }
    }

    func testSelectionFollowsSearchAndFavoritesAndClearsOnExitOrTabChange() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        openSeededOfflineLibrary(app)
        app.buttons["offlineSelectionMode"].tap()
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(5, in: app)
        captureDiagnostics("filter-selection-all-before-search", in: app)

        let search = app.textFields["offlineVideoSearch"]
        search.tap(); search.typeText("山间\n")
        waitForSelectionCount(1, in: app)
        captureDiagnostics("filter-selection-single-before-button-assertions", in: app)
        XCTAssertEqual(selectionRows(in: app).count, 1)
        XCTAssertEqual(selectionRows(in: app).firstMatch.label, Title.mountain)
        app.buttons["clearOfflineSearch"].tap()
        waitForSelectionCount(1, in: app)
        let restoredRows = collectAllSelectionRows(in: app)
        XCTAssertEqual(restoredRows.count, 5,
                       "Items returning after a filter change must not regain stale selection.")
        XCTAssertEqual(Set(restoredRows.values.map(\.title)), Title.all)
        XCTAssertEqual(restoredRows.values.filter { $0.value.hasPrefix("已选择") }.map(\.title), [Title.mountain])
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        waitForSelectionCount(1, in: app)
        XCTAssertEqual(selectionRows(in: app).count, 1)
        XCTAssertEqual(selectionRows(in: app).firstMatch.label, Title.mountain)
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(0, in: app)
        XCTAssertFalse(app.buttons["resumeSelectedDownloads"].isEnabled)
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(1, in: app)
        app.segmentedControls["offlineVideoFilter"].buttons["全部"].tap()
        waitForSelectionCount(1, in: app)

        search.tap(); search.typeText("花园\n")
        waitForSelectionCount(0, in: app)
        XCTAssertFalse(app.buttons["resumeSelectedDownloads"].isEnabled)
        task(Title.garden, in: app).tap()
        waitForSelectionCount(1, in: app)
        app.buttons["clearOfflineSearch"].tap()
        waitForSelectionCount(1, in: app)
        app.buttons["offlineSelectionMode"].tap()
        XCTAssertTrue(app.staticTexts["offlineSelectionSummary"].waitForNonExistence(timeout: 5))
        app.buttons["offlineSelectionMode"].tap()
        waitForSelectionCount(0, in: app)
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(5, in: app)
        app.tabBars.buttons["浏览"].tap()
        app.tabBars.buttons["离线"].tap()
        XCTAssertEqual(app.buttons["offlineSelectionMode"].value as? String, "未选择")
        XCTAssertFalse(app.staticTexts["offlineSelectionSummary"].exists)
        app.buttons["offlineSelectionMode"].tap()
        waitForSelectionCount(0, in: app)
        XCTAssertFalse(app.buttons["resumeSelectedDownloads"].isEnabled)
        XCTAssertFalse(app.buttons["pauseSelectedDownloads"].isEnabled)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
    }

    func testClearingAddressKeepsInputFocusAndCancellingReturnsToCurrentPage() throws {
        continueAfterFailure = false
        let app = launch(seedBatch: false)
        defer { app.terminate() }
        let page = app.webViews.staticTexts["直接视频 · 8 秒有声"]
        XCTAssertTrue(page.waitForExistence(timeout: 20))

        app.buttons["addressBar"].tap()
        let address = app.textFields["urlInput"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        captureDiagnostics("address-prefilled-before-field-tap", in: app)
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:8765/direct")
        XCTAssertTrue(app.buttons["navigate"].isEnabled)
        XCTAssertTrue(app.buttons["clearURLInput"].exists)
        address.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        captureDiagnostics("address-after-field-tap-before-first-clear", in: app)
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:8765/direct",
                       "Focusing the text field must not clear its existing value.")
        XCTAssertTrue(app.buttons["navigate"].isEnabled)
        app.buttons["clearURLInput"].tap()
        captureDiagnostics("address-after-first-clear", in: app)
        XCTAssertFalse(app.buttons["navigate"].isEnabled)
        XCTAssertTrue(app.navigationBars["去一个站点"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clearing must preserve the keyboard.")
        assertClearCannotNavigateEmptyAddress(app)

        // No second tap on the field: typing proves the clear button returned focus.
        address.typeText("http://127.0.0.1:8765/forbidden")
        captureDiagnostics("address-after-typing-without-refocusing", in: app)
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:8765/forbidden")
        XCTAssertTrue(app.buttons["navigate"].isEnabled)
        app.buttons["clearURLInput"].tap()
        captureDiagnostics("address-after-second-clear", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["navigate"].isEnabled)
        app.navigationBars["去一个站点"].buttons["取消"].tap()
        XCTAssertTrue(address.waitForNonExistence(timeout: 5))
        XCTAssertTrue(page.waitForExistence(timeout: 5), "Clearing and cancelling must preserve the current page.")
        XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected)
        XCTAssertFalse(app.buttons["返回网页"].isEnabled, "Editing must not add a navigation entry.")

        // The new-address entry point starts empty and remains editable.
        app.buttons["打开网址"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        captureDiagnostics("new-address-empty-after-field-tap", in: app)
        assertClearCannotNavigateEmptyAddress(app)
        address.typeText("http://127.0.0.1:8765/slow")
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:8765/slow")
        app.navigationBars["去一个站点"].buttons["取消"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["浏览"].isSelected)
    }

    private func launch(seedBatch: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", UUID().uuidString,
                               "--fixture-url", "http://127.0.0.1:8765/" + (seedBatch ? "batch" : "direct")]
        if seedBatch { app.launchArguments += ["--fixture-offline-batch", "--fixture-observe-idle-timer"] }
        launchedApp = app
        app.launch()
        return app
    }

    private func openSeededOfflineLibrary(_ app: XCUIApplication) {
        wait(for: NSPredicate(format: "exists == true AND value == %@", "ready"),
             on: app.staticTexts["offlineBatchFixtureReady"], timeout: 60)
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineSelectionMode"].waitForExistence(timeout: 10))
        waitUntilEnabled(app.buttons["offlineSelectionMode"])
    }

    private func selectionRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "offlineTaskSelection-"))
    }

    private func task(_ title: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = selectionRows(in: app).matching(NSPredicate(format: "label == %@", title)).firstMatch
        if row.exists && row.isHittable { return row }
        scrollSelectionListToStart(in: app)
        for _ in 0..<8 {
            if row.exists && row.isHittable { return row }
            let before = visibleSelectionSignature(in: app)
            scrollSelectionList(towardEnd: true, in: app)
            if visibleSelectionSignature(in: app) == before { break }
        }
        XCTAssertTrue(row.exists && row.isHittable, "Expected a real selectable button after scrolling: \(title)",
                      file: file, line: line)
        return row
    }

    private func collectAllSelectionRows(in app: XCUIApplication,
                                         file: StaticString = #filePath, line: UInt = #line) -> [String: SelectionRowSnapshot] {
        scrollSelectionListToStart(in: app)
        var result: [String: SelectionRowSnapshot] = [:]
        var reachedEnd = false
        for _ in 0..<8 {
            for row in selectionRows(in: app).allElementsBoundByIndex {
                let value = row.value as? String
                XCTAssertNotNil(value, "Selectable rows must expose their state.", file: file, line: line)
                result[row.identifier] = SelectionRowSnapshot(id: row.identifier, title: row.label, value: value ?? "")
            }
            let before = visibleSelectionSignature(in: app)
            scrollSelectionList(towardEnd: true, in: app)
            if visibleSelectionSignature(in: app) == before { reachedEnd = true; break }
        }
        let summary = result.values.sorted { $0.title < $1.title }
            .map { "\($0.id) | \($0.title) | \($0.value)" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: "Reached list end: \(reachedEnd)\n\(summary)")
        attachment.name = "Scrolled selection records"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        XCTAssertTrue(reachedEnd, "The bounded scroll must reach the end before counting all records.",
                      file: file, line: line)
        return result
    }

    private func scrollSelectionListToStart(in app: XCUIApplication) {
        for _ in 0..<8 {
            let before = visibleSelectionSignature(in: app)
            scrollSelectionList(towardEnd: false, in: app)
            if visibleSelectionSignature(in: app) == before { return }
        }
        XCTFail("The bounded scroll did not reach the beginning of the selection list.")
    }

    private func visibleSelectionSignature(in app: XCUIApplication) -> [String] {
        selectionRows(in: app).allElementsBoundByIndex.map {
            "\($0.identifier):\(Int($0.frame.minY.rounded()))"
        }
    }

    private func scrollSelectionList(towardEnd: Bool, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists, "The offline list must remain scrollable in selection mode.")
        let frame = list.frame.intersection(app.frame)
        let bottom = min(frame.maxY, app.tabBars.firstMatch.frame.minY) - 12
        let top = frame.minY + 12
        XCTAssertGreaterThan(bottom - top, 60, "There must be visible list space above the tab bar.")
        let startY = towardEnd ? bottom - 8 : top + 8
        let endY = towardEnd ? top + 8 : bottom - 8
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.midX, dy: startY))
        let end = origin.withOffset(CGVector(dx: frame.midX, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func inactiveResetCount(in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) -> Int {
        let value = app.staticTexts["downloadActivityProbe"].value as? String ?? ""
        let count = value.split(separator: ";").first(where: { $0.hasPrefix("inactiveResets=") })
            .flatMap { Int($0.dropFirst("inactiveResets=".count)) }
        XCTAssertNotNil(count, "Expected the DEBUG probe to report actual inactive resets: \(value)",
                        file: file, line: line)
        return count ?? -1
    }

    private func captureDiagnostics(_ name: String, in app: XCUIApplication, keepAlways: Bool = false) {
        guard !capturingDiagnostics else { return }
        capturingDiagnostics = true
        defer { capturingDiagnostics = false }
        let controls: [(String, XCUIElement)] = [
            ("urlInput", app.textFields["urlInput"]),
            ("clearURLInput", app.buttons["clearURLInput"]),
            ("navigate", app.buttons["navigate"]),
            ("keyboard", app.keyboards.firstMatch),
            ("offlineSelectionMode", app.buttons["offlineSelectionMode"]),
            ("offlineSelectionSummary", app.staticTexts["offlineSelectionSummary"]),
            ("resumeSelectedDownloads", app.buttons["resumeSelectedDownloads"]),
            ("pauseSelectedDownloads", app.buttons["pauseSelectedDownloads"]),
            ("resumeAllDownloads", app.buttons["resumeAllDownloads"]),
            ("offlineBatchFixtureReady", app.staticTexts["offlineBatchFixtureReady"]),
            ("downloadActivityProbe", app.staticTexts["downloadActivityProbe"])
        ]
        let states = controls.map { identifier, element in
            guard element.exists else { return "\(identifier): exists=false" }
            return "\(identifier): exists=true; enabled=\(element.isEnabled); hittable=\(element.isHittable); " +
                "type=\(element.elementType.rawValue); label=\(element.label); value=\(String(describing: element.value)); frame=\(element.frame)"
        }.joined(separator: "\n")
        let text = XCTAttachment(string: "\(name)\n\(states)\n\nAccessibility hierarchy:\n\(app.debugDescription)")
        text.name = name + "-accessibility"
        text.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(text)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name + "-screenshot"
        screenshot.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(screenshot)
    }

    private func waitForSelectionCount(_ count: Int, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        wait(for: NSPredicate(format: "exists == true AND label == %@", "已选择 \(count) 项"),
             on: app.staticTexts["offlineSelectionSummary"], file: file, line: line)
    }

    private func waitForValue(containing text: String, of element: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        wait(for: NSPredicate(format: "exists == true AND value CONTAINS %@", text),
             on: element, timeout: 15, file: file, line: line)
    }

    private func waitUntilEnabled(_ element: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        wait(for: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
             on: element, file: file, line: line)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected control state: \(predicate.predicateFormat)", file: file, line: line)
    }

    private func assertClearCannotNavigateEmptyAddress(_ app: XCUIApplication,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        let clear = app.buttons["clearURLInput"]
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(app.buttons["navigate"].isEnabled, file: file, line: line)
        XCTAssertTrue(app.textFields["urlInput"].exists, file: file, line: line)
        XCTAssertTrue(app.navigationBars["去一个站点"].exists, file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.exists, file: file, line: line)
    }
}
