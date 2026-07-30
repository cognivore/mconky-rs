import Foundation
import Testing
@testable import Wallstats
@testable import WallstatsCore

@Suite("Configuration file watcher")
struct ConfigFileWatcherTests {
    @Test("Unrelated files and Cargo build output do not reload")
    func unchangedDoesNotReload() async throws {
        let fixture = try ConfigWatcherFixture()
        defer { fixture.remove() }
        try Data("initial".utf8).write(to: fixture.configURL)
        let recorder = ConfigChangeRecorder()
        let watcher = makeWatcher(recorder: recorder)
        defer { watcher.stop() }

        watcher.watch(fixture.configURL)
        try Data("unrelated".utf8).write(
            to: fixture.rootURL.appendingPathComponent("notes.txt")
        )
        let targetURL = fixture.rootURL.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try Data("const GENERATED: u8 = 1;".utf8).write(
            to: targetURL.appendingPathComponent("generated.rs")
        )
        try await Task.sleep(for: .milliseconds(250))

        #expect(recorder.count == 0)
    }

    @Test("Sibling Rust module edits trigger one debounced reload")
    func siblingModuleEdit() async throws {
        let fixture = try ConfigWatcherFixture()
        defer { fixture.remove() }
        try Data("mod component;".utf8).write(to: fixture.configURL)
        let componentURL = fixture.rootURL.appendingPathComponent("component.rs")
        try Data("const VALUE: u8 = 1;".utf8).write(to: componentURL)
        let recorder = ConfigChangeRecorder()
        let watcher = makeWatcher(recorder: recorder)
        defer { watcher.stop() }

        watcher.watch(fixture.configURL)
        try Data("const VALUE: u8 = 2;".utf8).write(to: componentURL)
        try await waitForCount(1, recorder: recorder)

        #expect(recorder.urls == [fixture.configURL.standardizedFileURL])
    }

    @Test("Nested Rust module creation triggers one debounced reload")
    func nestedModuleCreation() async throws {
        let fixture = try ConfigWatcherFixture()
        defer { fixture.remove() }
        try Data("mod components;".utf8).write(to: fixture.configURL)
        let componentsURL = fixture.rootURL.appendingPathComponent("components", isDirectory: true)
        try FileManager.default.createDirectory(at: componentsURL, withIntermediateDirectories: true)
        let recorder = ConfigChangeRecorder()
        let watcher = makeWatcher(recorder: recorder)
        defer { watcher.stop() }

        watcher.watch(fixture.configURL)
        try Data("pub const VALUE: u8 = 1;".utf8).write(
            to: componentsURL.appendingPathComponent("clock.rs")
        )
        try await waitForCount(1, recorder: recorder)

        #expect(recorder.urls == [fixture.configURL.standardizedFileURL])
    }

    @Test("Direct file edits trigger one debounced reload")
    func directEdit() async throws {
        let fixture = try ConfigWatcherFixture()
        defer { fixture.remove() }
        try Data("before".utf8).write(to: fixture.configURL)
        let recorder = ConfigChangeRecorder()
        let watcher = makeWatcher(recorder: recorder)
        defer { watcher.stop() }

        watcher.watch(fixture.configURL)
        try Data("after".utf8).write(to: fixture.configURL)
        try await waitForCount(1, recorder: recorder)
        try await Task.sleep(for: .milliseconds(150))

        #expect(recorder.urls == [fixture.configURL.standardizedFileURL])
    }

    @Test("Atomic editor replacement is detected")
    func atomicReplacement() async throws {
        let fixture = try ConfigWatcherFixture()
        defer { fixture.remove() }
        try Data("before".utf8).write(to: fixture.configURL)
        let recorder = ConfigChangeRecorder()
        let watcher = makeWatcher(recorder: recorder)
        defer { watcher.stop() }

        watcher.watch(fixture.configURL)
        try Data("after atomic replacement".utf8).write(to: fixture.configURL, options: .atomic)
        try await waitForCount(1, recorder: recorder)

        #expect(recorder.count == 1)
    }

