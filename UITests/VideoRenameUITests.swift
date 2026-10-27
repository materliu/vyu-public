import XCTest

/// Every test uses a fresh local library and the loopback-only cloud/media fixture.
final class VideoRenameUITests: XCTestCase {
    func testLocalSwipesFavoriteRenameSaveCancelAndSelectionMode() throws {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID: fixtureID)
        defer { app.terminate() }
        downloadDirectVideo(in: app)
        let row = app.buttons["offlineVideoRow"]
        let originalTitle = row.label

        toggleFavoriteBySwiping(row, in: app)
        waitForValue(containing: "已收藏", on: row)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)

        openRenameBySwiping(row, in: app)
        XCTAssertEqual(nameInput(in: app).value as? String, originalTitle)
        replaceName(with: "未保存的滑动改名", in: app)
        app.buttons["cancelVideoName"].tap()
        XCTAssertTrue(nameInput(in: app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.label, originalTitle)
        waitForValue(containing: "已收藏", on: row)

        openRenameBySwiping(row, in: app)
        replaceName(with: "Swipe Meadow", in: app)
        saveName(in: app)
        waitForLabel("Swipe Meadow", on: row)
        waitForValue(containing: "已收藏", on: row)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists,
                       "Swiping to rename must not activate the underlying playback button.")

        app.buttons["offlineSelectionMode"].tap()
        let selection = selectionRows(in: app).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        selection.swipeLeft()
        XCTAssertFalse(app.buttons["swipeVideoRename"].exists)
        XCTAssertFalse(nameInput(in: app).exists)
        selection.swipeRight()
        XCTAssertFalse(app.buttons["swipeVideoFavorite"].exists)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        app.buttons["offlineSelectionMode"].tap()

        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        waitForLabel("Swipe Meadow", on: row)
        waitForValue(containing: "已收藏", on: row)
        toggleFavoriteBySwiping(row, in: app)
        wait(for: NSPredicate(format: "exists == true AND NOT (value CONTAINS %@)", "已收藏"), on: row)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
    }

    func testCloudSwipesFavoriteAndRenameWithoutRestoringMedia() throws {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID: fixtureID)
        defer { app.terminate() }
        downloadDirectVideo(in: app)
        wait(for: NSPredicate(format: "label CONTAINS %@", "1 个视频已同步"),
             on: app.staticTexts["cloudSyncStatus"], timeout: 20)
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["删除本机缓存"].tap()
        let row = app.buttons["cloudVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let originalTitle = row.label

        toggleFavoriteBySwiping(row, in: app)
        waitForValue(containing: "已收藏", on: row)
        openRenameBySwiping(row, in: app)
        replaceName(with: "未保存的云端改名", in: app)
        app.buttons["cancelVideoName"].tap()
        XCTAssertTrue(nameInput(in: app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.label, originalTitle)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)

        openRenameBySwiping(row, in: app)
        replaceName(with: "Swipe Cloud Meadow", in: app)
        saveName(in: app)
        waitForLabel("Swipe Cloud Meadow", on: row)
        waitForValue(containing: "已收藏", on: row)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists,
                       "Swiping a cloud row must not begin a media restore.")
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        toggleFavoriteBySwiping(row, in: app)
        wait(for: NSPredicate(format: "exists == true AND NOT (value CONTAINS %@)", "已收藏"), on: row)

        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        waitForLabel("Swipe Cloud Meadow", on: row)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
    }

    func testRenameCancelEmptyInputSearchAndRelaunchPreserveOrganization() throws {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID: fixtureID)
        defer { app.terminate() }
        downloadDirectVideo(in: app)
        let row = app.buttons["offlineVideoRow"]
        let originalTitle = row.label
        XCTAssertFalse(originalTitle.isEmpty)

        openRename(in: app)
        XCTAssertEqual(nameInput(in: app).value as? String, originalTitle)
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled)
        replaceName(with: "未保存的草稿", in: app)
        app.buttons["cancelVideoName"].tap()
        XCTAssertTrue(nameInput(in: app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.label, originalTitle)

        openRename(in: app)
        replaceName(with: "", in: app)
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled)
        nameInput(in: app).typeText("   ")
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled)
        app.buttons["cancelVideoName"].tap()
        XCTAssertEqual(row.label, originalTitle)

        openRename(in: app)
        replaceName(with: "  Meadow Morning  ", in: app)
        saveName(in: app)
        waitForLabel("Meadow Morning", on: row)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists,
                       "Editing a name must not start playback.")

        search(originalTitle, in: app)
        XCTAssertTrue(app.staticTexts["offlineSearchEmpty"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        search("Meadow", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "Meadow Morning")

        openRename(in: app)
        XCTAssertEqual(nameInput(in: app).value as? String, "Meadow Morning")
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled)
        nameInput(in: app).typeText("  ")
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled,
                       "Whitespace-only changes must not create another edit.")
        app.buttons["cancelVideoName"].tap()

        app.buttons["manageOfflineVideo"].tap()
        app.buttons["toggleVideoFavorite"].tap()
        waitForValue(containing: "已收藏", on: row)
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        XCTAssertTrue(row.exists)
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["editVideoTags"].tap()
        XCTAssertTrue(app.staticTexts["tagEditorVideoTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["tagEditorVideoTitle"].label, "Meadow Morning")
        let tags = app.textViews["videoTagInput"]
        tags.tap(); tags.typeText("练习")
        app.buttons["saveVideoTags"].tap()
        XCTAssertTrue(tags.waitForNonExistence(timeout: 5))
        search("Meadow #练习", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "Meadow Morning")

        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertEqual(row.label, "Meadow Morning")
        waitForValue(containing: "已收藏", on: row)
        waitForValue(containing: "练习", on: row)
        search("Meadow #练习", in: app)
        XCTAssertTrue(row.exists)
        openRename(in: app)
        XCTAssertEqual(nameInput(in: app).value as? String, "Meadow Morning")
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled)
        app.buttons["cancelVideoName"].tap()
    }

    func testPausedAndFailedNamesSurviveBatchResumeAndRepeatedEdits() throws {
        continueAfterFailure = false
        let app = launch(fixtureID: UUID().uuidString, seedBatch: true)
        defer { app.terminate() }
        wait(for: NSPredicate(format: "exists == true AND value == %@", "ready"),
             on: app.staticTexts["offlineBatchFixtureReady"], timeout: 60)
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineSelectionMode"].waitForExistence(timeout: 10))

        search("山间练习甲", in: app)
        app.buttons["offlineSelectionMode"].tap()
        let originalPaused = selectionRows(in: app).firstMatch
        XCTAssertTrue(originalPaused.waitForExistence(timeout: 5))
        let pausedID = originalPaused.identifier
        waitForValue(containing: "已暂停", on: originalPaused)
        app.buttons["offlineSelectionMode"].tap()

        openRename(in: app)
        replaceName(with: "Mountain Practice", in: app)
        saveName(in: app)
        XCTAssertTrue(app.staticTexts["offlineSearchEmpty"].waitForExistence(timeout: 5),
                      "The former title filter must update immediately after saving.")
        search("Mountain #练习", in: app)
        app.segmentedControls["offlineVideoFilter"].buttons["已收藏"].tap()
        XCTAssertTrue(app.buttons["manageOfflineVideo"].waitForExistence(timeout: 5))
        openRename(in: app)
        XCTAssertEqual(nameInput(in: app).value as? String, "Mountain Practice")
        replaceName(with: "Mountain Revised", in: app)
        saveName(in: app)

        app.buttons["offlineSelectionMode"].tap()
        let paused = app.buttons[pausedID]
        XCTAssertTrue(paused.waitForExistence(timeout: 5))
        XCTAssertEqual(paused.label, "Mountain Revised")
        XCTAssertEqual(selectionRows(in: app).count, 1)
        waitForValue(containing: "已暂停", on: paused)
        paused.tap()
        wait(for: NSPredicate(format: "label == %@", "已选择 1 项"),
             on: app.staticTexts["offlineSelectionSummary"])
        XCTAssertTrue(app.buttons["resumeSelectedDownloads"].isEnabled)
        app.buttons["resumeSelectedDownloads"].tap()
        waitForValue(containing: "正在下载", on: paused)
        XCTAssertEqual(paused.label, "Mountain Revised")
        app.buttons["pauseSelectedDownloads"].tap()
        waitForValue(containing: "已暂停", on: paused)
        XCTAssertEqual(paused.label, "Mountain Revised")
        XCTAssertEqual(paused.identifier, pausedID)
        XCTAssertEqual(selectionRows(in: app).count, 1,
                       "Continuing a renamed item must not create a duplicate row.")
        app.buttons["offlineSelectionMode"].tap()

        app.segmentedControls["offlineVideoFilter"].buttons["全部"].tap()
        search("湖边练习丙", in: app)
        app.buttons["offlineSelectionMode"].tap()
        let originalFailed = selectionRows(in: app).firstMatch
        XCTAssertTrue(originalFailed.waitForExistence(timeout: 5))
        let failedID = originalFailed.identifier
        let failureValue = originalFailed.value as? String
        XCTAssertTrue(failureValue?.contains("403") == true)
        app.buttons["offlineSelectionMode"].tap()
        openRename(in: app)
        replaceName(with: "Lake Review", in: app)
        saveName(in: app)
        search("Lake Review", in: app)
        app.buttons["offlineSelectionMode"].tap()
        let failed = app.buttons[failedID]
        XCTAssertTrue(failed.waitForExistence(timeout: 5))
        XCTAssertEqual(failed.label, "Lake Review")
        XCTAssertEqual(failed.value as? String, failureValue,
                       "Renaming must preserve the failure and stable record ID.")
        failed.tap()
        XCTAssertFalse(app.buttons["resumeSelectedDownloads"].isEnabled)
        XCTAssertFalse(app.buttons["pauseSelectedDownloads"].isEnabled)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
    }

    func testCloudOnlyRenameKeepsLongTitleAfterRelaunch() throws {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID: fixtureID)
        defer { app.terminate() }
        downloadDirectVideo(in: app)
        wait(for: NSPredicate(format: "label CONTAINS %@", "1 个视频已同步"),
             on: app.staticTexts["cloudSyncStatus"], timeout: 20)
        app.buttons["manageOfflineVideo"].tap()
        app.buttons["删除本机缓存"].tap()
        let row = app.buttons["cloudVideoRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists)

        let longTitle = "LongNameStart " + String(repeating: "山", count: 260) + " End"
        openRename(in: app, cloudOnly: true)
        replaceName(with: longTitle, in: app)
        saveName(in: app)
        waitForLabel(longTitle, on: row)
        XCTAssertFalse(app.staticTexts["offlinePlaybackLabel"].exists)
        search("LongNameStart", in: app)
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.label, longTitle, "A long name must not be silently shortened to 240 characters.")

        app.terminate()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID]
        app.launch()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertEqual(row.label, longTitle)
        openRename(in: app, cloudOnly: true)
        XCTAssertEqual(nameInput(in: app).value as? String, longTitle)
        XCTAssertFalse(app.buttons["saveVideoName"].isEnabled)
        app.buttons["cancelVideoName"].tap()
        XCTAssertEqual(row.label, longTitle)
        XCTAssertFalse(app.buttons["offlineVideoRow"].exists,
                       "Renaming a cloud-only item must not download its media.")
    }

    private func launch(fixtureID: String, seedBatch: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-cloud-sync", fixtureID, "--fixture-url",
                               "http://127.0.0.1:8765/" + (seedBatch ? "batch" : "direct")]
        if seedBatch { app.launchArguments += ["--fixture-offline-batch"] }
        app.launch()
        return app
    }

    private func downloadDirectVideo(in app: XCUIApplication) {
        let inline = app.webViews.buttons["下载此视频"]
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        inline.tap()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.buttons["offlineVideoRow"].waitForExistence(timeout: 60))
    }

    private func nameInput(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "videoNameInput").firstMatch
    }

    private func openRename(in app: XCUIApplication, cloudOnly: Bool = false) {
        let menu = app.buttons[cloudOnly ? "manageCloudVideo" : "manageOfflineVideo"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let rename = app.buttons["renameVideo"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        XCTAssertTrue(nameInput(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["重命名"].exists)
    }

    private func openRenameBySwiping(_ row: XCUIElement, in app: XCUIApplication) {
        row.swipeLeft()
        let rename = app.buttons["swipeVideoRename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertFalse(nameInput(in: app).exists,
                       "A left swipe reveals the action without opening the editor automatically.")
        rename.tap()
        XCTAssertTrue(nameInput(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["重命名"].exists)
    }

    private func toggleFavoriteBySwiping(_ row: XCUIElement, in app: XCUIApplication) {
        // A partial right swipe reveals the existing explicit favorite action;
        // a full swipe remains available to people who prefer that shortcut.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let favorite = app.buttons["swipeVideoFavorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.tap()
    }

    private func replaceName(with value: String, in app: XCUIApplication) {
        let field = nameInput(in: app)
        let current = field.value as? String ?? ""
        // All replaced drafts are short single-line names. A tap beyond their
        // final glyph places the caret at the end without localized edit menus.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)).tap()
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !value.isEmpty { field.typeText(value) }
    }

    private func saveName(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["saveVideoName"].isEnabled)
        app.buttons["saveVideoName"].tap()
        XCTAssertTrue(nameInput(in: app).waitForNonExistence(timeout: 5))
    }

    private func search(_ query: String, in app: XCUIApplication) {
        let clear = app.buttons["clearOfflineSearch"]
        if clear.exists { clear.tap() }
        let input = app.textFields["offlineVideoSearch"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(query + "\n")
    }

    private func selectionRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "offlineTaskSelection-"))
    }

    private func waitForLabel(_ label: String, on element: XCUIElement) {
        wait(for: NSPredicate(format: "exists == true AND label == %@", label), on: element)
    }

    private func waitForValue(containing text: String, on element: XCUIElement) {
        wait(for: NSPredicate(format: "exists == true AND value CONTAINS %@", text), on: element)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 10) {
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
}
