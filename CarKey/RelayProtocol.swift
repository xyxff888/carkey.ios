import Foundation

// ============================================================
// 继电器控制板指令协议（与微信小程序版 utils/protocol.js 完全一致）
//
// 语义：App 只下发「第几路 / 短接通还是长接通 / 多少毫秒」，
//       **脉冲由板载固件本地计时执行**。绝不要由手机发「吸合」
//       再发「断开」两条去拼 0.5 s——4G 延迟 / App 切后台会让
//       继电器长时间吸合，等于一直按住车钥匙。
//
// 帧格式： AA 55 | LEN | CMD | CH | MODE | DUR_H | DUR_L | SEQ | CHK
//   CMD   0x01=TRIGGER 0x10=STATUS 0x20=CONFIG 0x7F=HEARTBEAT
//   CH    通道 1~6
//   MODE  0x01=短接通(pulse) 0x02=长接通吸合 0x03=断开
//   DUR   脉宽 ms（大端，仅短接通有效）
//   SEQ   递增序号
//   CHK   LEN..SEQ 逐字节异或
//
// CONFIG 帧： AA 55 | LEN | 0x20 | SEQ | [CH,MODE,DUR_H,DUR_L,ENABLED]×6 | CHK
//
// 板子回包： AA 55 | LEN | CMD | CH | RESULT | SEQ | CHK
//   RESULT 0=已执行 1=权限拒绝 2=忙 3=该路未启用
//   ⚠️ ACK 只代表继电器动作完成，**不代表车锁已开/已关**。
//
// ⚠️ 固定明文帧 = 抓到一次包就能开车门。量产必须换成双向挑战应答 +
//    滚动码 / 时间戳 + AES 会话密钥，密钥不进 App 包。
// ============================================================

enum RelayCmd: UInt8 {
    case trigger   = 0x01
    case status    = 0x10
    case config    = 0x20
    case heartbeat = 0x7F
}

enum RelayFrameMode: UInt8 {
    case pulse    = 0x01
    case latchOn  = 0x02
    case latchOff = 0x03
}

final class RelayProtocol {

    private var sequence: UInt8 = 0

    private func nextSeq() -> UInt8 {
        sequence = sequence &+ 1
        return sequence
    }

    private func pack(_ body: [UInt8]) -> Data {
        var bytes: [UInt8] = [0xAA, 0x55] + body
        var chk: UInt8 = 0
        for b in body { chk ^= b }
        bytes.append(chk)
        return Data(bytes)
    }

    /// 触发一路继电器（off = 断开长接通）
    func buildTrigger(relay: RelayChannel, off: Bool = false) -> Data {
        let mode: RelayFrameMode = off ? .latchOff
            : (relay.modeEnum == .latch ? .latchOn : .pulse)
        let dur: UInt16 = mode == .pulse
            ? UInt16(min(5000, max(100, relay.duration))) : 0
        let body: [UInt8] = [
            0x08, RelayCmd.trigger.rawValue, UInt8(relay.id), mode.rawValue,
            UInt8((dur >> 8) & 0xFF), UInt8(dur & 0xFF),
            nextSeq()
        ]
        return pack(body)
    }

    func buildStatus() -> Data {
        return pack([0x08, RelayCmd.status.rawValue, 0, 0, 0, 0, nextSeq()])
    }

    /// 批量下发 6 路配置
    func buildConfig(_ list: [RelayChannel]) -> Data {
        var body: [UInt8] = [0x00, RelayCmd.config.rawValue, nextSeq()]
        for r in list.prefix(6) {
            let dur: UInt16 = r.modeEnum == .pulse ? UInt16(min(5000, max(100, r.duration))) : 0
            body.append(contentsOf: [
                UInt8(r.id),
                r.modeEnum == .latch ? RelayFrameMode.latchOn.rawValue : RelayFrameMode.pulse.rawValue,
                UInt8((dur >> 8) & 0xFF), UInt8(dur & 0xFF),
                r.enabled ? 1 : 0
            ])
        }
        body[0] = UInt8(body.count + 1)
        return pack(body)
    }

    /// 解析板子回包
    func parse(_ data: Data) -> (cmd: UInt8, channel: UInt8, result: UInt8)? {
        let v = [UInt8](data)
        guard v.count >= 6, v[0] == 0xAA, v[1] == 0x55 else { return nil }
        var chk: UInt8 = 0
        for i in 2..<(v.count - 1) { chk ^= v[i] }
        guard chk == v[v.count - 1] else { return nil }
        return (v[3], v[4], v[5])
    }

    func hex(_ data: Data) -> String {
        return [UInt8](data).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
