import Foundation

public struct MetricHistoryArchive: Codable, Equatable, Sendable {
    public let valueType: MetricValueType
    public let samples: [HistorySample]

    public init(valueType: MetricValueType, samples: [HistorySample]) {
        self.valueType = valueType
        self.samples = samples
    }
}

public struct DashboardHistoryArchive: Codable, Equatable, Sendable {
    public let version: Int
    public let metrics: [String: MetricHistoryArchive]

    public init(metrics: [String: MetricHistoryArchive]) {
        version = 1
        self.metrics = metrics
    }

    public func validate() throws {
        guard version == 1 else { throw HistoryArchiveError.unsupportedVersion(version) }
        for (id, history) in metrics {
            var previous: Int64 = -1
            for sample in history.samples {
                guard sample.timestampMS > previous, sample.value.isFinite,
                      Self.valid(sample.value, for: history.valueType)
                else { throw HistoryArchiveError.invalidSamples(id) }
                previous = sample.timestampMS
            }
        }
    }

    private static func valid(_ value: Double, for type: MetricValueType) -> Bool {
        switch type {
        case .ratio: (0 ... 1).contains(value)
        case .number: true
        case .bytes, .bytesPerSecond, .count, .durationSeconds: value >= 0
        case .text, .boolean, .table, .compactStatus: false
        }
    }
}

public enum HistoryArchiveError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidSamples(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "Unsupported graph history version \(version)."
        case let .invalidSamples(metric): "Invalid graph history for \(metric)."
        case .tooLarge: "Graph history exceeds its 4 MiB storage limit."
        }
    }
}
