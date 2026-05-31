import Foundation

enum LockPhase: String {
    case idle
    case scanning
    case connecting
    case discovering
    case authenticating
    case opened
    case autoClosing
    case closed
    case failed
}

enum LockActionMode: String {
    case normal
    case openOnly
    case closeOnly
}

enum PCBProfile: String, CaseIterable {
    case ti = "TI"
    case zg = "ZG"

    var serviceUUID: String {
        switch self {
        case .ti: return "f000c0e0-0451-4000-b000-000000000000"
        case .zg: return "0000fff0-0000-1000-8000-00805f9b34fb"
        }
    }

    var writeUUID: String {
        switch self {
        case .ti: return "f000c0e1-0451-4000-b000-000000000000"
        case .zg: return "0000fff2-0000-1000-8000-00805f9b34fb"
        }
    }

    var readUUID: String {
        switch self {
        case .ti: return "f000c0e2-0451-4000-b000-000000000000"
        case .zg: return "0000fff1-0000-1000-8000-00805f9b34fb"
        }
    }
}

struct LockConfig: Codable {
    var loginName: String = ""
    var cookie: String = ""
    var unlockHoldSeconds: Int = 10
    var autoOpen: Bool = false
    var autoOpenDelay: Int = 300
    var autoExit: Bool = false
}

struct KeyProfile: Codable, Identifiable, Equatable {
    var id: String { keyID }

    var label: String
    var keyID: String
    var bluetoothID: String
    var expireTime: String
    var createTime: String
    var hardVersion: String
    var adminFlag: UInt16
    var isReverse: UInt16
    var delayRestore: UInt16
    var motorOpen: UInt16
    var motorClose: UInt16
    var openReverseType: UInt16
    var serverAddress: String
    var cookie: String

    init(
        label: String,
        keyID: String,
        bluetoothID: String,
        expireTime: String,
        createTime: String,
        hardVersion: String = "2.1.xy.N18.220428",
        adminFlag: UInt16 = 0,
        isReverse: UInt16 = 0,
        delayRestore: UInt16 = 0,
        motorOpen: UInt16 = 0,
        motorClose: UInt16 = 0,
        openReverseType: UInt16 = 0,
        serverAddress: String = "csmy.hzcu.edu.cn",
        cookie: String = ""
    ) {
        self.label = label
        self.keyID = keyID
        self.bluetoothID = bluetoothID.uppercased()
        self.expireTime = expireTime
        self.createTime = createTime
        self.hardVersion = hardVersion
        self.adminFlag = adminFlag
        self.isReverse = isReverse
        self.delayRestore = delayRestore
        self.motorOpen = motorOpen
        self.motorClose = motorClose
        self.openReverseType = openReverseType
        self.serverAddress = serverAddress
        self.cookie = cookie
    }
}

struct BLEDeviceLite: Identifiable, Hashable {
    let id: String
    let name: String
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: String
    let message: String

    var line: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "[\(formatter.string(from: timestamp))] [\(level)] \(message)"
    }
}
