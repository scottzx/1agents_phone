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

    var body: some View {
        List {
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
                Button("重置会话") { coordinator.resetSession() }
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
                ForEach(Array((coordinator.bridgeLog + bluetooth.logLines).suffix(60).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .navigationTitle("硬件设备")
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
        case .delivered: return "已回复"
        case .failed(let message): return "失败：\(message)"
        }
    }
}
