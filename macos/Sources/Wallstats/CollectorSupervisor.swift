import Darwin
import Foundation
import WallstatsCore

@MainActor
final class CollectorSupervisor {
    private static let postTerminationDrainDeadline: Duration = .seconds(3)

    private enum StreamKind: String, Sendable {
        case stdout
        case stderr
    }

    private let model: AppModel
    private let options: LaunchOptions
    private let resolver: LaunchResolver
    private let bundledConfigURL: URL?
    private let decoder = WallstatsProtocolDecoder()

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutReader: DedicatedLineReader?
    private var stderrReader: DedicatedLineReader?
    private var terminationWaitTask: Task<Void, Never>?
    private var drainDeadlineTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?
    private var session = ProtocolSession()
    private var activeRunID: UInt64 = 0
    private var restartAfterTermination = false
    private var reloadAfterCollectorReady = false
    private var processUsesGroupTermination = false
    private var acceptingOutput = false
    private var readerShutdownForced = false
    private var shuttingDown = false
    private var shutdownCompletion: (() -> Void)?

    init(
        model: AppModel,
        options: LaunchOptions,
        resolver: LaunchResolver = LaunchResolver(),
        bundledConfigURL: URL?
    ) {
        self.model = model
        self.options = options
        self.resolver = resolver
        self.bundledConfigURL = bundledConfigURL
    }

    func start() {
        guard process == nil, !shuttingDown else { return }
        model.beginResolution()

        if let error = options.error {
            model.fail("Invalid command line: \(error) Use --config /path/to/config.rs or pass the path directly.")
            return
        }

        let configURL: URL
        switch resolver.resolveConfig(cliPath: options.configPath, bundledDefault: bundledConfigURL) {
        case let .found(url):
            configURL = url
        case let .missing(message, candidate):
            model.setConfigURL(candidate)
            model.fail(message)
            return
        }

        let executableURL: URL
        switch resolver.resolveRustScript() {
        case let .found(url):
            executableURL = url
        case let .missing(message, _):
            model.setConfigURL(configURL)
            model.fail(message)
            return
        }

        launch(executableURL: executableURL, configURL: configURL)
    }

    func requestReload() {
        guard !shuttingDown else { return }
        guard let process else {
            start()
            return
        }

        switch model.phase {
        case .starting, .waitingForPlan, .resolving:
            reloadAfterCollectorReady = true
            return
        case .reloading:
            // The pending launch will read the newest config after this process exits.
            return
        case .idle, .running, .failed:
            break
        }

        performReload(process: process)
    }

    private func performReload(process: Process) {
        restartAfterTermination = true
        acceptingOutput = false
        model.beginReload()
        if process.isRunning {
            sendSignal(SIGTERM, to: process)
            scheduleForcedTermination(for: process, runID: activeRunID)
        }
    }

    func prepareForApplicationTermination(completion: @escaping () -> Void) -> Bool {
        guard let process else { return false }

        shuttingDown = true
        restartAfterTermination = false
        acceptingOutput = false
        shutdownCompletion = completion
        if process.isRunning {
            sendSignal(SIGTERM, to: process)
            scheduleForcedTermination(for: process, runID: activeRunID)
        }
        return true
    }

    func terminateImmediatelyIfNeeded() {
        shuttingDown = true
        restartAfterTermination = false
        acceptingOutput = false
        stdoutReader?.cancel()
        stderrReader?.cancel()
        guard let process, process.isRunning else { return }
        sendSignal(SIGTERM, to: process)
    }

