import Foundation
import Testing
@testable import WallstatsCore

@Suite("Protocol decoding and validation")
struct ProtocolDecodingTests {
    @Test("A complete v1 fixture is accepted in order")
    func validSession() throws {
        var session = ProtocolSession()
        let records = try Fixture.records(named: "valid-session", extension: "jsonl")
        let events = try records.map { try session.consume($0) }

        #expect(events.count == 4)
        guard case let .plan(plan) = events[1] else {
            Issue.record("Second event was not a plan")
            return
        }
        #expect(plan.metrics.count == 9)
        #expect(plan.sections.allSatisfy { $0.weight == 1 })
        #expect(plan.sections.flatMap(\.widgets).allSatisfy { $0.series.isEmpty })

        guard case let .update(update) = events[2] else {
            Issue.record("Third event was not an update")
            return
        }
        #expect(update.values.count == 9)
        #expect(update.values.last?.value?.kind == .table)
    }

    @Test("Protocol records round-trip without changing typed values")
    func recordRoundTrip() throws {
        for record in try Fixture.records(named: "valid-session", extension: "jsonl") {
            let encoded = try JSONEncoder().encode(record)
            #expect(try WallstatsProtocolDecoder().decode(encoded) == record)
        }
    }

    @Test("Protocol major mismatches are rejected")
    func protocolMismatch() throws {
        let record = try Fixture.record(named: "protocol-mismatch")
        var session = ProtocolSession()
        #expect(throws: ProtocolValidationError.self) {
            try session.consume(record)
        }
    }

    @Test("Plans reject duplicate metric IDs")
    func duplicateMetrics() throws {
        let plan = try Fixture.plan(named: "duplicate-metrics")
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(plan)
        }
    }

    @Test("Plans reject unknown widget metric references")
    func unknownMetricReference() throws {
        let plan = try Fixture.plan(named: "unknown-reference")
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(plan)
        }
    }

    @Test("Plans reject invalid window dimensions")
    func invalidWindow() throws {
        let plan = try Fixture.plan(named: "invalid-window")
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(plan)
        }
    }

    @Test("Plans reject opacity outside zero through one")
    func invalidOpacity() throws {
        let plan = try Fixture.plan(named: "invalid-opacity")
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(plan)
        }
    }

    @Test("Gauge widgets remain ratio-only")
    func gaugeRequiresRatio() {
        let plan = DashboardPlan(
            title: "Gauge",
            metrics: [MetricDefinition(id: "load", valueType: .number, staleAfterMS: 1_000)],
            window: WindowPlan(
                width: 420,
                anchor: .topRight,
                margin: 20,
                layer: .desktop,
                opacity: 0.94
            ),
            sections: [
                SectionPlan(
                    title: "Load",
                    widgets: [
                        WidgetPlan(
                            kind: .gauge,
                            label: "Load",
                            metric: "load",
                            format: .number
                        ),
                    ]
                ),
            ]
        )

        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(plan)
        }
    }

    @Test("Updates reject ratios outside zero through one")
    func invalidRatio() throws {
        let plan = try Fixture.validPlan()
        guard case let .update(update) = try Fixture.record(named: "invalid-ratio") else {
            Issue.record("Fixture was not an update")
            return
        }
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(update, against: plan)
        }
    }

    @Test("Updates reject unknown metric references")
    func unknownUpdateMetric() throws {
        let plan = try Fixture.validPlan()
        guard case let .update(update) = try Fixture.record(named: "unknown-update") else {
            Issue.record("Fixture was not an update")
            return
        }
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(update, against: plan)
        }
    }

    @Test("Programmatic nonfinite values are rejected")
    func nonfiniteValue() throws {
        let plan = try Fixture.validPlan()
        let update = UpdateMessage(
            sequence: 3,
            timestampMS: 1_785_168_006_123,
            values: [UpdateItem(metric: "temperature", value: .number(.infinity))]
        )
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(update, against: plan)
        }
    }

    @Test("JSON numbers that overflow Double are rejected")
    func nonfiniteNumber() throws {
        let data = try Fixture.data(named: "nonfinite-number", extension: "json")
        var didThrow = false
        do {
            _ = try WallstatsProtocolDecoder().decode(data)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    @Test("The first two records must be hello and plan")
    func recordOrdering() throws {
        let planRecord = try Fixture.record(named: "duplicate-metrics")
        var session = ProtocolSession()
        #expect(throws: ProtocolValidationError.self) {
            try session.consume(planRecord)
        }
    }

    @Test("Compact status values decode and round-trip the exact wire shape")
    func compactStatusRoundTrip() throws {
        let data = Data(
            #"{"kind":"compact_status","leading":"☁️","trailing":"💾","light":"amber","age_seconds":123.0,"glyph_scale":0.75}"#.utf8
        )
        let value = try JSONDecoder().decode(TypedMetricValue.self, from: data)
        #expect(value == .compactStatus(CompactStatusMetricValue(
            leading: "☁️",
            trailing: "💾",
            light: .amber,
            ageSeconds: 123,
            glyphScale: 0.75
        )))
        #expect(try JSONDecoder().decode(
            TypedMetricValue.self,
            from: JSONEncoder().encode(value)
        ) == value)
        #expect(MetricValueType.compactStatus.rawValue == "compact_status")
        #expect(StatusLight.allCases.map(\.rawValue) == ["green", "blue", "amber", "red", "gray"])
    }

    @Test("Compact status JSON without glyph scale remains backward compatible")
    func compactStatusLegacyGlyphScale() throws {
        let data = Data(
            #"{"kind":"compact_status","leading":"☁️","trailing":"💾","light":"gray"}"#.utf8
        )
        guard case let .compactStatus(value) = try JSONDecoder().decode(
            TypedMetricValue.self,
            from: data
        ) else {
            Issue.record("Expected compact status")
            return
        }
        #expect(value.glyphScale == nil)
        #expect(CompactStatusGlyphLayout.resolve(glyphScale: value.glyphScale).fontSize == 13)
    }

    @Test("Compact status validation rejects invalid glyphs and ages")
    func compactStatusValidation() throws {
        let plan = compactStatusPlan()
        let valid = UpdateMessage(
            sequence: 1,
            timestampMS: 1_000,
            values: [UpdateItem(metric: "arbitrary", value: .compactStatus(CompactStatusMetricValue(
                leading: "☁️",
                trailing: "💾",
                light: .green,
                ageSeconds: 1
            )))]
        )
        try ProtocolValidator.validate(valid, against: plan)

        for value in [
            CompactStatusMetricValue(leading: "", trailing: "💾", light: .gray),
            CompactStatusMetricValue(leading: "abc", trailing: "💾", light: .gray),
            CompactStatusMetricValue(leading: "☁️", trailing: "\n", light: .gray),
            CompactStatusMetricValue(leading: "\u{200B}", trailing: "💾", light: .gray),
            CompactStatusMetricValue(leading: "☁️", trailing: "💾", light: .gray, ageSeconds: -1),
            CompactStatusMetricValue(leading: "☁️", trailing: "💾", light: .gray, ageSeconds: .infinity),
            CompactStatusMetricValue(leading: "☁️", trailing: "💾", light: .gray, glyphScale: 0.39),
            CompactStatusMetricValue(leading: "☁️", trailing: "💾", light: .gray, glyphScale: 1.51),
            CompactStatusMetricValue(leading: "☁️", trailing: "💾", light: .gray, glyphScale: .nan),
            CompactStatusMetricValue(
                leading: "👨‍👩‍👧‍👦👨‍👩‍👧‍👦",
                trailing: "💾",
                light: .gray
            ),
        ] {
            let update = UpdateMessage(
                sequence: 2,
                timestampMS: 2_000,
                values: [UpdateItem(metric: "arbitrary", value: .compactStatus(value))]
            )
            #expect(throws: ProtocolValidationError.self) {
                try ProtocolValidator.validate(update, against: plan)
            }
        }
    }

    @Test("Compact status metrics cannot use standard dashboard widgets")
    func compactStatusRejectsStandardWidgets() {
        let plan = DashboardPlan(
            title: "Compact",
            metrics: [
                MetricDefinition(id: "arbitrary", valueType: .compactStatus, staleAfterMS: 1_000),
            ],
            window: testWindow(),
            sections: [
                SectionPlan(
                    title: "Status",
                    widgets: [
                        WidgetPlan(
                            kind: .value,
                            label: "Status",
                            metric: "arbitrary",
                            format: .text
                        ),
                    ]
                ),
            ]
        )
        #expect(throws: ProtocolValidationError.self) {
            try ProtocolValidator.validate(plan)
        }
    }

    @Test("Plot, compact status, section weight, and number formats round-trip")
    func additivePlanRoundTrip() throws {
        let plan = DashboardPlan(
            title: "Generic",
            metrics: [
                MetricDefinition(id: "cpu", valueType: .ratio, staleAfterMS: 1_000),
                MetricDefinition(id: "temp", valueType: .number, staleAfterMS: 1_000),
                MetricDefinition(id: "status", valueType: .compactStatus, staleAfterMS: 1_000),
            ],
            window: testWindow(),
            sections: [SectionPlan(title: "hardware", widgets: [
                WidgetPlan(
                    kind: .plot,
                    label: "activity",
                    metric: "",
                    format: .number,
                    history: 60,
                    series: [
                        PlotSeries(metric: "cpu", format: .percent, accent: "cyan"),
                        PlotSeries(metric: "temp", format: .celsius, accent: "amber"),
                    ]
                ),
                WidgetPlan(
                    kind: .compactStatus,
                    label: "state",
                    metric: "status",
                    format: .compactStatus
                ),
            ], weight: 4)]
        )

        try ProtocolValidator.validate(plan)
        let decoded = try JSONDecoder().decode(
            DashboardPlan.self,
            from: JSONEncoder().encode(plan)
        )
        #expect(decoded == plan)
        #expect(decoded.sections[0].weight == 4)
        #expect(decoded.sections[0].widgets[0].series.count == 2)
        #expect(WidgetKind.plot.rawValue == "plot")
        #expect(WidgetKind.compactStatus.rawValue == "compact_status")
        #expect([
            MetricFormat.celsius.rawValue,
            MetricFormat.watts.rawValue,
            MetricFormat.megahertz.rawValue,
        ] == [
            "celsius", "watts", "megahertz",
        ])
    }

    @Test("Plot validation rejects empty, duplicate, unknown, and nonscalar series")
    func invalidPlots() {
        let metrics = [
            MetricDefinition(id: "cpu", valueType: .ratio, staleAfterMS: 1_000),
            MetricDefinition(id: "name", valueType: .text, staleAfterMS: 1_000),
        ]
        let invalidWidgets = [
            WidgetPlan(
                kind: .plot,
                label: "empty",
                metric: "",
                format: .number,
                history: 10,
                series: []
            ),
            WidgetPlan(
                kind: .plot,
                label: "duplicate",
                metric: "",
                format: .number,
                history: 10,
                series: [
                    PlotSeries(metric: "cpu", format: .percent),
                    PlotSeries(metric: "cpu", format: .percent),
                ]
            ),
            WidgetPlan(
                kind: .plot,
                label: "unknown",
                metric: "",
                format: .number,
                history: 10,
                series: [PlotSeries(metric: "missing", format: .number)]
            ),
            WidgetPlan(
                kind: .plot,
                label: "text",
                metric: "",
                format: .number,
                history: 10,
                series: [PlotSeries(metric: "name", format: .text)]
            ),
            WidgetPlan(
                kind: .plot,
                label: "history",
                metric: "",
                format: .number,
                history: 0,
                series: [PlotSeries(metric: "cpu", format: .percent)]
            ),
        ]

        for widget in invalidWidgets {
            let plan = DashboardPlan(
                title: "Invalid",
                metrics: metrics,
                window: testWindow(),
                sections: [SectionPlan(title: "bad", widgets: [widget])]
            )
            #expect(throws: ProtocolValidationError.self) {
                try ProtocolValidator.validate(plan)
            }
        }
    }

    @Test("Section weights must be from one through sixteen")
    func invalidSectionWeights() {
        for weight in [0, 17] {
            let plan = DashboardPlan(
                title: "Weight",
                metrics: [],
                window: testWindow(),
                sections: [SectionPlan(title: "bad", widgets: [], weight: weight)]
            )
            #expect(throws: ProtocolValidationError.self) {
                try ProtocolValidator.validate(plan)
            }
        }
    }

    private func compactStatusPlan() -> DashboardPlan {
        DashboardPlan(
            title: "Compact",
            metrics: [
                MetricDefinition(id: "arbitrary", valueType: .compactStatus, staleAfterMS: 1_000),
            ],
            window: testWindow(),
            sections: []
        )
    }

    private func testWindow() -> WindowPlan {
        WindowPlan(
            width: 420,
            anchor: .topRight,
            margin: 20,
            layer: .desktop,
            opacity: 0.94
        )
    }
}

private enum Fixture {
    static func data(named name: String, extension fileExtension: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension))
        return try Data(contentsOf: url)
    }

    static func record(named name: String) throws -> ProtocolRecord {
        try WallstatsProtocolDecoder().decode(data(named: name, extension: "json"))
    }

    static func records(named name: String, extension fileExtension: String) throws -> [ProtocolRecord] {
        let fixtureData = try data(named: name, extension: fileExtension)
        return try fixtureData.split(separator: 0x0A).map {
            try WallstatsProtocolDecoder().decode(Data($0))
        }
    }

    static func plan(named name: String) throws -> DashboardPlan {
        guard case let .plan(plan) = try record(named: name) else {
            throw FixtureError.expectedPlan
        }
        return plan
    }

    static func validPlan() throws -> DashboardPlan {
        let records = try records(named: "valid-session", extension: "jsonl")
        guard case let .plan(plan) = records[1] else {
            throw FixtureError.expectedPlan
        }
        return plan
    }
}

private enum FixtureError: Error {
    case expectedPlan
}
