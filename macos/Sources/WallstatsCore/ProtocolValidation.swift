import Foundation

public enum ProtocolValidationError: Error, Equatable, Sendable {
    case unexpectedRecord(expected: String, received: String)
    case unsupportedProtocol(receivedMajor: Int, supportedMajor: Int)
    case invalidHello(String)
    case invalidMetricID(String)
    case duplicateMetricID(String)
    case invalidStaleInterval(metric: String)
    case invalidWindow(field: String, reason: String)
    case unknownMetricReference(String)
    case invalidHistory(metric: String)
    case invalidSectionWeight(section: String)
    case invalidSurface(String)
    case incompatibleWidget(metric: String, reason: String)
    case duplicateUpdateMetric(String)
    case invalidUpdate(metric: String, reason: String)
    case valueTypeMismatch(metric: String, expected: MetricValueType, received: MetricValueType)
    case invalidSequence(previous: UInt64, received: UInt64)
    case invalidTimestamp(Int64)
    case invalidFatalMessage
}

extension ProtocolValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unexpectedRecord(expected, received):
            "Expected protocol record \(expected), received \(received)."
        case let .unsupportedProtocol(received, supported):
            "Unsupported protocol major version \(received); this app supports version \(supported)."
        case let .invalidHello(reason):
            "Invalid hello record: \(reason)."
        case let .invalidMetricID(id):
            "Invalid metric ID '\(id)'. IDs must match [a-z][a-z0-9_.-]{0,127}."
        case let .duplicateMetricID(id):
            "Duplicate metric ID '\(id)'."
        case let .invalidStaleInterval(metric):
            "Metric '\(metric)' must have a positive stale_after_ms."
        case let .invalidWindow(field, reason):
            "Invalid window \(field): \(reason)."
        case let .unknownMetricReference(metric):
            "Widget references unknown metric '\(metric)'."
        case let .invalidHistory(metric):
            "Sparkline for metric '\(metric)' must specify a positive history."
        case let .invalidSectionWeight(section):
            "Section '\(section)' must have a weight from 1 through 16."
        case let .invalidSurface(reason):
            "Invalid surface: \(reason)."
        case let .incompatibleWidget(metric, reason):
            "Invalid widget for metric '\(metric)': \(reason)."
        case let .duplicateUpdateMetric(metric):
            "Update contains metric '\(metric)' more than once."
        case let .invalidUpdate(metric, reason):
            "Invalid update for metric '\(metric)': \(reason)."
        case let .valueTypeMismatch(metric, expected, received):
            "Metric '\(metric)' expects \(expected.rawValue), received \(received.rawValue)."
        case let .invalidSequence(previous, received):
            "Sequence \(received) is not newer than \(previous)."
        case let .invalidTimestamp(timestamp):
            "Timestamp must be nonnegative; received \(timestamp)."
        case .invalidFatalMessage:
            "Fatal record message must not be empty."
        }
    }
}

public enum ProtocolValidator {
    public static let supportedMajor = 1

