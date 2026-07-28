import Foundation

struct LaunchOptions {
    let configPath: String?
    let error: String?

    static func parse(arguments: [String]) -> LaunchOptions {
        var configPath: String?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--config" {
                guard index + 1 < arguments.count else {
                    return LaunchOptions(configPath: nil, error: "--config requires a path.")
                }
                guard configPath == nil else {
                    return LaunchOptions(configPath: nil, error: "Specify the configuration path only once.")
                }
                configPath = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--config=") {
                guard configPath == nil else {
                    return LaunchOptions(configPath: nil, error: "Specify the configuration path only once.")
                }
                let value = String(argument.dropFirst("--config=".count))
                guard !value.isEmpty else {
                    return LaunchOptions(configPath: nil, error: "--config requires a path.")
                }
                configPath = value
                index += 1
            } else if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    index += 2
                } else {
                    index += 1
                }
            } else if argument.hasPrefix("-") {
                return LaunchOptions(configPath: nil, error: "Unknown option '\(argument)'.")
            } else {
                guard configPath == nil else {
                    return LaunchOptions(configPath: nil, error: "Specify the configuration path only once.")
                }
                configPath = argument
                index += 1
            }
        }

        return LaunchOptions(configPath: configPath, error: nil)
    }
}

enum PathResolution {
    case found(URL)
    case missing(message: String, candidate: URL?)
}

struct LaunchResolver {
    let environment: [String: String]
    let homeDirectory: URL
    let currentDirectory: URL
    let bundledRustScriptURL: URL?
    let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundledRustScriptURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.currentDirectory = currentDirectory
        self.bundledRustScriptURL = bundledRustScriptURL
        self.fileManager = fileManager
    }

    func resolveConfig(cliPath: String?, bundledDefault: URL?) -> PathResolution {
        if let cliPath {
            return resolveExplicitConfig(cliPath, source: "command-line configuration")
        }
        if let environmentPath = environment["WALLSTATS_CONFIG"], !environmentPath.isEmpty {
            return resolveExplicitConfig(environmentPath, source: "WALLSTATS_CONFIG")
        }

        let standardURL = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("wallstats", isDirectory: true)
            .appendingPathComponent("config.rs", isDirectory: false)
        if isReadableFile(standardURL) {
            return .found(standardURL)
        }
        if let bundledDefault, isReadableFile(bundledDefault) {
            return .found(bundledDefault)
        }

        return .missing(
            message: "No configuration found at \(standardURL.path). Create it, set WALLSTATS_CONFIG, or pass --config /path/to/config.rs.",
            candidate: standardURL
        )
    }

    func resolveRustScript() -> PathResolution {
        if let override = environment["WALLSTATS_RUST_SCRIPT"], !override.isEmpty {
            if override.contains("/") {
                let url = expandedURL(for: override)
                guard isExecutableFile(url) else {
                    return .missing(
                        message: "WALLSTATS_RUST_SCRIPT points to a missing or non-executable file: \(url.path)",
                        candidate: url
                    )
                }
                return .found(url)
            }
            if let url = executableOnPath(named: override) {
                return .found(url)
            }
            return .missing(
                message: "WALLSTATS_RUST_SCRIPT names '\(override)', but it was not found on PATH.",
                candidate: nil
            )
        }

        if let bundledRustScriptURL, isExecutableFile(bundledRustScriptURL) {
            return .found(bundledRustScriptURL.standardizedFileURL)
        }

        let commonURLs = [
            homeDirectory.appendingPathComponent(".nix-profile/bin/rust-script"),
            homeDirectory.appendingPathComponent(".cargo/bin/rust-script"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rust-script"),
            URL(fileURLWithPath: "/usr/local/bin/rust-script"),
        ]
        if let url = commonURLs.first(where: isExecutableFile) {
            return .found(url)
        }
        if let url = executableOnPath(named: "rust-script") {
            return .found(url)
        }

        return .missing(
            message: "rust-script was not found. Install it or set WALLSTATS_RUST_SCRIPT to its executable path.",
            candidate: nil
        )
    }

    func childEnvironment(resolvedRustScriptURL: URL) -> [String: String] {
        var childEnvironment = environment
        var pathEntries = [
            resolvedRustScriptURL.deletingLastPathComponent().path,
            homeDirectory.appendingPathComponent(".cargo/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".nix-profile/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        if let inheritedPath = environment["PATH"], !inheritedPath.isEmpty {
            pathEntries.append(inheritedPath)
        }
        childEnvironment["PATH"] = pathEntries.joined(separator: ":")
        return childEnvironment
    }

    private func resolveExplicitConfig(_ path: String, source: String) -> PathResolution {
        let url = expandedURL(for: path)
        guard isReadableFile(url) else {
            return .missing(
                message: "The \(source) file is missing or unreadable: \(url.path)",
                candidate: url
            )
        }
        return .found(url)
    }

    private func expandedURL(for path: String) -> URL {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }

        let url = URL(fileURLWithPath: expanded, relativeTo: currentDirectory)
        return url.standardizedFileURL
    }

    private func executableOnPath(named name: String) -> URL? {
        guard !name.contains("/") else { return nil }
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? currentDirectory : URL(fileURLWithPath: String(directory))
            let candidate = base.appendingPathComponent(name)
            if isExecutableFile(candidate) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private func isReadableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.path)
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }
}