    private func launch(executableURL: URL, configURL: URL) {
        activeRunID &+= 1
        let runID = activeRunID
        session = ProtocolSession()
        acceptingOutput = true
        readerShutdownForced = false
        restartAfterTermination = false
        reloadAfterCollectorReady = false
        processUsesGroupTermination = Self.shouldTerminateProcessGroup(
            executableURL: executableURL,
            bundledRustScriptURL: resolver.bundledRustScriptURL
        )
        drainDeadlineTask?.cancel()
        forceKillTask?.cancel()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--force", configURL.path, "--"]
        process.currentDirectoryURL = configURL.deletingLastPathComponent()
        process.environment = resolver.childEnvironment(resolvedRustScriptURL: executableURL)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let signaled = terminatedProcess.terminationReason == .uncaughtSignal
            Task { @MainActor [weak self] in
                self?.processDidTerminate(status: status, signaled: signaled, runID: runID)
            }
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        model.beginLaunch(configURL: configURL)
        model.appendDiagnostic(
            level: .info,
            message: "Launching \(executableURL.path) --force \(configURL.path) --"
        )

        do {
            try process.run()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            let stdoutReader = makeReader(
                handle: stdoutPipe.fileHandleForReading,
                stream: .stdout,
                maximumLineBytes: WallstatsProtocolLimits.maximumLineBytes,
                runID: runID
            )
            let stderrReader = makeReader(
                handle: stderrPipe.fileHandleForReading,
                stream: .stderr,
                maximumLineBytes: 16_384,
                runID: runID
            )
            self.stdoutReader = stdoutReader
            self.stderrReader = stderrReader
            stdoutReader.start()
            stderrReader.start()
            model.collectorDidLaunch()
        } catch {
            acceptingOutput = false
            self.process = nil
            closeUnlaunchedPipes(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            self.stdoutPipe = nil
            self.stderrPipe = nil
            model.fail("Could not launch rust-script at \(executableURL.path): \(error.localizedDescription)")
        }
    }

    private func makeReader(
        handle: FileHandle,
        stream: StreamKind,
        maximumLineBytes: Int,
        runID: UInt64
    ) -> DedicatedLineReader {
        DedicatedLineReader(
            handle,
            maximumLineBytes: maximumLineBytes,
            name: "Wallstats collector \(stream.rawValue)",
            onLine: { [weak self] line in
                guard let self else { return }
                await self.receive(line: line, from: stream, runID: runID)
            },
            onOversizedLine: { [weak self] error in
                guard let self else { return }
                await self.receiveOversizedLine(error, from: stream, runID: runID)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                await self.readerFailed(error, stream: stream, runID: runID)
            }
        )
    }

    private func receive(line: Data, from stream: StreamKind, runID: UInt64) {
        guard runID == activeRunID, process != nil else { return }

        switch stream {
        case .stdout:
            guard acceptingOutput else { return }
            do {
                try consumeProtocolLine(line)
            } catch {
                failProtocol(error)
            }
        case .stderr:
            model.appendDiagnostic(
                level: .warning,
                message: String(decoding: line, as: UTF8.self)
            )
        }
    }

    private func receiveOversizedLine(
        _ error: JSONLineBufferError,
        from stream: StreamKind,
        runID: UInt64
    ) {
        guard runID == activeRunID, process != nil else { return }

        switch stream {
        case .stdout:
            failProtocol(error)
        case .stderr:
            model.appendDiagnostic(
                level: .warning,
                message: "A rust-script diagnostic line exceeded 16384 bytes and was discarded."
            )
        }
    }

    private func readerFailed(_ error: Error, stream: StreamKind, runID: UInt64) {
        guard runID == activeRunID, process != nil, !readerShutdownForced else { return }
        let message = "Could not drain collector \(stream.rawValue): \(error.localizedDescription)"

        if acceptingOutput {
            acceptingOutput = false
            model.fail(message)
            terminateCurrentProcess()
        } else {
            model.appendDiagnostic(level: .warning, message: message)
        }
    }

    private func consumeProtocolLine(_ line: Data) throws {
        let record: ProtocolRecord
        do {
            record = try decoder.decode(line)
        } catch {
            let preview = String(decoding: line.prefix(240), as: UTF8.self)
            throw SupervisorError.invalidJSON(details: String(describing: error), preview: preview)
        }

        let event = try session.consume(record)
        try model.accept(event)

        if case .plan = event, reloadAfterCollectorReady {
            reloadAfterCollectorReady = false
            if let process {
                performReload(process: process)
            }
            return
        }

        if case .fatal = event {
            acceptingOutput = false
            terminateCurrentProcess()
        }
    }

    private func failProtocol(_ error: Error) {
        guard acceptingOutput else { return }
        acceptingOutput = false
        model.fail("Collector protocol error: \(error.localizedDescription)")
        terminateCurrentProcess()
    }

    private func terminateCurrentProcess() {
        guard let process, process.isRunning else { return }
        sendSignal(SIGTERM, to: process)
        scheduleForcedTermination(for: process, runID: activeRunID)
    }

    private func processDidTerminate(status: Int32, signaled: Bool, runID: UInt64) {
        guard runID == activeRunID, terminationWaitTask == nil else { return }
        if !processUsesGroupTermination {
            forceKillTask?.cancel()
        }

        let stdoutReader = stdoutReader
        let stderrReader = stderrReader
        schedulePostTerminationDrainDeadline(status: status, signaled: signaled, runID: runID)
        terminationWaitTask = Task { @MainActor [weak self] in
            if let stdoutReader {
                await stdoutReader.waitUntilFinished()
            }
            if let stderrReader {
                await stderrReader.waitUntilFinished()
            }
            guard let self, runID == activeRunID, process != nil else { return }
            drainDeadlineTask?.cancel()
            completeTermination(status: status, signaled: signaled, runID: runID)
        }
    }

    private func completeTermination(status: Int32, signaled: Bool, runID: UInt64) {
        guard runID == activeRunID, process != nil else { return }
        drainDeadlineTask?.cancel()
        forceKillTask?.cancel()
        acceptingOutput = false
        stdoutReader = nil
        stderrReader = nil
        terminationWaitTask = nil
        drainDeadlineTask = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil

        if restartAfterTermination, !shuttingDown {
            restartAfterTermination = false
            start()
        } else if shuttingDown {
            let completion = shutdownCompletion
            shutdownCompletion = nil
            completion?()
        } else {
            model.collectorExited(status: status, signaled: signaled)
        }
    }

    private func schedulePostTerminationDrainDeadline(
        status: Int32,
        signaled: Bool,
        runID: UInt64
    ) {
        drainDeadlineTask?.cancel()
        drainDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.postTerminationDrainDeadline)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self, runID == activeRunID, process != nil else { return }
            readerShutdownForced = true
            model.appendDiagnostic(
                level: .warning,
                message: "Collector output pipes remained open for 3 seconds after exit; closing inherited descriptors."
            )
            stdoutReader?.cancel()
            stderrReader?.cancel()
            terminationWaitTask?.cancel()
            completeTermination(status: status, signaled: signaled, runID: runID)
        }
    }

    private func scheduleForcedTermination(for process: Process, runID: UInt64) {
        forceKillTask?.cancel()
        let processIdentifier = process.processIdentifier
        let processUsesGroupTermination = processUsesGroupTermination
        forceKillTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self, runID == activeRunID,
                  let process = self.process,
                  process.processIdentifier == processIdentifier
            else {
                return
            }
            if processUsesGroupTermination {
                if Darwin.killpg(processIdentifier, SIGKILL) != 0 {
                    if process.isRunning {
                        Darwin.kill(processIdentifier, SIGKILL)
                    }
                }
            } else if process.isRunning {
                Darwin.kill(processIdentifier, SIGKILL)
            }
            // Process invokes its termination handler only after waitpid has reaped the child.
        }
    }

    private func sendSignal(_ signal: Int32, to process: Process) {
        let processIdentifier = process.processIdentifier
        if processUsesGroupTermination {
            if Darwin.killpg(processIdentifier, signal) != 0 {
                Darwin.kill(processIdentifier, signal)
            }
        } else {
            Darwin.kill(processIdentifier, signal)
        }
    }

    nonisolated static func shouldTerminateProcessGroup(
        executableURL: URL,
        bundledRustScriptURL: URL?
    ) -> Bool {
        bundledRustScriptURL?.standardizedFileURL == executableURL.standardizedFileURL
    }

    private func closeUnlaunchedPipes(stdoutPipe: Pipe, stderrPipe: Pipe) {
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
    }
}

private enum SupervisorError: Error, LocalizedError {
    case invalidJSON(details: String, preview: String)

    var errorDescription: String? {
        switch self {
        case let .invalidJSON(details, preview):
            "Invalid JSON record (\(details)). Record begins: \(preview)"
        }
    }
}
