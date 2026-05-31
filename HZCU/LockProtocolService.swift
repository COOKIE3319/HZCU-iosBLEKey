import CryptoKit
import Foundation

@MainActor
final class LockProtocolService {
    private let bleManager: BLEManager
    private var sequence: UInt16 = 0

    init(bleManager: BLEManager) {
        self.bleManager = bleManager
    }

    func runLockFlow(
        key: KeyProfile,
        loginName: String,
        holdSeconds: Int,
        mode: LockActionMode,
        logger: (String) -> Void
    ) async throws -> LockPhase {
        defer { bleManager.disconnect() }

        logger("正在扫描目标设备：\(key.bluetoothID)")
        let device = try await bleManager.scanTarget(named: key.bluetoothID, timeout: 12)

        let preferredPCB = detectPCB(name: device.name)
        let candidates: [PCBProfile] = [preferredPCB] + PCBProfile.allCases.filter { $0 != preferredPCB }

        var linked = false
        for profile in candidates {
            do {
                logger("使用 \(profile.rawValue) 配置进行连接")
                try await bleManager.connect(to: device.id, timeout: 8)
                try await bleManager.discover(profile: profile, timeout: 6)
                linked = true
                break
            } catch {
                bleManager.disconnect()
            }
        }

        guard linked else {
            throw BLEManagerError.serviceNotFound
        }

        logger("正在请求 Token")
        let token = try await requestToken()

        switch mode {
        case .openOnly:
            logger("发送开锁指令")
            _ = try await sendOpenLikeAction(token: token, key: key, loginName: loginName, action: 1)
            return .opened

        case .closeOnly:
            logger("发送关锁指令")
            _ = try await sendOpenLikeAction(token: token, key: key, loginName: loginName, action: 2)
            return .closed

        case .normal:
            logger("执行开锁")
            _ = try await sendOpenLikeAction(token: token, key: key, loginName: loginName, action: 1)

            let wait = max(1, holdSeconds)
            logger("\(wait) 秒后自动关锁")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

            logger("正在自动关锁")
            _ = try await sendOpenLikeAction(token: token, key: key, loginName: loginName, action: 2)
            return .closed
        }
    }

    private func requestToken() async throws -> Data {
        let packet = FrameCodec.pack(commandID: 0x0001, seq: nextSeq())
        try await bleManager.write(packet)

        let frame = try await bleManager.waitFrame(commandID: 0xF001, timeout: 6.5)
        guard FrameCodec.verify(frame) else {
            throw LockProtocolError.crcMismatch
        }

        let status = try FrameCodec.status(from: frame)
        guard status == 0 else {
            throw LockProtocolError.statusFailure(status)
        }
        return try FrameCodec.token(fromF001: frame)
    }

    private func sendOpenLikeAction(
        token: Data,
        key: KeyProfile,
        loginName: String,
        action: UInt16
    ) async throws -> UInt16 {
        let req = try buildOpenLockRequest(token: token, key: key, loginName: loginName, action: action)
        try await bleManager.write(req)
        let frame = try await bleManager.waitFrame(commandID: 0xF00D, timeout: 5)

        guard FrameCodec.verify(frame) else {
            throw LockProtocolError.crcMismatch
        }

        let status = try FrameCodec.status(from: frame)
        guard status == 0 else {
            throw LockProtocolError.statusFailure(status)
        }
        return status
    }

    private func buildOpenLockRequest(
        token: Data,
        key: KeyProfile,
        loginName: String,
        action: UInt16
    ) throws -> Data {
        let isNewFirmware = newFirmware(key.hardVersion)
        var payload = Data(repeating: 0, count: isNewFirmware ? 140 : 83)

        payload.writeUInt16BE(action, at: 0)
        payload.writeString(loginName, maxBytes: 18, at: 2)
        payload.writeString(key.expireTime, maxBytes: 10, at: 20)
        payload.writeString(key.createTime, maxBytes: 10, at: 30)
        payload.writeUInt16BE(key.adminFlag, at: 40)

        let keyBytes = try FrameCodec.hexToBytes(key.keyID)
        let digest = Insecure.MD5.hash(data: keyBytes + token)
        payload.writeData(Data(digest), at: 42, maxBytes: 16)

        payload.writeString(timestamp(), maxBytes: 17, at: 58)
        payload.writeUInt16BE(key.isReverse, at: 75)
        payload.writeUInt16BE(key.delayRestore, at: 77)
        payload.writeUInt16BE(key.motorOpen, at: 79)
        payload.writeUInt16BE(key.motorClose, at: 81)

        if isNewFirmware {
            payload.writeString(key.serverAddress, maxBytes: 37, at: 83)
            payload.writeUInt16BE(0, at: 136)
            payload.writeUInt16BE(key.openReverseType, at: 138)
        }

        return FrameCodec.pack(commandID: 0x000D, seq: nextSeq(), payload: payload)
    }

    private func detectPCB(name: String) -> PCBProfile {
        let normalized = name.uppercased()
        if normalized.contains("TMC_") || normalized.contains("TP_") {
            return .zg
        }
        return .ti
    }

    private func nextSeq() -> UInt16 {
        sequence = sequence &+ 1
        if sequence == 0 {
            sequence = 1
        }
        return sequence
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter.string(from: Date())
    }

    private func newFirmware(_ hardVersion: String) -> Bool {
        let parts = hardVersion.split(separator: ".")
        guard let last = parts.last else { return false }
        return String(last) > "200629"
    }
}

private extension Data {
    mutating func writeUInt16BE(_ value: UInt16, at index: Int) {
        guard count >= index + 2 else { return }
        self[index] = UInt8((value >> 8) & 0xFF)
        self[index + 1] = UInt8(value & 0xFF)
    }

    mutating func writeString(_ value: String, maxBytes: Int, at index: Int) {
        writeData(Data(value.utf8), at: index, maxBytes: maxBytes)
    }

    mutating func writeData(_ data: Data, at index: Int, maxBytes: Int) {
        guard count >= index + maxBytes else { return }
        let slice = data.prefix(maxBytes)
        replaceSubrange(index..<(index + slice.count), with: slice)
    }
}
