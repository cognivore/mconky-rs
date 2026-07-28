import Foundation
import Testing
@testable import WallstatsCore

@Suite("Bounded JSON line handling")
struct JSONLineBufferTests {
    @Test("Fragmented CRLF, empty lines, and final unterminated lines preserve order")
    func fragmentationAndFinalLine() throws {
        var buffer = JSONLineBuffer(maximumLineBytes: 32)

        #expect(try buffer.append(Data("first\r".utf8)).isEmpty)
        #expect(try strings(buffer.append(Data("\n\nsec".utf8))) == ["first"])
        #expect(try strings(buffer.append(Data("ond\nfinal".utf8))) == ["second"])
        #expect(try buffer.finish().map { String(decoding: $0, as: UTF8.self) } == "final")
        #expect(try buffer.finish() == nil)
    }

    @Test("The shared protocol limit accepts exactly 1 MiB and rejects one byte more")
    func sharedLimit() throws {
        #expect(WallstatsProtocolLimits.maximumLineBytes == 1_048_576)
        let exactLine = Data(repeating: 0x61, count: WallstatsProtocolLimits.maximumLineBytes)

        var exactBuffer = JSONLineBuffer()
        #expect(try exactBuffer.append(exactLine).isEmpty)
        #expect(try exactBuffer.finish()?.count == WallstatsProtocolLimits.maximumLineBytes)

        var oversizedBuffer = JSONLineBuffer()
        #expect(try oversizedBuffer.append(exactLine).isEmpty)
        #expect(throws: JSONLineBufferError.self) {
            try oversizedBuffer.append(Data([0x62]))
        }
    }

    @Test("Ordered readers drain stdout and stderr through EOF")
    func processDrainIntegration() async throws {
        let executableURL = URL(fileURLWithPath: "/usr/bin/tee")
        try #require(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["/dev/stderr"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let stdoutCollector = LineCollector()
        let stderrCollector = LineCollector()
        let stdoutTask = Task {
            try await OrderedLineReader.drain(
                stdoutPipe.fileHandleForReading,
                onLine: { line in
                    await stdoutCollector.append(String(decoding: line, as: UTF8.self))
                },
                onOversizedLine: { error in
                    await stdoutCollector.appendError(error.localizedDescription)
                }
            )
        }
        let stderrTask = Task {
            try await OrderedLineReader.drain(
                stderrPipe.fileHandleForReading,
                onLine: { line in
                    await stderrCollector.append(String(decoding: line, as: UTF8.self))
                },
                onOversizedLine: { error in
                    await stderrCollector.appendError(error.localizedDescription)
                }
            )
        }

        try stdinPipe.fileHandleForWriting.write(contentsOf: Data("first\npar".utf8))
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data("tial\nfinal".utf8))
        try stdinPipe.fileHandleForWriting.close()

        try await stdoutTask.value
        try await stderrTask.value

        #expect(await stdoutCollector.lines == ["first", "partial", "final"])
        #expect(await stderrCollector.lines == ["first", "partial", "final"])
        #expect(await stdoutCollector.errors.isEmpty)
        #expect(await stderrCollector.errors.isEmpty)

        for _ in 0 ..< 100 where process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
    }

    @Test("Closing and cancelling a reader releases a pipe whose writer retains the FD")
    func forcedReaderRelease() async throws {
        let pipe = Pipe()
        let collector = LineCollector()
        let reader = DedicatedLineReader(
            pipe.fileHandleForReading,
            onLine: { line in
                await collector.append(String(decoding: line, as: UTF8.self))
            },
            onOversizedLine: { error in
                await collector.appendError(error.localizedDescription)
            },
            onFailure: { error in
                await collector.appendError(error.localizedDescription)
            }
        )
        reader.start()

        try pipe.fileHandleForWriting.write(contentsOf: Data("complete\npartial".utf8))
        for _ in 0 ..< 100 where await collector.lines.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await collector.lines == ["complete"])

        reader.cancel()
        await reader.waitUntilFinished()
        try pipe.fileHandleForWriting.close()
        #expect(await collector.errors.isEmpty)
    }

    @Test("Silent stderr cannot starve stdout beyond pipe capacity")
    func silentStderrDoesNotStarveStdout() async throws {
        let executableURL = URL(fileURLWithPath: "/bin/sh")
        try #require(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let lineCount = 6_000
        let payload = String(repeating: "x", count: 96)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "-c",
            "payload='\(payload)'; i=0; while [ \"$i\" -lt \(lineCount) ]; do printf '%s:%s\\n' \"$i\" \"$payload\"; i=$((i + 1)); done; sleep 1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = LineCollector()
        let stderrCollector = LineCollector()
        let stdoutReader = DedicatedLineReader(
            stdoutPipe.fileHandleForReading,
            name: "stdout starvation regression reader",
            onLine: { line in
                await stdoutCollector.append(String(decoding: line, as: UTF8.self))
            },
            onOversizedLine: { error in
                await stdoutCollector.appendError(error.localizedDescription)
            },
            onFailure: { error in
                await stdoutCollector.appendError(error.localizedDescription)
            }
        )
        let stderrReader = DedicatedLineReader(
            stderrPipe.fileHandleForReading,
            name: "silent stderr starvation regression reader",
            onLine: { line in
                await stderrCollector.append(String(decoding: line, as: UTF8.self))
            },
            onOversizedLine: { error in
                await stderrCollector.appendError(error.localizedDescription)
            },
            onFailure: { error in
                await stderrCollector.appendError(error.localizedDescription)
            }
        )

        stderrReader.start()
        stdoutReader.start()
        do {
            try process.run()
        } catch {
            stdoutReader.cancel()
            stderrReader.cancel()
            await stdoutReader.waitUntilFinished()
            await stderrReader.waitUntilFinished()
            throw error
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        try await waitForReaders(
            stdoutReader,
            stderrReader,
            timeout: .seconds(8)
        )

        let stdoutLines = await stdoutCollector.lines
        #expect(stdoutLines.count == lineCount)
        #expect(stdoutLines == (0 ..< lineCount).map { "\($0):\(payload)" })
        #expect(await stdoutCollector.errors.isEmpty)
        #expect(await stderrCollector.lines.isEmpty)
        #expect(await stderrCollector.errors.isEmpty)

        for _ in 0 ..< 100 where process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
    }

    @Test("Oversized lines are discarded without losing following lines")
    func oversizedLineDiscard() async throws {
        let pipe = Pipe()
        let collector = LineCollector()
        let reader = DedicatedLineReader(
            pipe.fileHandleForReading,
            maximumLineBytes: 8,
            onLine: { line in
                await collector.append(String(decoding: line, as: UTF8.self))
            },
            onOversizedLine: { error in
                await collector.appendError(error.localizedDescription)
            }
        )
        reader.start()

        try pipe.fileHandleForWriting.write(
            contentsOf: Data("123456789 discarded\nnext\nfinal".utf8)
        )
        try pipe.fileHandleForWriting.close()
        await reader.waitUntilFinished()

        #expect(await collector.lines == ["next", "final"])
        #expect(await collector.errors.count == 1)
    }

    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }
}

private enum ReaderTestError: Error {
    case timedOut
}

private func waitForReaders(
    _ first: DedicatedLineReader,
    _ second: DedicatedLineReader,
    timeout: Duration
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await first.waitUntilFinished()
            await second.waitUntilFinished()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            first.cancel()
            second.cancel()
            throw ReaderTestError.timedOut
        }

        try await group.next()
        group.cancelAll()
    }
}

private actor LineCollector {
    private(set) var lines: [String] = []
    private(set) var errors: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func appendError(_ error: String) {
        errors.append(error)
    }
}
