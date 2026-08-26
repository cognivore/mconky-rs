import AppKit
import Combine
import Foundation
import WallstatsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let timelineRefreshRequester: WidgetTimelineRefreshRequester
    private var supervisor: CollectorSupervisor?
    private var configWatcher: ConfigFileWatcher?
    private var configURLCancellable: AnyCancellable?
    private var planCancellable: AnyCancellable?
    private var desktopPanelControllers: [DashboardPanelController] = []
    private var awaitingTerminationReply = false

    override init() {
        model = AppModel(widgetSnapshotPublisher: WidgetSnapshotPublisher())
        timelineRefreshRequester = WidgetTimelineRefreshRequester(
            reloader: SystemWidgetTimelineReloader()
        )
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(arguments: CommandLine.arguments)
        let bundledConfigURL = Bundle.main.url(
            forResource: "config",
            withExtension: "rs",
            subdirectory: "WallstatsDefaults"
        ) ?? Bundle.main.url(forResource: "config", withExtension: "rs")
        let bundledRustScriptURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("wallstats-rust-script", isDirectory: false)
        let supervisor = CollectorSupervisor(
            model: model,
            options: options,
            resolver: LaunchResolver(bundledRustScriptURL: bundledRustScriptURL),
            bundledConfigURL: bundledConfigURL
        )
        self.supervisor = supervisor

        let watcher = ConfigFileWatcher { [weak supervisor] _ in
            Task { @MainActor [weak supervisor] in
                supervisor?.requestReload()
            }
        }
        configWatcher = watcher
        configURLCancellable = model.$configURL
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak watcher] url in
                watcher?.watch(url)
            }
        planCancellable = model.$plan.sink { [weak self] plan in
            self?.updateDesktopSurfaces(plan)
        }
        supervisor.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        configWatcher?.stop()
        supervisor?.terminateImmediatelyIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !awaitingTerminationReply else { return .terminateLater }
        configWatcher?.stop()
        guard let supervisor else { return .terminateNow }

        let delayed = supervisor.prepareForApplicationTermination { [weak self] in
            self?.awaitingTerminationReply = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        if delayed {
            awaitingTerminationReply = true
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func handle(_ url: URL) {
        let fileManager = FileManager.default
        guard let action = ConfigURLRouter.action(
            for: url,
            currentConfigURL: model.configURL,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        ) else {
            return
        }

        switch action {
        case let .config(target):
            openConfig(target, fileManager: fileManager)
        case .reload:
            model.forceNextWidgetPublication()
            supervisor?.requestReload()
        case .refresh:
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await timelineRefreshRequester.refresh()
                } catch {
                    model.appendDiagnostic(
                        level: .warning,
                        message: "Could not refresh the Wallstats widget: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func openConfig(_ target: ConfigOpenTarget, fileManager: FileManager) {
        do {
            let targetURL: URL
            switch target {
            case let .file(url):
                targetURL = url
            case let .directory(url):
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                targetURL = url
            }
            guard NSWorkspace.shared.open(targetURL) else {
                throw ConfigOpenError.workspaceRejected(targetURL)
            }
        } catch {
            model.appendDiagnostic(
                level: .error,
                message: "Could not open the Wallstats configuration: \(error.localizedDescription)"
            )
        }
    }

    // Panels are matched to desktop surfaces by position in the plan, so a
    // reload reuses existing panels instead of flickering through teardown.
    private func updateDesktopSurfaces(_ plan: DashboardPlan?) {
        let surfaces = plan?.surfaces.filter { $0.kind == .desktop } ?? []
        while desktopPanelControllers.count > surfaces.count {
            desktopPanelControllers.removeLast().hide()
        }
        for (index, surface) in surfaces.enumerated() {
            if index < desktopPanelControllers.count {
                desktopPanelControllers[index].update(surface: surface)
            } else {
                desktopPanelControllers.append(
                    DashboardPanelController(model: model, surface: surface)
                )
            }
        }
    }
}

private enum ConfigOpenError: Error, LocalizedError {
    case workspaceRejected(URL)

    var errorDescription: String? {
        switch self {
        case let .workspaceRejected(url):
            "The default application could not open \(url.path)."
        }
    }
}
