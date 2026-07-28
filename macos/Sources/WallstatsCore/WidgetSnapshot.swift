import Foundation

public enum WidgetSnapshotValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidSampledAt
    case invalidValue(String)
    case historyTooLong(String)
}

extension WidgetSnapshotValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported widget snapshot schema version \(version)."
        case .invalidSampledAt:
            "Invalid widget snapshot timestamp."
        case let .invalidValue(field):
            "Invalid widget snapshot value for \(field)."
        case let .historyTooLong(field):
            "Widget snapshot history \(field) exceeds 60 samples."
        }
    }
}

public struct WidgetRenderSeries: Codable, Equatable, Sendable {
    public let metric: String
    public let format: MetricFormat
    public let accent: String?

    public init(metric: String, format: MetricFormat, accent: String?) {
        self.metric = metric
        self.format = format
        self.accent = accent
    }

    enum CodingKeys: String, CodingKey {
        case metric = "m"
        case format = "f"
        case accent = "a"
    }
}

public struct WidgetRenderWidget: Codable, Equatable, Sendable {
    public let kind: WidgetKind
    public let label: String
    public let metric: String?
    public let format: MetricFormat?
    public let accent: String?
    public let history: Int?
    public let series: [WidgetRenderSeries]

    public init(_ widget: WidgetPlan) {
        kind = widget.kind
        label = widget.label
        metric = widget.kind == .plot ? nil : widget.metric
        format = widget.kind == .plot ? nil : widget.format
        accent = widget.accent
        history = widget.history.map { min($0, WidgetSnapshot.maximumHistoryCount) }
        series = widget.series.map {
            WidgetRenderSeries(metric: $0.metric, format: $0.format, accent: $0.accent)
        }
    }

    public init(
        kind: WidgetKind,
        label: String,
        metric: String? = nil,
        format: MetricFormat? = nil,
        accent: String? = nil,
        history: Int? = nil,
        series: [WidgetRenderSeries] = []
    ) {
        self.kind = kind
        self.label = label
        self.metric = metric
        self.format = format
        self.accent = accent
        self.history = history
        self.series = series
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case label = "l"
        case metric = "m"
        case format = "f"
        case accent = "a"
        case history = "h"
        case series = "s"
    }
}

public struct WidgetRenderSection: Codable, Equatable, Sendable {
    public let title: String
    public let weight: Int
    public let widgets: [WidgetRenderWidget]

    public init(_ section: SectionPlan) {
        title = section.title
        weight = section.weight
        widgets = section.widgets.map(WidgetRenderWidget.init)
    }

    public init(title: String, weight: Int = 1, widgets: [WidgetRenderWidget]) {
        self.title = title
        self.weight = weight
        self.widgets = widgets
    }

    enum CodingKeys: String, CodingKey {
        case title = "t"
        case weight = "w"
        case widgets = "x"
    }
}

public struct WidgetRenderPlan: Codable, Equatable, Sendable {
    public let sections: [WidgetRenderSection]

    public init(sections: [WidgetRenderSection]) {
        self.sections = sections
    }

    public init(_ plan: DashboardPlan) {
        sections = plan.sections.map(WidgetRenderSection.init)
    }

    enum CodingKeys: String, CodingKey {
        case sections = "s"
    }
}

public struct WidgetRenderMetric: Codable, Equatable, Sendable {
    public let metricID: String
    public let valueType: MetricValueType
    public let value: TypedMetricValue?
    public let error: String?
    public let timestampMS: Int64?
    public let history: [Double]

    public init(
        metricID: String,
        valueType: MetricValueType,
        value: TypedMetricValue?,
        error: String?,
        timestampMS: Int64?,
        history: [Double]
    ) {
        self.metricID = metricID
        self.valueType = valueType
        self.value = value
        self.error = error
        self.timestampMS = timestampMS
        self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case metricID = "i"
        case valueType = "k"
        case value = "v"
        case error = "e"
        case timestampMS = "t"
        case history = "h"
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumHistoryCount = 60

    public let schemaVersion: Int
    public let sampledAt: Date
    public let renderPlan: WidgetRenderPlan
    public let metrics: [WidgetRenderMetric]

    public init(
        sampledAt: Date,
        renderPlan: WidgetRenderPlan,
        metrics: [WidgetRenderMetric]
    ) throws {
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            sampledAt: sampledAt,
            renderPlan: renderPlan,
            metrics: metrics
        )
    }

    public init(dashboard: DashboardState, sampledAt: Date) throws {
        let renderPlan = WidgetRenderPlan(dashboard.plan)
        let references = Self.references(in: dashboard.plan)
        let definitions = Dictionary(uniqueKeysWithValues: dashboard.plan.metrics.map { ($0.id, $0) })
        let metrics = references.order.compactMap { metricID -> WidgetRenderMetric? in
            guard let definition = definitions[metricID],
                  let snapshot = dashboard.metrics[metricID]
            else {
                return nil
            }
            let historyLimit = min(references.historyLimits[metricID] ?? 0, Self.maximumHistoryCount)
            return WidgetRenderMetric(
                metricID: metricID,
                valueType: definition.valueType,
                value: Self.boundedValue(snapshot.value),
                error: snapshot.error.map { String($0.prefix(256)) },
                timestampMS: snapshot.timestampMS,
                history: dashboard.history(for: metricID, limit: historyLimit).map(\.value)
            )
        }

        try self.init(
            sampledAt: sampledAt,
            renderPlan: renderPlan,
            metrics: metrics
        )
    }

