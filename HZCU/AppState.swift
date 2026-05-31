import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var config: LockConfig
    @Published var keys: [KeyProfile]
    @Published var activeKeyID: String?
    @Published var lockPhase: LockPhase = .idle
    @Published var isBusy = false
    @Published var devices: [BLEDeviceLite] = []
    @Published var lockStateMap: [String: String]
    @Published var logs: [LogEntry] = []

    private let storage: StorageService
    private let configService: ConfigService
    private let bleManager: BLEManager
    private let protocolService: LockProtocolService

    init(
        storage: StorageService = StorageService(),
        configService: ConfigService = ConfigService(),
        bleManager: BLEManager? = nil
    ) {
        let resolvedBLEManager = bleManager ?? BLEManager()

        self.storage = storage
        self.configService = configService
        self.bleManager = resolvedBLEManager
        self.protocolService = LockProtocolService(bleManager: resolvedBLEManager)

        self.config = storage.loadConfig()
        self.keys = storage.loadKeys().sorted { $0.label < $1.label }
        self.activeKeyID = storage.loadActiveKeyID()
        self.lockStateMap = storage.loadLockState()

        if activeKey == nil {
            activeKeyID = keys.first?.id
        }
        appendLog("应用初始化完成")
    }

    var activeKey: KeyProfile? {
        get {
            keys.first(where: { $0.id == activeKeyID })
        }
        set {
            guard let newValue else { return }
            upsertKey(newValue)
            activeKeyID = newValue.id
        }
    }

    var lockPhaseTitle: String {
        switch lockPhase {
        case .idle: return "空闲"
        case .scanning: return "扫描中"
        case .connecting: return "连接中"
        case .discovering: return "发现服务中"
        case .authenticating: return "认证中"
        case .opened: return "已开锁"
        case .autoClosing: return "自动关锁中"
        case .closed: return "已关锁"
        case .failed: return "失败"
        }
    }

    func persist() {
        storage.saveConfig(config)
        storage.saveKeys(keys)
        storage.saveActiveKeyID(activeKeyID)
        storage.saveLockState(lockStateMap)
    }

    func setActiveKey(_ id: String) {
        activeKeyID = id
        persist()
    }

    func upsertKey(_ key: KeyProfile) {
        if let index = keys.firstIndex(where: { $0.id == key.id }) {
            keys[index] = key
        } else {
            keys.append(key)
        }
        keys.sort { $0.label < $1.label }
        if activeKeyID == nil {
            activeKeyID = key.id
        }
        persist()
    }

    func deleteKey(at offsets: IndexSet) {
        keys.remove(atOffsets: offsets)
        if let active = activeKeyID, !keys.contains(where: { $0.id == active }) {
            activeKeyID = keys.first?.id
        }
        persist()
    }

    func refreshFromBackend() async {
        guard !config.loginName.isEmpty else {
            appendLog("请先填写登录账号", level: "警告")
            return
        }
        isBusy = true
        appendLog("正在从后台刷新钥匙配置")
        do {
            let result = try await configService.refresh(loginName: config.loginName, cookie: config.cookie)
            config.cookie = result.normalizedCookie ?? config.cookie

            for profile in result.keyProfiles {
                upsertKey(profile)
            }
            if activeKeyID == nil {
                activeKeyID = keys.first?.id
            }

            persist()
            appendLog("配置刷新完成：\(result.keyProfiles.count) 把钥匙")
        } catch {
            appendLog(friendlyErrorMessage(error), level: "错误")
            lockPhase = .failed
        }
        isBusy = false
    }

    func scanAllDevices() async {
        isBusy = true
        appendLog("开始扫描附近全部 BLE 设备")
        do {
            lockPhase = .scanning
            devices = try await bleManager.scanAll(timeout: 8)
            appendLog("扫描完成：\(devices.count) 个设备")
            lockPhase = .idle
        } catch {
            appendLog(friendlyErrorMessage(error), level: "错误")
            lockPhase = .failed
        }
        isBusy = false
    }

    func runLockAction(mode: LockActionMode) async {
        guard !isBusy else { return }
        guard let key = activeKey else {
            appendLog("当前没有激活钥匙", level: "警告")
            return
        }

        isBusy = true
        do {
            lockPhase = .scanning
            let result = try await protocolService.runLockFlow(
                key: key,
                loginName: config.loginName,
                holdSeconds: config.unlockHoldSeconds,
                mode: mode
            ) { [weak self] message in
                self?.appendLog(message)
            }

            lockPhase = result
            switch result {
            case .opened:
                lockStateMap[key.id] = "已开锁"
            case .closed:
                lockStateMap[key.id] = "已关锁"
            default:
                break
            }
            persist()
        } catch {
            lockPhase = .failed
            appendLog(friendlyErrorMessage(error), level: "错误")
        }
        isBusy = false
    }

    func importKeys(from text: String) {
        guard let data = text.data(using: .utf8) else {
            appendLog("导入内容不是有效文本", level: "错误")
            return
        }

        do {
            let decoder = JSONDecoder()
            if let wrapped = try? decoder.decode(KeyListWrapper.self, from: data) {
                wrapped.keys.forEach(upsertKey)
                appendLog("导入完成：\(wrapped.keys.count) 把钥匙")
                return
            }

            let array = try decoder.decode([KeyProfile].self, from: data)
            array.forEach(upsertKey)
            appendLog("导入完成：\(array.count) 把钥匙")
        } catch {
            appendLog("导入失败：\(friendlyErrorMessage(error))", level: "错误")
        }
    }

    func exportKeysJSON() -> String {
        let wrapper = KeyListWrapper(keys: keys)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(wrapper),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func appendLog(_ message: String, level: String = "信息") {
        logs.append(LogEntry(timestamp: Date(), level: level, message: message))
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private func friendlyErrorMessage(_ error: Error) -> String {
        if let bleError = error as? BLEManagerError {
            return bleError.localizedDescription
        }
        if let cfgError = error as? ConfigServiceError {
            return cfgError.localizedDescription
        }
        if let protocolError = error as? LockProtocolError {
            return protocolError.localizedDescription
        }

        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == kCFErrorDomainCFNetwork as String,
           underlying.code == -1200 {
            return "TLS 连接失败：服务器证书校验未通过（可能已过期）"
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorServerCertificateHasBadDate:
                return "服务器证书已过期或尚未生效，请联系后端维护证书"
            case NSURLErrorServerCertificateUntrusted:
                return "服务器证书不受信任，请联系后端维护证书链"
            case NSURLErrorSecureConnectionFailed:
                return "TLS 安全连接失败，请检查校园网环境、证书信任或稍后重试"
            case NSURLErrorNotConnectedToInternet:
                return "当前网络不可用，请检查网络连接"
            case NSURLErrorTimedOut:
                return "请求超时，请重试"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "无法连接到服务器，请确认网络或服务器地址"
            default:
                break
            }
        }

        return error.localizedDescription
    }
}

private struct KeyListWrapper: Codable {
    let keys: [KeyProfile]
}
