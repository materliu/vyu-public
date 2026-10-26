import XCTest
@testable import VYu

final class DownloadProgressPresentationTests: XCTestCase {
    func testConnectingDoesNotShowAnEmptyDeterminateBar() {
        let view = make(.downloading)
        XCTAssertEqual(view.status, "正在连接视频…")
        XCTAssertNil(view.fraction)
        XCTAssertNil(view.percentage)
    }

    func testUnknownLengthShowsReceivedBytesWithoutInventingAPercentage() {
        let view = make(.downloading, bytes: 2_000_000)
        XCTAssertTrue(view.status.contains("已下载"))
        XCTAssertTrue(view.status.contains("总大小未知"))
        XCTAssertNil(view.fraction)
        XCTAssertNil(view.percentage)
    }

    func testKnownByteTotalProducesMeasuredProgress() {
        let view = make(.downloading, bytes: 375, expected: 1_000)
        XCTAssertEqual(view.fraction, 0.375)
        XCTAssertEqual(view.percentage, "37%")
        XCTAssertTrue(view.status.contains(" / "))
    }

    func testHLSLoadedDurationCanShowProgressWithoutAByteTotal() {
        let view = make(.downloading, fraction: 0.375)
        XCTAssertEqual(view.percentage, "37%")
        XCTAssertEqual(view.status, "正在下载视频…")
        XCTAssertFalse(view.status.contains("0 KB"))
    }

    func testPreparingAndValidatingRemainIndeterminateDespiteOldTransferProgress() {
        let preparing = make(.queued, bytes: 100, expected: 100, fraction: 1)
        XCTAssertEqual(preparing.status, "正在准备下载…")
        XCTAssertNil(preparing.fraction)
        let validating = make(.validating, bytes: 100, expected: 100, fraction: 1)
        XCTAssertEqual(validating.status, "下载结束，正在检查视频…")
        XCTAssertNil(validating.percentage)
    }

    func testTransferNeverClaimsCompletionAndIgnoresInvalidFractions() {
        XCTAssertEqual(make(.downloading, bytes: 100, expected: 100, fraction: 1).percentage, "99%")
        XCTAssertNil(make(.downloading, fraction: .nan).percentage)
        XCTAssertNil(make(.downloading, fraction: .infinity).percentage)
        XCTAssertNil(make(.downloading, bytes: -1, expected: -1, fraction: -1).percentage)
    }

    private func make(_ phase: DownloadPhase, bytes: Int64 = 0, expected: Int64? = nil,
                      fraction: Double = 0) -> DownloadProgressPresentation {
        DownloadProgressPresentation(phase: phase, bytesWritten: bytes, expectedBytes: expected,
                                     reportedFraction: fraction)
    }
}
