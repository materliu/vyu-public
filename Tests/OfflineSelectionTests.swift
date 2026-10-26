import XCTest
@testable import VYu

final class OfflineSelectionTests: XCTestCase {
    func testSelectAllUsesOnlyTheCurrentVisibleLocalRows() {
        let local = UUID(), filteredOut = UUID(), cloud = UUID()
        var selection = OfflineSelection()
        selection.begin()
        selection.toggleAll(visibleLocalIDs: [local])
        XCTAssertEqual(selection.ids, [local])
        selection.toggle(cloud, visibleLocalIDs: [local])
        selection.toggle(filteredOut, visibleLocalIDs: [local])
        XCTAssertEqual(selection.ids, [local])
        XCTAssertTrue(selection.includesAll(visibleLocalIDs: [local]))
        selection.toggleAll(visibleLocalIDs: [local])
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testFilteringAndDeletionDiscardHiddenSelectionWithoutRestoringItLater() {
        let first = UUID(), second = UUID(), third = UUID()
        var selection = OfflineSelection()
        selection.begin()
        selection.toggleAll(visibleLocalIDs: [first, second, third])
        selection.reconcile(visibleLocalIDs: [second, third])
        XCTAssertEqual(selection.ids, [second, third])
        selection.reconcile(visibleLocalIDs: [third])
        XCTAssertEqual(selection.ids, [third])
        selection.reconcile(visibleLocalIDs: [first, third])
        XCTAssertEqual(selection.ids, [third])
        XCTAssertFalse(selection.includesAll(visibleLocalIDs: [first, third]))
    }

    func testEndingSelectionClearsItAndIgnoresLaterRowTaps() {
        let id = UUID()
        var selection = OfflineSelection()
        selection.begin()
        selection.toggle(id, visibleLocalIDs: [id])
        selection.end()
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.ids.isEmpty)
        selection.toggle(id, visibleLocalIDs: [id])
        selection.toggleAll(visibleLocalIDs: [id])
        XCTAssertTrue(selection.ids.isEmpty)
        selection.begin()
        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertFalse(selection.includesAll(visibleLocalIDs: []))
    }
}
