import CoreBluetooth
import Foundation

enum BLEManagerError: Error, LocalizedError {
    case bluetoothUnavailable
    case bluetoothInitializing
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case bluetoothUnsupported
    case simulatorUnsupported
    case scanTimeout
    case deviceNotFound
    case connectTimeout
    case connectFailed
    case noPeripheral
    case serviceNotFound
    case characteristicNotFound
    case discoverTimeout
    case writeTimeout
    case responseTimeout

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "蓝牙不可用"
        case .bluetoothInitializing: return "蓝牙状态初始化中，请稍后重试"
        case .bluetoothUnauthorized: return "蓝牙权限未授权，请在系统设置中允许蓝牙访问"
        case .bluetoothPoweredOff: return "蓝牙未开启，请先打开系统蓝牙"
        case .bluetoothUnsupported: return "当前设备不支持 BLE"
        case .simulatorUnsupported: return "iOS 模拟器不支持 CoreBluetooth，请使用真机测试"
        case .scanTimeout: return "BLE 扫描超时"
        case .deviceNotFound: return "未找到目标设备"
        case .connectTimeout: return "BLE 连接超时"
        case .connectFailed: return "BLE 连接失败"
        case .noPeripheral: return "当前没有已连接外设"
        case .serviceNotFound: return "未找到服务"
        case .characteristicNotFound: return "未找到特征"
        case .discoverTimeout: return "服务发现超时"
        case .writeTimeout: return "写入超时"
        case .responseTimeout: return "BLE 响应超时"
        }
    }
}

@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var discoveredDevices: [BLEDeviceLite] = []

    private lazy var central = CBCentralManager(delegate: self, queue: nil)

    private var devicesByID: [String: CBPeripheral] = [:]
    private var currentPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readCharacteristic: CBCharacteristic?

    private var scanContinuation: CheckedContinuation<BLEDeviceLite, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var waiters: [UInt16: CheckedContinuation<Data, Error>] = [:]
    private var stateUpdateContinuation: CheckedContinuation<Void, Never>?

    private var targetNormalizedName: String?
    private var readBuffer = Data()

    func scanTarget(named target: String, timeout: TimeInterval = 12) async throws -> BLEDeviceLite {
        try await ensureBluetoothReady()
        discoveredDevices = []
        devicesByID.removeAll()
        targetNormalizedName = normalizeName(target)

        return try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.scanTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.scanContinuation = continuation
                self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        }
    }

    func scanAll(timeout: TimeInterval = 8) async throws -> [BLEDeviceLite] {
        try await ensureBluetoothReady()
        discoveredDevices = []
        devicesByID.removeAll()
        targetNormalizedName = nil

        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        central.stopScan()
        return discoveredDevices
    }

    func connect(to deviceID: String, timeout: TimeInterval = 8) async throws {
        try await ensureBluetoothReady()
        guard let peripheral = devicesByID[deviceID] else { throw BLEManagerError.deviceNotFound }
        peripheral.delegate = self
        currentPeripheral = peripheral

        try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.connectTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.connectContinuation = continuation
                self.central.connect(peripheral, options: nil)
            }
        }
    }

    func discover(profile: PCBProfile, timeout: TimeInterval = 6) async throws {
        guard let peripheral = currentPeripheral else { throw BLEManagerError.noPeripheral }

        readCharacteristic = nil
        writeCharacteristic = nil

        try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.discoverTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.discoverContinuation = continuation
                peripheral.discoverServices([CBUUID(string: profile.serviceUUID)])
            }
        }
    }

    func write(_ data: Data) async throws {
        guard let peripheral = currentPeripheral,
              let characteristic = writeCharacteristic else {
            throw BLEManagerError.characteristicNotFound
        }

        let chunkSize = 20
        var index = 0
        while index < data.count {
            let end = min(index + chunkSize, data.count)
            let chunk = data.subdata(in: index..<end)
            try await withTimeout(seconds: 3, timeoutError: BLEManagerError.writeTimeout) {
                try await withCheckedThrowingContinuation { continuation in
                    self.writeContinuation = continuation
                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                }
            }
            index = end
            if index < data.count {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    func waitFrame(commandID: UInt16, timeout: TimeInterval = 5) async throws -> Data {
        try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.responseTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.waiters[commandID] = continuation
            }
        }
    }

    func disconnect() {
        if let peripheral = currentPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        currentPeripheral = nil
        writeCharacteristic = nil
        readCharacteristic = nil
        readBuffer.removeAll(keepingCapacity: false)
        waiters.values.forEach { $0.resume(throwing: BLEManagerError.noPeripheral) }
        waiters.removeAll()
    }

    private func ensureBluetoothReady() async throws {
#if targetEnvironment(simulator)
        throw BLEManagerError.simulatorUnsupported
#else
        // Trigger CBCentralManager creation early so state callback can fire.
        _ = central

        if bluetoothState == .unknown || bluetoothState == .resetting {
            await waitForStateUpdate(timeout: 5.0)
        }

        guard bluetoothState == .poweredOn else {
            throw mapStateToError(bluetoothState)
        }
#endif
    }

    private func waitForStateUpdate(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            stateUpdateContinuation = continuation

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                guard let pending = self.stateUpdateContinuation else { return }
                self.stateUpdateContinuation = nil
                pending.resume()
            }
        }
    }

    private func mapStateToError(_ state: CBManagerState) -> BLEManagerError {
        switch state {
        case .unknown, .resetting:
            return .bluetoothInitializing
        case .poweredOff:
            return .bluetoothPoweredOff
        case .unauthorized:
            return .bluetoothUnauthorized
        case .unsupported:
            return .bluetoothUnsupported
        default:
            return .bluetoothUnavailable
        }
    }

    private func normalizeName(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "BLDLOCK", with: "BLELOCK")
            .replacingOccurrences(of: "CLELOCK", with: "BLELOCK")
    }

    private func registerDevice(_ peripheral: CBPeripheral) -> BLEDeviceLite {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? "Unknown"
        devicesByID[id] = peripheral

        let device = BLEDeviceLite(id: id, name: name)
        if !discoveredDevices.contains(device) {
            discoveredDevices.append(device)
        }
        return device
    }

    private func completeScanIfMatched(device: BLEDeviceLite) {
        guard let target = targetNormalizedName else { return }
        if normalizeName(device.name) == target {
            central.stopScan()
            targetNormalizedName = nil
            scanContinuation?.resume(returning: device)
            scanContinuation = nil
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.handleStateUpdate(central.state)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let device = registerDevice(peripheral)
        completeScanIfMatched(device: device)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? BLEManagerError.connectFailed)
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        currentPeripheral = nil
        writeCharacteristic = nil
        readCharacteristic = nil
    }
}

