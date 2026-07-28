import Foundation
import Testing
@testable import Wallstats
@testable import WallstatsCore

@Suite("Widget snapshot publisher")
struct WidgetSnapshotPublisherTests {
    @Test("Writes immediately, retains the newest pending state, and throttles reloads")
    @MainActor
    func coalescingAndReloading() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let clock = ManualWidgetClock(now: Date(timeIntervalSince1970: 1_000))
        let reloader = RecordingWidgetReloader()
        let reloadDateStore = InMemoryReloadDateStore()
        let recorder = WidgetFailureRecorder()
        let publisher = WidgetSnapshotPublisher(
            store: fixture.store,
            clock: clock,
            reloader: reloader,
            reloadDateStore: reloadDateStore
        )
        let first = try snapshot(sampledAt: 1_000, cpu: 0.1)
        let superseded = try snapshot(sampledAt: 1_001, cpu: 0.2)
        let newest = try snapshot(sampledAt: 1_002, cpu: 0.3)
        let store = fixture.store

        await publisher.publish(first, reportFailure: recorder.record)
        #expect(try fixture.store.read() == first)
        #expect(await reloader.reloadCount() == 1)

        await publisher.publish(superseded, reportFailure: recorder.record)
        await publisher.publish(newest, reportFailure: recorder.record)
        await waitForSleeper(clock)
        #expect(try fixture.store.read() == first)

        await clock.advance(by: 59)
        await Task.yield()
        #expect(try fixture.store.read() == first)

        await clock.advance(by: 1)
        try await waitUntil {
            try store.read() == newest
        }
        #expect(await reloader.reloadCount() == 1)

        await clock.advance(by: 29 * 60)
        let reloadEligible = try snapshot(sampledAt: 2_800, cpu: 0.4)
        await publisher.publish(reloadEligible, reportFailure: recorder.record)
        #expect(try fixture.store.read() == reloadEligible)
        #expect(await reloader.reloadCount() == 2)
        let persistedReloadDate = await reloadDateStore.date(forKey: "widget-last-reload-v1")
        #expect(persistedReloadDate == Date(timeIntervalSince1970: 2_800))

        await clock.advance(by: 60)
        let timestampOnlyChange = try snapshot(sampledAt: 2_860, cpu: 0.4)
        await publisher.publish(timestampOnlyChange, reportFailure: recorder.record)
        #expect(try fixture.store.read() == timestampOnlyChange)
        #expect(await reloader.reloadCount() == 2)
        #expect(recorder.messages.isEmpty)

        await clock.advance(by: 29 * 60)
        let statusAndDiskChange = try snapshot(
            sampledAt: 4_600,
            cpu: 0.4,
            diskFreeBytes: 300,
            light: .red
        )
        await publisher.publish(statusAndDiskChange, reportFailure: recorder.record)
        #expect(await reloader.reloadCount() == 3)

