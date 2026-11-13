import Foundation

public struct HistorySample: Codable, Equatable, Sendable {
    public let timestampMS: Int64
    public let value: Double

    public init(timestampMS: Int64, value: Double) {
        self.timestampMS = timestampMS
        self.value = value
    }
}

public struct MetricSnapshot: Equatable, Sendable {
    public var value: TypedMetricValue?
    public var error: String?
    public var timestampMS: Int64?

    public init(
        value: TypedMetricValue? = nil,
        error: String? = nil,
        timestampMS: Int64? = nil
    ) {
        self.value = value
        self.error = error
        self.timestampMS = timestampMS
    }
}

public struct DashboardState: Equatable, Sendable {
    public let plan: DashboardPlan
    public private(set) var metrics: [String: MetricSnapshot]
    public private(set) var histories: [String: [HistorySample]]

    private let historyLimits: [String: Int]
    private let historyIntervals: [String: Int64]

    public init(plan: DashboardPlan) throws {
        try ProtocolValidator.validate(plan)
        self.plan = plan
        metrics = Dictionary(uniqueKeysWithValues: plan.metrics.map { ($0.id, MetricSnapshot()) })

        var limits: [String: Int] = [:]
        let surfaceWidgets = plan.surfaces.flatMap { Self.widgets(in: $0.root) }
        for widget in plan.sections.flatMap(\.widgets) + surfaceWidgets {
            if widget.kind == .sparkline, let history = widget.history {
                limits[widget.metric] = max(limits[widget.metric, default: 0], history)
            }
            if widget.kind == .plot, let history = widget.history {
                for series in widget.series {
                    limits[series.metric] = max(limits[series.metric, default: 0], history)
                }
            }
        }
        historyLimits = limits
        historyIntervals = Dictionary(uniqueKeysWithValues: plan.metrics.compactMap { metric in
            metric.sampleIntervalMS.map { (metric.id, $0) }
        })
        histories = Dictionary(uniqueKeysWithValues: limits.keys.map { ($0, []) })
    }

    public mutating func apply(_ update: UpdateMessage) throws {
        // Validate the whole batch before changing state so widgets never observe a partial update.
        try ProtocolValidator.validate(update, against: plan)

        for item in update.values {
            var snapshot = metrics[item.metric, default: MetricSnapshot()]
            snapshot.timestampMS = update.timestampMS

            if let error = item.error {
                snapshot.error = error
            } else if let value = item.value {
                snapshot.value = value
                snapshot.error = nil

                if let numericValue = value.numericValue,
                   let limit = historyLimits[item.metric]
                {
                    var samples = histories[item.metric, default: []]
                    let sample = HistorySample(timestampMS: update.timestampMS, value: numericValue)
                    if let last = samples.last, update.timestampMS < last.timestampMS {
                        // Clock rollback must not disorder a time series.
                        samples.removeAll { $0.timestampMS >= update.timestampMS }
                    }
                    if let last = samples.last,
                       last.timestampMS == update.timestampMS
                        || historyIntervals[item.metric].map({
                            last.timestampMS / $0 == update.timestampMS / $0
                        }) == true
                    {
                        // Reloading a slow collector must not consume its entire
                        // history capacity with duplicate samples in one interval.
                        samples[samples.count - 1] = sample
                    } else {
                        samples.append(sample)
                    }
                    if samples.count > limit {
                        samples.removeFirst(samples.count - limit)
                    }
                    histories[item.metric] = samples
                }
            }

            metrics[item.metric] = snapshot
        }
    }

    public func isStale(metric id: String, at timestampMS: Int64) -> Bool {
        guard let definition = plan.metrics.first(where: { $0.id == id }),
              let snapshot = metrics[id], snapshot.error == nil,
              let lastTimestamp = snapshot.timestampMS,
              timestampMS > lastTimestamp
        else {
            return false
        }
        return timestampMS - lastTimestamp > definition.staleAfterMS
    }

    public func history(for metric: String, limit: Int? = nil) -> [HistorySample] {
        let samples = histories[metric] ?? []
        guard let limit, limit >= 0, samples.count > limit else { return samples }
        return Array(samples.suffix(limit))
    }

    public var historyArchive: DashboardHistoryArchive {
        let entries = plan.metrics.compactMap { definition -> (String, MetricHistoryArchive)? in
            guard let samples = histories[definition.id], !samples.isEmpty else { return nil }
            return (definition.id, MetricHistoryArchive(valueType: definition.valueType, samples: samples))
        }
        return DashboardHistoryArchive(metrics: Dictionary(uniqueKeysWithValues: entries))
    }

    public mutating func restoreHistory(_ archive: DashboardHistoryArchive) throws {
        try archive.validate()
        for definition in plan.metrics {
            guard let limit = historyLimits[definition.id],
                  let saved = archive.metrics[definition.id],
                  saved.valueType == definition.valueType
            else { continue }
            histories[definition.id] = Array(saved.samples.suffix(limit))
        }
    }

    private static func widgets(in node: LayoutNode) -> [WidgetPlan] {
        switch node {
        case let .widget(widget):
            [widget]
        case let .section(_, _, child):
            widgets(in: child)
        case let .stack(_, children), let .flow(_, _, _, children):
            children.flatMap(widgets)
        case let .split(_, _, tracks):
            tracks.flatMap { widgets(in: $0.child) }
        }
    }
}
