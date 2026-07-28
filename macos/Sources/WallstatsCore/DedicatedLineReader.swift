import Darwin
import Dispatch
import Foundation

public enum DedicatedLineReaderError: Error, Equatable, Sendable {
    case readFailed(code: Int32)
}

extension DedicatedLineReaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .readFailed(code):
            "Pipe read failed with errno \(code)."
        }
    }
}

public final class DedicatedLineReader: @unchecked Sendable {
    private static let readChunkBytes = 65_536
    private static let cancellationPollMilliseconds: Int32 = 100

    private let handle: FileHandle
    private let maximumLineBytes: Int
    private let name: String
    private let onLine: @Sendable (Data) async -> Void
    private let onOversizedLine: @Sendable (JSONLineBufferError) async -> Void
    private let onFailure: @Sendable (DedicatedLineReaderError) async -> Void

    private let stateLock = NSLock()
    private var thread: Thread?
    private var started = false
    private var cancellationRequested = false
    private var completed = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        _ handle: FileHandle,
        maximumLineBytes: Int = WallstatsProtocolLimits.maximumLineBytes,
        name: String = "Wallstats pipe reader",
        onLine: @escaping @Sendable (Data) async -> Void,
        onOversizedLine: @escaping @Sendable (JSONLineBufferError) async -> Void,
        onFailure: @escaping @Sendable (DedicatedLineReaderError) async -> Void = { _ in }
    ) {
        precondition(maximumLineBytes > 0)
        self.handle = handle
        self.maximumLineBytes = maximumLineBytes
        self.name = name
        self.onLine = onLine
        self.onOversizedLine = onOversizedLine
        self.onFailure = onFailure
    }

    deinit {
        cancel()
    }

    public func start() {
        stateLock.lock()
        precondition(!started, "DedicatedLineReader may only be started once")
        started = true
        if completed || cancellationRequested {
            stateLock.unlock()
            return
        }

        let thread = Thread { [self] in
            run()
        }
        thread.name = name
        thread.qualityOfService = .utility
        self.thread = thread
        stateLock.unlock()
        thread.start()
    }

    public func cancel() {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var closeWithoutThread = false

        stateLock.lock()
        cancellationRequested = true
        if !started, !completed {
            completed = true
            closeWithoutThread = true
            waiters = completionWaiters
            completionWaiters.removeAll(keepingCapacity: false)
        }
        stateLock.unlock()

        if closeWithoutThread {
            try? handle.close()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    public func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if completed {
                stateLock.unlock()
                continuation.resume()
            } else {
                completionWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    private func run() {
        defer {
            try? handle.close()
            finish()
        }

        let fileDescriptor = handle.fileDescriptor
        var pollDescriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        var readBuffer = [UInt8](repeating: 0, count: Self.readChunkBytes)
        var lineBuffer = JSONLineBuffer(maximumLineBytes: maximumLineBytes)
        var discardingOversizedLine = false

        while !isCancellationRequested {
            pollDescriptor.revents = 0
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                Self.cancellationPollMilliseconds
            )
            if pollResult < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                deliver(.readFailed(code: code), to: onFailure)
                return
            }
            if pollResult == 0 {
                continue
            }
            if pollDescriptor.revents & Int16(POLLNVAL) != 0 {
                if !isCancellationRequested {
                    deliver(.readFailed(code: EBADF), to: onFailure)
                }
                return
            }

            let readableEvents = Int16(POLLIN | POLLHUP | POLLERR)
            guard pollDescriptor.revents & readableEvents != 0 else { continue }

            let readCount = readBuffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if readCount < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN {
                    continue
                }
                if !isCancellationRequested {
                    deliver(.readFailed(code: code), to: onFailure)
                }
                return
            }
            if readCount == 0 {
                if !discardingOversizedLine {
                    do {
                        if let finalLine = try lineBuffer.finish() {
                            deliver(finalLine, to: onLine)
                        }
                    } catch let error as JSONLineBufferError {
                        deliver(error, to: onOversizedLine)
                    } catch {
                        preconditionFailure("JSONLineBuffer emitted an unexpected error: \(error)")
                    }
                }
                return
            }

            for byte in readBuffer.prefix(readCount) {
                if discardingOversizedLine {
                    if byte == 0x0A {
                        discardingOversizedLine = false
                    }
                    continue
                }

                do {
                    if let line = try lineBuffer.append(byte) {
                        deliver(line, to: onLine)
                        if isCancellationRequested {
                            return
                        }
                    }
                } catch let error as JSONLineBufferError {
                    deliver(error, to: onOversizedLine)
                    lineBuffer = JSONLineBuffer(maximumLineBytes: maximumLineBytes)
                    discardingOversizedLine = true
                    if isCancellationRequested {
                        return
                    }
                } catch {
                    preconditionFailure("JSONLineBuffer emitted an unexpected error: \(error)")
                }
            }
        }
    }

    private var isCancellationRequested: Bool {
        stateLock.lock()
        let value = cancellationRequested
        stateLock.unlock()
        return value
    }

    private func deliver<Value: Sendable>(
        _ value: Value,
        to callback: @escaping @Sendable (Value) async -> Void
    ) {
        let latch = CallbackLatch()
        Task {
            await callback(value)
            latch.signal()
        }
        latch.wait()
    }

    private func finish() {
        stateLock.lock()
        guard !completed else {
            stateLock.unlock()
            return
        }
        completed = true
        thread = nil
        let waiters = completionWaiters
        completionWaiters.removeAll(keepingCapacity: false)
        stateLock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }
}

public enum OrderedLineReader {
    public static func drain(
        _ handle: FileHandle,
        maximumLineBytes: Int = WallstatsProtocolLimits.maximumLineBytes,
        onLine: @escaping @Sendable (Data) async -> Void,
        onOversizedLine: @escaping @Sendable (JSONLineBufferError) async -> Void
    ) async throws {
        let failureState = LineReaderFailureState()
        let reader = DedicatedLineReader(
            handle,
            maximumLineBytes: maximumLineBytes,
            onLine: onLine,
            onOversizedLine: onOversizedLine,
            onFailure: { error in
                failureState.record(error)
            }
        )

        await withTaskCancellationHandler {
            reader.start()
            await reader.waitUntilFinished()
        } onCancel: {
            reader.cancel()
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if let failure = failureState.failure {
            throw failure
        }
    }
}

private final class CallbackLatch: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }
}

private final class LineReaderFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: DedicatedLineReaderError?

    var failure: DedicatedLineReaderError? {
        lock.lock()
        let failure = storedFailure
        lock.unlock()
        return failure
    }

    func record(_ failure: DedicatedLineReaderError) {
        lock.lock()
        storedFailure = failure
        lock.unlock()
    }
}
