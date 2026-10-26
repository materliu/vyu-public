import XCTest
@testable import VYu

final class MediaDurationFormatterTests: XCTestCase {
    func testSecondsAndMinuteBoundary() {
        for (seconds, expected) in [(1.0, "1 秒"), (8, "8 秒"), (59, "59 秒"),
                                    (60, "1 分钟"), (65, "1 分 5 秒"), (300, "5 分钟")] {
            XCTAssertEqual(MediaDurationFormatter.string(seconds: seconds), expected, "seconds: \(seconds)")
        }
    }

    func testHourBoundaryAndOmittedSeconds() {
        for (seconds, expected) in [(3_599.0, "59 分 59 秒"), (3_600, "1 小时"),
                                    (3_659, "1 小时"), (3_900, "1 小时 5 分"),
                                    (7_200, "2 小时"), (7_325, "2 小时 2 分")] {
            XCTAssertEqual(MediaDurationFormatter.string(seconds: seconds), expected, "seconds: \(seconds)")
        }
    }

    func testRoundsToNearestSecondBeforeChoosingUnits() {
        for (seconds, expected) in [(7.999, "8 秒"), (59.49, "59 秒"),
                                    (59.5, "1 分钟"), (3_599.5, "1 小时"),
                                    (3_659.5, "1 小时 1 分")] {
            XCTAssertEqual(MediaDurationFormatter.string(seconds: seconds), expected, "seconds: \(seconds)")
        }
    }

    func testSubsecondDurationIsNotRoundedToZero() {
        XCTAssertEqual(MediaDurationFormatter.string(seconds: 0.01), "不足 1 秒")
        XCTAssertEqual(MediaDurationFormatter.string(seconds: 0.999), "不足 1 秒")
    }

    func testMissingInvalidAndOverflowingDurationsAreUnknown() {
        let invalid: [Double?] = [nil, 0, -1, .nan, .infinity, -.infinity,
                                  .greatestFiniteMagnitude, Double(Int.max)]
        for seconds in invalid {
            XCTAssertEqual(MediaDurationFormatter.string(seconds: seconds), "时长未知")
        }
    }
}
