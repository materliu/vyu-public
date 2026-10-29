import XCTest

/// Uses a fresh local library and loopback-only synthetic media for every launch.
final class DownloadStartupUITests: XCTestCase {
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

    func testPausedMixedLibraryColdLaunchPreservesRecordsAndRespondsToFilters() throws {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID: fixtureID, seed: true)
        defer { app.terminate() }
        openOfflineLibrary(app, seeded: true)
        enterSelection(in: app)
        let baseline = collectAllSelectionRows(in: app)
        XCTAssertEqual(baseline.count, 5)
        XCTAssertEqual(Set(baseline.values.map(\.title)), Title.all)
        waitForValue(containing: "active=false;idle=false", of: app.staticTexts["downloadActivityProbe"])

        app.terminate()
        relaunch(app, fixtureID: fixtureID)
        openOfflineLibrary(app)
        enterSelection(in: app)
        assertSameRecords(collectAllSelectionRows(in: app), as: baseline)
        XCTAssertFalse(app.buttons["pauseSelectedDownloads"].isEnabled)
        waitForValue(containing: "active=false;idle=false", of: app.staticTexts["downloadActivityProbe"])
        exerciseSearchAndSelection(in: app)
        app.tabBars.buttons["浏览"].tap()
        app.tabBars.buttons["离线"].tap()
        XCTAssertEqual(app.buttons["offlineSelectionMode"].value as? String, "未选择")
        enterSelection(in: app)
        assertSameRecords(collectAllSelectionRows(in: app), as: baseline)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
    }

    func testActiveTasksColdLaunchThenPauseAndBackgroundRoundTripPreservesIDs() throws {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID: fixtureID, seed: true)
        defer { app.terminate() }
        openOfflineLibrary(app, seeded: true)
        enterSelection(in: app)
        let baseline = collectAllSelectionRows(in: app)
        XCTAssertEqual(baseline.count, 5)
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(5, in: app)
        app.buttons["resumeSelectedDownloads"].tap()
        waitForValue(containing: "正在下载", of: task(Title.mountain, in: app))
        waitForValue(containing: "正在下载", of: task(Title.garden, in: app))
        waitForValue(containing: "active=true;idle=true", of: app.staticTexts["downloadActivityProbe"])

        // No reseeding on cold launch: retain the actual persisted fixture IDs and attempts.
        app.terminate()
        relaunch(app, fixtureID: fixtureID)
        openOfflineLibrary(app)
        enterSelection(in: app)
        app.buttons["selectAllOfflineTasks"].tap()
        waitForSelectionCount(5, in: app)
        let pause = app.buttons["pauseSelectedDownloads"]
        let restoredMountain = task(Title.mountain, in: app)
        let restoredGarden = task(Title.garden, in: app)
        // The first UI frame may precede URLSession task adoption. Do not mistake
        // that transient idle frame for finished recovery.
        let recovery = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if pause.isEnabled { return true }
            return [restoredMountain, restoredGarden].allSatisfy { row in
                guard row.exists, let value = row.value as? String else { return false }
                return ["已暂停", "下载已中断", "含音轨", "无音轨"].contains { value.contains($0) }
            }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [recovery], timeout: 20), .completed,
                       "Restoration must settle or expose an actionable pause control.")
        if pause.isEnabled { pause.tap() }
        waitForValue(containing: "active=false;idle=false", of: app.staticTexts["downloadActivityProbe"])
        let stopped = collectAllSelectionRows(in: app)
        XCTAssertEqual(Set(stopped.keys), Set(baseline.keys))
        for original in baseline.values where [Title.lake, Title.forest, Title.window].contains(original.title) {
            XCTAssertEqual(stopped[original.id].map(state), state(original),
                           "Cold launch must preserve completed, failed and cancelled fixture rows.")
        }
        for row in stopped.values where [Title.mountain, Title.garden].contains(row.title) {
            let status = state(row)
            // iOS can cancel background transfers on process termination. A safe
            // interrupted state is valid; it must neither hang nor silently duplicate/retry.
            XCTAssertTrue(["已暂停", "下载已中断", "含音轨", "无音轨"].contains(where: status.hasPrefix),
                          "Expected paused, safely interrupted, or fully validated fixture media: \(status)")
        }
        captureDiagnostics("cold-launch-transfer-outcome", in: app)
        app.buttons["offlineSelectionMode"].tap()
        let inactiveResets = inactiveResetCount(in: app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["离线"].waitForExistence(timeout: 10))
        waitForValue(containing: "active=false;idle=false", of: app.staticTexts["downloadActivityProbe"])
        XCTAssertGreaterThan(inactiveResetCount(in: app), inactiveResets)
        enterSelection(in: app)
        exerciseSearchAndSelection(in: app)
        assertSameRecords(collectAllSelectionRows(in: app), as: stopped)

        app.terminate()
        relaunch(app, fixtureID: fixtureID)
        openOfflineLibrary(app)
        enterSelection(in: app)
        assertSameRecords(collectAllSelectionRows(in: app), as: stopped)
        waitForValue(containing: "active=false;idle=false", of: app.staticTexts["downloadActivityProbe"])
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
    }

    private func launch(fixtureID: String, seed: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID, "--fixture-observe-idle-timer"]
        if seed {
            app.launchArguments += ["--fixture-url", "http://127.0.0.1:8765/batch", "--fixture-offline-batch"]
        }
        launchedApp = app
        app.launch()
        return app
    }

    private func relaunch(_ app: XCUIApplication, fixtureID: String) {
        app.launchArguments = ["--fixture-cloud-sync", fixtureID, "--fixture-observe-idle-timer"]
        app.launch()
    }

    private func openOfflineLibrary(_ app: XCUIApplication, seeded: Bool = false) {
        if seeded {
            wait(for: NSPredicate(format: "exists == true AND value == %@", "ready"),
                 on: app.staticTexts["offlineBatchFixtureReady"], timeout: 60)
        }
        let offline = app.tabBars.buttons["离线"]
        XCTAssertTrue(offline.waitForExistence(timeout: 10))
        offline.tap()
        waitUntilEnabled(app.buttons["offlineSelectionMode"])
    }

    private func enterSelection(in app: XCUIApplication) {
        app.buttons["offlineSelectionMode"].tap()
        waitForSelectionCount(0, in: app)
    }

    private func state(_ row: SelectionRowSnapshot) -> String {
        row.value.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }

    private func assertSameRecords(_ rows: [String: SelectionRowSnapshot],
                                   as baseline: [String: SelectionRowSnapshot],
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(rows.keys), Set(baseline.keys), file: file, line: line)
        for (id, original) in baseline {
            XCTAssertEqual(rows[id]?.title, original.title, file: file, line: line)
            XCTAssertEqual(rows[id].map(state), state(original), file: file, line: line)
        }
    }

    private func exerciseSearchAndSelection(in app: XCUIApplication) {
        let search = app.textFields["offlineVideoSearch"]
        search.tap(); search.typeText("山间\n")
        waitForSelectionCount(0, in: app)
        XCTAssertEqual(selectionRows(in: app).count, 1)
        let row = task(Title.mountain, in: app)
        row.tap()
        waitForSelectionCount(1, in: app)
        app.buttons["clearOfflineSearch"].tap()
        waitForSelectionCount(1, in: app)
        app.buttons["offlineSelectionMode"].tap()
        XCTAssertTrue(app.staticTexts["offlineSelectionSummary"].waitForNonExistence(timeout: 5))
        enterSelection(in: app)
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

}
