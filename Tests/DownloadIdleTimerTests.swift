import XCTest
import UIKit
@testable import VYu

@MainActor
final class DownloadIdleTimerTests: XCTestCase {
    func testLeavingForegroundRestoresIdleTimerAndReturningRechecksActivity() {
        var transitions: [Bool] = []
        let timer = DownloadIdleTimerController { transitions.append($0) }
        timer.update(isSceneActive: true, hasActiveDownloads: true)
        timer.update(isSceneActive: false, hasActiveDownloads: true) // inactive or background
        timer.update(isSceneActive: false, hasActiveDownloads: false) // task ends while away
        timer.update(isSceneActive: true, hasActiveDownloads: false)
        XCTAssertEqual(transitions, [true, false])
        timer.update(isSceneActive: true, hasActiveDownloads: true)
        timer.update(isSceneActive: false, hasActiveDownloads: true)
        timer.update(isSceneActive: true, hasActiveDownloads: true)
        XCTAssertEqual(transitions, [true, false, true, false, true])
        timer.reset()
        XCTAssertEqual(transitions.last, false)
    }

    func testRepeatedProgressAndExplicitCleanupDoNotLeaveAnIdleTimerOverride() {
        var transitions: [Bool] = []
        let timer = DownloadIdleTimerController { transitions.append($0) }
        for _ in 0..<10 { timer.update(isSceneActive: true, hasActiveDownloads: true) }
        XCTAssertEqual(transitions, [true])
        timer.reset()
        timer.reset()
        XCTAssertEqual(transitions, [true, false])
    }

    func testControllerChangesOnlyApplicationIdleTimerAndRestoresIt() {
        let previous = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = previous }
        UIApplication.shared.isIdleTimerDisabled = false
        let timer = DownloadIdleTimerController()
        timer.update(isSceneActive: true, hasActiveDownloads: true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        timer.update(isSceneActive: false, hasActiveDownloads: true)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        timer.update(isSceneActive: true, hasActiveDownloads: true)
        timer.update(isSceneActive: true, hasActiveDownloads: false)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }
}
