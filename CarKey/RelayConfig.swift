import Foundation

// ============================================================
// 6 路继电器配置模型 + 三通道权限矩阵
// 与微信小程序版 utils/relays.js 完全一致。
//
// 原理：车钥匙留在车上，继电器触点并接在钥匙按键两端。
//   「短接通 500 ms」= 模拟按一下按键 → 钥匙自己发射频 → 原车执行。
//   脉冲由板载固件本地计时执行，App 只下发一条指令。
//
// 权限（固件与云端也要各自校验）：
//   4G 远程   → 全部 6 路
//   NFC 卡片  → 仅 1、2 路
//   蓝牙距离  → 仅 1、2 路（靠近解锁 / 离开关锁）
// ============================================================

enum RelaySource: String, CaseIterable {
    case g4  = "4g"
    case nfc = "nfc"
    case ble = "ble"

    var label: String {
        switch self {
        case .g4:  return "4G 远程"
        case .nfc: return "NFC 卡片"
        case .ble: return "蓝牙距离"
        }
    }

    /// 该通道最多能碰哪几路（硬约束）
    var allowedChannels: Set<Int> {
        switch self {
        case .g4:  return [1, 2, 3, 4, 5, 6]
        case .nfc: return [1, 2]
        case .ble: return [1, 2]
        }
    }
}

enum RelayMode: String {
    case pulse = "pulse"   // 短接通：吸合 duration 毫秒后自动断开
    case latch = "latch"   // 长接通：保持吸合直到手动断开
}

enum RelayAction: String, CaseIterable {
    case unlock, lock, start, trunk, spare, custom

    var label: String {
        switch self {
        case .unlock: return "开锁"
        case .lock:   return "关锁"
        case .start:  return "启动"
        case .trunk:  return "开后备箱"
        case .spare:  return "备用"
        case .custom: return "自定义"
        }
    }
}

struct RelayChannel: Codable, Equatable {
    var id: Int
    var name: String
    var note: String
    var action: String
    var mode: String
    var duration: Int          // 毫秒，短接通有效
    var enabled: Bool
    var sources: [String]      // ["4g", "nfc", "ble"]

    var modeEnum: RelayMode { mode == "latch" ? .latch : .pulse }

    var modeText: String {
        if modeEnum == .pulse {
            return String(format: "短接通 %.2f s", Double(duration) / 1000.0)
        }
        return "长接通 · 保持吸合"
    }
}

final class RelayConfig {

    static let shared = RelayConfig()
    private let key = "ck_relays_v2"

    static let defaults: [RelayChannel] = [
        RelayChannel(id: 1, name: "开锁",     note: "短按原车钥匙解锁键",   action: "unlock", mode: "pulse", duration: 500, enabled: true,  sources: ["4g", "nfc", "ble"]),
        RelayChannel(id: 2, name: "关锁",     note: "短按原车钥匙上锁键",   action: "lock",   mode: "pulse", duration: 500, enabled: true,  sources: ["4g", "nfc", "ble"]),
        RelayChannel(id: 3, name: "启动",     note: "点动启动 / 点火回路",   action: "start",  mode: "pulse", duration: 800, enabled: true,  sources: ["4g"]),
        RelayChannel(id: 4, name: "开后备箱", note: "短按原车钥匙后备箱键", action: "trunk",  mode: "pulse", duration: 500, enabled: true,  sources: ["4g"]),
        RelayChannel(id: 5, name: "备用 1",   note: "预留，可自定义动作",   action: "spare",  mode: "pulse", duration: 500, enabled: false, sources: ["4g"]),
        RelayChannel(id: 6, name: "备用 2",   note: "预留，可自定义动作",   action: "spare",  mode: "pulse", duration: 500, enabled: false, sources: ["4g"])
    ]

    private(set) var channels: [RelayChannel] = []

    private init() { channels = load() }

    private func load() -> [RelayChannel] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RelayChannel].self, from: data) else {
            return RelayConfig.defaults
        }
        return sanitize(list)
    }

    /// 清洗外部数据（UserDefaults / 界面传回都可能不可信）
    func sanitize(_ list: [RelayChannel]) -> [RelayChannel] {
        return RelayConfig.defaults.map { def in
            guard let r = list.first(where: { $0.id == def.id }) else { return def }
            var src = r.sources.filter { k in
                guard let s = RelaySource(rawValue: k) else { return false }
                return s.allowedChannels.contains(def.id)
            }
            if src.isEmpty { src = ["4g"] }
            let validAction = RelayAction(rawValue: r.action) != nil ? r.action : def.action
            return RelayChannel(
                id: def.id,
                name: String(r.name.prefix(16)),
                note: String(r.note.prefix(40)),
                action: validAction,
                mode: r.mode == "latch" ? "latch" : "pulse",
                duration: min(5000, max(100, r.duration)),
                enabled: r.enabled,
                sources: src
            )
        }
    }

    func update(_ list: [RelayChannel]) {
        channels = sanitize(list)
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        channels = RelayConfig.defaults
    }

    func byId(_ id: Int) -> RelayChannel? {
        return channels.first { $0.id == id }
    }

    func byAction(_ action: String, source: RelaySource) -> RelayChannel? {
        return channels.first { $0.action == action && canTrigger($0, source: source) }
    }

    /// 权限校验：硬约束 + 用户配置 + 启用状态
    func canTrigger(_ r: RelayChannel, source: RelaySource) -> Bool {
        guard r.enabled else { return false }
        guard source.allowedChannels.contains(r.id) else { return false }
        return r.sources.contains(source.rawValue)
    }

    var enabledCount: Int { channels.filter { $0.enabled }.count }
}