@MainActor
private extension BLEManager {
    func handleStateUpdate(_ state: CBManagerState) {
        bluetoothState = state
        stateUpdateContinuation?.resume()
        stateUpdateContinuation = nil
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            discoverContinuation?.resume(throwing: error)
            discoverContinuation = nil
            return
        }

        guard let services = peripheral.services,
              let service = services.first else {
            discoverContinuation?.resume(throwing: BLEManagerError.serviceNotFound)
            discoverContinuation = nil
            return
        }

        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            discoverContinuation?.resume(throwing: error)
            discoverContinuation = nil
            return
        }

        guard let chars = service.characteristics else {
            discoverContinuation?.resume(throwing: BLEManagerError.characteristicNotFound)
            discoverContinuation = nil
            return
        }

        writeCharacteristic = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) })
        readCharacteristic = chars.first(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) })

        guard let readCharacteristic else {
            discoverContinuation?.resume(throwing: BLEManagerError.characteristicNotFound)
            discoverContinuation = nil
            return
        }

        peripheral.setNotifyValue(true, for: readCharacteristic)

        guard writeCharacteristic != nil else {
            discoverContinuation?.resume(throwing: BLEManagerError.characteristicNotFound)
            discoverContinuation = nil
            return
        }

        discoverContinuation?.resume()
        discoverContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            writeContinuation?.resume(throwing: error)
        } else {
            writeContinuation?.resume()
        }
        writeContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }

        readBuffer.append(value)
        let frames = FrameCodec.extractFrames(buffer: &readBuffer)
        for frame in frames {
            guard let cmdID = try? FrameCodec.commandID(from: frame) else { continue }
            if let waiter = waiters.removeValue(forKey: cmdID) {
                waiter.resume(returning: frame)
            }
        }
    }
}

private func withTimeout<T>(seconds: TimeInterval, timeoutError: Error, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw timeoutError
        }

        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
