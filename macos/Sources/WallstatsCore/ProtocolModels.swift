import Foundation

public enum MetricValueType: String, Codable, CaseIterable, Sendable {
    case ratio
    case bytes
    case bytesPerSecond = "bytes_per_second"
    case count
    case durationSeconds = "duration_seconds"
    case number
    case text
    case boolean
    case table
    case compactStatus = "compact_status"
}

public enum MetricFormat: String, Codable, CaseIterable, Sendable {
    case percent
    case bytes
    case bytesPerSecond = "bytes_per_second"
    case count
    case number
    case duration
    case text
    case boolean
    case table
    case compactStatus = "compact_status"
    case celsius
    case watts
    case megahertz
}

public enum WidgetKind: String, Codable, CaseIterable, Sendable {
    case value
    case sparkline
    case gauge
    case table
    case plot
    case compactStatus = "compact_status"
}

public enum WindowAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft = "top_left"
    case topCenter = "top_center"
    case topRight = "top_right"
    case centerLeft = "center_left"
    case center
    case centerRight = "center_right"
    case bottomLeft = "bottom_left"
    case bottomCenter = "bottom_center"
    case bottomRight = "bottom_right"
}

public enum WindowLayer: String, Codable, CaseIterable, Sendable {
    case desktop
    case floating
}

public struct HelloMessage: Codable, Equatable, Sendable {
    public let protocolMajor: Int
    public let protocolMinor: Int
    public let sdkVersion: String

    public init(protocolMajor: Int, protocolMinor: Int, sdkVersion: String) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.sdkVersion = sdkVersion
    }

    enum CodingKeys: String, CodingKey {
        case protocolMajor = "protocol_major"
        case protocolMinor = "protocol_minor"
        case sdkVersion = "sdk_version"
    }
}

public struct MetricDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let valueType: MetricValueType
    public let staleAfterMS: Int64

    public init(id: String, valueType: MetricValueType, staleAfterMS: Int64) {
        self.id = id
        self.valueType = valueType
        self.staleAfterMS = staleAfterMS
    }

    enum CodingKeys: String, CodingKey {
        case id
        case valueType = "value_type"
        case staleAfterMS = "stale_after_ms"
    }
}

public struct WindowPlan: Codable, Equatable, Sendable {
    public let width: Double
    public let anchor: WindowAnchor
    public let margin: Double
    public let layer: WindowLayer
    public let opacity: Double

    public init(
        width: Double,
        anchor: WindowAnchor,
        margin: Double,
        layer: WindowLayer,
        opacity: Double
    ) {
        self.width = width
        self.anchor = anchor
        self.margin = margin
        self.layer = layer
        self.opacity = opacity
    }
}

public struct PlotSeries: Codable, Equatable, Sendable {
    public let metric: String
    public let format: MetricFormat
    public let accent: String?

    public init(metric: String, format: MetricFormat, accent: String? = nil) {
        self.metric = metric
        self.format = format
        self.accent = accent
    }
}

public struct WidgetPlan: Codable, Equatable, Sendable {
    public let kind: WidgetKind
    public let label: String
    public let metric: String
    public let format: MetricFormat
    public let accent: String?
    public let history: Int?
    public let series: [PlotSeries]

    public init(
        kind: WidgetKind,
        label: String,
        metric: String = "",
        format: MetricFormat = .number,
        accent: String? = nil,
        history: Int? = nil,
        series: [PlotSeries] = []
    ) {
        self.kind = kind
        self.label = label
        self.metric = metric
        self.format = format
        self.accent = accent
        self.history = history
        self.series = series
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case label
        case metric
        case format
        case accent
        case history
        case series
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(WidgetKind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        metric = try container.decodeIfPresent(String.self, forKey: .metric) ?? ""
        format = try container.decodeIfPresent(MetricFormat.self, forKey: .format) ?? .number
        accent = try container.decodeIfPresent(String.self, forKey: .accent)
        history = try container.decodeIfPresent(Int.self, forKey: .history)
        series = try container.decodeIfPresent([PlotSeries].self, forKey: .series) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        if kind != .plot {
            try container.encode(metric, forKey: .metric)
            try container.encode(format, forKey: .format)
        }
        try container.encodeIfPresent(accent, forKey: .accent)
        try container.encodeIfPresent(history, forKey: .history)
        if !series.isEmpty {
            try container.encode(series, forKey: .series)
        }
    }
}

public struct SectionPlan: Codable, Equatable, Sendable {
    public let title: String
    public let widgets: [WidgetPlan]
    public let weight: Int

    public init(title: String, widgets: [WidgetPlan], weight: Int = 1) {
        self.title = title
        self.widgets = widgets
        self.weight = weight
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case widgets
        case weight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        widgets = try container.decode([WidgetPlan].self, forKey: .widgets)
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(widgets, forKey: .widgets)
        if weight != 1 {
            try container.encode(weight, forKey: .weight)
        }
    }
}

public struct DashboardPlan: Codable, Equatable, Sendable {
    public let title: String
    public let metrics: [MetricDefinition]
    public let window: WindowPlan
    public let sections: [SectionPlan]

    public init(
        title: String,
        metrics: [MetricDefinition],
        window: WindowPlan,
        sections: [SectionPlan]
    ) {
        self.title = title
        self.metrics = metrics
        self.window = window
        self.sections = sections
    }
}

public struct TableValue: Equatable, Sendable {
    public let columns: [String]
    public let rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

public enum TypedMetricValue: Equatable, Sendable {
    case ratio(Double)
    case bytes(UInt64)
    case bytesPerSecond(Double)
    case count(UInt64)
    case durationSeconds(Double)
    case number(Double)
    case text(String)
    case boolean(Bool)
    case table(TableValue)
    case compactStatus(CompactStatusMetricValue)

