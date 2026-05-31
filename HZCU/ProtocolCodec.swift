import Foundation

enum LockProtocolError: Error, LocalizedError {
    case malformedFrame
    case invalidHeader
    case crcMismatch
    case commandMismatch(expected: UInt16, actual: UInt16)
    case tokenMissing
    case statusFailure(UInt16)
    case invalidHex

    var errorDescription: String? {
        switch self {
        case .malformedFrame:
            return "门锁数据帧格式错误"
        case .invalidHeader:
            return "门锁数据帧头无效"
        case .crcMismatch:
            return "CRC 校验失败"
        case let .commandMismatch(expected, actual):
            return "命令 ID 不匹配，期望=\(expected)，实际=\(actual)"
        case .tokenMissing:
            return "缺少 Token 数据"
        case let .statusFailure(code):
            return String(format: "门锁指令失败，状态码=0x%04X", code)
        case .invalidHex:
            return "十六进制字符串格式错误"
        }
    }
}

enum FrameCodec {
    static let header: [UInt8] = [0xaa, 0x11, 0x77, 0xdd]

    static func pack(commandID: UInt16, seq: UInt16, payload: Data = Data()) -> Data {
        var frame = Data()
        frame.append(contentsOf: header)
        frame.appendUInt16BE(UInt16(payload.count + 4))
        frame.appendUInt16BE(commandID)
        frame.appendUInt16BE(seq)
        frame.append(payload)
        let crc = crc16(frame)
        frame.appendUInt16BE(crc)
        return frame
    }

    static func verify(_ frame: Data) -> Bool {
        guard frame.count >= 12 else { return false }
        guard Array(frame.prefix(4)) == header else { return false }
        let dataLen = frame.uint16BE(at: 4)
        let total = Int(6 + dataLen + 2)
        guard total == frame.count else { return false }
        let payload = frame.prefix(total - 2)
        let expectedCRC = crc16(payload)
        return frame.uint16BE(at: total - 2) == expectedCRC
    }

    static func extractFrames(buffer: inout Data) -> [Data] {
        var frames: [Data] = []
        var index = 0

        while index + 8 <= buffer.count {
            if !buffer.matchesHeader(at: index) {
                index += 1
                continue
            }
            if index + 6 > buffer.count { break }

            let dataLen = buffer.uint16BE(at: index + 4)
            let total = Int(6 + dataLen + 2)
            if index + total > buffer.count { break }

            let candidate = buffer.subdata(in: index..<(index + total))
            if verify(candidate) {
                frames.append(candidate)
                index += total
            } else {
                index += 1
            }
        }

        if index > 0 {
            buffer.removeSubrange(0..<index)
        }
        return frames
    }

    static func commandID(from frame: Data) throws -> UInt16 {
        guard frame.count >= 10 else { throw LockProtocolError.malformedFrame }
        return frame.uint16BE(at: 6)
    }

    static func status(from frame: Data) throws -> UInt16 {
        guard frame.count >= 12 else { throw LockProtocolError.malformedFrame }
        return frame.uint16BE(at: 10)
    }

    static func token(fromF001 frame: Data) throws -> Data {
        guard try commandID(from: frame) == 0xF001 else {
            throw LockProtocolError.commandMismatch(expected: 0xF001, actual: try commandID(from: frame))
        }
        guard frame.count >= 28 else { throw LockProtocolError.tokenMissing }
        return frame.subdata(in: 12..<28)
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(reverseBits8(byte)) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return reverseBits16(crc)
    }

    static func hexToBytes(_ hex: String) throws -> Data {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "")
            .lowercased()

        guard cleaned.count.isMultiple(of: 2) else {
            throw LockProtocolError.invalidHex
        }

        var out = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byteText = cleaned[index..<next]
            guard let byte = UInt8(byteText, radix: 16) else {
                throw LockProtocolError.invalidHex
            }
            out.append(byte)
            index = next
        }
        return out
    }

    private static func reverseBits8(_ value: UInt8) -> UInt8 {
        var output: UInt8 = 0
        for i in 0..<8 where ((value >> i) & 0x1) == 0x1 {
            output |= 1 << (7 - i)
        }
        return output
    }

    private static func reverseBits16(_ value: UInt16) -> UInt16 {
        var output: UInt16 = 0
        for i in 0..<16 where ((value >> i) & 0x1) == 0x1 {
            output |= 1 << (15 - i)
        }
        return output
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func uint16BE(at index: Int) -> UInt16 {
        let hi = UInt16(self[index])
        let lo = UInt16(self[index + 1])
        return (hi << 8) | lo
    }

    func matchesHeader(at index: Int) -> Bool {
        guard count >= index + 4 else { return false }
        return self[index] == 0xaa && self[index + 1] == 0x11 && self[index + 2] == 0x77 && self[index + 3] == 0xdd
    }
}
