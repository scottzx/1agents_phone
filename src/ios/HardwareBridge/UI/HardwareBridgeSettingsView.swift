import SwiftUI

/// Debug/bring-up screen for the agent_link hardware bridge: scan, connect,
/// and watch the BLE + transcription + agent pipeline's live state. This is
/// the entry point that makes HardwareBridgeCoordinator.shared come alive —
/// nothing else in the app touches it, so opening this screen is what first
/// creates the CBCentralManager (and can trigger the Bluetooth permission
/// prompt), not app launch.
struct HardwareBridgeSettingsView: View {
    @ObservedObject private var coordinator = HardwareBridgeCoordinator.shared
    @ObservedObject private var bluetooth = HardwareBridgeCoordinator.shared.bluetooth
    @ObservedObject private var environmentStore = EnvVarStore.shared
    @State private var mossAPIKey = ""
    @State private var keySaveMessage = ""

    var body: some View {
        List {
            Section("Moss 语音") {
                LabeledContent("API Key", value: mossAPIKeyStatus)
                SecureField("粘贴 MOSS_API_KEY", text: $mossAPIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("保存 API Key") { saveMossAPIKey() }
                    .disabled(mossAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !keySaveMessage.isEmpty {
                    Text(keySaveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("仅硬件桥使用；当前测试版内置 Key，手动保存的 Key 会优先使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接状态") {
                LabeledContent("BLE", value: stateLabel)
                LabeledContent("Turn 状态", value: activityLabel)
                Button(bluetooth.state.isReady ? "断开" : "扫描附近设备") {
                    if bluetooth.state.isReady {
                        bluetooth.disconnect()
                    } else {
                        bluetooth.startScanning()
                    }
                }
                if let level = coordinator.batteryLevel {
                    LabeledContent("设备电量", value: "\(level)%\(coordinator.batteryState.map { "（\($0.displayText)）" } ?? "")")
                }
                Button("重置会话") { coordinator.resetSession() }
            }

            Section {
                Picker("语音输出", selection: $coordinator.voiceRoute) {
                    ForEach(HardwareVoiceOutput.Route.allCases) { route in
                        Text(route.displayName).tag(route)
                    }
                }
                if coordinator.voiceRoute != .device, !VoiceOutputPreferences.isEnabled {
                    // The phone fallback goes through VoiceOutputPlayer, which
                    // drops every enqueue while this preference is off — the
                    // failure mode is silence, so it has to be visible here.
                    Label("手机播报需要先在语音设置里打开“朗读回复”，否则回落时无声",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Picker("名册通道", selection: $coordinator.rosterTransport) {
                    ForEach(HardwareBLECentral.RosterTransport.allCases) { transport in
                        Text(transport.displayName).tag(transport)
                    }
                }
            } header: {
                Text("下发通道")
            } footer: {
                Text("连接成功即下发完整会话列表：全部群聊 + 每个 Agent 的单聊，含名称、emoji 与主题色。0x33 单帧上限约 470 字节，装不下整份列表；0x37 分片路线没有该限制（板子已实现）。默认「自动」按体积二选一。")
            }

            if let roster = coordinator.pushedRoster {
                Section("已下发名册") {
                    LabeledContent("版本", value: "rev \(roster.rev)")
                    LabeledContent("会话类型", value: roster.conversation.kind == .group ? "群聊" : "单聊")
                    ForEach(roster.members, id: \.id) { member in
                        HStack {
                            Text(member.emoji)
                            VStack(alignment: .leading) {
                                Text(member.name)
                                if !member.title.isEmpty {
                                    Text(member.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(member.accentColor)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let manifest = bluetooth.latestManifest {
                Section {
                    LabeledContent("能力", value: capabilityText(manifest))
                    ForEach(manifest.endpoints, id: \.id) { endpoint in
                        LabeledContent(endpoint.id) {
                            Text("\(endpoint.dir) · \(endpoint.kind) · \(endpoint.value)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                } header: {
                    Text("设备 I/O 端点（rev \(manifest.rev)）")
                } footer: {
                    Text("由设备通过 0x18 自描述上报。名册与消息下发依赖其中的 roster0 / chat0 / state0 端点。")
                }
            }

            if !coordinator.readings.isEmpty {
                Section("传感器读数") {
                    ForEach(coordinator.readings.sorted(by: { $0.key < $1.key }), id: \.key) { id, value in
                        LabeledContent(id, value: value)
                    }
                }
            }

            if !bluetooth.peripherals.isEmpty, !bluetooth.state.isReady {
                Section("发现的设备") {
                    ForEach(bluetooth.peripherals) { peripheral in
                        Button {
                            bluetooth.connect(to: peripheral.id)
                        } label: {
                            HStack {
                                Text(peripheral.name)
                                Spacer()
                                Text("\(peripheral.rssi) dBm")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !coordinator.lastTranscript.isEmpty || !coordinator.lastReply.isEmpty {
                Section("最近一次") {
                    if !coordinator.lastTranscript.isEmpty {
                        LabeledContent("转写", value: coordinator.lastTranscript)
                    }
                    if !coordinator.lastReply.isEmpty {
                        LabeledContent("回复", value: coordinator.lastReply)
                    }
                }
            }

            Section("日志") {
                // Merged by timestamp, not concatenated. Appending one list to
                // the other and taking the last 60 showed only the tail of the
                // second one: the BLE log alone runs to its own 80-line cap
                // during a single turn, so every coordinator line — the roster
                // pushes, the prompts, the playback results — was cut off and
                // had never once been visible here.
                ForEach(Array(mergedLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .navigationTitle("硬件设备")
    }

    /// Both logs in one chronological view. Each line already starts with
    /// "HH:mm:ss", which sorts correctly as text within a session.
    private var mergedLog: [String] {
        (coordinator.bridgeLog + bluetooth.logLines)
            .sorted { $0.prefix(8) < $1.prefix(8) }
            .suffix(60)
    }

    private func capabilityText(_ manifest: IoManifestAssembler.Manifest) -> String {
        let names = IoManifestAssembler.DeviceCapability.allCases
            .filter { manifest.hasCapability($0) }
            .map(\.displayName)
        return names.isEmpty ? "未声明" : names.joined(separator: "、")
    }

    private var stateLabel: String {
        switch bluetooth.state {
        case .bluetoothUnavailable(let reason): return "不可用（\(reason)）"
        case .idle: return "未连接"
        case .scanning: return "扫描中"
        case .connecting(let name): return "连接中 \(name)"
        case .discovering(let name): return "发现服务 \(name)"
        case .ready(let name): return "已连接 \(name)"
        }
    }

    private var activityLabel: String {
        switch coordinator.activity {
        case .idle: return "空闲"
        case .transcribing: return "转写中"
        case .waitingForAgent: return "等待 Agent"
        case .synthesizing: return "生成语音"
        case .deliveringAudio: return "发送语音到设备"
        case .delivered: return "已回复"
        case .failed(let message): return "失败：\(message)"
        }
    }

    private var hasMossAPIKey: Bool {
        if let value = environmentStore.value(forKey: MossSpeechClient.apiKeyEnvironmentName),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
#if DEBUG
        if !(ProcessInfo.processInfo.environment[MossSpeechClient.apiKeyEnvironmentName] ?? "").isEmpty {
            return true
        }
#endif
        return !MossSpeechClient.bundledTestAPIKey.isEmpty
    }

    private var mossAPIKeyStatus: String {
        if let value = environmentStore.value(forKey: MossSpeechClient.apiKeyEnvironmentName),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "钥匙串"
        }
#if DEBUG
        if !(ProcessInfo.processInfo.environment[MossSpeechClient.apiKeyEnvironmentName] ?? "").isEmpty {
            return "调试环境"
        }
#endif
        return MossSpeechClient.bundledTestAPIKey.isEmpty ? "未配置" : "内置测试 Key"
    }

    private func saveMossAPIKey() {
        let value = mossAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let entry = environmentStore.entries.first(where: { $0.key == MossSpeechClient.apiKeyEnvironmentName }) {
            environmentStore.update(
                id: entry.id,
                key: MossSpeechClient.apiKeyEnvironmentName,
                value: value,
                note: "OJBadge 硬件桥 Moss ASR/TTS"
            )
        } else {
            environmentStore.add(
                key: MossSpeechClient.apiKeyEnvironmentName,
                value: value,
                note: "OJBadge 硬件桥 Moss ASR/TTS"
            )
        }
        mossAPIKey = ""
        keySaveMessage = hasMossAPIKey ? "已保存" : "保存失败，请重试"
    }
}
