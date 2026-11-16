import Foundation
import WebKit

// ============================================================
// JS ↔ 原生 消息桥（6 路继电器点动版）
//
// 界面（index.html）通过 CustomEvent 下发，WKWebView 脚本转成
// window.webkit.messageHandlers.carkey.postMessage(...)，这里统一分发：
//   pulse          → 校验权限 → 构造帧 → BLE / 4G 下发
//   config         → 保存 6 路配置 → 下发 CONFIG 帧
//   saveProximity  → 更新距离引擎参数
//   scan / nfc / switch → 扫描 / 读卡 / 开关
//
// 权限硬约束：NFC 与蓝牙距离只能触发继电器 1、2，
// 4G 可触发全部 6 路。固件与云端仍须各自再校验一次。
// ============================================================

final class CarKeyBridge: NSObject, WKScriptMessageHandler {

    static let shared = CarKeyBridge()

    weak var webView: WKWebView?

    private let proto = RelayProtocol()
    private let config = RelayConfig.shared
    private let proximity = ProximityEngine()

    func attach(_ webView: WKWebView) {
        self.webView = webView

        BLEManager.shared.onRSSI = { [weak self] rssi in
            _ = self?.proximity.feed(rssi: rssi)
        }
        BLEManager.shared.onDevices = { [weak self] names in
            self?.emit(["type": "devices", "names": names])
        }
        BLEManager.shared.onState = { [weak self] text in
            self?.emit(["type": "log", "text": text])
        }
        BLEManager.shared.onFrame = { [weak self] data in
            guard let parsed = self?.proto.parse(data) else { return }
            // ACK 只代表继电器动作完成，不代表车锁状态，不用于改界面锁态
            self?.emit(["type": "frame", "cmd": Int(parsed.cmd),
                        "channel": Int(parsed.channel), "state": Int(parsed.result)])
        }

        proximity.onDistance = { [weak self] d in
            self?.emit(["type": "distance", "value": String(format: "%.2f", d)])
        }
        // 距离感应：靠近 → 继电器 1（开锁），离开 → 继电器 2（关锁）
        proximity.onZoneChange = { [weak self] zone in
            guard let cfg = self?.config else { return }
            switch zone {
            case .near:
                guard self?.proximity.settings.autoUnlock == true else { return }
                if let r = cfg.byAction("unlock", source: .ble) {
                    self?.send(relay: r, source: .ble, label: "靠近自动解锁")
                }
            case .far:
                guard self?.proximity.settings.autoLock == true else { return }
                if let r = cfg.byAction("lock", source: .ble) {
                    self?.send(relay: r, source: .ble, label: "离开关锁")
                }
            case .middle:
                break
            }
        }

        NFCManager.shared.onPayload = { [weak self] text in
            self?.emit(["type": "toast", "text": "NFC 卡片已读取 · " + text])
            // NFC 只允许开锁 / 关锁两路
            if let r = RelayConfig.shared.byAction("unlock", source: .nfc) {
                self?.send(relay: r, source: .nfc, label: "NFC 解锁")
            }
        }
        NFCManager.shared.onError = { [weak self] text in
            self?.emit(["type": "toast", "text": text])
        }
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {

        case "pulse":
            let id = intValue(body["id"]) ?? 1
            let src = RelaySource(rawValue: (body["source"] as? String) ?? "4g") ?? .g4
            guard let r = config.byId(id) else {
                emit(["type": "toast", "text": "继电器 \(id) 不存在"]); return
            }
            guard r.enabled else {
                emit(["type": "toast", "text": "继电器 \(id) 未启用，请先在设置里开启"]); return
            }
            guard config.canTrigger(r, source: src) else {
                emit(["type": "toast", "text": "\(src.label) 无权触发继电器 \(id) · 仅开锁 / 关锁可用"]); return
            }
            send(relay: r, source: src, label: nil)

        case "config":
            // 界面传回 6 路配置（字典数组）→ 落盘 → 下发 CONFIG 帧
            if let raw = body["relays"] as? [[String: Any]] {
                let list = raw.compactMap { dict -> RelayChannel? in
                    guard let id = dict["id"] as? Int else { return nil }
                    return RelayChannel(
                        id: id,
                        name: (dict["name"] as? String) ?? "",
                        note: (dict["note"] as? String) ?? "",
                        action: (dict["action"] as? String) ?? "custom",
                        mode: (dict["mode"] as? String) ?? "pulse",
                        duration: (dict["duration"] as? Int) ?? 500,
                        enabled: (dict["enabled"] as? Bool) ?? true,
                        sources: (dict["sources"] as? [String]) ?? ["4g"]
                    )
                }
                config.update(list)
                let frame = proto.buildConfig(config.channels)
                if BLEManager.shared.isConnected { BLEManager.shared.write(frame) }
                if !CloudClient.shared.apiBase.isEmpty {
                    CloudClient.shared.pushConfig(config.channels, frameHex: proto.hex(frame)) { _, _ in }
                } else {
                    NSLog("[CarKey] 配置已保存，帧 = \(proto.hex(frame))（演示模式）")
                }
            }

        case "saveProximity":
            if let near = doubleValue(body["near"]) { proximity.settings.nearThreshold = near }
            if let far = doubleValue(body["far"]) { proximity.settings.farThreshold = far }
            if let smooth = intValue(body["smooth"]) { proximity.settings.smoothWindow = smooth }
            if let au = body["autoUnlock"] as? Bool { proximity.settings.autoUnlock = au }
            if let al = body["autoLock"] as? Bool { proximity.settings.autoLock = al }
            proximity.reset()
            NSLog("[CarKey] 距离参数已同步: near=\(proximity.settings.nearThreshold) far=\(proximity.settings.farThreshold)")

        case "scan":
            if BLEManager.shared.serviceUUID != nil { BLEManager.shared.startScan() }

        case "nfc":
            NFCManager.shared.begin()

        case "switch":
            let key = body["key"] as? String ?? ""
            let on = body["on"] as? Bool ?? false
            switch key {
            case "autoUnlock": proximity.settings.autoUnlock = on
            case "autoLock":   proximity.settings.autoLock = on
            case "proxMaster":
                if on { BLEManager.shared.startRSSI() } else { BLEManager.shared.stopRSSI() }
            default: break
            }

        default:
            break
        }
    }

