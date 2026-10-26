import Foundation

/// Presentation uses only measured bytes or a progress callback. An empty HLS
/// progress callback means an indeterminate transfer, not a stalled 0% bar.
struct DownloadProgressPresentation {
    let fraction: Double?
    let percentage: String?
    let status: String

    init(phase: DownloadPhase, bytesWritten: Int64, expectedBytes: Int64?, reportedFraction: Double) {
        let bytes = max(0, bytesWritten)
        let expected = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
        let reported = reportedFraction.isFinite && reportedFraction > 0 ? reportedFraction : nil
        let measured: Double?
        if phase == .downloading {
            if let reported { measured = reported }
            else if bytes > 0, let expected { measured = Double(bytes) / Double(expected) }
            else { measured = nil }
        } else { measured = nil }
        // A transfer reaching its end still has to pass offline validation.
        fraction = measured.map { min(0.99, max(0, $0)) }
        percentage = fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }

        switch phase {
        case .queued:
            status = "正在准备下载…"
        case .validating:
            status = "下载结束，正在检查视频…"
        case .downloading:
            if bytes == 0, fraction == nil {
                status = "正在连接视频…"
            } else if bytes > 0 {
                let downloaded = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                if let expected {
                    let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                    status = "正在下载 · \(downloaded) / \(total)"
                } else {
                    status = "正在下载 · 已下载 \(downloaded)" + (fraction == nil ? " · 总大小未知" : "")
                }
            } else { status = "正在下载视频…" }
        default:
            status = ""
        }
    }
}
