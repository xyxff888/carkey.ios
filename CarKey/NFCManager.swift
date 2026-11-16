import Foundation
import CoreNFC

// ============================================================
// CoreNFC 读卡（NDEF）
//
// ⚠️ iOS 侧限制：
//    - 需要 Info.plist 的 NFCReaderUsageDescription
//    - 需要 com.apple.developer.nfc.readersession.formats entitlement
//    - 必须弹出系统读卡会话，不能像安卓那样后台静默感应
//    - TrollStore 安装的未签名 App 上，该 entitlement 是否生效取决于
//      巨魔版本与系统版本，需真机验证；不生效时 NFC 只能作为备用入口
//    - 因此产品定位上，NFC 是备用钥匙，主通道仍是蓝牙 + 4G
// ============================================================

final class NFCManager: NSObject, NFCNDEFReaderSessionDelegate {

    static let shared = NFCManager()

    var onPayload: ((String) -> Void)?
    var onError: ((String) -> Void)?

    /// ⚠️ 默认关闭。TrollStore 安装的未签名 App 通常不带
    /// com.apple.developer.nfc.readersession.formats entitlement，
    /// 此时调用 NFCNDEFReaderSession.begin() 会直接抛异常终止 App。
    /// 确认已在巨魔中为该 App 注入 NFC entitlement 后，再改为 true。
    static var enabled = false

    private var session: NFCNDEFReaderSession?

    var isAvailable: Bool {
        return NFCNDEFReaderSession.readingAvailable
    }

    func begin() {
        guard NFCManager.enabled else {
            // 静默跳过：界面已按演示态提示，不重复打扰
            NSLog("[CarKey] NFC 未启用（需先注入 NFC entitlement）")
            return
        }
        guard isAvailable else {
            onError?("此设备不支持 NFC 读卡")
            return
        }
        let s = NFCNDEFReaderSession(delegate: self,
                                     queue: .main,
                                     invalidateAfterFirstRead: true)
        s.alertMessage = "将 NFC 卡片靠近手机顶部"
        session = s
        s.begin()
    }

    func readerSession(_ session: NFCNDEFReaderSession,
                       didDetectNDEFs messages: [NFCNDEFMessage]) {
        for message in messages {
            for record in message.records {
                if let text = String(data: record.payload, encoding: .utf8) {
                    onPayload?(text)
                }
            }
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession,
                       didInvalidateWithError error: Error) {
        // 200 = 用户主动取消 / 正常结束，不提示
        let code = (error as NSError).code
        if code != 200 {
            onError?(error.localizedDescription)
        }
        self.session = nil
    }
}
