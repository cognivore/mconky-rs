import CryptoKit
import Foundation
import WallstatsCore

protocol DashboardHistoryStoring {
    func read(configURL: URL) throws -> DashboardHistoryArchive?
    func write(_ archive: DashboardHistoryArchive, configURL: URL) throws
}

struct DashboardHistoryStore: DashboardHistoryStoring {
    static let maximumBytes = 4 * 1_024 * 1_024
    let directoryURL: URL

    init(directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/wallstats/history", isDirectory: true))
    {
        self.directoryURL = directoryURL
    }

    func read(configURL: URL) throws -> DashboardHistoryArchive? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archiveURL(configURL))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw HistoryArchiveError.tooLarge }
        let archive = try JSONDecoder().decode(DashboardHistoryArchive.self, from: data)
        try archive.validate()
        return archive
    }

    func write(_ archive: DashboardHistoryArchive, configURL: URL) throws {
        try archive.validate()
        let data = try JSONEncoder().encode(archive)
        guard data.count <= Self.maximumBytes else { throw HistoryArchiveError.tooLarge }
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = archiveURL(configURL)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func archiveURL(_ configURL: URL) -> URL {
        let key = SHA256.hash(data: Data(configURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(key).json")
    }
}
