#if DEBUG
import Foundation

/// Serves the roster/state payloads over the existing DEBUG JSON-RPC server so
/// the identity path can be exercised with no board attached.
///
/// This is the whole point of keeping `DeviceRosterService` transport-free: the
/// firmware side of 0x37 does not exist yet (the SDK's `on_agent_list` callback
/// is declared but never invoked, and `agent_link_report_selected_agent` is
/// still a `not_ready` stub with a TODO), and the CuiCan board's agent_link is
/// an unwired snapshot. Waiting for both would leave this code untested until
/// the last moment; here the exact bytes that would go on the wire can be
/// inspected today.
enum HardwareBridgeDebugRPC {

    /// `debug.hardware.roster` — the current snapshot plus the frames each
    /// transport would actually emit, so a firmware engineer can diff against
    /// what their parser sees.
    @MainActor
    static func roster(params: [String: Any]) -> Any {
        let coordinator = HardwareBridgeCoordinator.shared

        // Allow driving a hypothetical roster without a live session, which is
        // how the multi-member roundtable case gets exercised before work
        // package A exists.
        if let agentIds = params["agentIds"] as? [String], !agentIds.isEmpty {
            DeviceRosterService.shared.bind(
                conversationId: params["conversationId"] as? String ?? "debug-conversation",
                title: params["title"] as? String ?? "调试会话",
                agentIds: agentIds
            )
        }

        guard let snapshot = DeviceRosterService.shared.snapshot else {
            return ["error": "没有已绑定的名册。传 agentIds 构造一个，或先连接设备。"]
        }

        guard let json = try? DeviceRosterJSON.encode(snapshot) else {
            return ["error": "名册序列化失败"]
        }

        let budget = (params["fragmentBudget"] as? Int) ?? 180
        let fragments = AgentLinkCodec.agentRosterCommands(
            json: json,
            fragmentBudget: budget,
            startingSequence: 0
        )
        let singleFrame = AgentLinkCodec.ioActuateCommand(
            endpointId: DeviceEndpoint.roster,
            args: json,
            sequence: 0
        )

        return [
            "rev": snapshot.rev,
            "conversationKind": snapshot.conversation.kind.rawValue,
            "memberCount": snapshot.members.count,
            "json": String(data: json, encoding: .utf8) ?? "",
            "jsonBytes": json.count,
            "routeA": [
                "endpoint": DeviceEndpoint.roster,
                "commandId": "0x33",
                "frameBytes": singleFrame.count,
                "frameHex": singleFrame.hexString,
                // Route A is one GATT write; anything larger has to use 0x37.
                "fitsOneWrite": singleFrame.count <= budget + AgentLinkCodec.headerSize,
            ],
            "routeB": [
                "commandId": "0x37",
                "fragmentBudget": budget,
                "fragmentCount": fragments.count,
                "fragmentsHex": fragments.map(\.hexString),
            ],
            "pushedToDevice": coordinator.pushedRoster?.rev as Any? ?? NSNull(),
        ]
    }

    /// `debug.hardware.state` — encodes (and, when a device is connected,
    /// sends) one round-screen state transition from DEMO_PRD.md §5.
    @MainActor
    static func state(params: [String: Any]) -> Any {
        guard let raw = params["state"] as? String,
              let state = DeviceRoundtableState(rawValue: raw) else {
            return [
                "error": "未知 state",
                "allowed": DeviceRoundtableState.allCases.map(\.rawValue),
            ]
        }
        let event = DeviceStateEvent(
            state: state,
            name: params["name"] as? String ?? "",
            textBrief: params["textBrief"] as? String ?? ""
        )
        guard let json = try? DeviceRosterJSON.encode(event) else {
            return ["error": "状态事件序列化失败"]
        }
        let frame = AgentLinkCodec.ioActuateCommand(
            endpointId: DeviceEndpoint.state,
            args: json,
            sequence: 0
        )

        var sent = false
        if HardwareBridgeCoordinator.shared.bluetooth.state.isReady {
            HardwareBridgeCoordinator.shared.sendState(
                state,
                name: event.name,
                brief: event.textBrief
            )
            sent = true
        }

        return [
            "endpoint": DeviceEndpoint.state,
            "json": String(data: json, encoding: .utf8) ?? "",
            "frameHex": frame.hexString,
            "sentToDevice": sent,
        ]
    }

    /// `debug.hardware.manifest` — the board's last reassembled self-description.
    @MainActor
    static func manifest() -> Any {
        guard let manifest = HardwareBridgeCoordinator.shared.bluetooth.latestManifest else {
            return ["error": "尚未收到 0x18 I/O manifest（设备未连接，或未注册任何端点）"]
        }
        return [
            "proto": manifest.proto,
            "rev": manifest.rev,
            "caps": manifest.caps,
            "capabilities": IoManifestAssembler.DeviceCapability.allCases
                .filter { manifest.hasCapability($0) }
                .map(\.displayName),
            "endpoints": manifest.endpoints.map { endpoint in
                [
                    "id": endpoint.id,
                    "dir": endpoint.dir,
                    "kind": endpoint.kind,
                    "value": endpoint.value,
                    "llmVisible": endpoint.isLLMVisible,
                ] as [String: Any]
            },
            "rawJSON": manifest.rawJSON,
        ]
    }
}

private extension Data {
    /// Lowercase hex, for pasting into a firmware-side parser test.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
