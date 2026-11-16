import Foundation

/// 距离感应引擎：RSSI → 距离 → 滞回状态机
/// 与微信小程序版 utils/ble.js + engine.js 的逻辑对齐。
///
/// 设计要点：
///  - 2.0 m 解锁 / 4.0 m 上锁，中间是缓冲带，避免在阈值附近反复跳变
///  - 滑动平均平滑 RSSI
///  - 状态改变需持续满足 1.2 s 才真正触发（防抖）
final class ProximityEngine {

    struct Settings {
        var txPower: Double = -59          // 1 m 处标定 RSSI，需按实际模组现场标定
        var pathLoss: Double = 2.0         // 路径损耗指数
        var nearThreshold: Double = 2.0    // 靠近解锁距离
        var farThreshold: Double = 4.0     // 离开关锁距离
        var smoothWindow: Int = 5          // 滑动平均窗口
        var holdMs: Int = 1200             // 状态持续时长
        var autoUnlock: Bool = true
        var autoLock: Bool = true
    }

    enum Zone: Equatable {
        case near, middle, far
    }

    var settings = Settings()
    var onZoneChange: ((Zone) -> Void)?
    var onDistance: ((Double) -> Void)?

    private(set) var zone: Zone = .far
    private var window: [Double] = []
    private var pendingZone: Zone?
    private var pendingSince: Date?

    /// RSSI → 距离（米）
    func distance(fromRSSI rssi: Double) -> Double {
        return pow(10.0, (settings.txPower - rssi) / (10.0 * settings.pathLoss))
    }

    /// 喂入一次 RSSI 采样，返回平滑后的距离
    @discardableResult
    func feed(rssi: Double) -> Double {
        let d = distance(fromRSSI: rssi)
        window.append(d)
        let cap = max(1, settings.smoothWindow)
        if window.count > cap {
            window.removeFirst(window.count - cap)
        }
        let avg = window.reduce(0.0, +) / Double(window.count)
        onDistance?(avg)
        evaluate(avg)
        return avg
    }

    private func evaluate(_ distance: Double) {
        let next: Zone
        if distance <= settings.nearThreshold {
            next = .near
        } else if distance >= settings.farThreshold {
            next = .far
        } else {
            next = .middle
        }

        // middle 是缓冲带：清除待决状态，但不改变当前 zone
        guard next != .middle, next != zone else {
            pendingZone = nil
            pendingSince = nil
            return
        }

        if pendingZone != next {
            pendingZone = next
            pendingSince = Date()
            return
        }

        let elapsed = Date().timeIntervalSince(pendingSince ?? Date()) * 1000.0
        if elapsed >= Double(settings.holdMs) {
            zone = next
            pendingZone = nil
            pendingSince = nil
            onZoneChange?(next)
        }
    }

    func reset() {
        window.removeAll()
        zone = .far
        pendingZone = nil
        pendingSince = nil
    }
}
