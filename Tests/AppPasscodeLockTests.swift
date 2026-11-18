import XCTest
@testable import VYu

@MainActor
final class AppPasscodeLockTests: XCTestCase {
    private func makeLock() -> AppPasscodeLock {
        AppPasscodeLock(phraseDigest: "ab07f3900933cba3ffbc844ac30b5da3af6178fa897bdde42fd2593f2748c670")
    }

    func testUnconfiguredInstallationNeverAcceptsInput() {
        let lock = AppPasscodeLock(phraseDigest: "")
        lock.sceneChanged(to: .foregroundActive)
        lock.showPrompt()
        lock.submit("")
        lock.submit("fixture-access")
        XCTAssertFalse(lock.isUnlocked)
    }

    func testPhraseRequiresExplicitPromptAndClearsPromptAfterUnlock() {
        let lock = makeLock()
        lock.sceneChanged(to: .foregroundActive)
        lock.submit("fixture-access")
        XCTAssertFalse(lock.isUnlocked)
        lock.showPrompt()
        lock.submit("654321")
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertTrue(lock.hasError)
        lock.submit("fixture-access")
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertFalse(lock.isPromptPresented)
        XCTAssertFalse(lock.hasError)
        XCTAssertFalse(makeLock().isUnlocked)
    }

    func testCancelAndHideReturnToConcealedSession() {
        let lock = makeLock()
        var visibility: [Bool] = []
        lock.visibilityChanged = { visibility.append($0) }
        lock.sceneChanged(to: .foregroundActive)
        lock.showPrompt()
        lock.submit("wrong")
        lock.cancelPrompt()
        XCTAssertFalse(lock.isPromptPresented)
        XCTAssertFalse(lock.hasError)
        lock.showPrompt()
        lock.submit(" FIXTURE-ACCESS ")
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertEqual(visibility.last, true)
        lock.hideContent()
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertEqual(visibility.last, false)
    }

    func testInactiveAndBackgroundCoverContentWithoutRevokingSession() {
        let lock = makeLock()
        var visible = false
        lock.visibilityChanged = { visible = $0 }
        lock.sceneChanged(to: .foregroundActive)
        lock.showPrompt()
        lock.submit("fixture-access")
        XCTAssertTrue(visible)
        lock.sceneChanged(to: .foregroundInactive)
        XCTAssertFalse(visible)
        lock.sceneChanged(to: .foregroundActive)
        XCTAssertTrue(visible)
        for _ in 0..<3 {
            lock.sceneChanged(to: .background)
            XCTAssertTrue(lock.isUnlocked)
            XCTAssertFalse(visible)
            lock.sceneChanged(to: .foregroundActive)
            XCTAssertTrue(lock.isUnlocked)
            XCTAssertTrue(visible)
        }
        lock.sceneChanged(to: .unattached)
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertFalse(visible)
        XCTAssertFalse(makeLock().isUnlocked, "A new process must start concealed.")
        lock.hideContent()
        lock.sceneChanged(to: .foregroundActive)
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertFalse(visible)
    }

    func testInactiveCancelsPromptAndRejectsInput() {
        let lock = makeLock()
        lock.sceneChanged(to: .foregroundActive)
        lock.showPrompt()
        lock.submit(String(repeating: "a", count: 10000))
        XCTAssertFalse(lock.isUnlocked)
        lock.sceneChanged(to: .foregroundInactive)
        XCTAssertFalse(lock.isPromptPresented)
        XCTAssertFalse(lock.hasError)
        lock.showPrompt()
        lock.submit("fixture-access")
        XCTAssertFalse(lock.isPromptPresented)
        XCTAssertFalse(lock.isUnlocked)
    }
}