        let relaunchedReloader = RecordingWidgetReloader()
        let relaunchedPublisher = WidgetSnapshotPublisher(
            store: fixture.store,
            clock: clock,
            reloader: relaunchedReloader,
            reloadDateStore: reloadDateStore
        )
        await relaunchedPublisher.publish(
            try snapshot(sampledAt: 2_861, cpu: 0.5),
            reportFailure: recorder.record
        )
        #expect(await relaunchedReloader.reloadCount() == 0)
    }

    @Test("Repeated store failures report once and do not throw")
    @MainActor
    func storeFailureIsDeduplicated() async throws {
        let fixture = try PublisherFixture(blockDirectory: true)
        defer { fixture.remove() }
        let clock = ManualWidgetClock(now: Date(timeIntervalSince1970: 1_000))
        let recorder = WidgetFailureRecorder()
        let publisher = WidgetSnapshotPublisher(
            store: fixture.store,
            clock: clock,
            reloader: RecordingWidgetReloader()
        )

        await publisher.publish(
            try snapshot(sampledAt: 1_000, cpu: 0.1),
            reportFailure: recorder.record
        )
        #expect(recorder.messages.count == 1)

        await publisher.publish(
            try snapshot(sampledAt: 1_001, cpu: 0.2),
            reportFailure: recorder.record
        )
        await waitForSleeper(clock)
        await clock.advance(by: 60)
        try await waitUntil {
            await clock.pendingSleeperCount() == 0
        }
        #expect(recorder.messages.count == 1)
    }

    @Test("Forced publication bypasses write and reload throttles")
    @MainActor
    func forcedPublicationBypassesThrottles() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let clock = ManualWidgetClock(now: Date(timeIntervalSince1970: 1_000))
        let reloader = RecordingWidgetReloader()
        let reloadDateStore = InMemoryReloadDateStore()
        let recorder = WidgetFailureRecorder()
        let publisher = WidgetSnapshotPublisher(
            store: fixture.store,
            clock: clock,
            reloader: reloader,
            reloadDateStore: reloadDateStore
        )
        let first = try snapshot(sampledAt: 1_000, cpu: 0.1)
        let pending = try snapshot(sampledAt: 1_010, cpu: 0.2)
        let forced = try snapshot(sampledAt: 1_011, cpu: 0.3)

        #expect(await publisher.publish(first, force: false, reportFailure: recorder.record))
        await clock.advance(by: 10)
        #expect(await publisher.publish(pending, force: false, reportFailure: recorder.record))
        #expect(try fixture.store.read() == first)

        #expect(await publisher.publish(forced, force: true, reportFailure: recorder.record))
        #expect(try fixture.store.read() == forced)
        #expect(await reloader.reloadCount() == 2)
        #expect(
            await reloadDateStore.date(forKey: "widget-last-reload-v1")
                == Date(timeIntervalSince1970: 1_010)
        )

        let ordinary = try snapshot(sampledAt: 1_012, cpu: 0.4)
        #expect(await publisher.publish(ordinary, force: false, reportFailure: recorder.record))
        #expect(try fixture.store.read() == forced)
        #expect(await reloader.reloadCount() == 2)
        await clock.advance(by: 60)
        await Task.yield()
    }

    @Test("AppModel keeps collection live and owns one widget diagnostic")
    @MainActor
    func appModelDiagnosticIsDeduplicated() async throws {
        let publisher = AlwaysFailingWidgetPublisher()
        let model = AppModel(widgetSnapshotPublisher: publisher)
        try model.accept(.plan(singleMetricPlan()))

        try model.accept(.update(UpdateMessage(
            sequence: 1,
            timestampMS: 1_000,
            values: [UpdateItem(metric: "cpu.total", value: .ratio(0.2))]
        )))
        try await waitUntil {
            await publisher.publishCount() == 1
        }

        try model.accept(.update(UpdateMessage(
            sequence: 2,
            timestampMS: 2_000,
            values: [UpdateItem(metric: "cpu.total", value: .ratio(0.4))]
        )))
        try await waitUntil {
            await publisher.publishCount() == 2
        }

        #expect(model.phase == .running)
        #expect(model.dashboard?.metrics["cpu.total"]?.value == .ratio(0.4))
        #expect(model.diagnostics.count == 1)
        #expect(model.diagnostics.first?.level == .warning)
    }

    @Test("AppModel ignores unrelated updates until system metrics are coherent")
    @MainActor
    func appModelWaitsForSystemMetrics() async throws {
        let publisher = RecordingWidgetSnapshotPublisher()
        let model = AppModel(widgetSnapshotPublisher: publisher)
        try model.accept(.plan(widgetReadinessPlan(includeCompactStatus: false)))

        try model.accept(.update(unrelatedUpdate(sequence: 1, timestampMS: 1_000)))
        #expect(await publisher.publishCount() == 0)
        #expect(model.dashboard?.metrics["logs.systeml.issues"]?.value == .count(4))

        try model.accept(.update(systemUpdate(sequence: 2, timestampMS: 2_000)))
        try await waitUntil {
            await publisher.publishCount() == 1
        }

        let snapshot = try #require(await publisher.firstSnapshot())
        #expect(snapshot.metrics.first(where: { $0.metricID == "cpu.total" })?.value == .ratio(0.42))
        #expect(snapshot.metrics.first(where: { $0.metricID == "memory.ratio" })?.value == .ratio(0.64))
    }

    @Test("AppModel waits for system and compact status regardless of arrival order")
    @MainActor
    func appModelWaitsForSystemAndCompactStatus() async throws {
        for statusFirst in [false, true] {
            let publisher = RecordingWidgetSnapshotPublisher()
            let model = AppModel(widgetSnapshotPublisher: publisher)
            try model.accept(.plan(widgetReadinessPlan(includeCompactStatus: true)))

            if statusFirst {
                try model.accept(.update(compactStatusUpdate(sequence: 1, timestampMS: 1_000)))
                #expect(await publisher.publishCount() == 0)
                try model.accept(.update(systemUpdate(sequence: 2, timestampMS: 2_000)))
            } else {
                try model.accept(.update(systemUpdate(sequence: 1, timestampMS: 1_000)))
                #expect(await publisher.publishCount() == 0)
                try model.accept(.update(compactStatusUpdate(sequence: 2, timestampMS: 2_000)))
            }

            try await waitUntil {
                await publisher.publishCount() == 1
            }
            let snapshot = try #require(await publisher.firstSnapshot())
            #expect(snapshot.metrics.first(where: { $0.metricID == "cpu.total" })?.value == .ratio(0.42))
            let status = try #require(snapshot.metrics.first(where: { $0.metricID == "sync.summary" }))
            #expect(status.value == .compactStatus(CompactStatusMetricValue(
                leading: "☁️",
                trailing: "💾",
                light: .green,
                ageSeconds: 1_080
            )))
        }
    }

    @Test("An explicit compact-status error counts as reported")
    @MainActor
    func appModelCompactStatusErrorAllowsPublication() async throws {
        let publisher = RecordingWidgetSnapshotPublisher()
        let model = AppModel(widgetSnapshotPublisher: publisher)
        try model.accept(.plan(widgetReadinessPlan(includeCompactStatus: true)))
        try model.accept(.update(systemUpdate(sequence: 1, timestampMS: 1_000)))
        try model.accept(.update(compactStatusUpdate(
            sequence: 2,
            timestampMS: 2_000,
            error: "unavailable"
        )))

        try await waitUntil {
            await publisher.publishCount() == 1
        }
        let snapshot = try #require(await publisher.firstSnapshot())
        #expect(snapshot.metrics.first(where: { $0.metricID == "sync.summary" })?.error == "unavailable")
    }

    @Test("Initial readiness requires only declared meaningful system metrics")
    @MainActor
    func appModelUsesDeclaredSystemSubset() async throws {
        let subsetPublisher = RecordingWidgetSnapshotPublisher()
        let subsetModel = AppModel(widgetSnapshotPublisher: subsetPublisher)
        try subsetModel.accept(.plan(singleMetricPlan()))
        try subsetModel.accept(.update(UpdateMessage(
            sequence: 1,
            timestampMS: 1_000,
            values: [UpdateItem(metric: "cpu.total", value: .ratio(0.3))]
        )))
        try await waitUntil {
            await subsetPublisher.publishCount() == 1
        }

        let emptyPublisher = RecordingWidgetSnapshotPublisher()
        let emptyModel = AppModel(widgetSnapshotPublisher: emptyPublisher)
        try emptyModel.accept(.plan(emptyPlan()))
        #expect(await emptyPublisher.publishCount() == 0)
    }

    @Test("Initial readiness waits for every unique plot and widget metric")
    @MainActor
    func appModelWaitsForEveryReference() async throws {
        for ioFirst in [false, true] {
            let publisher = RecordingWidgetSnapshotPublisher()
            let model = AppModel(widgetSnapshotPublisher: publisher)
            let plan = DashboardPlan(
                title: "Independent sources",
                metrics: [
                    MetricDefinition(id: "disk.io", valueType: .bytesPerSecond, staleAfterMS: 1_000),
                    MetricDefinition(id: "macmon.cpu", valueType: .ratio, staleAfterMS: 1_000),
                    MetricDefinition(id: "sync", valueType: .compactStatus, staleAfterMS: 1_000),
                ],
                window: testWindow(),
                sections: [
                    SectionPlan(title: "activity", widgets: [
                        WidgetPlan(
                            kind: .plot,
                            label: "io + cpu",
                            history: 60,
                            series: [
                                PlotSeries(metric: "disk.io", format: .bytesPerSecond),
                                PlotSeries(metric: "macmon.cpu", format: .percent),
                            ]
                        ),
                        WidgetPlan(
                            kind: .gauge,
                            label: "cpu duplicate",
                            metric: "macmon.cpu",
                            format: .percent
                        ),
                    ]),
                    SectionPlan(title: "status", widgets: [
                        WidgetPlan(
                            kind: .compactStatus,
                            label: "sync",
                            metric: "sync",
                            format: .compactStatus
                        ),
                    ]),
                    SectionPlan(title: "empty", widgets: []),
                ]
            )
            try model.accept(.plan(plan))
            try model.accept(.update(UpdateMessage(
                sequence: 1,
                timestampMS: 1_000,
                values: [UpdateItem(metric: "sync", error: "unavailable")]
            )))
            #expect(await publisher.publishCount() == 0)

            let firstMetric = ioFirst ? "disk.io" : "macmon.cpu"
            let firstValue: TypedMetricValue = ioFirst ? .bytesPerSecond(2_000) : .ratio(0.4)
            try model.accept(.update(UpdateMessage(
                sequence: 2,
                timestampMS: 2_000,
                values: [UpdateItem(metric: firstMetric, value: firstValue)]
            )))
            #expect(await publisher.publishCount() == 0)

            let secondMetric = ioFirst ? "macmon.cpu" : "disk.io"
            let secondValue: TypedMetricValue = ioFirst ? .ratio(0.4) : .bytesPerSecond(2_000)
            try model.accept(.update(UpdateMessage(
                sequence: 3,
                timestampMS: 3_000,
                values: [UpdateItem(metric: secondMetric, value: secondValue)]
            )))
            try await waitUntil {
                await publisher.publishCount() == 1
            }

            let snapshot = try #require(await publisher.firstSnapshot())
            #expect(snapshot.metrics.first(where: { $0.metricID == "sync" })?.error == "unavailable")
            #expect(snapshot.metrics.first(where: { $0.metricID == "disk.io" })?.timestampMS != nil)
            #expect(snapshot.metrics.first(where: { $0.metricID == "macmon.cpu" })?.timestampMS != nil)
            #expect(snapshot.metrics.filter { $0.metricID == "macmon.cpu" }.count == 1)
        }
    }

    @Test("Forced AppModel publication survives reset and is consumed once")
    @MainActor
    func appModelForceSurvivesReset() async throws {
        let publisher = RecordingWidgetSnapshotPublisher()
        let model = AppModel(widgetSnapshotPublisher: publisher)
        model.forceNextWidgetPublication()
        model.forceNextWidgetPublication()
        model.beginResolution()
        try model.accept(.plan(widgetReadinessPlan(includeCompactStatus: false)))

        try model.accept(.update(unrelatedUpdate(sequence: 1, timestampMS: 1_000)))
        #expect(await publisher.publishCount() == 0)
        try model.accept(.update(systemUpdate(sequence: 2, timestampMS: 2_000)))
        try await waitUntil {
            await publisher.publishCount() == 1
        }
        #expect(await publisher.forceFlags() == [true])

        try model.accept(.update(unrelatedUpdate(sequence: 3, timestampMS: 3_000)))
        try await waitUntil {
            await publisher.publishCount() == 2
        }
        #expect(await publisher.forceFlags() == [true, false])
    }

    @Test("Failed forced publication remains forced until one succeeds")
    @MainActor
    func appModelForceWaitsForSuccess() async throws {
        let publisher = SequencedWidgetSnapshotPublisher(results: [false, true, true])
        let model = AppModel(widgetSnapshotPublisher: publisher)
        model.forceNextWidgetPublication()
        try model.accept(.plan(singleMetricPlan()))

        for sequence in 1 ... 3 {
            try model.accept(.update(UpdateMessage(
                sequence: UInt64(sequence),
                timestampMS: Int64(sequence * 1_000),
                values: [UpdateItem(metric: "cpu.total", value: .ratio(Double(sequence) / 10))]
            )))
            try await waitUntil {
                await publisher.publishCount() == sequence
            }
        }

        #expect(await publisher.forceFlags() == [true, true, false])
    }

    private func snapshot(
        sampledAt: TimeInterval,
        cpu: Double,
        diskFreeBytes: UInt64 = 400,
        light: StatusLight = .green
    ) throws -> WidgetSnapshot {
        try WidgetSnapshot(
            sampledAt: Date(timeIntervalSince1970: sampledAt),
            renderPlan: WidgetRenderPlan(sections: [
                WidgetRenderSection(title: "test", widgets: [
                    WidgetRenderWidget(
                        kind: .plot,
                        label: "activity",
                        history: 10,
                        series: [WidgetRenderSeries(metric: "cpu", format: .percent, accent: "cyan")]
                    ),
                    WidgetRenderWidget(
                        kind: .value,
                        label: "free",
                        metric: "free",
                        format: .bytes
                    ),
                    WidgetRenderWidget(
                        kind: .compactStatus,
                        label: "sync",
                        metric: "sync.summary",
                        format: .compactStatus
                    ),
                ]),
            ]),
            metrics: [
                WidgetRenderMetric(
                    metricID: "cpu",
                    valueType: .ratio,
                    value: .ratio(cpu),
                    error: nil,
                    timestampMS: Int64(sampledAt * 1_000),
                    history: [cpu]
                ),
                WidgetRenderMetric(
                    metricID: "free",
                    valueType: .bytes,
                    value: .bytes(diskFreeBytes),
                    error: nil,
                    timestampMS: Int64(sampledAt * 1_000),
                    history: []
                ),
                WidgetRenderMetric(
                    metricID: "sync.summary",
                    valueType: .compactStatus,
                    value: .compactStatus(CompactStatusMetricValue(
                        leading: "☁️",
                        trailing: "💾",
                        light: light,
                        ageSeconds: 1_080
                    )),
                    error: nil,
                    timestampMS: Int64(sampledAt * 1_000),
                    history: []
                ),
            ]
        )
    }

    private func singleMetricPlan() -> DashboardPlan {
        DashboardPlan(
            title: "Test",
            metrics: [
                MetricDefinition(id: "cpu.total", valueType: .ratio, staleAfterMS: 3_000),
            ],
            window: WindowPlan(
                width: 420,
                anchor: .topRight,
                margin: 20,
                layer: .desktop,
                opacity: 0.94
            ),
            sections: [SectionPlan(title: "cpu", widgets: [
                WidgetPlan(
                    kind: .value,
                    label: "cpu",
                    metric: "cpu.total",
                    format: .percent
                ),
            ])]
        )
    }

    private func widgetReadinessPlan(includeCompactStatus: Bool) -> DashboardPlan {
        var metrics = [
            MetricDefinition(id: "cpu.total", valueType: .ratio, staleAfterMS: 3_000),
            MetricDefinition(id: "memory.ratio", valueType: .ratio, staleAfterMS: 3_000),
            MetricDefinition(id: "disk.root.ratio", valueType: .ratio, staleAfterMS: 3_000),
            MetricDefinition(id: "disk.root.used", valueType: .bytes, staleAfterMS: 3_000),
            MetricDefinition(id: "disk.root.total", valueType: .bytes, staleAfterMS: 3_000),
            MetricDefinition(id: "network.down", valueType: .bytesPerSecond, staleAfterMS: 3_000),
            MetricDefinition(id: "network.up", valueType: .bytesPerSecond, staleAfterMS: 3_000),
            MetricDefinition(id: "logs.systeml.issues", valueType: .count, staleAfterMS: 3_000),
        ]
        if includeCompactStatus {
            metrics.append(MetricDefinition(
                id: "sync.summary",
                valueType: .compactStatus,
                staleAfterMS: 3_000
            ))
        }
        return DashboardPlan(
            title: "Readiness",
            metrics: metrics,
            window: testWindow(),
            sections: [
                SectionPlan(title: "system", widgets: [
                    WidgetPlan(
                        kind: .plot,
                        label: "system",
                        metric: "",
                        format: .number,
                        history: 60,
                        series: [
                            PlotSeries(metric: "cpu.total", format: .percent),
                            PlotSeries(metric: "memory.ratio", format: .percent),
                            PlotSeries(metric: "disk.root.ratio", format: .percent),
                            PlotSeries(metric: "network.down", format: .bytesPerSecond),
                            PlotSeries(metric: "network.up", format: .bytesPerSecond),
                        ]
                    ),
                ]),
            ] + (includeCompactStatus ? [
                SectionPlan(title: "status", widgets: [
                    WidgetPlan(
                        kind: .compactStatus,
                        label: "sync",
                        metric: "sync.summary",
                        format: .compactStatus
                    ),
                ]),
            ] : [])
        )
    }

    private func emptyPlan() -> DashboardPlan {
        DashboardPlan(
            title: "Empty",
            metrics: [
                MetricDefinition(id: "logs.systeml.issues", valueType: .count, staleAfterMS: 3_000),
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

    private func unrelatedUpdate(sequence: UInt64, timestampMS: Int64) -> UpdateMessage {
        UpdateMessage(
            sequence: sequence,
            timestampMS: timestampMS,
            values: [UpdateItem(metric: "logs.systeml.issues", value: .count(4))]
        )
    }

    private func systemUpdate(sequence: UInt64, timestampMS: Int64) -> UpdateMessage {
        UpdateMessage(
            sequence: sequence,
            timestampMS: timestampMS,
            values: [
                UpdateItem(metric: "cpu.total", value: .ratio(0.42)),
                UpdateItem(metric: "memory.ratio", value: .ratio(0.64)),
                UpdateItem(metric: "disk.root.ratio", value: .ratio(0.37)),
                UpdateItem(metric: "disk.root.used", value: .bytes(600)),
                UpdateItem(metric: "disk.root.total", value: .bytes(1_000)),
                UpdateItem(metric: "network.down", value: .bytesPerSecond(2_000)),
                UpdateItem(metric: "network.up", value: .bytesPerSecond(500)),
            ]
        )
    }

    private func compactStatusUpdate(
        sequence: UInt64,
        timestampMS: Int64,
        error: String? = nil
    ) -> UpdateMessage {
        let item = error.map {
            UpdateItem(metric: "sync.summary", error: $0)
        } ?? UpdateItem(
            metric: "sync.summary",
            value: .compactStatus(CompactStatusMetricValue(
                leading: "☁️",
                trailing: "💾",
                light: .green,
                ageSeconds: 18 * 60
            ))
        )
        return UpdateMessage(
            sequence: sequence,
            timestampMS: timestampMS,
            values: [item]
        )
    }
}

private actor ManualWidgetClock: WidgetSnapshotClock {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var currentDate: Date
    private var sleepers: [Sleeper] = []

    init(now: Date) {
        currentDate = now
    }

    func now() async -> Date {
        currentDate
    }

    func sleep(for seconds: TimeInterval) async throws {
        let deadline = currentDate.addingTimeInterval(seconds)
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        }
    }

    func advance(by seconds: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(seconds)
        let ready = sleepers.filter { $0.deadline <= currentDate }
        sleepers.removeAll { $0.deadline <= currentDate }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    func pendingSleeperCount() -> Int {
        sleepers.count
    }
}

private actor RecordingWidgetReloader: WidgetTimelineReloading {
    private var kinds: [String] = []

    func reloadTimelines(ofKind kind: String) async throws {
        kinds.append(kind)
    }

    func reloadCount() -> Int {
        kinds.count
    }
}

private actor AlwaysFailingWidgetPublisher: WidgetSnapshotPublishing {
    private var count = 0

    func publish(
        _ snapshot: WidgetSnapshot,
        force: Bool,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        count += 1
        await reportFailure("Widget snapshot: test failure")
        return false
    }

    func publishCount() -> Int {
        count
    }
}

private actor RecordingWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private var snapshots: [WidgetSnapshot] = []
    private var forces: [Bool] = []

    func publish(
        _ snapshot: WidgetSnapshot,
        force: Bool,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        snapshots.append(snapshot)
        forces.append(force)
        return true
    }

    func publishCount() -> Int {
        snapshots.count
    }

    func firstSnapshot() -> WidgetSnapshot? {
        snapshots.first
    }

    func forceFlags() -> [Bool] {
        forces
    }
}

private actor SequencedWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private var results: [Bool]
    private var forces: [Bool] = []

    init(results: [Bool]) {
        self.results = results
    }

    func publish(
        _ snapshot: WidgetSnapshot,
        force: Bool,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        forces.append(force)
        return results.isEmpty ? true : results.removeFirst()
    }

    func publishCount() -> Int {
        forces.count
    }

    func forceFlags() -> [Bool] {
        forces
    }
}

private actor InMemoryReloadDateStore: WidgetReloadDateStoring {
    private var dates: [String: Date] = [:]

    func date(forKey key: String) async -> Date? {
        dates[key]
    }

    func set(_ date: Date, forKey key: String) async {
        dates[key] = date
    }
}

@MainActor
private final class WidgetFailureRecorder {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

private struct PublisherFixture {
    let rootURL: URL
    let store: WidgetSnapshotStore

    init(blockDirectory: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallstats-publisher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let directoryURL = rootURL.appendingPathComponent("snapshot", isDirectory: true)
        if blockDirectory {
            try Data().write(to: directoryURL)
        }
        store = WidgetSnapshotStore(directoryURL: directoryURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum PublisherTestError: Error {
    case conditionTimedOut
}

private func waitForSleeper(_ clock: ManualWidgetClock) async {
    for _ in 0 ..< 100 {
        if await clock.pendingSleeperCount() > 0 {
            return
        }
        await Task.yield()
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw PublisherTestError.conditionTimedOut
}

private func waitUntil(
    _ condition: @escaping @Sendable () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if try condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw PublisherTestError.conditionTimedOut
}
