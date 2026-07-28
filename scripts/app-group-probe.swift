import Darwin
import Foundation

private let appGroupIdentifier = "22GNLKBRMV.com.memorici.wallstats"

private enum ProbeError: LocalizedError {
    case appGroupUnavailable
    case payloadMismatch
    case markerWasNotDeleted

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "FileManager denied the Wallstats App Group container."
        case .payloadMismatch:
            "The App Group marker did not round-trip unchanged."
        case .markerWasNotDeleted:
            "The App Group marker remained after deletion."
        }
    }
}

private func probeAppGroup() throws -> URL {
    let fileManager = FileManager.default
    guard let containerURL = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
        throw ProbeError.appGroupUnavailable
    }

    try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)

    let nonce = UUID().uuidString
    let markerURL = containerURL.appendingPathComponent(
        ".wallstats-app-group-probe-\(nonce).marker",
        isDirectory: false
    )
    let payload = Data("wallstats-app-group-probe:\(nonce)".utf8)
    defer {
        try? fileManager.removeItem(at: markerURL)
    }

    try payload.write(to: markerURL, options: .atomic)
    let readPayload = try Data(contentsOf: markerURL)
    guard readPayload == payload else {
        throw ProbeError.payloadMismatch
    }

    try fileManager.removeItem(at: markerURL)
    guard !fileManager.fileExists(atPath: markerURL.path) else {
        throw ProbeError.markerWasNotDeleted
    }

    return containerURL.standardizedFileURL
}

do {
    print(try probeAppGroup().path)
} catch {
    FileHandle.standardError.write(Data("wallstats-app-group-probe: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
