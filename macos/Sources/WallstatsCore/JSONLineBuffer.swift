import Foundation

public enum WallstatsProtocolLimits {
    public static let maximumLineBytes = 1_048_576
}

public enum JSONLineBufferError: Error, LocalizedError, Equatable, Sendable {
    case lineTooLong(limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .lineTooLong(limit):
            "Protocol line exceeds the \(limit)-byte safety limit."
        }
    }
}

public struct JSONLineBuffer: Sendable {
    private var buffer = Data()
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = WallstatsProtocolLimits.maximumLineBytes) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if let line = try append(byte) {
                lines.append(line)
            }
        }
        return lines
    }

    public mutating func finish() throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        guard buffer.count <= maximumLineBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw JSONLineBufferError.lineTooLong(limit: maximumLineBytes)
        }

        var line = buffer
        buffer.removeAll(keepingCapacity: false)
        if line.last == 0x0D {
            line.removeLast()
        }
        return line.isEmpty ? nil : line
    }

    mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 0x0A {
            var line = buffer
            buffer.removeAll(keepingCapacity: true)
            if line.last == 0x0D {
                line.removeLast()
            }
            return line.isEmpty ? nil : line
        }

        guard buffer.count < maximumLineBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw JSONLineBufferError.lineTooLong(limit: maximumLineBytes)
        }
        buffer.append(byte)
        return nil
    }
}