    // MARK: - 指令下发
    private func send(relay: RelayChannel, source: RelaySource, label: String?) {
        guard config.canTrigger(relay, source: source) else {
            emit(["type": "toast", "text": "\(source.label) 无权触发继电器 \(relay.id)"])
            return
        }
        let frame = proto.buildTrigger(relay: relay)
        let hex = proto.hex(frame)

        // 板载 BLE 已连则就近下发；否则走 4G（4G 权限更宽）
        if BLEManager.shared.isConnected {
            BLEManager.shared.write(frame)
            NSLog("[CarKey] BLE 触发 继电器 \(relay.id) \(relay.modeText) frame = \(hex)")
            if let label = label { emit(["type": "toast", "text": label + " · 指令已下发"]) }
            return
        }

        if !CloudClient.shared.apiBase.isEmpty {
            CloudClient.shared.trigger(relay: relay, source: source, off: false, frameHex: hex) { [weak self] ok, msg in
                self?.emit(["type": "toast", "text": ok ? "4G 已下发 · 继电器 \(relay.id)" : "下发失败 · " + msg])
            }
            return
        }

        // 演示模式：界面已自行更新回执，这里只记录指令帧，不对外发送
        NSLog("[CarKey] 演示模式 继电器 \(relay.id) \(relay.name) \(relay.modeText) frame = \(hex)")
        if let label = label { emit(["type": "toast", "text": label + " · 演示模式"]) }
    }

    // MARK: - 工具
    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // MARK: - 原生 → JS
    private func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.dispatchEvent(new CustomEvent('carkey-native',{detail:\(json)}));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
