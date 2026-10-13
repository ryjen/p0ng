import Foundation

/// Length-delimited data packets for a future authenticated Network.framework
/// stream. This is framing only: neither encryption nor peer authentication.
public enum WireFrameError: Error, Equatable {
    case invalidLength
    case overflow
    case malformedMessage
}

public enum MatchWireFraming {
    public static let maximumPayloadBytes = 4096
    public static let maximumBufferedBytes = 16 * 1024

    public static func encode(_ message: MatchMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw WireFrameError.invalidLength
        }
        let n = UInt32(payload.count)
        var bytes = Data([UInt8(n >> 24), UInt8((n >> 16) & 0xff),
                          UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        bytes.append(payload)
        return bytes
    }
}

/// Handles arbitrary TCP/QUIC byte stream fragmentation and coalescing.
/// On any error discard the stream and close the associated connection.
public struct MatchWireDecoder {
    private var bytes: [UInt8] = []
    public init() {}

    public mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    public mutating func accept(_ chunk: Data) throws -> [MatchMessage] {
        guard bytes.count <= MatchWireFraming.maximumBufferedBytes,
              chunk.count <= MatchWireFraming.maximumBufferedBytes - bytes.count else {
            reset()
            throw WireFrameError.overflow
        }
        bytes.append(contentsOf: chunk)
        var messages: [MatchMessage] = []
        while bytes.count >= 4 {
            let n = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) |
                    (Int(bytes[2]) << 8) | Int(bytes[3])
            guard (1...MatchWireFraming.maximumPayloadBytes).contains(n) else {
                reset()
                throw WireFrameError.invalidLength
            }
            guard bytes.count >= n + 4 else { break }
            guard let message = try? JSONDecoder().decode(
                MatchMessage.self, from: Data(bytes[4..<(n + 4)])) else {
                reset()
                throw WireFrameError.malformedMessage
            }
            messages.append(message)
            bytes.removeFirst(n + 4)
        }
        return messages
    }
}