    public static func validate(_ hello: HelloMessage) throws {
        guard hello.protocolMajor == supportedMajor else {
            throw ProtocolValidationError.unsupportedProtocol(
                receivedMajor: hello.protocolMajor,
                supportedMajor: supportedMajor
            )
        }
        guard hello.protocolMinor >= 0 else {
            throw ProtocolValidationError.invalidHello("protocol_minor must be nonnegative")
        }
        guard !hello.sdkVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtocolValidationError.invalidHello("sdk_version must not be empty")
        }
    }

    public static func validate(_ plan: DashboardPlan) throws {
        var metricTypes: [String: MetricValueType] = [:]

        for metric in plan.metrics {
            guard isValidMetricID(metric.id) else {
                throw ProtocolValidationError.invalidMetricID(metric.id)
            }
            guard metricTypes.updateValue(metric.valueType, forKey: metric.id) == nil else {
                throw ProtocolValidationError.duplicateMetricID(metric.id)
            }
            guard metric.staleAfterMS > 0 else {
                throw ProtocolValidationError.invalidStaleInterval(metric: metric.id)
            }
        }

        try validate(plan.window)

        for section in plan.sections {
            guard (1 ... 16).contains(section.weight) else {
                throw ProtocolValidationError.invalidSectionWeight(section: section.title)
            }
            for widget in section.widgets {
                try validateWidget(widget, metricTypes: metricTypes)
            }
        }

        var surfaceKinds: Set<SurfaceKind> = []
        for surface in plan.surfaces {
            guard surfaceKinds.insert(surface.kind).inserted else {
                throw ProtocolValidationError.invalidSurface(
                    "surface kind \(surface.kind.rawValue) appears more than once"
                )
            }
            try validateSurfaceGeometry(surface)
            var nodeCount = 0
            try validateLayoutNode(
                surface.root,
                depth: 1,
                nodeCount: &nodeCount,
                metricTypes: metricTypes
            )
        }
    }

    public static func validate(_ update: UpdateMessage, against plan: DashboardPlan) throws {
        guard update.timestampMS >= 0 else {
            throw ProtocolValidationError.invalidTimestamp(update.timestampMS)
        }

        var metricTypes: [String: MetricValueType] = [:]
        for metric in plan.metrics {
            guard metricTypes.updateValue(metric.valueType, forKey: metric.id) == nil else {
                throw ProtocolValidationError.duplicateMetricID(metric.id)
            }
        }
        var seen: Set<String> = []

        for item in update.values {
            guard seen.insert(item.metric).inserted else {
                throw ProtocolValidationError.duplicateUpdateMetric(item.metric)
            }
            guard let expectedType = metricTypes[item.metric] else {
                throw ProtocolValidationError.unknownMetricReference(item.metric)
            }

            switch (item.value, item.error) {
            case let (.some(value), .none):
                guard value.kind == expectedType else {
                    throw ProtocolValidationError.valueTypeMismatch(
                        metric: item.metric,
                        expected: expectedType,
                        received: value.kind
                    )
                }
                try validate(value, metric: item.metric)
            case let (.none, .some(error)):
                guard !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProtocolValidationError.invalidUpdate(
                        metric: item.metric,
                        reason: "error must not be empty"
                    )
                }
            case (.some, .some):
                throw ProtocolValidationError.invalidUpdate(
                    metric: item.metric,
                    reason: "provide either value or error, not both"
                )
            case (.none, .none):
                throw ProtocolValidationError.invalidUpdate(
                    metric: item.metric,
                    reason: "provide either value or error"
                )
            }
        }
    }

    public static func validate(_ heartbeat: HeartbeatMessage) throws {
        guard heartbeat.timestampMS >= 0 else {
            throw ProtocolValidationError.invalidTimestamp(heartbeat.timestampMS)
        }
    }

    public static func validate(_ fatal: FatalMessage) throws {
        guard !fatal.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtocolValidationError.invalidFatalMessage
        }
    }

    private static func validate(_ window: WindowPlan) throws {
        guard window.width.isFinite, window.width > 0 else {
            throw ProtocolValidationError.invalidWindow(
                field: "width",
                reason: "must be finite and greater than zero"
            )
        }
        guard window.margin.isFinite, window.margin >= 0 else {
            throw ProtocolValidationError.invalidWindow(
                field: "margin",
                reason: "must be finite and nonnegative"
            )
        }
        guard window.opacity.isFinite, (0 ... 1).contains(window.opacity) else {
            throw ProtocolValidationError.invalidWindow(
                field: "opacity",
                reason: "must be finite and between zero and one"
            )
        }
    }

    private static func validate(_ value: TypedMetricValue, metric: String) throws {
        switch value {
        case let .ratio(number):
            guard number.isFinite, (0 ... 1).contains(number) else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "ratio must be finite and between zero and one"
                )
            }
        case .bytes:
            break
        case let .bytesPerSecond(number):
            guard number.isFinite, number >= 0 else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "bytes_per_second must be finite and nonnegative"
                )
            }
        case .count:
            break
        case let .durationSeconds(number):
            guard number.isFinite, number >= 0 else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "duration_seconds must be finite and nonnegative"
                )
            }
        case let .number(number):
            guard number.isFinite else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "number must be finite"
                )
            }
        case .text, .boolean:
            break
        case let .table(table):
            guard !table.columns.isEmpty else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "table must contain at least one column"
                )
            }
            guard table.rows.allSatisfy({ $0.count == table.columns.count }) else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "every table row must match the column count"
                )
            }
        case let .compactStatus(status):
            guard CompactStatusMetricValue.isValidGlyph(status.leading) else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "compact_status leading glyph is invalid"
                )
            }
            guard CompactStatusMetricValue.isValidGlyph(status.trailing) else {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "compact_status trailing glyph is invalid"
                )
            }
            if let ageSeconds = status.ageSeconds,
               !ageSeconds.isFinite || ageSeconds < 0
            {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "compact_status age_seconds must be finite and nonnegative"
                )
            }
            if let glyphScale = status.glyphScale,
               !glyphScale.isFinite || !(0.4 ... 1.5).contains(glyphScale)
            {
                throw ProtocolValidationError.invalidUpdate(
                    metric: metric,
                    reason: "compact_status glyph_scale must be finite and between 0.4 and 1.5"
                )
            }
        }
    }

    private static func isValidMetricID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1 ... 128).contains(bytes.count), let first = bytes.first,
              (Character("a").asciiValue! ... Character("z").asciiValue!).contains(first)
        else {
            return false
        }

        return bytes.dropFirst().allSatisfy { byte in
            (Character("a").asciiValue! ... Character("z").asciiValue!).contains(byte)
                || (Character("0").asciiValue! ... Character("9").asciiValue!).contains(byte)
                || byte == Character("_").asciiValue
                || byte == Character(".").asciiValue
                || byte == Character("-").asciiValue
        }
    }

    private static func isCompatible(format: MetricFormat, valueType: MetricValueType) -> Bool {
        switch format {
        case .percent:
            valueType == .ratio || valueType == .number
        case .bytes:
            valueType == .bytes
        case .bytesPerSecond:
            valueType == .bytesPerSecond
        case .count:
            valueType == .count
        case .number:
            [.ratio, .bytes, .bytesPerSecond, .count, .durationSeconds, .number].contains(valueType)
        case .duration:
            valueType == .durationSeconds
        case .text:
            valueType == .text
        case .boolean:
            valueType == .boolean
        case .table:
            valueType == .table
        case .compactStatus:
            valueType == .compactStatus
        case .celsius, .watts, .megahertz:
            valueType == .number
        }
    }

    private static func validatePlot(
        _ widget: WidgetPlan,
        metricTypes: [String: MetricValueType]
    ) throws {
        guard let history = widget.history, history > 0 else {
            throw ProtocolValidationError.invalidHistory(metric: widget.label)
        }
        guard !widget.series.isEmpty else {
            throw ProtocolValidationError.incompatibleWidget(
                metric: widget.label,
                reason: "plots require at least one series"
            )
        }

        var seen: Set<String> = []
        let scalarTypes: Set<MetricValueType> = [
            .ratio, .bytes, .bytesPerSecond, .count, .durationSeconds, .number,
        ]
        for series in widget.series {
            guard seen.insert(series.metric).inserted else {
                throw ProtocolValidationError.incompatibleWidget(
                    metric: series.metric,
                    reason: "plot series metrics must be unique"
                )
            }
            guard let valueType = metricTypes[series.metric] else {
                throw ProtocolValidationError.unknownMetricReference(series.metric)
            }
            guard scalarTypes.contains(valueType),
                  isCompatible(format: series.format, valueType: valueType)
            else {
                throw ProtocolValidationError.incompatibleWidget(
                    metric: series.metric,
                    reason: "plot series require compatible scalar metrics and formats"
                )
            }
        }
    }

    private static func validateWidget(
        _ widget: WidgetPlan,
        metricTypes: [String: MetricValueType]
    ) throws {
        if widget.kind == .plot {
            try validatePlot(widget, metricTypes: metricTypes)
            return
        }
        guard let valueType = metricTypes[widget.metric] else {
            throw ProtocolValidationError.unknownMetricReference(widget.metric)
        }
        if widget.kind == .sparkline, widget.history == nil || widget.history! <= 0 {
            throw ProtocolValidationError.invalidHistory(metric: widget.metric)
        }
        if let history = widget.history, history <= 0 {
            throw ProtocolValidationError.invalidHistory(metric: widget.metric)
        }
        if widget.kind == .compactStatus {
            guard valueType == .compactStatus, widget.format == .compactStatus else {
                throw ProtocolValidationError.incompatibleWidget(
                    metric: widget.metric,
                    reason: "compact_status widgets require a compact_status metric and format"
                )
            }
            return
        }
        if valueType == .compactStatus || widget.format == .compactStatus {
            throw ProtocolValidationError.incompatibleWidget(
                metric: widget.metric,
                reason: "compact_status is available only to native compact status surfaces"
            )
        }
        if widget.kind == .sparkline,
           ![MetricValueType.ratio, .bytes, .bytesPerSecond, .count, .durationSeconds, .number]
            .contains(valueType)
        {
            throw ProtocolValidationError.incompatibleWidget(
                metric: widget.metric,
                reason: "sparklines require a numeric value"
            )
        }
        if widget.kind == .gauge, valueType != .ratio {
            throw ProtocolValidationError.incompatibleWidget(
                metric: widget.metric,
                reason: "gauges require a ratio value"
            )
        }
        if widget.kind == .table, valueType != .table {
            throw ProtocolValidationError.incompatibleWidget(
                metric: widget.metric,
                reason: "table widgets require a table value"
            )
        }
        guard isCompatible(format: widget.format, valueType: valueType) else {
            throw ProtocolValidationError.incompatibleWidget(
                metric: widget.metric,
                reason: "format \(widget.format.rawValue) is incompatible with \(valueType.rawValue)"
            )
        }
    }

    private static func validateSurfaceGeometry(_ surface: SurfacePlan) throws {
        switch surface.kind {
        case .desktop:
            guard let x = surface.x, x.isFinite,
                  let y = surface.y, y.isFinite,
                  surface.origin != nil,
                  let width = surface.width, width.isFinite, width > 0,
                  let opacity = surface.backgroundOpacity,
                  opacity.isFinite, (0 ... 1).contains(opacity),
                  surface.clickThrough != nil
            else {
                throw ProtocolValidationError.invalidSurface(
                    "desktop geometry must be complete and finite"
                )
            }
        case .widgetLarge, .widgetMedium, .widgetSmall:
            guard surface.x == nil,
                  surface.y == nil,
                  surface.origin == nil,
                  surface.width == nil,
                  surface.backgroundOpacity == nil,
                  surface.clickThrough == nil
            else {
                throw ProtocolValidationError.invalidSurface(
                    "widget surfaces cannot contain desktop geometry"
                )
            }
        }
    }

    private static func validateLayoutNode(
        _ node: LayoutNode,
        depth: Int,
        nodeCount: inout Int,
        metricTypes: [String: MetricValueType]
    ) throws {
        guard depth <= 32 else {
            throw ProtocolValidationError.invalidSurface("layout depth exceeds 32")
        }
        nodeCount += 1
        guard nodeCount <= 256 else {
            throw ProtocolValidationError.invalidSurface("layout node count exceeds 256")
        }

        switch node {
        case let .widget(widget):
            try validateWidget(widget, metricTypes: metricTypes)
        case let .section(title, insets, child):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProtocolValidationError.invalidSurface("section title cannot be empty")
            }
            for value in [insets.top, insets.right, insets.bottom, insets.left] {
                try validateLayoutDimension(value)
            }
            try validateLayoutNode(
                child,
                depth: depth + 1,
                nodeCount: &nodeCount,
                metricTypes: metricTypes
            )
        case let .stack(gap, children):
            try validateLayoutDimension(gap)
            guard !children.isEmpty else {
                throw ProtocolValidationError.invalidSurface("stack children cannot be empty")
            }
            for child in children {
                try validateLayoutNode(
                    child,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    metricTypes: metricTypes
                )
            }
        case let .split(gap, minimumTrackWidth, tracks):
            try validateLayoutDimension(gap)
            try validateLayoutDimension(minimumTrackWidth)
            guard !tracks.isEmpty else {
                throw ProtocolValidationError.invalidSurface("split tracks cannot be empty")
            }
            for track in tracks {
                guard track.weight.isFinite, track.weight > 0 else {
                    throw ProtocolValidationError.invalidSurface(
                        "split track weights must be finite and positive"
                    )
                }
                try validateLayoutNode(
                    track.child,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    metricTypes: metricTypes
                )
            }
        case let .flow(horizontalGap, verticalGap, minimumItemWidth, children):
            try validateLayoutDimension(horizontalGap)
            try validateLayoutDimension(verticalGap)
            try validateLayoutDimension(minimumItemWidth)
            guard !children.isEmpty else {
                throw ProtocolValidationError.invalidSurface("flow children cannot be empty")
            }
            for child in children {
                try validateLayoutNode(
                    child,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    metricTypes: metricTypes
                )
            }
        }
    }

    private static func validateLayoutDimension(_ value: Double) throws {
        guard value.isFinite, value >= 0 else {
            throw ProtocolValidationError.invalidSurface(
                "layout dimensions must be finite and nonnegative"
            )
        }
    }
}

