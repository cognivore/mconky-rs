import Foundation

enum ConfigOpenTarget: Equatable {
    case file(URL)
    case directory(URL)
}

enum WallstatsURLAction: Equatable {
    case config(ConfigOpenTarget)
    case reload
    case refresh
}

enum ConfigURLRouter {
    static func defaultConfigURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("wallstats", isDirectory: true)
            .appendingPathComponent("config.rs", isDirectory: false)
    }

    static func action(
        for url: URL,
        currentConfigURL: URL?,
        homeDirectory: URL,
        fileExists: (URL) -> Bool
    ) -> WallstatsURLAction? {
        guard url.scheme?.lowercased() == "wallstats",
              url.path.isEmpty || url.path == "/"
        else {
            return nil
        }

        switch url.host?.lowercased() {
        case "config":
            let configURL = currentConfigURL ?? defaultConfigURL(homeDirectory: homeDirectory)
            if fileExists(configURL) {
                return .config(.file(configURL))
            }
            return .config(.directory(configURL.deletingLastPathComponent()))
        case "reload":
            return .reload
        case "refresh":
            return .refresh
        default:
            return nil
        }
    }
}
