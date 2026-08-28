import CoreBluetooth
import Foundation

/// Ported from voice_type_hardware/apps/ios/AgentBridge/AgentBridge/Bluetooth/BLECentral.swift,
/// with two additions AgentBridge (a foreground debug shell) doesn't need:
///   - CBCentralManager state restoration, so `bluetooth-central` background
///     mode can cold-relaunch this app on a BLE event and reconnect.
///   - Opening the agent_link record-stream L2CAP CoC (PSM 0x0081) once the
///     GATT control channel is ready, and routing 0x52/0x53 control events
///     into AgentLinkL2CAPReceiver to assemble the streamed PCM16 audio.
struct HardwarePeripheralSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor
final class HardwareBLECentral: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case bluetoothUnavailable(String)
        case idle
        case scanning
        case connecting(String)
        case discovering(String)
        case ready(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    static let restorationIdentifier = "com.1agents.phone.hardwarebridge"

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var peripherals: [HardwarePeripheralSummary] = []
    @Published private(set) var logLines: [String] = []

    /// Fired for the simple 0x04 PromptEvent path (device sends ready-made text).
    var onPrompt: ((String) -> Void)?
    /// Fired once a real-time ASR audio stream finishes (0x53 StreamEnd) with
    /// the assembled raw PCM16 (16kHz mono) bytes and whether it was truncated.
    var onAudioStreamFinished: ((Data, Bool) -> Void)?

    private static let identityService = CBUUID(string: "AB883C83-3FCC-4A0F-A951-E18D0C944DA4")
    private static let controlService = CBUUID(string: "FFC0")
    private static let commandCharacteristic = CBUUID(string: "FFC1")
    private static let eventCharacteristic = CBUUID(string: "FFC4")

    private var central: CBCentralManager?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var commandChannel: CBCharacteristic?
    private var eventChannel: CBCharacteristic?
    private var scanRequested = false
    private var l2capChannelRequested = false

    let l2capReceiver = AgentLinkL2CAPReceiver()

    override init() {
        super.init()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
            )
        } else {
            state = .bluetoothUnavailable("单元测试环境")
        }
    }

    func startScanning() {
        scanRequested = true
        peripherals.removeAll()
        discovered.removeAll()
        guard let central, central.state == .poweredOn else {
            appendLog("等待系统蓝牙就绪")
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.identityService], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        appendLog("扫描 agent_link 身份 UUID")
    }

    func stopScanning() {
        scanRequested = false
        central?.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(to id: UUID) {
        guard let peripheral = discovered[id] else { return }
        stopScanning()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        state = .connecting(displayName(peripheral))
        appendLog("连接 \(displayName(peripheral))")
        central?.connect(peripheral)
    }

    func disconnect() {
        if let connectedPeripheral {
            central?.cancelPeripheralConnection(connectedPeripheral)
        }
        resetConnection()
    }

    func sendScreenText(_ text: String, sequence: UInt8) throws {
        guard let peripheral = connectedPeripheral,
              let commandChannel,
              state.isReady else {
            throw BLEError.notReady
        }
        let data = AgentLinkCodec.screenTextCommand(text, sequence: sequence)
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw BLEError.messageTooLarge(data.count)
        }
        peripheral.writeValue(data, for: commandChannel, type: .withResponse)
        appendLog("下发 screen0：\(text)")
    }

    private func resetConnection() {
        connectedPeripheral = nil
        commandChannel = nil
        eventChannel = nil
        l2capChannelRequested = false
        l2capReceiver.detach()
        state = .idle
    }

    private func displayName(_ peripheral: CBPeripheral) -> String {
        peripheral.name ?? "未命名设备"
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("\(formatter.string(from: Date()))  \(text)")
        if logLines.count > 80 { logLines.removeFirst(logLines.count - 80) }
        print("[HardwareBridge.BLE] \(text)")
    }

    enum BLEError: LocalizedError {
        case notReady
        case messageTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .notReady: return "BLE 设备尚未就绪"
            case .messageTooLarge(let bytes): return "BLE 消息过长（\(bytes) 字节）"
            }
        }
    }
}

