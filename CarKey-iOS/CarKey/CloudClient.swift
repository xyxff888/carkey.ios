import Foundation

// ============================================================
// 4G 云端下发通道
//
// 链路：App → 业务云 / API 网关 → 控制板（板载 4G，MQTT 长连接）→ 继电器
// 与微信小程序版 utils/cloud.js 对应。
//
// 控制板自带 4G 与 BLE，手机不直接连板子的蜂窝网络。
// 4G 是唯一能控制「启动 / 后备箱 / 备用路」的通道。
//
// ⚠️ 接入前把 apiBase 换成你的 HTTPS 接口地址；留空时 4G 保持演示态。
// ⚠️ 云端必须做：用户-设备绑定校验、nonce / 时间戳防重放、频率限制、审计日志。
// ============================================================

final class CloudClient {

    static let shared = CloudClient()

    var apiBase: String = ""
    var token: String = ""
    var deviceId: String = ""

    private func post(_ path: String, _ body: [String: Any],
                      completion: @escaping (Bool, String) -> Void) {
        guard !apiBase.isEmpty, let url = URL(string: apiBase + path) else {
            completion(false, "未配置云端地址 · 演示模式")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var payload = body
        payload["deviceId"] = deviceId
        payload["ts"] = Int(Date().timeIntervalSince1970)
        payload["nonce"] = UUID().uuidString
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let e = error { completion(false, e.localizedDescription); return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion((200..<300).contains(code), "HTTP \(code)")
            }
        }.resume()
    }

    /// 下发一条继电器触发指令
    func trigger(relay: RelayChannel, source: RelaySource, off: Bool, frameHex: String,
                 completion: @escaping (Bool, String) -> Void) {
        post("/v1/relay/trigger", [
            "relayId": relay.id,
            "mode": off ? "off" : relay.mode,
            "durationMs": relay.modeEnum == .pulse ? relay.duration : 0,
            "source": source.rawValue,
            "frameHex": frameHex,
            "channel": "4g"
        ], completion: completion)
    }

    /// 批量下发 6 路配置
    func pushConfig(_ list: [RelayChannel], frameHex: String,
                    completion: @escaping (Bool, String) -> Void) {
        let arr: [[String: Any]] = list.map { r in
            return [
                "id": r.id, "name": r.name, "note": r.note, "action": r.action,
                "mode": r.mode, "durationMs": r.duration,
                "enabled": r.enabled, "sources": r.sources
            ]
        }
        post("/v1/relay/config", ["relays": arr, "frameHex": frameHex, "channel": "4g"],
             completion: completion)
    }
}
