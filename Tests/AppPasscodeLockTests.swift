import XCTest
@testable import VYu

@MainActor
final class AppPasscodeLockTests: XCTestCase {
    func testOnlyCompleteFixedPasscodeUnlocksAndInputIsCleared() {
        let lock = AppPasscodeLock()
        lock.sceneChanged(to: .foregroundActive)
        for digit in [6, 5, 4, 3, 2] { lock.enter(digit) }
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertEqual(lock.digits, "65432")
        lock.enter(1)
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertEqual(lock.digits, "")
        lock.enter(9)
        XCTAssertEqual(lock.digits, "")
        XCTAssertFalse(AppPasscodeLock().isUnlocked, "Unlocking must not survive a fresh app session.")
    }

    func testWrongPasscodeClearsAndDeleteAllowsCorrection() {
        let lock = AppPasscodeLock()
        lock.sceneChanged(to: .foregroundActive)
        for _ in 0..<6 { lock.enter(0) }
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertTrue(lock.hasError)
        XCTAssertEqual(lock.digits, "")
        lock.enter(-1)
        lock.enter(10)
        XCTAssertEqual(lock.digits, "")
        lock.enter(6)
        XCTAssertFalse(lock.hasError)
        lock.enter(0)
        lock.deleteLastDigit()
        XCTAssertEqual(lock.digits, "6")
        for digit in [5, 4, 3, 2, 1] { lock.enter(digit) }
        XCTAssertTrue(lock.isUnlocked)
    }

    func testInactiveClearsPartialInputAndBackgroundRequiresUnlockAgain() {
        let lock = AppPasscodeLock()
        lock.sceneChanged(to: .foregroundActive)
        lock.enter(6)
        lock.sceneChanged(to: .foregroundInactive)
        lock.enter(5)
        XCTAssertEqual(lock.digits, "")
        lock.sceneChanged(to: .foregroundActive)
        for digit in [6, 5, 4, 3, 2, 1] { lock.enter(digit) }
        lock.sceneChanged(to: .foregroundInactive)
        lock.sceneChanged(to: .foregroundActive)
        XCTAssertTrue(lock.isUnlocked, "A temporary system interruption is not a background round trip.")
        lock.sceneChanged(to: .background)
        lock.sceneChanged(to: .foregroundActive)
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertEqual(lock.digits, "")
    }
}
