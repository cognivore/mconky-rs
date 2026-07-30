import Foundation

final class ConfigFileWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable (URL) -> Void

    private struct Fingerprint: Equatable {
        struct ContentIdentity: Equatable {
            let path: String
            let exists: Bool
            let size: UInt64?
            let hash: UInt64?
        }

        struct FileIdentity: Equatable {
            let content: ContentIdentity
            let modificationDate: Date?
            let fileNumber: UInt64?
        }

        let files: [FileIdentity]

        var content: [ContentIdentity] {
            files.map(\.content)
        }

        static func read(_ configURL: URL, fileManager: FileManager = .default) -> Fingerprint {
            let configURL = configURL.standardizedFileURL
            var urls = rustSourceURLs(beside: configURL, fileManager: fileManager)
            if !urls.contains(configURL) {
                urls.append(configURL)
            }
            urls.sort { $0.path < $1.path }

            return Fingerprint(files: urls.map { readFile($0, fileManager: fileManager) })
        }

        private static func readFile(
            _ url: URL,
            fileManager: FileManager
        ) -> FileIdentity {
            guard fileManager.fileExists(atPath: url.path) else {
                return FileIdentity(
                    content: ContentIdentity(
                        path: url.path,
                        exists: false,
                        size: nil,
                        hash: nil
                    ),
                    modificationDate: nil,
                    fileNumber: nil
                )
            }

            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            return FileIdentity(
                content: ContentIdentity(
                    path: url.path,
                    exists: true,
                    size: (attributes?[.size] as? NSNumber)?.uint64Value,
                    hash: data.map(stableHash)
                ),
                modificationDate: attributes?[.modificationDate] as? Date,
                fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            )
        }

        private static func rustSourceURLs(
            beside configURL: URL,
            fileManager: FileManager
        ) -> [URL] {
            let directoryURL = configURL.deletingLastPathComponent()
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL else {
                    return nil
                }
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey]
                )
                if values?.isDirectory == true {
                    if url.lastPathComponent == "target" {
                        enumerator.skipDescendants()
                    }
                    return nil
                }
                guard
                      url.pathExtension == "rs",
                      values?.isRegularFile == true
                else {
                    return nil
                }
                return url.standardizedFileURL
            }
        }

        private static func stableHash(_ data: Data) -> UInt64 {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }

    private let queue = DispatchQueue(label: "com.memorici.wallstats.config-watcher", qos: .utility)
    private let pollMilliseconds: Int
    private let debounceMilliseconds: Int
    private let onChange: ChangeHandler

    private var watchedURL: URL?
    private var timer: DispatchSourceTimer?
    private var pendingDelivery: DispatchWorkItem?
    private var observedFingerprint: Fingerprint?
    private var deliveredFingerprint: Fingerprint?

    init(
        pollInterval: TimeInterval = 0.2,
        debounceInterval: TimeInterval = 0.4,
        onChange: @escaping ChangeHandler
    ) {
        precondition(pollInterval > 0)
        precondition(debounceInterval > 0)
        pollMilliseconds = max(1, Int((pollInterval * 1_000).rounded()))
        debounceMilliseconds = max(1, Int((debounceInterval * 1_000).rounded()))
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func watch(_ url: URL) {
        queue.sync {
            stopLocked()
            watchedURL = url.standardizedFileURL
            let fingerprint = Fingerprint.read(url)
            observedFingerprint = fingerprint
            deliveredFingerprint = fingerprint

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + .milliseconds(pollMilliseconds),
                repeating: .milliseconds(pollMilliseconds)
            )
            timer.setEventHandler { [weak self] in
                self?.pollLocked()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func stopLocked() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        watchedURL = nil
        observedFingerprint = nil
        deliveredFingerprint = nil
    }

    private func pollLocked() {
        guard let watchedURL else { return }
        let fingerprint = Fingerprint.read(watchedURL)
        guard fingerprint != observedFingerprint else { return }
        observedFingerprint = fingerprint
        scheduleDeliveryLocked()
    }

    private func scheduleDeliveryLocked() {
        pendingDelivery?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.deliverIfStableLocked()
        }
        pendingDelivery = workItem
        queue.asyncAfter(
            deadline: .now() + .milliseconds(debounceMilliseconds),
            execute: workItem
        )
    }

    private func deliverIfStableLocked() {
        guard let watchedURL else { return }
        let fingerprint = Fingerprint.read(watchedURL)
        if fingerprint != observedFingerprint {
            observedFingerprint = fingerprint
            scheduleDeliveryLocked()
            return
        }

        pendingDelivery = nil
        guard fingerprint.content != deliveredFingerprint?.content else {
            deliveredFingerprint = fingerprint
            return
        }
        deliveredFingerprint = fingerprint
        onChange(watchedURL)
    }
}
