import Combine
import Foundation
import WallstatsCore

enum ConnectionPhase: String, Equatable {
    case idle = "Idle"
    case resolving = "Resolving configuration"
    case starting = "Starting collector"
    case waitingForPlan = "Waiting for plan"
    case running = "Live"
    case reloading = "Reloading"
    case failed = "Attention required"
}

enum DiagnosticLevel: String, Equatable {
    case info
    case warning
    case error
}

struct DiagnosticLine: Identifiable, Equatable {
    let id: UInt64
    let level: DiagnosticLevel
    let message: String
}

struct AppWindowPresentation: Equatable {
    let width: Double
    let anchor: WindowAnchor
    let margin: Double
    let layer: WindowLayer
    let opacity: Double
    let clickThrough: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var statusDetail = "Looking for a Wallstats configuration."
    @Published private(set) var sdkVersion: String?
    @Published private(set) var plan: DashboardPlan?
    @Published private(set) var dashboard: DashboardState?
    @Published private(set) var fatalMessage: String?
    @Published private(set) var diagnostics: [DiagnosticLine] = []
    @Published private(set) var configURL: URL?
    @Published private(set) var lastHeartbeatMS: Int64?
    @Published var clickThrough = true
    @Published var layerOverride: WindowLayer?

    private var nextDiagnosticID: UInt64 = 0
    private var diagnosticCharacterCount = 0
    private let maximumDiagnosticLines = 200
    private let maximumDiagnosticCharacters = 65_536
    private let widgetSnapshotPublisher: (any WidgetSnapshotPublishing)?
    private var widgetDiagnosticID: UInt64?
    private var widgetPublicationTask: Task<Void, Never>?
    private var submittedInitialWidgetSnapshot = false
    private var forceNextWidgetSnapshot = false
    private var forcedWidgetPublicationInFlight = false
    private var forceRequestedDuringPublication = false

    init(widgetSnapshotPublisher: (any WidgetSnapshotPublishing)? = nil) {
        self.widgetSnapshotPublisher = widgetSnapshotPublisher
    }

    var windowPresentation: AppWindowPresentation {
        let window = plan?.window ?? WindowPlan(
            width: 420,
            anchor: .topRight,
            margin: 20,
            layer: .desktop,
            opacity: 0.94
        )
        return AppWindowPresentation(
            width: window.width,
            anchor: window.anchor,
            margin: window.margin,
            layer: layerOverride ?? window.layer,
            opacity: window.opacity,
            clickThrough: clickThrough
        )
    }

    func beginResolution() {
        phase = .resolving
        statusDetail = "Resolving rust-script and the configuration path."
        fatalMessage = nil
        sdkVersion = nil
        plan = nil
        dashboard = nil
        lastHeartbeatMS = nil
        submittedInitialWidgetSnapshot = false
    }

    func setConfigURL(_ configURL: URL?) {
        self.configURL = configURL
    }

    func beginLaunch(configURL: URL) {
        self.configURL = configURL
        phase = .starting
        statusDetail = "Launching \(configURL.lastPathComponent)."
        fatalMessage = nil
        sdkVersion = nil
        plan = nil
        dashboard = nil
        lastHeartbeatMS = nil
        submittedInitialWidgetSnapshot = false
    }

    func collectorDidLaunch() {
        phase = .waitingForPlan
        statusDetail = "Collector started; waiting for protocol hello and plan."
    }

    func beginReload() {
        phase = .reloading
        statusDetail = "Stopping the current collector before reloading."
    }

    func forceNextWidgetPublication() {
        if forcedWidgetPublicationInFlight {
            forceRequestedDuringPublication = true
        } else {
            forceNextWidgetSnapshot = true
        }
    }

    func accept(_ event: ProtocolSessionEvent) throws {
        switch event {
        case let .hello(hello):
            sdkVersion = hello.sdkVersion
            phase = .waitingForPlan
            statusDetail = "Protocol v\(hello.protocolMajor).\(hello.protocolMinor), SDK \(hello.sdkVersion)."

        case let .plan(plan):
            self.plan = plan
            dashboard = try DashboardState(plan: plan)
            submittedInitialWidgetSnapshot = false
            phase = .running
            statusDetail = "Receiving metrics from \(configURL?.lastPathComponent ?? "collector")."

        case let .update(update):
            guard var dashboard else {
                throw ProtocolValidationError.unexpectedRecord(expected: "plan", received: "update")
            }
            try dashboard.apply(update)
            self.dashboard = dashboard
            phase = .running
            if submittedInitialWidgetSnapshot {
                _ = publishWidgetSnapshot(dashboard, timestampMS: update.timestampMS)
            } else if isReadyForInitialWidgetSnapshot(dashboard),
                      publishWidgetSnapshot(dashboard, timestampMS: update.timestampMS)
            {
                submittedInitialWidgetSnapshot = true
            }

        case let .heartbeat(heartbeat):
            lastHeartbeatMS = heartbeat.timestampMS
            phase = .running

        case let .fatal(fatal):
            fatalMessage = fatal.message
            phase = .failed
            statusDetail = fatal.message
            appendDiagnostic(level: .error, message: "Collector fatal: \(fatal.message)")
        }
    }