    public var kind: MetricValueType {
        switch self {
        case .ratio: .ratio
        case .bytes: .bytes
        case .bytesPerSecond: .bytesPerSecond
        case .count: .count
        case .durationSeconds: .durationSeconds
        case .number: .number
        case .text: .text
        case .boolean: .boolean
        case .table: .table
        case .compactStatus: .compactStatus
        }
    }

    public var numericValue: Double? {
        switch self {
        case let .ratio(value), let .bytesPerSecond(value),
             let .durationSeconds(value), let .number(value):
            value
        case let .bytes(value):
            Double(value)
        case let .count(value):
            Double(value)
        case .text, .boolean, .table, .compactStatus:
            nil
        }
    }
}

extension TypedMetricValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case columns
        case rows
        case leading
        case trailing
        case light
        case ageSeconds = "age_seconds"
        case glyphScale = "glyph_scale"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(MetricValueType.self, forKey: .kind)

        switch kind {
        case .ratio:
            self = .ratio(try container.decode(Double.self, forKey: .value))
        case .bytes:
            self = .bytes(try container.decode(UInt64.self, forKey: .value))
        case .bytesPerSecond:
            self = .bytesPerSecond(try container.decode(Double.self, forKey: .value))
        case .count:
            self = .count(try container.decode(UInt64.self, forKey: .value))
        case .durationSeconds:
            self = .durationSeconds(try container.decode(Double.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .table:
            self = .table(TableValue(
                columns: try container.decode([String].self, forKey: .columns),
                rows: try container.decode([[String]].self, forKey: .rows)
            ))
        case .compactStatus:
            self = .compactStatus(CompactStatusMetricValue(
                leading: try container.decode(String.self, forKey: .leading),
                trailing: try container.decode(String.self, forKey: .trailing),
                light: try container.decode(StatusLight.self, forKey: .light),
                ageSeconds: try container.decodeIfPresent(Double.self, forKey: .ageSeconds),
                glyphScale: try container.decodeIfPresent(Double.self, forKey: .glyphScale)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case let .ratio(value):
            try container.encode(value, forKey: .value)
        case let .bytes(value):
            try container.encode(value, forKey: .value)
        case let .bytesPerSecond(value):
            try container.encode(value, forKey: .value)
        case let .count(value):
            try container.encode(value, forKey: .value)
        case let .durationSeconds(value):
            try container.encode(value, forKey: .value)
        case let .number(value):
            try container.encode(value, forKey: .value)
        case let .text(value):
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(value, forKey: .value)
        case let .table(value):
            try container.encode(value.columns, forKey: .columns)
            try container.encode(value.rows, forKey: .rows)
        case let .compactStatus(value):
            try container.encode(value.leading, forKey: .leading)
            try container.encode(value.trailing, forKey: .trailing)
            try container.encode(value.light, forKey: .light)
            try container.encodeIfPresent(value.ageSeconds, forKey: .ageSeconds)
            try container.encodeIfPresent(value.glyphScale, forKey: .glyphScale)
        }
    }
}

public struct UpdateItem: Codable, Equatable, Sendable {
    public let metric: String
    public let value: TypedMetricValue?
    public let error: String?

    public init(metric: String, value: TypedMetricValue? = nil, error: String? = nil) {
        self.metric = metric
        self.value = value
        self.error = error
    }
}

public struct UpdateMessage: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let timestampMS: Int64
    public let values: [UpdateItem]

    public init(sequence: UInt64, timestampMS: Int64, values: [UpdateItem]) {
        self.sequence = sequence
        self.timestampMS = timestampMS
        self.values = values
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestampMS = "timestamp_ms"
        case values
    }
}

public struct HeartbeatMessage: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let timestampMS: Int64

    public init(sequence: UInt64, timestampMS: Int64) {
        self.sequence = sequence
        self.timestampMS = timestampMS
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestampMS = "timestamp_ms"
    }
}

public struct FatalMessage: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum ProtocolRecord: Equatable, Sendable {
    case hello(HelloMessage)
    case plan(DashboardPlan)
    case update(UpdateMessage)
    case heartbeat(HeartbeatMessage)
    case fatal(FatalMessage)

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .plan: "plan"
        case .update: "update"
        case .heartbeat: "heartbeat"
        case .fatal: "fatal"
        }
    }
}

extension ProtocolRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum RecordType: String, Codable {
        case hello
        case plan
        case update
        case heartbeat
        case fatal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RecordType.self, forKey: .type)

        switch type {
        case .hello:
            self = .hello(try HelloMessage(from: decoder))
        case .plan:
            self = .plan(try DashboardPlan(from: decoder))
        case .update:
            self = .update(try UpdateMessage(from: decoder))
        case .heartbeat:
            self = .heartbeat(try HeartbeatMessage(from: decoder))
        case .fatal:
            self = .fatal(try FatalMessage(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .hello(message):
            try container.encode(RecordType.hello, forKey: .type)
            try message.encode(to: encoder)
        case let .plan(message):
            try container.encode(RecordType.plan, forKey: .type)
            try message.encode(to: encoder)
        case let .update(message):
            try container.encode(RecordType.update, forKey: .type)
            try message.encode(to: encoder)
        case let .heartbeat(message):
            try container.encode(RecordType.heartbeat, forKey: .type)
            try message.encode(to: encoder)
        case let .fatal(message):
            try container.encode(RecordType.fatal, forKey: .type)
            try message.encode(to: encoder)
        }
    }
}

public struct WallstatsProtocolDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> ProtocolRecord {
        try JSONDecoder().decode(ProtocolRecord.self, from: data)
    }
}
