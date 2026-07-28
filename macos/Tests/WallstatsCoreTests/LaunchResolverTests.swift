import Foundation
import Testing
@testable import Wallstats

@Suite("Launch resolution")
struct LaunchResolverTests {
    @Test("An explicit environment override wins over the bundled helper")
    func overrideWins() throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let override = try fixture.makeExecutable("override/rust-script")
        let bundled = try fixture.makeExecutable("Wallstats.app/Contents/Helpers/wallstats-rust-script")
        let resolver = LaunchResolver(
            environment: ["WALLSTATS_RUST_SCRIPT": override.path, "PATH": ""],
            homeDirectory: fixture.home,
            currentDirectory: fixture.root,
            bundledRustScriptURL: bundled
        )

        guard case let .found(result) = resolver.resolveRustScript() else {
            Issue.record("Expected explicit rust-script override")
            return
        }
        #expect(result == override.standardizedFileURL)
    }

    @Test("The bundled helper wins over common and inherited PATH candidates")
    func bundledHelperWins() throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let bundled = try fixture.makeExecutable("Wallstats.app/Contents/Helpers/wallstats-rust-script")
        _ = try fixture.makeExecutable("home/.cargo/bin/rust-script")
        let pathCandidate = try fixture.makeExecutable("path/rust-script")
        let resolver = LaunchResolver(
            environment: ["PATH": pathCandidate.deletingLastPathComponent().path],
            homeDirectory: fixture.home,
            currentDirectory: fixture.root,
            bundledRustScriptURL: bundled
        )

        guard case let .found(result) = resolver.resolveRustScript() else {
            Issue.record("Expected bundled rust-script helper")
            return
        }
        #expect(result == bundled.standardizedFileURL)
    }

    @Test("Child PATH supports Finder launches and preserves inherited PATH")
    func childPath() throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let helper = fixture.root.appendingPathComponent("Wallstats.app/Contents/Helpers/wallstats-rust-script")
        let resolver = LaunchResolver(
            environment: ["PATH": "/inherited/bin:/second/bin", "KEEP_ME": "yes"],
            homeDirectory: fixture.home,
            currentDirectory: fixture.root,
            bundledRustScriptURL: helper
        )

        let environment = resolver.childEnvironment(resolvedRustScriptURL: helper)
        let expected = [
            helper.deletingLastPathComponent().path,
            fixture.home.appendingPathComponent(".cargo/bin").path,
            fixture.home.appendingPathComponent(".nix-profile/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/inherited/bin:/second/bin",
        ].joined(separator: ":")
        #expect(environment["PATH"] == expected)
        #expect(environment["KEEP_ME"] == "yes")
    }
}

private final class ResolverFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallstats-resolver-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeExecutable(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