    func fail(_ message: String) {
        phase = .failed
        statusDetail = message
        appendDiagnostic(level: .error, message: message)
    }

    func collectorExited(status: Int32, signaled: Bool) {
        guard phase != .failed else { return }
        let reason = signaled ? "after receiving a signal" : "with status \(status)"
        fail("Collector exited \(reason). Choose Reload Configuration after correcting the issue.")
    }

    func appendDiagnostic(level: DiagnosticLevel, message: String) {
        for rawLine in message.split(omittingEmptySubsequences: true, whereSeparator: \Character.isNewline) {
            let line = String(rawLine.prefix(2_048))
            guard !line.isEmpty else { continue }

            nextDiagnosticID &+= 1
            diagnostics.append(DiagnosticLine(id: nextDiagnosticID, level: level, message: line))
            diagnosticCharacterCount += line.count
        }

        trimDiagnostics()
    }

    func toggleLayer() {
        layerOverride = windowPresentation.layer == .desktop ? .floating : .desktop
    }

    private func isReadyForInitialWidgetSnapshot(_ dashboard: DashboardState) -> Bool {
        let references = Set(dashboard.plan.sections.flatMap { section in
            section.widgets.flatMap { widget in
                widget.kind == .plot ? widget.series.map(\.metric) : [widget.metric]
            }.filter { !$0.isEmpty }
        })
        guard !references.isEmpty else { return false }
        return references.allSatisfy { hasReported($0, in: dashboard) }
    }

    private func hasReported(_ metric: String, in dashboard: DashboardState) -> Bool {
        guard let snapshot = dashboard.metrics[metric], snapshot.timestampMS != nil else {
            return false
        }
        return snapshot.value != nil || snapshot.error != nil
    }

    @discardableResult
    private func publishWidgetSnapshot(_ dashboard: DashboardState, timestampMS: Int64) -> Bool {
        guard let widgetSnapshotPublisher else { return false }

        let snapshot: WidgetSnapshot
        do {
            snapshot = try WidgetSnapshot(
                dashboard: dashboard,
                sampledAt: Date(timeIntervalSince1970: Double(timestampMS) / 1_000)
            )
        } catch {
            reportWidgetSnapshotFailure("Widget snapshot: \(error.localizedDescription)")
            return false
        }

        let previousPublication = widgetPublicationTask
        widgetPublicationTask = Task { [weak self, widgetSnapshotPublisher] in
            if let previousPublication {
                await previousPublication.value
            }
            guard let self else { return }
            let force = reserveForcedWidgetPublication()
            let succeeded = await widgetSnapshotPublisher.publish(
                snapshot,
                force: force
            ) { [weak self] message in
                self?.reportWidgetSnapshotFailure(message)
            }
            if force {
                completeForcedWidgetPublication(succeeded: succeeded)
            }
        }
        return true
    }

    private func reserveForcedWidgetPublication() -> Bool {
        guard forceNextWidgetSnapshot, !forcedWidgetPublicationInFlight else { return false }
        forcedWidgetPublicationInFlight = true
        return true
    }

    private func completeForcedWidgetPublication(succeeded: Bool) {
        forcedWidgetPublicationInFlight = false
        if succeeded, !forceRequestedDuringPublication {
            forceNextWidgetSnapshot = false
        } else {
            forceNextWidgetSnapshot = true
        }
        forceRequestedDuringPublication = false
    }

    private func reportWidgetSnapshotFailure(_ message: String) {
        let line = String(message.prefix(2_048))
        guard !line.isEmpty else { return }

        if let widgetDiagnosticID,
           let index = diagnostics.firstIndex(where: { $0.id == widgetDiagnosticID })
        {
            guard diagnostics[index].message != line else { return }
            diagnosticCharacterCount -= diagnostics[index].message.count
            diagnostics[index] = DiagnosticLine(
                id: widgetDiagnosticID,
                level: .warning,
                message: line
            )
            diagnosticCharacterCount += line.count
        } else {
            nextDiagnosticID &+= 1
            widgetDiagnosticID = nextDiagnosticID
            diagnostics.append(DiagnosticLine(id: nextDiagnosticID, level: .warning, message: line))
            diagnosticCharacterCount += line.count
        }
        trimDiagnostics()
    }

    private func trimDiagnostics() {
        while diagnostics.count > maximumDiagnosticLines
            || diagnosticCharacterCount > maximumDiagnosticCharacters
        {
            guard !diagnostics.isEmpty else { break }
            diagnosticCharacterCount -= diagnostics.removeFirst().message.count
        }
    }
}
