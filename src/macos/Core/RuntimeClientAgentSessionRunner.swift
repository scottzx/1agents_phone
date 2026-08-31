import Foundation
import MinisAgentContracts

/// macOS implementation of the same AgentKit runner contract used by the iOS
/// group orchestrator. It keeps desktop presentation code on RuntimeClient and
/// never creates an Agent ViewModel or writes the database directly.
@MainActor
final class RuntimeClientAgentSessionRunner: AgentSessionRunning {
    private let client: any RuntimeClient

    init(client: any RuntimeClient) {
        self.client = client
    }

    func createSession(_ request: AgentSessionCreateRequest) async -> String? {
        var payload: [String: JSONValue] = [
            "title": .string(request.title ?? request.spawnTitle ?? "New conversation"),
            "source": .string(request.source),
            "role": .string(request.role)
        ]
        if let agentId = request.agentId { payload["agentId"] = .string(agentId) }
        if let groupId = request.groupId { payload["groupId"] = .string(groupId) }
        if let parent = request.parentSessionId { payload["parentSessionId"] = .string(parent) }
        do {
            let events = try await client.request(RuntimeRequest(method: "session.create", payload: .object(payload)))
            return events.last(where: { $0.name == "session.created" })?.sessionID
        } catch {
            return nil
        }
    }

    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult {
        do {
            let events = try await client.request(
                RuntimeRequest(
                    method: "session.send",
                    sessionID: request.sessionId,
                    payload: .object(["text": .string(request.prompt)])
                )
            )
            if let cancelled = events.last(where: { $0.name == "session.updated" }), cancelled.error != nil {
                return AgentSessionRunResult(text: nil, accepted: true, timedOut: false, cancelled: true)
            }
            let record = events.reversed().compactMap { event -> RuntimeMessageRecord? in
                guard event.name == "message.completed", let payload = event.payload else { return nil }
                return try? payload.decoded(RuntimeMessageRecord.self)
            }.first
            return AgentSessionRunResult(text: record?.text, accepted: true, timedOut: false, cancelled: false)
        } catch is CancellationError {
            return AgentSessionRunResult(text: nil, accepted: true, timedOut: false, cancelled: true)
        } catch {
            return .rejected
        }
    }

    func cancel(sessionId: String) {
        Task { try? await client.request(RuntimeRequest(method: "session.cancel", sessionID: sessionId)) }
    }

    func status(sessionId: String) async -> AgentSessionStatus {
        guard let events = try? await client.request(RuntimeRequest(method: "runtime.snapshot")),
              let payload = events.last(where: { $0.name == "runtime.snapshot" })?.payload,
              let snapshot = try? payload.decoded(RuntimeSnapshot.self),
              let state = snapshot.states[sessionId] else { return AgentSessionStatus(isRunning: false) }
        let running = [RuntimeState.queued, .thinking, .runningTool, .waitingApproval, .speakingInGroup].contains(state)
        let opened = try? await client.request(RuntimeRequest(method: "session.open", sessionID: sessionId))
        let messages: [RuntimeMessageRecord] = {
            guard case .object(let object)? = opened?.last?.payload, let value = object["messages"] else { return [] }
            return (try? value.decoded([RuntimeMessageRecord].self)) ?? []
        }()
        return AgentSessionStatus(
            isRunning: running,
            lastAssistantText: messages.last(where: { $0.role == .assistant })?.text
        )
    }

    func isRunning(sessionId: String) async -> Bool {
        await status(sessionId: sessionId).isRunning
    }
}
