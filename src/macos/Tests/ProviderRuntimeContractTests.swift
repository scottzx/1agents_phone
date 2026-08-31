import XCTest
@testable import MinisDesktopCore
import MinisProviderDomain

final class ProviderRuntimeContractTests: XCTestCase {
    func testStoreMigratesLegacyDefaultIntoMultipleProviderRegistry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let legacy = configuration(id: "legacy", model: "legacy-model")
        try await store.setMetadata(legacy, for: "provider.default")

        let migratedIDs = try await store.providerConfigurations().map(\.id)
        XCTAssertEqual(migratedIDs, ["legacy"])

        let secondary = configuration(id: "secondary", model: "secondary-model")
        try await store.upsertProviderConfiguration(secondary)
        let providerIDs = try await store.providerConfigurations().map(\.id)
        let initialDefaultID = try await store.defaultProviderConfiguration()?.id
        XCTAssertEqual(Set(providerIDs), ["legacy", "secondary"])
        XCTAssertEqual(initialDefaultID, "legacy")

        try await store.upsertProviderConfiguration(secondary, makeDefault: true)
        let updatedDefaultID = try await store.defaultProviderConfiguration()?.id
        XCTAssertEqual(updatedDefaultID, "secondary")
        let legacyDefault = try await store.metadata(ProviderConfiguration.self, for: "provider.default")
        XCTAssertEqual(legacyDefault?.id, "secondary")
    }

    func testProviderConfigureAndListSupportMultipleConfigurations() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentRuntime(
            store: try DesktopStore(baseURL: directory),
            credentials: InMemoryCredentialStore(),
            provider: ConfigurationEchoProvider()
        )

        let first = configuration(id: "first", model: "model-a")
        let second = configuration(id: "second", model: "model-b")
        _ = await runtime.handle(RuntimeRequest(method: "provider.configure", payload: .object([
            "configuration": try .encoded(first),
            "apiKey": .string("secret-a"),
            "makeDefault": .bool(true),
        ])))
        _ = await runtime.handle(RuntimeRequest(method: "provider.configure", payload: .object([
            "configuration": try .encoded(second),
            "apiKey": .string("secret-b"),
        ])))

        let events = await runtime.handle(RuntimeRequest(method: "provider.list"))
        let values = try XCTUnwrap(events.last?.payload).decoded([ProviderConfiguration].self)
        XCTAssertEqual(values.map(\.id), ["first", "second"])
        XCTAssertFalse(String(describing: events.last?.payload).contains("secret-a"))
        XCTAssertFalse(String(describing: events.last?.payload).contains("secret-b"))
    }

    func testSessionBindingSelectsProviderAndCanReturnToDefault() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let provider = ConfigurationEchoProvider()
        let runtime = AgentRuntime(store: store, credentials: InMemoryCredentialStore(), provider: provider)
        let primary = configuration(id: "primary", model: "model-a")
        let specialist = configuration(id: "specialist", model: "model-b")
        try await store.upsertProviderConfiguration(primary, makeDefault: true)
        try await store.upsertProviderConfiguration(specialist)

        let created = await runtime.handle(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Bound")])) )
        let sessionID = try XCTUnwrap(created.last?.sessionID)
        let bound = await runtime.handle(RuntimeRequest(
            method: "provider.setSessionBinding",
            sessionID: sessionID,
            payload: .object(["providerId": .string("specialist")])
        ))
        XCTAssertEqual(bound.last?.name, "session.updated")
        let boundProviderID = try await store.conversation(sessionID)?.providerConfigurationID
        XCTAssertEqual(boundProviderID, "specialist")

        _ = await runtime.handle(RuntimeRequest(method: "session.send", sessionID: sessionID, payload: .object(["text": .string("hello")])) )
        let firstRunIDs = await provider.configurationIDs()
        XCTAssertEqual(firstRunIDs, ["specialist"])

        _ = await runtime.handle(RuntimeRequest(
            method: "provider.setSessionBinding",
            sessionID: sessionID,
            payload: .object(["providerId": .null])
        ))
        _ = await runtime.handle(RuntimeRequest(method: "session.send", sessionID: sessionID, payload: .object(["text": .string("again")])) )
        let allRunIDs = await provider.configurationIDs()
        let clearedProviderID = try await store.conversation(sessionID)?.providerConfigurationID
        XCTAssertEqual(allRunIDs, ["specialist", "primary"])
        XCTAssertNil(clearedProviderID)
    }

    func testSessionBindingRejectsUnknownProviderWithoutMutatingSession() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let runtime = AgentRuntime(store: store, credentials: InMemoryCredentialStore(), provider: ConfigurationEchoProvider())
        try await store.upsertProviderConfiguration(configuration(id: "primary"), makeDefault: true)
        let created = await runtime.handle(RuntimeRequest(method: "session.create"))
        let sessionID = try XCTUnwrap(created.last?.sessionID)

        let events = await runtime.handle(RuntimeRequest(
            method: "provider.setSessionBinding",
            sessionID: sessionID,
            payload: .object(["providerId": .string("missing")])
        ))
        XCTAssertEqual(events.last?.name, "runtime.error")
        let persistedProviderID = try await store.conversation(sessionID)?.providerConfigurationID
        XCTAssertNil(persistedProviderID)
    }

    func testProviderTestReportsRealRunnerSuccessAndFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        try await store.upsertProviderConfiguration(configuration(id: "healthy"), makeDefault: true)
        try await store.upsertProviderConfiguration(configuration(id: "broken"))
        let runtime = AgentRuntime(store: store, credentials: InMemoryCredentialStore(), provider: ProviderProbeStub())

        let healthyEvents = await runtime.handle(RuntimeRequest(method: "provider.test", payload: .object(["providerId": .string("healthy")])) )
        let healthy = try XCTUnwrap(healthyEvents.last?.payload).decoded(RuntimeProviderTestResult.self)
        XCTAssertTrue(healthy.success)
        XCTAssertNil(healthy.error)

        let brokenEvents = await runtime.handle(RuntimeRequest(method: "provider.test", payload: .object(["providerId": .string("broken")])) )
        let broken = try XCTUnwrap(brokenEvents.last?.payload).decoded(RuntimeProviderTestResult.self)
        XCTAssertFalse(broken.success)
        XCTAssertEqual(broken.error, "probe failed")
        XCTAssertEqual(brokenEvents.last?.name, "provider.tested")
    }

    func testLegacyConversationWithoutProviderBindingStillDecodes() throws {
        let data = Data(#"{"id":"old","title":"Legacy","kind":"conversation","agentShellAccess":false,"createdAt":0,"updatedAt":0}"#.utf8)
        let decoded = try JSONDecoder.runtime.decode(RuntimeConversation.self, from: data)
        XCTAssertNil(decoded.providerConfigurationID)
    }

    func testSharedChatRepositoryUpdatePreservesDesktopProviderBinding() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let createdAt = Date(timeIntervalSince1970: 10)
        let runtime = RuntimeConversation(
            id: "session",
            title: "Runtime",
            providerConfigurationID: "specialist",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await store.upsertConversation(runtime)
        try await store.repositorySaveSession(ChatSession(
            id: runtime.id,
            title: "Synced title",
            modelId: "remote-model",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(5)
        ))

        let persisted = try await store.conversation(runtime.id)
        XCTAssertEqual(persisted?.title, "Synced title")
        XCTAssertEqual(persisted?.providerConfigurationID, "specialist")
    }

    private func configuration(id: String, model: String = "model") -> ProviderConfiguration {
        ProviderConfiguration(
            id: id,
            displayName: id,
            endpoint: URL(string: "https://example.com/v1/chat/completions")!,
            model: model,
            providerType: .openAI
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor ConfigurationEchoProvider: ProviderRunner {
    private var ids: [String] = []

    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: ProviderConfiguration) async throws -> String {
        ids.append(configuration.id)
        return "provider=\(configuration.id)"
    }

    func configurationIDs() -> [String] { ids }
}

private struct ProviderProbeFailure: LocalizedError {
    var errorDescription: String? { "probe failed" }
}

private actor ProviderProbeStub: ProviderRunner {
    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: ProviderConfiguration) async throws -> String {
        if configuration.id == "broken" { throw ProviderProbeFailure() }
        return "OK"
    }
}