    @Test("Rapid writes coalesce into one stable change")
    func debounceCoalesces() async throws {
        let fixture = try ConfigWatcherFixture()
        defer { fixture.remove() }
        try Data("zero".utf8).write(to: fixture.configURL)
        let recorder = ConfigChangeRecorder()
        let watcher = ConfigFileWatcher(
            pollInterval: 0.015,
            debounceInterval: 0.25,
            onChange: { url in recorder.record(url) }
        )
        defer { watcher.stop() }

        watcher.watch(fixture.configURL)
        for content in ["one", "two", "three"] {
            try Data(content.utf8).write(to: fixture.configURL, options: .atomic)
            try await Task.sleep(for: .milliseconds(15))
        }
        try await waitForCount(1, recorder: recorder)
        try await Task.sleep(for: .milliseconds(300))

        #expect(recorder.count == 1)
    }

    private func makeWatcher(recorder: ConfigChangeRecorder) -> ConfigFileWatcher {
        ConfigFileWatcher(
            pollInterval: 0.015,
            debounceInterval: 0.08,
            onChange: { url in
                recorder.record(url)
            }
        )
    }
}

@Suite("Configuration URL routing")
struct ConfigURLRouterTests {
    @Test("The config URL uses the resolved file when it exists")
    func resolvedFile() throws {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let resolved = URL(fileURLWithPath: "/tmp/custom/config.rs")
        let request = try #require(URL(string: "wallstats://config"))

        #expect(ConfigURLRouter.action(
            for: request,
            currentConfigURL: resolved,
            homeDirectory: home,
            fileExists: { $0 == resolved }
        ) == .config(.file(resolved)))
    }

    @Test("A missing pre-resolution config opens the default parent directory")
    func defaultDirectory() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let request = try #require(URL(string: "wallstats://config"))
        let expected = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("wallstats", isDirectory: true)

        #expect(ConfigURLRouter.action(
            for: request,
            currentConfigURL: nil,
            homeDirectory: home,
            fileExists: { _ in false }
        ) == .config(.directory(expected)))
    }

    @Test("Reload and refresh URLs map to invisible actions")
    func reloadAndRefreshActions() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let reload = try #require(URL(string: "wallstats://reload"))
        let refresh = try #require(URL(string: "wallstats://refresh"))

        #expect(ConfigURLRouter.action(
            for: reload,
            currentConfigURL: nil,
            homeDirectory: home,
            fileExists: { _ in false }
        ) == .reload)
        #expect(ConfigURLRouter.action(
            for: refresh,
            currentConfigURL: nil,
            homeDirectory: home,
            fileExists: { _ in false }
        ) == .refresh)
    }

    @Test("Refresh requests use the injected timeline reloader")
    func refreshUsesInjectedReloader() async throws {
        let reloader = ConfigTestTimelineReloader()
        let requester = WidgetTimelineRefreshRequester(reloader: reloader)

        try await requester.refresh()

        #expect(await reloader.kinds == [WidgetSnapshotStore.widgetKind])
    }

    @Test("Unrelated URLs are ignored")
    func rejectsOtherURLs() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        for rawURL in [
            "https://config",
            "wallstats://other",
            "wallstats://config/extra",
            "wallstats://reload/extra",
            "wallstats://refresh/extra",
        ] {
            let url = try #require(URL(string: rawURL))
            #expect(ConfigURLRouter.action(
                for: url,
                currentConfigURL: nil,
                homeDirectory: home,
                fileExists: { _ in false }
            ) == nil)
        }
    }
}

private actor ConfigTestTimelineReloader: WidgetTimelineReloading {
    private(set) var kinds: [String] = []

    func reloadTimelines(ofKind kind: String) async throws {
        kinds.append(kind)
    }
}

private final class ConfigChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.lock()
        let value = recordedURLs
        lock.unlock()
        return value
    }

    var count: Int {
        lock.lock()
        let value = recordedURLs.count
        lock.unlock()
        return value
    }

    func record(_ url: URL) {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }
}

private struct ConfigWatcherFixture {
    let rootURL: URL
    let configURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallstats-config-watcher-\(UUID().uuidString)", isDirectory: true)
        configURL = rootURL.appendingPathComponent("config.rs")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum ConfigWatcherTestError: Error {
    case timedOut
}

private func waitForCount(_ count: Int, recorder: ConfigChangeRecorder) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if recorder.count >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ConfigWatcherTestError.timedOut
}
