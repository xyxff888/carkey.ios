import Foundation
import CoreBluetooth

// ============================================================
// CoreBluetooth 控制器：扫描 / 连接 / 发现服务 / 写指令 / 读 RSSI
// 与微信小程序版 utils/ble.js 对应。
//
// ⚠️ 接入真实硬件前，必须把下面三个 UUID 换成你模组固件里实际的
//    Service UUID / 写特征 UUID / 通知特征 UUID。留空时会保持在演示态，
//    界面照常切换但不会向任何设备发指令。
//
// ⚠️ iOS 后台蓝牙限制（很重要）：
//    - 后台扫描必须在 scanForPeripherals 里指定 Service UUID，不能传 nil
//    - 后台扫描回调可能延迟数十秒到数分钟，AllowDuplicatesKey 会被忽略
//    - 用户手动上滑杀掉 App 后，State Restoration 全部失效
//    - 想做可靠的「靠近自动解锁」，让模组同时广播 iBeacon，
//      用 CoreLocation 的 CLBeaconRegion 区域监听来唤醒 App（系统级，
//      杀进程后仍可触发），再用 CoreBluetooth 建立连接完成认证与写指令。
// ============================================================

final class BLEManager: NSObject {

    static let shared = BLEManager()

    // MARK: - 需要按固件替换的配置
    var serviceUUID: CBUUID?
    var writeUUID: CBUUID?
    var notifyUUID: CBUUID?

    // MARK: - 回调
    var onState: ((String) -> Void)?
    var onDevices: (([String]) -> Void)?
    var onRSSI: ((Double) -> Void)?
    var onFrame: ((Data) -> Void)?

    // MARK: - 内部状态
    private var central: CBCentralManager!
    private var found: [CBPeripheral] = []
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var rssiTimer: Timer?

    /// 是否已建立可写连接；为 false 时所有指令停留在演示态
    var isConnected: Bool {
        return peripheral?.state == .connected && writeChar != nil
    }

    private override init() {
        super.init()
        // 带恢复标识，配合 Info.plist 的 bluetooth-central 后台模式
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.carkey.ble.central"]
        )
    }

    // MARK: - 扫描
    func startScan() {
        guard central.state == .poweredOn else {
            onState?("蓝牙未开启")
            return
        }
        found.removeAll()
        // 后台扫描必须指定 Service UUID；未配置时仅前台全扫（演示用）
        let services = serviceUUID.map { [$0] }
        central.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        onState?("正在扫描附近设备")
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(index: Int) {
        guard index >= 0, index < found.count else { return }
        stopScan()
        peripheral = found[index]
        central.connect(found[index], options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    func disconnect() {
        stopRSSI()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
    }

    // MARK: - 指令
    func write(_ data: Data) {
        guard let p = peripheral, let c = writeChar, p.state == .connected else {
            onState?("未连接设备 · 当前为演示模式")
            return
        }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: c, type: type)
    }

    // MARK: - RSSI 循环
    func startRSSI(interval: TimeInterval = 0.8) {
        stopRSSI()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }

    func stopRSSI() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:  onState?("蓝牙已就绪")
        case .poweredOff: onState?("蓝牙已关闭")
        case .unauthorized: onState?("未授权蓝牙权限")
        case .unsupported:  onState?("设备不支持蓝牙")
        default:            onState?("蓝牙不可用")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if !found.contains(where: { $0.identifier == peripheral.identifier }) {
            found.append(peripheral)
            onDevices?(found.map { $0.name ?? "未命名设备" })
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(serviceUUID.map { [$0] })
        onState?("已连接 · 正在发现服务")
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        onState?("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        writeChar = nil
        stopRSSI()
        onState?("连接已断开")
    }

    /// 系统因内存回收终止 App 后，蓝牙事件可在此恢复
    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        if let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = list.first {
            peripheral = p
            p.delegate = self
            onState?("已从后台恢复连接")
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            let wanted = writeUUID.map { [$0] } ?? (notifyUUID.map { [$0] })
            peripheral.discoverCharacteristics(wanted, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                if writeUUID == nil || c.uuid == writeUUID {
                    writeChar = c
                }
            }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        if writeChar != nil {
            onState?("设备就绪")
            startRSSI()
        } else {
            onState?("未找到可写特征 · 请核对 UUID")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber,
                    error: Error?) {
        guard error == nil else { return }
        onRSSI?(RSSI.doubleValue)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let value = characteristic.value {
            onFrame?(value)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            onState?("写入失败：\(e.localizedDescription)")
        }
    }
}
