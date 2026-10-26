enum MediaDurationFormatter {
    static func string(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "时长未知" }
        if seconds < 1 { return "不足 1 秒" }

        // Round the source duration to the nearest second before choosing units.
        guard let totalSeconds = Int(exactly: seconds.rounded()) else { return "时长未知" }
        if totalSeconds < 60 { return "\(totalSeconds) 秒" }

        let minutes = totalSeconds / 60
        if totalSeconds < 3_600 {
            let remainingSeconds = totalSeconds % 60
            return remainingSeconds == 0
                ? "\(minutes) 分钟"
                : "\(minutes) 分 \(remainingSeconds) 秒"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours) 小时"
            : "\(hours) 小时 \(remainingMinutes) 分"
    }
}
