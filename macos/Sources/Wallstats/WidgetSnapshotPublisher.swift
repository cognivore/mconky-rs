import Foundation
import WidgetKit
import WallstatsCore

protocol WidgetSnapshotPublishing: Sendable {
    @discardableResult
    func publish(
        _ snapshot: WidgetSnapshot,
        force: Bool,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool
}

extension WidgetSnapshotPublishing {
    @discardableResult
    func publish(
        _ snapshot: WidgetSnapshot,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        await publish(snapshot, force: false, reportFailure: reportFailure)
    }
}

protocol WidgetSnapshotClock: Sendable {
    func now() async -> Date
    func sleep(for seconds: TimeInterval) async throws
}

protocol WidgetTimelineReloading: Sendable {
    func reloadTimelines(ofKind kind: String) async throws
}

protocol WidgetReloadDateStoring: Sendable {
    func date(forKey key: String) async -> Date?
    func set(_ date: Date, forKey key: String) async
}

struct SystemWidgetSnapshotClock: WidgetSnapshotClock {
    func now() async -> Date { Date() }

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(seconds, 0)))
    }
}

struct SystemWidgetTimelineReloader: WidgetTimelineReloading {
    func reloadTimelines(ofKind kind: String) async throws {
        await MainActor.run {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}

struct WidgetTimelineRefreshRequester: Sendable {
    let reloader: any WidgetTimelineReloading

    func refresh() async throws {
        try await reloader.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
    }
}

actor UserDefaultsWidgetReloadDateStore: WidgetReloadDateStoring {
    private let defaults: UserDefaults?

    init(suiteName: String) {
        defaults = UserDefaults(suiteName: suiteName)
    }

    func date(forKey key: String) async -> Date? {
        defaults?.object(forKey: key) as? Date
    }

    func set(_ date: Date, forKey key: String) async {
        defaults?.set(date, forKey: key)
    }
}

actor WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private static let minimumWriteInterval: TimeInterval = 60
    private static let minimumReloadInterval: TimeInterval = 30 * 60
    private static let lastReloadDefaultsKey = "widget-last-reload-v1"

    private struct PendingSnapshot: Sendable {
        let snapshot: WidgetSnapshot
        let force: Bool
        let reportFailure: @MainActor @Sendable (String) -> Void
    }

    private let store: WidgetSnapshotStore?
    private let storeInitializationError: WidgetSnapshotStoreError?
    private let clock: any WidgetSnapshotClock
    private let reloader: any WidgetTimelineReloading
    private let reloadDateStore: (any WidgetReloadDateStoring)?

    private var pending: PendingSnapshot?
    private var scheduledWrite: Task<Void, Never>?
    private var lastWriteAttemptAt: Date?
    private var lastWrittenSnapshot: WidgetSnapshot?
    private var didLoadStoredSnapshot = false
    private var didLoadReloadDate = false
    private var lastReloadAt: Date?
    private var reloadNeeded = false
    private var lastReportedFailure: String?

    init() {
        do {
            store = try WidgetSnapshotStore()
            storeInitializationError = nil
        } catch let error as WidgetSnapshotStoreError {
            store = nil
            storeInitializationError = error
        } catch {
            store = nil
            storeInitializationError = .appGroupUnavailable
        }
        clock = SystemWidgetSnapshotClock()
        reloader = SystemWidgetTimelineReloader()
        reloadDateStore = UserDefaultsWidgetReloadDateStore(
            suiteName: WidgetSnapshotStore.appGroupIdentifier
        )
    }

    init(
        store: WidgetSnapshotStore,
        clock: any WidgetSnapshotClock = SystemWidgetSnapshotClock(),
        reloader: any WidgetTimelineReloading = SystemWidgetTimelineReloader(),
        reloadDateStore: (any WidgetReloadDateStoring)? = nil
    ) {
        self.store = store
        storeInitializationError = nil
        self.clock = clock
        self.reloader = reloader
        self.reloadDateStore = reloadDateStore
    }

    deinit {
        scheduledWrite?.cancel()
    }

    @discardableResult
    func publish(
        _ snapshot: WidgetSnapshot,
        force: Bool = false,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let now = await clock.now()
        pending = PendingSnapshot(
            snapshot: snapshot,
            force: force,
            reportFailure: reportFailure
        )

        if force {
            scheduledWrite?.cancel()
            scheduledWrite = nil
            return await flushPending(at: now)
        }
        guard let lastWriteAttemptAt else {
            return await flushPending(at: now)
        }

        let elapsed = now.timeIntervalSince(lastWriteAttemptAt)
        if elapsed >= Self.minimumWriteInterval {
            scheduledWrite?.cancel()
            scheduledWrite = nil
            return await flushPending(at: now)
        } else {
            scheduleWrite(after: elapsed < 0 ? Self.minimumWriteInterval : Self.minimumWriteInterval - elapsed)
            return true
        }
    }

    private func scheduleWrite(after seconds: TimeInterval) {
        guard scheduledWrite == nil else { return }
        let clock = clock
        scheduledWrite = Task { [weak self] in
            do {
                try await clock.sleep(for: seconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.scheduledWriteDidFire()
        }
    }

    private func scheduledWriteDidFire() async {
        scheduledWrite = nil
        guard pending != nil else { return }

        let now = await clock.now()
        if let lastWriteAttemptAt {
            let elapsed = now.timeIntervalSince(lastWriteAttemptAt)
            if elapsed < Self.minimumWriteInterval {
                scheduleWrite(
                    after: elapsed < 0 ? Self.minimumWriteInterval : Self.minimumWriteInterval - elapsed
                )
                return
            }
        }
        _ = await flushPending(at: now)
    }

    private func flushPending(at now: Date) async -> Bool {
        guard let pending else { return true }
        self.pending = nil
        lastWriteAttemptAt = now

        guard let store else {
            await report(
                "Widget snapshot: \((storeInitializationError ?? .appGroupUnavailable).localizedDescription)",
                using: pending.reportFailure
            )
            return false
        }

        if !didLoadStoredSnapshot {
            didLoadStoredSnapshot = true
            do {
                lastWrittenSnapshot = try store.read()
            } catch {
                await report(
                    "Widget snapshot: \(error.localizedDescription)",
                    using: pending.reportFailure
                )
            }
        }

        let changed = lastWrittenSnapshot.map {
            !$0.hasSameWidgetData(as: pending.snapshot)
        } ?? true

        do {
            try store.write(pending.snapshot)
            lastWrittenSnapshot = pending.snapshot
        } catch {
            await report(
                "Widget snapshot: \(error.localizedDescription)",
                using: pending.reportFailure
            )
            return false
        }

        if changed || pending.force {
            reloadNeeded = true
        }
        return await reloadIfNeeded(
            at: now,
            force: pending.force,
            reportFailure: pending.reportFailure
        )
    }

    private func reloadIfNeeded(
        at now: Date,
        force: Bool,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        guard reloadNeeded || force else { return true }
        if !didLoadReloadDate {
            didLoadReloadDate = true
            lastReloadAt = await reloadDateStore?.date(forKey: Self.lastReloadDefaultsKey)
        }
        if !force, let lastReloadAt {
            let elapsed = now.timeIntervalSince(lastReloadAt)
            guard elapsed >= Self.minimumReloadInterval else { return true }
        }

        do {
            try await reloader.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
            lastReloadAt = now
            reloadNeeded = false
            if let reloadDateStore {
                await reloadDateStore.set(now, forKey: Self.lastReloadDefaultsKey)
            }
            return true
        } catch {
            await report(
                "Widget timeline: \(error.localizedDescription)",
                using: reportFailure
            )
            return false
        }
    }

    private func report(
        _ message: String,
        using reporter: @escaping @MainActor @Sendable (String) -> Void
    ) async {
        guard message != lastReportedFailure else { return }
        lastReportedFailure = message
        await reporter(message)
    }
}

private extension WidgetSnapshot {
    func hasSameWidgetData(as other: WidgetSnapshot) -> Bool {
        schemaVersion == other.schemaVersion
            && renderPlan == other.renderPlan
            && metrics.count == other.metrics.count
            && zip(metrics, other.metrics).allSatisfy { left, right in
                left.metricID == right.metricID
                    && left.valueType == right.valueType
                    && left.value == right.value
                    && left.error == right.error
                    && left.history == right.history
            }
    }
}
