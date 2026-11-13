import Foundation
import Testing
@testable import Wallstats
@testable import WallstatsCore

@Suite("Persistent usage graphs")
struct PersistentHistoryTests {
    private let quarterHour: Int64 = 900_000
    private let config = URL(fileURLWithPath: "/example/config.rs")

    @Test("Actual reload and relaunch paths preserve quota history, isolated by configuration")
    @MainActor
    func reloadAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardHistoryStore(directoryURL: directory)
        let model = AppModel(historyStore: store)
        model.beginLaunch(configURL: config)
        try model.accept(.plan(plan()))
        try model.accept(.update(update(1, at: 2 * quarterHour, used: 0.42)))
        try model.accept(.update(update(2, at: 3 * quarterHour, used: 0.45)))

        model.beginReload()
        model.beginResolution()
        model.beginLaunch(configURL: config)
        try model.accept(.plan(plan()))
        #expect(model.dashboard?.history(for: "usage.week").map(\.value) == [0.42, 0.45])
        model.flushHistory()

        let restarted = AppModel(historyStore: store)
        restarted.beginLaunch(configURL: config)
        try restarted.accept(.plan(plan()))
        #expect(restarted.dashboard?.history(for: "usage.week").map(\.timestampMS)
            == [2 * quarterHour, 3 * quarterHour])
        restarted.beginResolution()
        restarted.beginLaunch(configURL: URL(fileURLWithPath: "/different/config.rs"))
        try restarted.accept(.plan(plan()))
        #expect(restarted.dashboard?.history(for: "usage.week").isEmpty == true)
    }

    @Test("Repeated reload samples do not evict twelve hours of quota readings")
    func intervalDeduplication() throws {
        var state = try DashboardState(plan: plan())
        for index in 1 ... 48 {
            try state.apply(update(UInt64(index), at: Int64(index) * quarterHour, used: 0.4))
        }
        for index in 1 ... 100 {
            try state.apply(update(UInt64(48 + index), at: 48 * quarterHour + Int64(index), used: 0.45))
        }
        #expect(state.history(for: "usage.week").count == 48)
        #expect(state.history(for: "usage.week").first?.timestampMS == quarterHour)
        #expect(state.history(for: "usage.week").last?.value == 0.45)
    }

    @Test("Restoring history honours changed types and smaller plan bounds")
    func compatibleRestore() throws {
        var state = try DashboardState(plan: plan())
        for index in 1 ... 5 {
            try state.apply(update(UInt64(index), at: Int64(index) * quarterHour, used: 0.4))
        }
        var smaller = try DashboardState(plan: plan(history: 2))
        try smaller.restoreHistory(state.historyArchive)
        #expect(smaller.history(for: "usage.week").map(\.timestampMS) == [4 * quarterHour, 5 * quarterHour])
        var changed = try DashboardState(plan: plan(type: .number))
        try changed.restoreHistory(state.historyArchive)
        #expect(changed.history(for: "usage.week").isEmpty)
    }

    @Test("Sparse and unequal histories share the same real twelve-hour axis")
    func realTimePositions() throws {
        let now: Int64 = 24 * 3_600_000
        let timeline = PlotTimeline(
            timestamps: [now - 3_600_000, now - quarterHour, now],
            intervalsMS: [quarterHour], capacity: 48, nowMS: now
        )
        #expect(timeline.upperMS - timeline.lowerMS == 12 * 3_600_000)
        #expect(try #require(timeline.position(timestampMS: now - 3_600_000)) > 0.9)
        #expect(timeline.position(timestampMS: now) == 1)
        #expect(timeline.position(timestampMS: now - 13 * 3_600_000) == nil)
        #expect(!PlotTimeline.connects(from: now - 3_600_000, to: now, intervalMS: quarterHour))
        #expect(PlotTimeline.connects(from: now - quarterHour, to: now, intervalMS: quarterHour))
    }

    @Test("Render snapshots retain timestamps and cadence through encoding")
    func snapshotTiming() throws {
        var state = try DashboardState(plan: plan())
        try state.apply(update(1, at: quarterHour, used: 0.42))
        try state.apply(update(2, at: 2 * quarterHour, used: 0.45))
        let snapshot = try WidgetSnapshot(dashboard: state, sampledAt: Date(timeIntervalSince1970: 1_800))
        let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.metrics.first?.history == [0.42, 0.45])
        #expect(restored.metrics.first?.historyTimestampsMS == [quarterHour, 2 * quarterHour])
        #expect(restored.metrics.first?.sampleIntervalMS == quarterHour)
    }

    @Test("Corrupt history is reported without preventing fresh collection")
    @MainActor
    func corruptHistoryRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DashboardHistoryStore(directoryURL: directory)
        try Data("not JSON".utf8).write(to: store.archiveURL(config))
        let model = AppModel(historyStore: store)
        model.beginLaunch(configURL: config)
        try model.accept(.plan(plan()))
        try model.accept(.update(update(1, at: quarterHour, used: 0.42)))
        #expect(model.phase == .running)
        #expect(model.dashboard?.history(for: "usage.week").map(\.value) == [0.42])
        #expect(model.diagnostics.contains { $0.message.hasPrefix("Graph history:") })
    }

    @Test("A malformed archive cannot introduce invalid ratios or reordered samples")
    func invalidArchive() throws {
        for samples in [
            [HistorySample(timestampMS: 1, value: 1.5)],
            [HistorySample(timestampMS: 2, value: 0.5), HistorySample(timestampMS: 1, value: 0.4)],
        ] {
            let archive = DashboardHistoryArchive(metrics: [
                "usage.week": MetricHistoryArchive(valueType: .ratio, samples: samples),
            ])
            var state = try DashboardState(plan: plan())
            #expect(throws: HistoryArchiveError.self) { try state.restoreHistory(archive) }
            #expect(state.history(for: "usage.week").isEmpty)
        }
    }

    @Test("Oversized history is bounded before decoding")
    func oversizedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DashboardHistoryStore(directoryURL: directory)
        try Data(repeating: 32, count: DashboardHistoryStore.maximumBytes + 1)
            .write(to: store.archiveURL(config))
        #expect(throws: HistoryArchiveError.self) { try store.read(configURL: config) }
    }

    private func update(_ sequence: UInt64, at timestamp: Int64, used: Double) -> UpdateMessage {
        UpdateMessage(sequence: sequence, timestampMS: timestamp,
                      values: [UpdateItem(metric: "usage.week", value: .ratio(used))])
    }

    private func plan(history: Int = 48, type: MetricValueType = .ratio) -> DashboardPlan {
        DashboardPlan(
            title: "Usage",
            metrics: [MetricDefinition(id: "usage.week", valueType: type,
                                       staleAfterMS: 3 * quarterHour, sampleIntervalMS: quarterHour)],
            window: WindowPlan(width: 420, anchor: .topRight, margin: 20, layer: .desktop, opacity: 1),
            sections: [SectionPlan(title: "Usage", widgets: [WidgetPlan(
                kind: .plot, label: "Usage", metric: "", format: .number, history: history,
                series: [PlotSeries(metric: "usage.week", format: type == .ratio ? .percent : .number)]
            )])]
        )
    }
}
