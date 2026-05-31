# HZCU iOS

杭州某校园门锁 iOS 客户端（SwiftUI + CoreBluetooth）。

参考：[安卓版本](https://github.com/Loanio/HZCU-AndroidBLEKey/issues)

本项目复刻了安卓版本的核心能力：
- 一键开锁
- 离线 BLE 开锁
- 自动关锁
- 刷新钥匙配置
- 本地钥匙管理（导入/导出）

## 当前状态

已实现的主要模块：
- 原生多页面 UI：开锁、配置、钥匙、开发
- BLE 管理：扫描、连接、服务发现、通知订阅、分片写入
- 协议层：GetToken / OpenLock / AutoClose、CRC16、帧解析
- 配置刷新：登录 + 拉取钥匙列表
- 本地存储：UserDefaults + Keychain

## 目录结构

- `HZCU/`：主应用源码
  - `ContentView.swift`：主界面和页面结构
  - `AppState.swift`：全局状态与业务编排
  - `BLEManager.swift`：蓝牙扫描/连接/收发
  - `LockProtocolService.swift`：门锁协议流程
  - `ProtocolCodec.swift`：帧打包/CRC/解析
  - `ConfigService.swift`：后端配置刷新
  - `StorageService.swift`：本地持久化
  - `Models.swift`：数据模型
- `HZCUTests/`：单元测试
- `HZCUUITests/`：UI 测试

## 环境要求

- macOS + Xcode（完整版本，不是仅 CommandLineTools）
- iOS 真机（模拟器不支持 CoreBluetooth）
- iOS 18.5+（当前工程配置）

## 运行方式

1. 用 Xcode 打开 `HZCU.xcodeproj`
2. 选择真机作为运行目标
3. 首次运行允许蓝牙权限
4. 在“配置”页面填写：
   - 账号：原系统登录账号（通常为手机号）
   - JSESSIONID：可先留空，刷新时自动更新
5. 点击“从后台刷新配置”
6. 在“开锁”页面执行一键开锁

## 已知问题

### 1) 后端证书/TLS 问题

如果日志出现：
- `A TLS error caused the secure connection to fail`
- `system TLS Trust evaluation failed(-9802)`

通常是服务端证书链或网络路径问题。实践上：
- 移动网络可用时，优先使用移动网络刷新配置
- 校园网环境下可能命中证书异常链路

### 2) 蓝牙不可用

请确认：
- 使用真机运行
- 系统蓝牙已开启
- App 蓝牙权限已允许

## 与 Android 版本行为对齐

- BLE UUID 与协议流程对齐
- 刷新配置逻辑对齐
- 钥匙名称生成逻辑对齐（优先房间信息）

## 免责声明

本项目仅供技术学习与交流，请遵守当地法律法规及相关服务条款，不得用于违法用途。