extension HardwareBLECentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .idle
            appendLog("系统蓝牙已就绪")
            if scanRequested { startScanning() }
        case .poweredOff: state = .bluetoothUnavailable("已关闭")
        case .unauthorized: state = .bluetoothUnavailable("未授权")
        case .unsupported: state = .bluetoothUnavailable("设备不支持 BLE")
        case .resetting: state = .bluetoothUnavailable("正在重置")
        case .unknown: state = .bluetoothUnavailable("状态未知")
        @unknown default: state = .bluetoothUnavailable("未知状态")
        }
    }

    /// iOS relaunches the app in the background on a BLE event tied to our
    /// restoration identifier; this hands back the peripheral(s) that were
    /// connected/connecting when the app was previously suspended so we can
    /// resume without the user re-pairing.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        appendLog("恢复后台 BLE 状态")
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let peripheral = restored.first else { return }
        discovered[peripheral.identifier] = peripheral
        connectedPeripheral = peripheral
        peripheral.delegate = self
        state = .discovering(displayName(peripheral))
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.controlService])
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discovered[peripheral.identifier] = peripheral
        let summary = HardwarePeripheralSummary(
            id: peripheral.identifier,
            name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "未命名设备",
            rssi: RSSI.intValue
        )
        if let index = peripherals.firstIndex(where: { $0.id == summary.id }) {
            peripherals[index] = summary
        } else {
            peripherals.append(summary)
            appendLog("发现 \(summary.name) RSSI \(summary.rssi)")
        }
        peripherals.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering(displayName(peripheral))
        appendLog("BLE 已连接，读取服务")
        peripheral.discoverServices([Self.controlService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        appendLog("连接失败：\(error?.localizedDescription ?? "未知错误")")
        resetConnection()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        appendLog("设备已断开\(error.map { "：\($0.localizedDescription)" } ?? "")")
        resetConnection()
    }
}

extension HardwareBLECentral: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            appendLog("读取服务失败：\(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.controlService }) else {
            appendLog("设备没有 FFC0 服务")
            return
        }
        peripheral.discoverCharacteristics(
            [Self.commandCharacteristic, Self.eventCharacteristic],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            appendLog("读取特征失败：\(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.commandCharacteristic:
                commandChannel = characteristic
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            case Self.eventCharacteristic:
                eventChannel = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        updateReadyState(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            appendLog("订阅 \(characteristic.uuid) 失败：\(error.localizedDescription)")
            return
        }
        appendLog("已订阅 \(characteristic.uuid)")
        updateReadyState(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            appendLog("接收失败：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        guard characteristic.uuid == Self.eventCharacteristic else {
            if characteristic.uuid == Self.commandCharacteristic {
                if let frame = try? AgentLinkCodec.decode(data) {
                    appendLog("收到命令响应 0x\(String(frame.identifier, radix: 16))")
                }
            }
            return
        }
        handleEvent(data)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            appendLog("BLE 写入失败：\(error.localizedDescription)")
        } else {
            appendLog("BLE 写入成功")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error {
            appendLog("L2CAP 通道打开失败：\(error.localizedDescription)")
            l2capChannelRequested = false
            return
        }
        guard let channel else { return }
        l2capReceiver.attach(channel)
        appendLog("L2CAP 音频通道已打开 (PSM 0x\(String(AgentLinkL2CAPReceiver.psm, radix: 16)))")
    }

    private func handleEvent(_ data: Data) {
        do {
            if let prompt = try AgentLinkCodec.prompt(from: data) {
                appendLog("收到 Prompt：\(prompt)")
                onPrompt?(prompt)
                return
            }
            if let start = try AgentLinkCodec.streamStart(from: data) {
                appendLog("音频流开始：\(start.name)")
                l2capReceiver.streamStarted()
                return
            }
            if let end = try AgentLinkCodec.streamEnd(from: data) {
                appendLog("音频流结束：\(end.validBytes) 字节，truncated=\(end.isTruncated)")
                Task { [weak self] in
                    guard let self else { return }
                    guard let audio = await self.l2capReceiver.streamEnded(validBytes: end.validBytes) else { return }
                    await MainActor.run {
                        self.onAudioStreamFinished?(audio, end.isTruncated)
                    }
                }
                return
            }
        } catch {
            appendLog("忽略无效 agent_link 帧：\(error.localizedDescription)")
        }
    }

    private func updateReadyState(for peripheral: CBPeripheral) {
        guard commandChannel != nil,
              let eventChannel,
              eventChannel.isNotifying else { return }
        state = .ready(displayName(peripheral))
        appendLog("agent_link 控制通道已就绪")
        openL2CAPChannelIfNeeded(for: peripheral)
    }

    private func openL2CAPChannelIfNeeded(for peripheral: CBPeripheral) {
        guard !l2capChannelRequested else { return }
        l2capChannelRequested = true
        appendLog("请求打开 L2CAP 通道 PSM 0x\(String(AgentLinkL2CAPReceiver.psm, radix: 16))")
        peripheral.openL2CAPChannel(CBL2CAPPSM(AgentLinkL2CAPReceiver.psm))
    }
}
