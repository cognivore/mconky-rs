import Foundation

/// All series share one wall-clock axis. A fresh or sparse history occupies
/// only the time it actually covers, rather than stretching to fill the chart.
public struct PlotTimeline: Equatable, Sendable {
    public let lowerMS: Double
    public let upperMS: Double

    public init(timestamps: [Int64], intervalsMS: [Int64], capacity: Int, nowMS: Int64) {
        upperMS = Double(max(nowMS, timestamps.max() ?? nowMS))
        let observedSpan = upperMS - Double(timestamps.min() ?? nowMS)
        let scheduledSpan = intervalsMS.filter { $0 > 0 }.max().map {
            Double($0) * Double(max(1, capacity))
        }
        lowerMS = max(0, upperMS - max(scheduledSpan ?? observedSpan, 1))
    }

    public func position(timestampMS: Int64) -> Double? {
        let timestamp = Double(timestampMS)
        guard timestamp >= lowerMS, timestamp <= upperMS else { return nil }
        return upperMS > lowerMS ? (timestamp - lowerMS) / (upperMS - lowerMS) : 1
    }

    public static func connects(from previous: Int64, to next: Int64, intervalMS: Int64?) -> Bool {
        guard next > previous else { return false }
        guard let intervalMS, intervalMS > 0 else { return true }
        return Double(next) - Double(previous) <= Double(intervalMS) * 2.5
    }
}
