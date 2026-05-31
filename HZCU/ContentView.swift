//
//  ContentView.swift
//  HZCU
//
//  Created by DataNeko.IO on 2026/05/31.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        TabView {
            LockPageView()
                .tabItem {
                    Label("开锁", systemImage: "lock.circle")
                }

            ConfigPageView()
                .tabItem {
                    Label("配置", systemImage: "gear")
                }

            KeysPageView()
                .tabItem {
                    Label("钥匙", systemImage: "key")
                }

            DeveloperPageView()
                .tabItem {
                    Label("开发", systemImage: "terminal")
                }
        }
        .overlay(alignment: .topTrailing) {
            if app.isBusy {
                ProgressView()
                    .padding(10)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}

private struct LockPageView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("当前状态") {
                    HStack {
                        Text("流程")
                        Spacer()
                        Text(app.lockPhaseTitle)
                            .foregroundStyle(color(for: app.lockPhase))
                    }

                    if let key = app.activeKey {
                        LabeledContent("当前钥匙", value: key.label)
                        LabeledContent("蓝牙 ID", value: key.bluetoothID)
                        LabeledContent("Key ID", value: key.keyID)
                        LabeledContent("记录的物理状态", value: app.lockStateMap[key.id] ?? "未知")
                    } else {
                        Text("当前没有激活钥匙，请先到“钥匙”页添加或激活。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("操作") {
                    Button("一键开锁") {
                        Task { await app.runLockAction(mode: .normal) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.activeKey == nil || app.isBusy)

                    Button("仅开锁") {
                        Task { await app.runLockAction(mode: .openOnly) }
                    }
                    .disabled(app.activeKey == nil || app.isBusy)

                    Button("仅关锁") {
                        Task { await app.runLockAction(mode: .closeOnly) }
                    }
                    .disabled(app.activeKey == nil || app.isBusy)

                    Button("扫描附近全部设备") {
                        Task { await app.scanAllDevices() }
                    }
                    .disabled(app.isBusy)
                }

                if !app.devices.isEmpty {
                    Section("最近扫描结果") {
                        ForEach(app.devices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                Text(device.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("HZCU 门锁")
        }
    }

    private func color(for phase: LockPhase) -> Color {
        switch phase {
        case .opened, .closed: return .green
        case .failed: return .red
        case .scanning, .connecting, .discovering, .authenticating, .autoClosing: return .orange
        case .idle: return .secondary
        }
    }
}

private struct ConfigPageView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    TextField("登录账号", text: $app.config.loginName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    TextField("JSESSIONID 会话", text: $app.config.cookie)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section("自动关锁") {
                    Stepper(value: $app.config.unlockHoldSeconds, in: 1...300) {
                        Text("关锁延迟：\(app.config.unlockHoldSeconds) 秒")
                    }

                    Toggle("自动开锁", isOn: $app.config.autoOpen)
                    Stepper(value: $app.config.autoOpenDelay, in: 10...3600) {
                        Text("自动开锁延迟：\(app.config.autoOpenDelay) 秒")
                    }
                    .disabled(!app.config.autoOpen)

                    Toggle("成功后自动退出", isOn: $app.config.autoExit)
                }

                Section {
                    Button("从后台刷新配置") {
                        Task { await app.refreshFromBackend() }
                    }
                    .disabled(app.config.loginName.isEmpty || app.isBusy)

                    Button("保存本地配置") {
                        app.persist()
                    }
                    .disabled(app.isBusy)
                }
            }
            .navigationTitle("配置")
        }
    }
}

private struct KeysPageView: View {
    @EnvironmentObject private var app: AppState
    @State private var draft = KeyProfile(
        label: "",
        keyID: "",
        bluetoothID: "",
        expireTime: "",
        createTime: ""
    )

    var body: some View {
        NavigationStack {
            List {
                Section("已保存钥匙") {
                    if app.keys.isEmpty {
                        Text("暂无钥匙")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.keys) { key in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(key.label)
                                    .font(.headline)
                                Spacer()
                                if app.activeKeyID == key.id {
                                    Text("已激活")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.green.opacity(0.2), in: Capsule())
                                }
                            }
                            Text("\(key.bluetoothID) | \(key.keyID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("设为激活") {
                                app.setActiveKey(key.id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete(perform: app.deleteKey)
                }

                Section("新增 / 更新钥匙") {
                    TextField("标签", text: $draft.label)
                    TextField("蓝牙 ID", text: $draft.bluetoothID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                    TextField("Key ID（十六进制）", text: $draft.keyID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("到期时间", text: $draft.expireTime)
                    TextField("创建时间", text: $draft.createTime)

                    Button("保存钥匙") {
                        let normalized = KeyProfile(
                            label: draft.label.isEmpty ? draft.bluetoothID : draft.label,
                            keyID: draft.keyID.lowercased(),
                            bluetoothID: draft.bluetoothID,
                            expireTime: draft.expireTime,
                            createTime: draft.createTime,
                            hardVersion: draft.hardVersion,
                            adminFlag: draft.adminFlag,
                            isReverse: draft.isReverse,
                            delayRestore: draft.delayRestore,
                            motorOpen: draft.motorOpen,
                            motorClose: draft.motorClose,
                            openReverseType: draft.openReverseType,
                            serverAddress: draft.serverAddress,
                            cookie: app.config.cookie
                        )
                        app.upsertKey(normalized)
                    }
                    .disabled(draft.bluetoothID.isEmpty || draft.keyID.isEmpty)
                }
            }
            .navigationTitle("钥匙")
        }
    }
}

private struct DeveloperPageView: View {
    @EnvironmentObject private var app: AppState
    @State private var importText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("导入 / 导出") {
                    TextEditor(text: $importText)
                        .frame(minHeight: 120)

                    Button("从 JSON 导入钥匙") {
                        app.importKeys(from: importText)
                    }

                    Button("加载导出 JSON") {
                        importText = app.exportKeysJSON()
                    }
                }

                Section("日志") {
                    if app.logs.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(app.logs.reversed()) { entry in
                        Text(entry.line)
                            .font(.caption.monospaced())
                    }

                    Button("清空日志", role: .destructive) {
                        app.clearLogs()
                    }
                }
            }
            .navigationTitle("开发")
        }
    }
}