    private init(
        schemaVersion: Int,
        sampledAt: Date,
        renderPlan: WidgetRenderPlan,
        metrics: [WidgetRenderMetric]
    ) throws {
        try Self.validate(
            schemaVersion: schemaVersion,
            sampledAt: sampledAt,
            renderPlan: renderPlan,
            metrics: metrics
        )
        self.schemaVersion = schemaVersion
        self.sampledAt = sampledAt
        self.renderPlan = renderPlan
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case sampledAt = "t"
        case renderPlan = "p"
        case metrics = "m"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasGenericPlan = container.contains(.renderPlan)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            sampledAt: try container.decode(Date.self, forKey: .sampledAt),
            renderPlan: try (hasGenericPlan
                ? container.decodeIfPresent(WidgetRenderPlan.self, forKey: .renderPlan)
                : nil)
                ?? WidgetRenderPlan(sections: []),
            metrics: try (hasGenericPlan
                ? container.decodeIfPresent([WidgetRenderMetric].self, forKey: .metrics)
                : nil) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(
            schemaVersion: schemaVersion,
            sampledAt: sampledAt,
            renderPlan: renderPlan,
            metrics: metrics
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sampledAt, forKey: .sampledAt)
        try container.encode(renderPlan, forKey: .renderPlan)
        try container.encode(metrics, forKey: .metrics)
    }

    private static func validate(
        schemaVersion: Int,
        sampledAt: Date,
        renderPlan: WidgetRenderPlan,
        metrics: [WidgetRenderMetric]
    ) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw WidgetSnapshotValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        let timestamp = sampledAt.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0 else {
            throw WidgetSnapshotValidationError.invalidSampledAt
        }
        guard renderPlan.sections.allSatisfy({ (1 ... 16).contains($0.weight) }) else {
            throw WidgetSnapshotValidationError.invalidValue("section weight")
        }

        var seen: Set<String> = []
        for metric in metrics {
            guard seen.insert(metric.metricID).inserted else {
                throw WidgetSnapshotValidationError.invalidValue("duplicate metric")
            }
            guard metric.history.count <= maximumHistoryCount else {
                throw WidgetSnapshotValidationError.historyTooLong(metric.metricID)
            }
            guard metric.history.allSatisfy(\.isFinite) else {
                throw WidgetSnapshotValidationError.invalidValue("metric history")
            }
            if let value = metric.value {
                guard value.kind == metric.valueType else {
                    throw WidgetSnapshotValidationError.invalidValue("metric value type")
                }
                try validateValue(value)
            }
        }
    }

    private static func validateValue(_ value: TypedMetricValue) throws {
        switch value {
        case let .ratio(number):
            guard number.isFinite, (0 ... 1).contains(number) else {
                throw WidgetSnapshotValidationError.invalidValue("ratio")
            }
        case let .bytesPerSecond(number), let .durationSeconds(number):
            guard number.isFinite, number >= 0 else {
                throw WidgetSnapshotValidationError.invalidValue("nonnegative number")
            }
        case let .number(number):
            guard number.isFinite else {
                throw WidgetSnapshotValidationError.invalidValue("number")
            }
        case let .compactStatus(status):
            guard status.isValid else {
                throw WidgetSnapshotValidationError.invalidValue("compact status")
            }
        case .bytes, .count, .text, .boolean, .table:
            break
        }
    }

    private static func references(
        in plan: DashboardPlan
    ) -> (order: [String], historyLimits: [String: Int]) {
        var order: [String] = []
        var seen: Set<String> = []
        var historyLimits: [String: Int] = [:]
        for section in plan.sections {
            for widget in section.widgets {
                if widget.kind == .plot {
                    for series in widget.series {
                        if seen.insert(series.metric).inserted {
                            order.append(series.metric)
                        }
                        historyLimits[series.metric] = max(
                            historyLimits[series.metric, default: 0],
                            widget.history ?? 0
                        )
                    }
                } else if !widget.metric.isEmpty {
                    if seen.insert(widget.metric).inserted {
                        order.append(widget.metric)
                    }
                    if widget.kind == .sparkline {
                        historyLimits[widget.metric] = max(
                            historyLimits[widget.metric, default: 0],
                            widget.history ?? 0
                        )
                    }
                }
            }
        }
        return (order, historyLimits)
    }

    private static func boundedValue(_ value: TypedMetricValue?) -> TypedMetricValue? {
        guard let value else { return nil }
        switch value {
        case let .text(text):
            return .text(String(text.prefix(256)))
        case let .table(table):
            let columns = Array(table.columns.prefix(8)).map { String($0.prefix(64)) }
            let rows = table.rows.prefix(8).map { row in
                Array(row.prefix(columns.count)).map { String($0.prefix(96)) }
            }
            return .table(TableValue(columns: columns, rows: rows))
        default:
            return value
        }
    }
}
