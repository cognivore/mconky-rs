import Foundation

public enum WidgetSnapshotStoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case snapshotTooLarge
    case readFailed
    case invalidSnapshot
    case writeFailed
}

extension WidgetSnapshotStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Wallstats App Group is unavailable."
        case .snapshotTooLarge:
            "Widget snapshot exceeds the size limit."
        case .readFailed:
            "Widget snapshot could not be read."
        case .invalidSnapshot:
            "Widget snapshot is invalid."
        case .writeFailed:
            "Widget snapshot could not be written."
        }
    }
}

public struct WidgetSnapshotStore: Sendable {
    public static let appGroupIdentifier = "22GNLKBRMV.com.memorici.wallstats"
    public static let filename = "widget-snapshot-v1.plist"
    public static let widgetKind = "WallstatsWidget"
    public static let maximumFileSize = 65_536

    public let directoryURL: URL

    public init(fileManager: FileManager = .default) throws {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw WidgetSnapshotStoreError.appGroupUnavailable
        }
        directoryURL = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Wallstats", isDirectory: true)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.filename, isDirectory: false)
    }

    public func read() throws -> WidgetSnapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw WidgetSnapshotStoreError.readFailed
        }

        var data = Data()
        do {
            while data.count <= Self.maximumFileSize {
                let remaining = Self.maximumFileSize + 1 - data.count
                guard remaining > 0 else { break }
                guard let chunk = try handle.read(upToCount: min(8_192, remaining)),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw WidgetSnapshotStoreError.readFailed
        }

        guard data.count <= Self.maximumFileSize else {
            throw WidgetSnapshotStoreError.snapshotTooLarge
        }
        do {
            return try PropertyListDecoder().decode(WidgetSnapshot.self, from: data)
        } catch {
            throw WidgetSnapshotStoreError.invalidSnapshot
        }
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw WidgetSnapshotStoreError.writeFailed
        }
        guard data.count <= Self.maximumFileSize else {
            throw WidgetSnapshotStoreError.snapshotTooLarge
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw WidgetSnapshotStoreError.writeFailed
        }
    }
}