public enum ProtocolSessionEvent: Equatable, Sendable {
    case hello(HelloMessage)
    case plan(DashboardPlan)
    case update(UpdateMessage)
    case heartbeat(HeartbeatMessage)
    case fatal(FatalMessage)
}

public struct ProtocolSession: Sendable {
    private enum State: Sendable {
        case awaitingHello
        case awaitingPlan
        case running
        case terminated
    }

    private var state: State = .awaitingHello
    private var plan: DashboardPlan?
    private var lastSequence: UInt64?

    public init() {}

    public mutating func consume(_ record: ProtocolRecord) throws -> ProtocolSessionEvent {
        switch (state, record) {
        case let (.awaitingHello, .hello(hello)):
            try ProtocolValidator.validate(hello)
            state = .awaitingPlan
            return .hello(hello)

        case let (.awaitingPlan, .plan(plan)):
            try ProtocolValidator.validate(plan)
            self.plan = plan
            state = .running
            return .plan(plan)

        case let (.running, .update(update)):
            guard let plan else {
                preconditionFailure("Running protocol session has no plan")
            }
            try validateSequence(update.sequence)
            try ProtocolValidator.validate(update, against: plan)
            lastSequence = update.sequence
            return .update(update)

        case let (.running, .heartbeat(heartbeat)):
            try validateSequence(heartbeat.sequence)
            try ProtocolValidator.validate(heartbeat)
            lastSequence = heartbeat.sequence
            return .heartbeat(heartbeat)

        case let (.running, .fatal(fatal)):
            try ProtocolValidator.validate(fatal)
            state = .terminated
            return .fatal(fatal)

        default:
            throw ProtocolValidationError.unexpectedRecord(
                expected: expectedRecordDescription,
                received: record.typeName
            )
        }
    }

    private mutating func validateSequence(_ sequence: UInt64) throws {
        if let lastSequence, sequence <= lastSequence {
            throw ProtocolValidationError.invalidSequence(previous: lastSequence, received: sequence)
        }
    }

    private var expectedRecordDescription: String {
        switch state {
        case .awaitingHello: "hello"
        case .awaitingPlan: "plan"
        case .running: "update, heartbeat, or fatal"
        case .terminated: "none after fatal"
        }
    }
}
