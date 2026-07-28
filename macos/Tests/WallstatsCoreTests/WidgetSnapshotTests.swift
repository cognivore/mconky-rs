import Foundation
import Testing
@testable import WallstatsCore

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    @Test("Binary property-list store roundtrips a compact generic snapshot")
    func roundtrip() throws {
        let fixture = try SnapshotStoreFixture()
        defer { fixture.remove() }
        let snapshot = try sampleSnapshot()

        try fixture.store.write(snapshot)

        #expect(try fixture.store.read() == snapshot)
        let encoded = try Data(contentsOf: fixture.store.fileURL)
        #expect(encoded.starts(with: Data("bplist00".utf8)))
        #expect(encoded.count < WidgetSnapshotStore.maximumFileSize)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
        )
        #expect(plist["p"] != nil)
        #expect(plist["m"] != nil)
        #expect(plist["u"] != nil)
    }

    @Test("Corrupt and oversized snapshots are rejected")
    func corruptionAndSize() throws {
        let fixture = try SnapshotStoreFixture()
        defer { fixture.remove() }
        try Data("not a property list".utf8).write(to: fixture.store.fileURL)
        #expect(throws: WidgetSnapshotStoreError.invalidSnapshot) {
            try fixture.store.read()
        }

        try Data(repeating: 0, count: WidgetSnapshotStore.maximumFileSize + 1)
            .write(to: fixture.store.fileURL)
        #expect(throws: WidgetSnapshotStoreError.snapshotTooLarge) {
            try fixture.store.read()
        }
    }

    @Test("Generic snapshot validation rejects invalid state")
    func validation() throws {
        let plan = WidgetRenderPlan(sections: [
            WidgetRenderSection(title: "bad", weight: 1, widgets: []),
        ])
        #expect(throws: WidgetSnapshotValidationError.invalidSampledAt) {
            try WidgetSnapshot(
                sampledAt: Date(timeIntervalSince1970: -1),
                renderPlan: plan,
                metrics: []
            )
        }
        #expect(throws: WidgetSnapshotValidationError.historyTooLong("cpu")) {
            try WidgetSnapshot(
                sampledAt: Date(),
                renderPlan: plan,
                metrics: [WidgetRenderMetric(
                    metricID: "cpu",
                    valueType: .ratio,
                    value: .ratio(0.5),
                    error: nil,
                    timestampMS: 1,
                    history: Array(repeating: 0.5, count: 61)
                )]
            )
        }
        #expect(throws: WidgetSnapshotValidationError.invalidValue("metric value type")) {
            try WidgetSnapshot(
                sampledAt: Date(),
                renderPlan: plan,
                metrics: [WidgetRenderMetric(
                    metricID: "cpu",
                    valueType: .ratio,
                    value: .number(0.5),
                    error: nil,
                    timestampMS: 1,
                    history: []
                )]
            )
        }
    }

    @Test("Legacy schema-v1 fixed snapshots decode to an empty generic plan")
    func legacyFallback() throws {
        let legacy: [String: Any] = [
            "v": 1,
            "t": Date(timeIntervalSince1970: 1_700_000_000),
            "c": 0.5,
            "m": 0.6,
            "d": 0.4,
            "s": [["i": "old"]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: legacy,
            format: .binary,
            options: 0
        )

        let snapshot = try PropertyListDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(snapshot.renderPlan.sections.isEmpty)
        #expect(snapshot.metrics.isEmpty)
    }

    @Test("Dashboard conversion preserves plan order and only referenced metrics")
    func dashboardConversion() throws {
        var dashboard = try DashboardState(plan: dashboardPlan(history: 90))
        for sequence in 1 ... 65 {
            try dashboard.apply(UpdateMessage(
                sequence: UInt64(sequence),
                timestampMS: Int64(sequence * 1_000),
                values: [
                    UpdateItem(metric: "cpu", value: .ratio(Double(sequence % 10) / 10)),
                    UpdateItem(metric: "temperature", value: .number(42.5)),
                    UpdateItem(metric: "unused", value: .count(99)),
                    UpdateItem(metric: "sync", value: .compactStatus(statusValue())),
                ]
            ))
        }

        let snapshot = try WidgetSnapshot(dashboard: dashboard, sampledAt: Date())
        #expect(snapshot.widgetSurfaces.map(\.kind) == [.widgetLarge, .widgetSmall])
        #expect(snapshot.renderPlan.sections.isEmpty)
        #expect(snapshot.metrics.map(\.metricID) == ["cpu", "temperature", "sync"])
        #expect(snapshot.metrics.first(where: { $0.metricID == "cpu" })?.history.count == 60)
        #expect(snapshot.metrics.contains(where: { $0.metricID == "unused" }) == false)
    }

    @Test("Metric errors and bounded table values are persisted")
    func errorsAndTableBounds() throws {
        let plan = DashboardPlan(
            title: "Table",
            metrics: [
                MetricDefinition(id: "rows", valueType: .table, staleAfterMS: 1_000),
                MetricDefinition(id: "state", valueType: .text, staleAfterMS: 1_000),
            ],
            window: testWindow(),
            sections: [SectionPlan(title: "data", widgets: [
                WidgetPlan(kind: .table, label: "rows", metric: "rows", format: .table),
                WidgetPlan(kind: .value, label: "state", metric: "state", format: .text),
            ])]
        )
        var dashboard = try DashboardState(plan: plan)
        try dashboard.apply(UpdateMessage(
            sequence: 1,
            timestampMS: 1_000,
            values: [
                UpdateItem(metric: "rows", value: .table(TableValue(
                    columns: (0 ..< 10).map { "column-\($0)" },
                    rows: (0 ..< 12).map { row in (0 ..< 10).map { "\(row)-\($0)" } }
                ))),
                UpdateItem(metric: "state", error: String(repeating: "x", count: 400)),
            ]
        ))

        let snapshot = try WidgetSnapshot(dashboard: dashboard, sampledAt: Date())
        guard case let .table(table) = snapshot.metrics[0].value else {
            Issue.record("Expected bounded table")
            return
        }
        #expect(table.columns.count == 8)
        #expect(table.rows.count == 8)
        #expect(snapshot.metrics[1].error?.count == 256)
    }

    private func sampleSnapshot() throws -> WidgetSnapshot {
        try WidgetSnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000),
            renderPlan: WidgetRenderPlan(sections: [
                WidgetRenderSection(title: "signals", weight: 2, widgets: [
                    WidgetRenderWidget(
                        kind: .plot,
                        label: "activity",
                        history: 60,
                        series: [WidgetRenderSeries(metric: "cpu", format: .percent, accent: "cyan")]
                    ),
                ]),
            ]),
            metrics: [WidgetRenderMetric(
                metricID: "cpu",
                valueType: .ratio,
                value: .ratio(0.42),
                error: nil,
                timestampMS: 1_700_000_000_000,
                history: [0.2, 0.4, 0.42]
            )],
            widgetSurfaces: [SurfacePlan(
                kind: .widgetLarge,
                root: .widget(WidgetPlan(
                    kind: .plot,
                    label: "activity",
                    history: 60,
                    series: [PlotSeries(metric: "cpu", format: .percent, accent: "cyan")]
                ))
            )]
        )
    }

    private func dashboardPlan(history: Int) -> DashboardPlan {
        DashboardPlan(
            title: "Generic",
            metrics: [
                MetricDefinition(id: "cpu", valueType: .ratio, staleAfterMS: 1_000),
                MetricDefinition(id: "temperature", valueType: .number, staleAfterMS: 1_000),
                MetricDefinition(id: "unused", valueType: .count, staleAfterMS: 1_000),
                MetricDefinition(id: "sync", valueType: .compactStatus, staleAfterMS: 1_000),
            ],
            window: testWindow(),
            sections: [
                SectionPlan(title: "signals", widgets: [
                    WidgetPlan(
                        kind: .plot,
                        label: "activity",
                        metric: "",
                        format: .number,
                        history: history,
                        series: [
                            PlotSeries(metric: "cpu", format: .percent, accent: "cyan"),
                            PlotSeries(metric: "temperature", format: .celsius, accent: "amber"),
                        ]
                    ),
                ], weight: 3),
                SectionPlan(title: "status", widgets: [
                    WidgetPlan(
                        kind: .compactStatus,
                        label: "sync",
                        metric: "sync",
                        format: .compactStatus
                    ),
                ]),
            ],
            surfaces: [
                SurfacePlan(
                    kind: .desktop,
                    root: .widget(WidgetPlan(
                        kind: .value,
                        label: "unused",
                        metric: "unused",
                        format: .count
                    )),
                    x: 0,
                    y: 0,
                    width: 300,
                    backgroundOpacity: 0,
                    clickThrough: true
                ),
                SurfacePlan(
                    kind: .widgetLarge,
                    root: .section(
                        title: "signals",
                        insets: .zero,
                        child: .widget(WidgetPlan(
                            kind: .plot,
                            label: "activity",
                            history: history,
                            series: [
                                PlotSeries(metric: "cpu", format: .percent, accent: "cyan"),
                                PlotSeries(metric: "temperature", format: .celsius, accent: "amber"),
                            ]
                        ))
                    )
                ),
                SurfacePlan(
                    kind: .widgetSmall,
                    root: .widget(WidgetPlan(
                        kind: .compactStatus,
                        label: "sync",
                        metric: "sync",
                        format: .compactStatus
                    ))
                ),
            ]
        )
    }

    private func statusValue() -> CompactStatusMetricValue {
        CompactStatusMetricValue(
            leading: "☁️",
            trailing: "💾",
            light: .green,
            ageSeconds: 60,
            glyphScale: 0.8
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

private struct SnapshotStoreFixture {
    let directoryURL: URL
    let store: WidgetSnapshotStore

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallstats-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        store = WidgetSnapshotStore(directoryURL: directoryURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
