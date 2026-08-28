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
    /// Every decoded event, including the ones with dedicated callbacks below.
    /// The catch-all exists so a new firmware event is observable without
    /// another callback property.
    var onEvent: ((AgentLinkEvent) -> Void)?
    /// 0x18 fragments reassembled and parsed.
    var onManifest: ((IoManifestAssembler.Manifest) -> Void)?
    /// 0x14 PowerStatus.
    var onPowerStatus: ((AgentLinkEvent.PowerState, UInt8) -> Void)?
    /// 0x19 IoReading, already decoded per the endpoint's `agent_val_t`.
    var onReading: ((String, AgentLinkValue) -> Void)?
    /// 0x16 SelectedAgent — the device telling us which agent the user picked
    /// on its own screen.
    var onSelectedAgent: ((UInt8, String) -> Void)?

    /// The board's last reassembled self-description, or nil before the first
    /// 0x18 arrives (a board with no registered endpoints never sends one).
    @Published private(set) var latestManifest: IoManifestAssembler.Manifest?

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
    private var manifestAssembler = IoManifestAssembler()
    /// Sequence counter for frames this class originates (manifest re-fetches,
    /// roster fragments). Kept separate from the coordinator's counter, which
    /// brackets voice sessions; the firmware only uses `sequence` to pair a
    /// response with its command, so two independent counters are fine.
    private var localSequence: UInt8 = 0x80

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
        let data = AgentLinkCodec.screenTextCommand(text, sequence: sequence)
        try sendCommand(data)
        appendLog("下发 screen0：\(text)")
    }

    /// Which wire path a roster push takes.
    ///
    /// Both exist because they have different prerequisites, not because one is
    /// better. Route A needs two `register_io` calls on the board and no SDK
    /// change at all, so it can be brought up while the firmware roadmap is
    /// still moving; route B needs an SDK command handler but carries a roster
    /// of any size.
    enum RosterTransport: String, CaseIterable, Identifiable {
        /// 0x33 IoActuate to the `roster0` endpoint. One frame, so the JSON
        /// must fit the ATT write budget (~470 bytes ≈ 5 members).
        case ioEndpoint
        /// 0x37 SetAgentRoster, fragmented exactly like the firmware's own
        /// 0x18 manifest. No size limit; requires firmware support.
        case fragmentedCommand

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ioEndpoint: return "通用 I/O（0x33，零固件改动）"
            case .fragmentedCommand: return "分片命令（0x37，需固件支持）"
            }
        }
    }

    /// Pushes the roster. Returns the number of frames written.
    ///
    /// Route A refuses rather than truncates when the roster doesn't fit: a
    /// half-parsed roster would leave the device drawing the wrong names, which
    /// is worse than drawing none.
    @discardableResult
    func sendRoster(_ snapshot: DeviceRosterSnapshot, transport: RosterTransport) throws -> Int {
        let json = try DeviceRosterJSON.encode(snapshot)

        switch transport {
        case .ioEndpoint:
            let frame = AgentLinkCodec.ioActuateCommand(
                endpointId: DeviceEndpoint.roster,
                args: json,
                sequence: nextLocalSequence()
            )
            guard frame.count <= writeBudget else {
                throw BLEError.rosterTooLarge(bytes: json.count, budget: rosterJSONBudget)
            }
            try sendCommand(frame)
            appendLog("下发 roster0：rev=\(snapshot.rev)，\(snapshot.members.count) 名成员，\(json.count) 字节")
            return 1

        case .fragmentedCommand:
            let frames = AgentLinkCodec.agentRosterCommands(
                json: json,
                fragmentBudget: fragmentBudget,
                startingSequence: nextLocalSequence(advancing: 0)
            )
            for frame in frames { try sendCommand(frame) }
            localSequence = localSequence &+ UInt8(truncatingIfNeeded: frames.count)
            appendLog("下发 0x37 roster：rev=\(snapshot.rev)，\(json.count) 字节分 \(frames.count) 片")
            return frames.count
        }
    }

    /// Pushes one message with its sender attached, so the device can render
    /// who is speaking without re-reading the roster.
    func sendChatMessage(_ message: DeviceChatMessage) throws {
        let json = try DeviceRosterJSON.encode(message)
        let frame = AgentLinkCodec.ioActuateCommand(
            endpointId: DeviceEndpoint.chat,
            args: json,
            sequence: nextLocalSequence()
        )
        guard frame.count <= writeBudget else {
            throw BLEError.messageTooLarge(frame.count)
        }
        try sendCommand(frame)
        appendLog("下发 chat0：from=\(message.from) seq=\(message.sequence)")
    }

    /// Pushes a roundtable state transition (DEMO_PRD.md §5) so the round
    /// screen can light the node for whoever is speaking.
    func sendStateEvent(_ event: DeviceStateEvent) throws {
        let json = try DeviceRosterJSON.encode(event)
        let frame = AgentLinkCodec.ioActuateCommand(
            endpointId: DeviceEndpoint.state,
            args: json,
            sequence: nextLocalSequence()
        )
        guard frame.count <= writeBudget else {
            throw BLEError.messageTooLarge(frame.count)
        }
        try sendCommand(frame)
        appendLog("下发 state0：\(event.state.rawValue)（\(event.name)）")
    }

    /// 0x34 GetIoManifest. Best-effort: a board with no endpoints answers with
    /// an ACK and no 0x18, which is a valid outcome, so failure only logs.
    func requestIoManifest() {
        manifestAssembler.reset()
        do {
            try sendCommand(AgentLinkCodec.getIoManifestCommand(sequence: nextLocalSequence()))
            appendLog("请求 I/O manifest（0x34）")
        } catch {
            appendLog("请求 manifest 失败：\(error.localizedDescription)")
        }
    }

    /// Largest complete frame a GATT write can carry, or a conservative floor
    /// before a peripheral is attached.
    private var writeBudget: Int {
        connectedPeripheral?.maximumWriteValueLength(for: .withResponse) ?? 180
    }

    /// JSON bytes that fit one 0x33 frame: the write budget minus the 6-byte
    /// agent_link header and the `[id_len][id]` prefix.
    private var rosterJSONBudget: Int {
        max(0, writeBudget - AgentLinkCodec.headerSize - 1 - DeviceEndpoint.roster.utf8.count)
    }

    /// Mirrors the firmware's own fragment arithmetic. `maximumWriteValueLength`
    /// already excludes the 3 bytes of ATT overhead the firmware subtracts, so
    /// only the 6-byte frame header plus 2-byte chunk header come off here.
    private var fragmentBudget: Int {
        AgentLinkCodec.fragmentBudget(attMTU: writeBudget + 3)
    }

    private func nextLocalSequence(advancing: UInt8 = 1) -> UInt8 {
        let current = localSequence
        localSequence = localSequence &+ advancing
        return current
    }

    /// Sends headerless little-endian PCM16/16 kHz/mono to the device speaker.
    /// VoiceReply status 2/3 brackets the bytes on the shared audio L2CAP CoC.
    func sendVoicePCM16(
        _ pcm16: Data,
        sessionID: UInt32,
        startSequence: UInt8,
        endSequence: UInt8
    ) async throws {
        try await beginVoicePCM16(sessionID: sessionID, sequence: startSequence)
        do {
            try await appendVoicePCM16(pcm16)
        } catch {
            try? endVoicePCM16(sessionID: sessionID, sequence: endSequence)
            throw error
        }
        try endVoicePCM16(sessionID: sessionID, sequence: endSequence)
    }

    /// Opens one logical TTS reply while keeping the underlying CoC persistent.
    func beginVoicePCM16(sessionID: UInt32, sequence: UInt8) async throws {
        let start = AgentLinkCodec.voiceReplyCommand(
            sessionID: sessionID,
            status: 2,
            sequence: sequence
        )
        try sendCommand(start)
        l2capReceiver.beginPacedWrite()
        appendLog("TTS 流式下行开始")

        // Let the GATT start command reach the firmware before the independent
        // L2CAP data path begins sending its first SDU.
        try await Task.sleep(for: .milliseconds(80))
    }

    func appendVoicePCM16(_ pcm16: Data) async throws {
        try await l2capReceiver.writePCM16Chunk(pcm16)
    }

    func endVoicePCM16(sessionID: UInt32, sequence: UInt8) throws {
        l2capReceiver.endPacedWrite()
        let end = AgentLinkCodec.voiceReplyCommand(
            sessionID: sessionID,
            status: 3,
            sequence: sequence
        )
        try sendCommand(end)
        appendLog("TTS 流式下行完成")
    }

    private func sendCommand(_ data: Data) throws {
        guard let peripheral = connectedPeripheral,
              let commandChannel,
              state.isReady else {
            throw BLEError.notReady
        }
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw BLEError.messageTooLarge(data.count)
        }
        peripheral.writeValue(data, for: commandChannel, type: .withResponse)
    }

    private func resetConnection() {
        connectedPeripheral = nil
        commandChannel = nil
        eventChannel = nil
        l2capChannelRequested = false
        l2capReceiver.detach()
        // A reconnect renegotiates the MTU and replays the manifest from
        // fragment 0, so nothing from the old link may survive into the new one.
        manifestAssembler.reset()
        latestManifest = nil
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
        /// Route A (0x33 to `roster0`) can only carry one frame. Refusing beats
        /// truncating, which would leave the device showing a partial roster.
        case rosterTooLarge(bytes: Int, budget: Int)

        var errorDescription: String? {
            switch self {
            case .notReady: return "BLE 设备尚未就绪"
            case .messageTooLarge(let bytes): return "BLE 消息过长（\(bytes) 字节）"
            case .rosterTooLarge(let bytes, let budget):
                return "roster \(bytes) 字节超出单帧上限 \(budget) 字节，请改用 0x37 分片路线"
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

    /// Routes one device→App event.
    ///
    /// Previously this tried the prompt decoder, then the two stream decoders,
    /// and returned — so 0x14 battery, 0x18 I/O manifest, 0x19 readings and
    /// 0x1A manifest-changed all arrived and were discarded without a trace.
    /// Now every event decodes into a typed case and reaches `onEvent`, with
    /// the three that drive existing machinery still getting their dedicated
    /// callbacks.
    private func handleEvent(_ data: Data) {
        let event: AgentLinkEvent
        do {
            guard let decoded = try AgentLinkCodec.event(from: data) else { return }
            event = decoded
        } catch {
            appendLog("忽略无效 agent_link 帧：\(error.localizedDescription)")
            return
        }

        appendLog(event.logDescription)

        switch event {
        case .prompt(let text):
            guard !text.isEmpty else { break }
            onPrompt?(text)

        case .recordStreamStart:
            l2capReceiver.streamStarted()

        case .recordStreamEnd(let payload):
            Task { [weak self] in
                guard let self else { return }
                guard let audio = await self.l2capReceiver.streamEnded(validBytes: payload.validBytes) else { return }
                await MainActor.run {
                    self.onAudioStreamFinished?(audio, payload.isTruncated)
                }
            }

        case .ioManifestChunk(let index, let isLast, let fragment):
            switch manifestAssembler.accept(index: index, isLast: isLast, fragment: fragment) {
            case .incomplete:
                break
            case .complete(let json):
                guard let manifest = IoManifestAssembler.parse(json) else {
                    appendLog("I/O manifest JSON 解析失败（\(json.count) 字节）")
                    break
                }
                latestManifest = manifest
                appendLog("I/O manifest 就绪：rev=\(manifest.rev)，\(manifest.endpoints.count) 个端点，能力 \(capabilitySummary(manifest))")
                onManifest?(manifest)
            case .desynchronized(let expected, let received):
                appendLog("manifest 分片乱序（期望 #\(expected)，收到 #\(received)），重新拉取")
                requestIoManifest()
            }

        case .manifestChanged:
            // The board only tells us the revision moved; the content comes
            // from a 0x34 re-fetch.
            requestIoManifest()

        case .powerStatus(let state, let level):
            onPowerStatus?(state, level)

        case .ioReading(let endpointId, let value):
            onReading?(endpointId, value)

        case .selectedAgent(let index, let agentId):
            onSelectedAgent?(index, agentId)

        case .button, .sensor, .wakeword, .imageStreamStart, .imageStreamEnd, .custom, .unknown:
            // No dedicated consumer yet; `onEvent` below still sees these, and
            // the log line above records them.
            break
        }

        onEvent?(event)
    }

    private func capabilitySummary(_ manifest: IoManifestAssembler.Manifest) -> String {
        let names = IoManifestAssembler.DeviceCapability.allCases
            .filter { manifest.hasCapability($0) }
            .map(\.displayName)
        return names.isEmpty ? "无" : names.joined(separator: "/")
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
