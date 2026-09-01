import XCTest
@testable import MinisDesktopCore

final class MinisDesktopCoreTests: XCTestCase {
    func testTerminalTabsKeepIndependentBuffersAndBoundRetainedOutput() {
        var first = TerminalTabState(
            terminalID: UUID(),
            workspaceID: "workspace-a",
            title: "Terminal 1"
        )
        var second = TerminalTabState(
            terminalID: UUID(),
            workspaceID: "workspace-a",
            title: "Terminal 2"
        )

        first.appendOutput("abcdef", limit: 4)
        second.appendOutput("other")
        first.clearOutput()

        XCTAssertEqual(first.output, "")
        XCTAssertEqual(second.output, "other")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testGroupMentionRouterIsCompiledByDesktopCore() {
        let member = GroupMember(id: "agent-1", name: "Researcher", title: "Research", emoji: "", accentColor: "#000000", summary: "", slot: 0)
        XCTAssertEqual(GroupMentionRouter.encode("@Research hello", members: [member]), "<@agent-1> hello")
    }

    func testShellRunsInGrantedWorkspaceWithSeparatedStreams() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = MacCommandExecutionBackend()
        let result = try await shell.execute(CommandRequest(command: "printf 'hello'; printf 'warning' >&2; pwd", workingDirectory: directory, sessionID: "test"))
        XCTAssertEqual(result.stdout.prefix(5), "hello")
        XCTAssertEqual(result.stderr, "warning")
        XCTAssertTrue(result.stdout.contains(directory.path))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRuntimeRejectsUnversionedRequest() async {
        let runtime = AgentRuntime()
        let request = RuntimeRequest(method: "initialize")
        let event = await runtime.handle(request).first
        XCTAssertEqual(event?.name, "runtime.ready")
    }

    func testProtocolUsesDocumentedJSONKeys() throws {
        let request = RuntimeRequest(method: "initialize", sessionID: "session-1")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
        XCTAssertTrue(json.contains("\"requestId\""))
        XCTAssertTrue(json.contains("\"sessionId\""))
        XCTAssertFalse(json.contains("requestID"))
    }

    func testShellTimeoutTerminatesCommand() async throws {
        let shell = MacCommandExecutionBackend()
        let result = try await shell.execute(CommandRequest(command: "sleep 5", workingDirectory: FileManager.default.temporaryDirectory, sessionID: "test", timeout: 0.05))
        XCTAssertTrue(result.wasCancelled)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testShellStopsRetainingOutputAboveLimit() async {
        let shell = MacCommandExecutionBackend(outputLimit: 65_536)
        do {
            _ = try await shell.execute(CommandRequest(command: "yes x", workingDirectory: FileManager.default.temporaryDirectory, sessionID: "test"))
            XCTFail("Expected the output limit to be enforced")
        } catch let error as CommandError {
            XCTAssertEqual(error, .outputLimitExceeded)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAgentToolLoopWritesOnlyInsideGrantedWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory.appendingPathComponent("store"))
        try await store.setMetadata(RuntimeProviderConfiguration(), for: "provider.default")
        let workspaces = WorkspaceRegistry()
        let workspaceID = try await workspaces.grant(directory)
        let provider = ToolLoopProvider()
        let runtime = AgentRuntime(store: store, workspaces: workspaces, credentials: InMemoryCredentialStore(), provider: provider)
        let created = await runtime.handle(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Tools")])))
        let sessionID = try XCTUnwrap(created.last?.sessionID)
        _ = await runtime.handle(RuntimeRequest(method: "workspace.setSessionWorkspace", sessionID: sessionID, payload: .object(["workspaceId": .string(workspaceID)])))
        let events = await runtime.handle(RuntimeRequest(method: "session.send", sessionID: sessionID, payload: .object(["text": .string("Create a note")])) )
        XCTAssertTrue(events.contains(where: { $0.name == "tool.completed" && $0.error == nil }))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("note.txt"), encoding: .utf8), "hello from agent")

        let executor = RuntimeToolExecutor(shell: MacCommandExecutionBackend(), workspace: directory, sessionID: sessionID, agentID: nil)
        do {
            _ = try await executor.execute(ProviderToolCall(id: "escape", name: "file_write", arguments: #"{"path":"../escape.txt","content":"no"}"#))
            XCTFail("Expected workspace traversal to be rejected")
        } catch let error as RuntimeToolError {
            guard case .outsideWorkspace = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAgentShellWaitsForExplicitOneTimeApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory.appendingPathComponent("store"))
        try await store.setMetadata(RuntimeProviderConfiguration(), for: "provider.default")
        let workspaces = WorkspaceRegistry()
        let workspaceID = try await workspaces.grant(directory)
        let client = DirectRuntimeClient(runtime: AgentRuntime(
            store: store,
            workspaces: workspaces,
            credentials: InMemoryCredentialStore(),
            provider: ShellApprovalProvider()
        ))
        let created = try await client.request(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Approval")])) )
        let sessionID = try XCTUnwrap(created.last?.sessionID)
        _ = try await client.request(RuntimeRequest(method: "workspace.setSessionWorkspace", sessionID: sessionID, payload: .object(["workspaceId": .string(workspaceID)])))
        _ = try await client.request(RuntimeRequest(method: "session.setShellAccess", sessionID: sessionID, payload: .object(["enabled": .bool(true)])))

        let stream = await client.events()
        let send = Task {
            try await client.request(RuntimeRequest(method: "session.send", sessionID: sessionID, payload: .object(["text": .string("Run the command")])) )
        }
        var iterator = stream.makeAsyncIterator()
        var approvalID: String?
        while approvalID == nil, let event = await iterator.next() {
            if event.name == "approval.requested", case .object(let object)? = event.payload {
                approvalID = object.string("approvalId")
                XCTAssertEqual(object.string("command"), "printf approved")
                XCTAssertEqual(object.string("cwd"), directory.path)
            }
        }
        let resolvedID = try XCTUnwrap(approvalID)
        _ = try await client.request(RuntimeRequest(method: "tool.approve", sessionID: sessionID, payload: .object(["approvalId": .string(resolvedID)])))
        let events = try await send.value
        XCTAssertTrue(events.contains(where: { $0.name == "tool.completed" && $0.error == nil }))
        XCTAssertEqual(events.last?.name, "message.completed")
        let auditEvents = try await client.request(RuntimeRequest(method: "audit.list", sessionID: sessionID))
        let audit = try XCTUnwrap(auditEvents.last(where: { $0.name == "audit.list" })?.payload)
            .decoded([RuntimeAuditRecord].self)
        XCTAssertEqual(audit.map(\.decision), ["approved", "requested"])
        XCTAssertTrue(audit.contains(where: { $0.detail.contains("printf approved") }))
        await client.shutdown()
    }

    func testNativeCapabilityMatrixAndReverseInvocationRoundTrip() async throws {
        XCTAssertEqual(NativeToolCatalog.capabilities.first(where: { $0.id == "clipboard_read" })?.availability, .available)
        XCTAssertEqual(NativeToolCatalog.capabilities.first(where: { $0.id == "calendar" })?.availability, .requiresPermission)
        XCTAssertEqual(NativeToolCatalog.capabilities.first(where: { $0.id == "contacts" })?.availability, .requiresPermission)
        XCTAssertEqual(NativeToolCatalog.capabilities.first(where: { $0.id == "reminders" })?.availability, .requiresPermission)
        XCTAssertEqual(NativeToolCatalog.capabilities.first(where: { $0.id == "health" })?.availability, .unavailable)
        XCTAssertTrue(NativeToolCatalog.contains("calendar_list"))
        XCTAssertTrue(NativeToolCatalog.contains("calendar_create"))
        XCTAssertTrue(NativeToolCatalog.contains("contacts_search"))
        XCTAssertTrue(NativeToolCatalog.contains("reminders_list"))
        XCTAssertTrue(NativeToolCatalog.contains("reminders_create"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory.appendingPathComponent("store"))
        try await store.setMetadata(RuntimeProviderConfiguration(), for: "provider.default")
        let workspaces = WorkspaceRegistry()
        let workspaceID = try await workspaces.grant(directory)
        let client = DirectRuntimeClient(runtime: AgentRuntime(
            store: store,
            workspaces: workspaces,
            credentials: InMemoryCredentialStore(),
            provider: NativeInvocationProvider()
        ))
        let created = try await client.request(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Native")])) )
        let sessionID = try XCTUnwrap(created.last?.sessionID)
        _ = try await client.request(RuntimeRequest(method: "workspace.setSessionWorkspace", sessionID: sessionID, payload: .object(["workspaceId": .string(workspaceID)])))

        let stream = await client.events()
        let send = Task {
            try await client.request(RuntimeRequest(method: "session.send", sessionID: sessionID, payload: .object(["text": .string("Read clipboard")])) )
        }
        var iterator = stream.makeAsyncIterator()
        var invocationID: String?
        while invocationID == nil, let event = await iterator.next() {
            if event.name == "native.invoke", case .object(let object)? = event.payload {
                XCTAssertEqual(object.string("name"), "clipboard_read")
                invocationID = object.string("invocationId")
            }
        }
        _ = try await client.request(RuntimeRequest(method: "native.resolve", sessionID: sessionID, payload: .object([
            "invocationId": .string(try XCTUnwrap(invocationID)),
            "result": .object(["text": .string("copied value")])
        ])))
        let events = try await send.value
        XCTAssertTrue(events.contains(where: { $0.name == "tool.completed" && $0.error == nil }))
        XCTAssertEqual(events.last?.name, "message.completed")
        let auditEvents = try await client.request(RuntimeRequest(method: "audit.list", sessionID: sessionID))
        let audit = try XCTUnwrap(auditEvents.last(where: { $0.name == "audit.list" })?.payload)
            .decoded([RuntimeAuditRecord].self)
        XCTAssertEqual(audit.map(\.decision), ["completed", "requested"])
        XCTAssertTrue(audit.allSatisfy { !$0.detail.contains("copied value") })
        await client.shutdown()
    }

    func testNativeSideEffectRequiresApprovalBeforeHostInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory.appendingPathComponent("store"))
        try await store.setMetadata(RuntimeProviderConfiguration(), for: "provider.default")
        let workspaces = WorkspaceRegistry()
        let workspaceID = try await workspaces.grant(directory)
        let client = DirectRuntimeClient(runtime: AgentRuntime(
            store: store,
            workspaces: workspaces,
            credentials: InMemoryCredentialStore(),
            provider: NativeSideEffectProvider()
        ))
        let created = try await client.request(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Native approval")])) )
        let sessionID = try XCTUnwrap(created.last?.sessionID)
        _ = try await client.request(RuntimeRequest(method: "workspace.setSessionWorkspace", sessionID: sessionID, payload: .object(["workspaceId": .string(workspaceID)])))

        let stream = await client.events()
        let send = Task {
            try await client.request(RuntimeRequest(method: "session.send", sessionID: sessionID, payload: .object(["text": .string("Open a file")])) )
        }
        var iterator = stream.makeAsyncIterator()
        var approvalID: String?
        while approvalID == nil, let event = await iterator.next() {
            if event.name == "approval.requested", case .object(let object)? = event.payload {
                XCTAssertEqual(object.string("tool"), "system_open")
                XCTAssertEqual(object.string("command"), "Open /tmp/outside.txt")
                approvalID = object.string("approvalId")
            }
        }
        _ = try await client.request(RuntimeRequest(method: "tool.approve", sessionID: sessionID, payload: .object([
            "approvalId": .string(try XCTUnwrap(approvalID))
        ])))

        var invocationID: String?
        while invocationID == nil, let event = await iterator.next() {
            if event.name == "native.invoke", case .object(let object)? = event.payload {
                XCTAssertEqual(object.string("name"), "system_open")
                invocationID = object.string("invocationId")
            }
        }
        _ = try await client.request(RuntimeRequest(method: "native.resolve", sessionID: sessionID, payload: .object([
            "invocationId": .string(try XCTUnwrap(invocationID)),
            "result": .object(["opened": .bool(true)])
        ])))
        let events = try await send.value
        XCTAssertEqual(events.last?.name, "message.completed")
        let auditEvents = try await client.request(RuntimeRequest(method: "audit.list", sessionID: sessionID))
        let audit = try XCTUnwrap(auditEvents.last(where: { $0.name == "audit.list" })?.payload)
            .decoded([RuntimeAuditRecord].self)
        XCTAssertTrue(audit.contains(where: { $0.category == "native_tool" && $0.decision == "approved" }))
        await client.shutdown()
    }

    func testDesktopStorePersistsSessionsAgentsGroupsAndMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try DesktopStore(baseURL: directory)
        let agent = RuntimeAgentRecord(name: "Planner")
        try await store.upsertAgent(agent)
        let conversation = RuntimeConversation(title: "Launch", kind: .agent, agentID: agent.id)
        try await store.upsertConversation(conversation)
        let message = RuntimeMessageRecord(sessionID: conversation.id, role: .user, text: "hello")
        try await store.appendMessage(message)
        let groupConversation = RuntimeConversation(title: "Team", kind: .group)
        let group = RuntimeGroupRecord(sessionID: groupConversation.id, title: "Team", memberIDs: [agent.id])
        try await store.createGroup(group, conversation: groupConversation)

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.agents.map(\.id), [agent.id])
        XCTAssertTrue(snapshot.conversations.contains(where: { $0.id == conversation.id }))
        let storedMessages = try await store.messages(sessionID: conversation.id)
        let storedGroup = try await store.group(group.id)
        XCTAssertEqual(storedMessages.map(\.id), [message.id])
        XCTAssertEqual(storedMessages.first?.text, message.text)
        XCTAssertEqual(storedMessages.first?.createdAt.timeIntervalSince1970 ?? 0, message.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(storedGroup?.sessionID, groupConversation.id)
    }

    func testRuntimeCreatesAndOpensPersistedConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = AgentRuntime(store: try DesktopStore(baseURL: directory), credentials: InMemoryCredentialStore(), provider: MockProvider())
        let created = await runtime.handle(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Desktop")])))
        let id = try XCTUnwrap(created.last?.sessionID)
        let opened = await runtime.handle(RuntimeRequest(method: "session.open", sessionID: id))
        XCTAssertEqual(opened.last?.name, "session.opened")
        guard case .object(let object)? = opened.last?.payload else { return XCTFail("Missing open payload") }
        let session = try XCTUnwrap(object["session"]).decoded(RuntimeConversation.self)
        XCTAssertEqual(session.title, "Desktop")
    }

    func testDirectRuntimePublishesLifecycleEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = DirectRuntimeClient(runtime: AgentRuntime(store: try DesktopStore(baseURL: directory), credentials: InMemoryCredentialStore(), provider: MockProvider()))
        let stream = await client.events()
        _ = try await client.request(RuntimeRequest(method: "session.create", payload: .object(["title": .string("Events")])))
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.name, "session.created")
        await client.shutdown()
    }

    func testRuntimeGroupStartsEveryMentionedMember() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try DesktopStore(baseURL: directory)
        let credentials = InMemoryCredentialStore()
        await credentials.save("unused", account: "default")
        try await store.setMetadata(RuntimeProviderConfiguration(), for: "provider.default")
        let provider = MockProvider()
        let runtime = AgentRuntime(store: store, credentials: credentials, provider: provider)
        let first = RuntimeAgentRecord(id: "agent-first", name: "First")
        let second = RuntimeAgentRecord(id: "agent-second", name: "Second")
        _ = await runtime.handle(RuntimeRequest(method: "agent.create", payload: try .encoded(first)))
        _ = await runtime.handle(RuntimeRequest(method: "agent.create", payload: try .encoded(second)))
        let group = RuntimeGroupRecord(sessionID: UUID().uuidString, title: "Room", memberIDs: [first.id, second.id], ownerAgentID: first.id)
        _ = await runtime.handle(RuntimeRequest(method: "group.create", payload: try .encoded(group)))
        let events = await runtime.handle(RuntimeRequest(method: "group.send", sessionID: group.sessionID, payload: .object(["groupId": .string(group.id), "text": .string("<@everyone> answer")])) )
        let started = events.filter { $0.name == "group.memberStarted" }.compactMap { event -> String? in
            guard case .object(let object)? = event.payload, case .string(let id)? = object["agentId"] else { return nil }
            return id
        }
        XCTAssertEqual(Set(started), Set([first.id, second.id]))
        let callCount = await provider.callCount
        let groupMessageCount = try await store.messages(sessionID: group.sessionID).count
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(groupMessageCount, 3)
    }

    func testHostPTYIsInteractiveAndAcceptsUnicode() async throws {
        let terminal = MacTerminalBackend()
        let created = try await terminal.create(workingDirectory: FileManager.default.temporaryDirectory, size: TerminalSize(columns: 80, rows: 24))
        let expectation = expectation(description: "terminal exits")
        let collected = TerminalCollector()
        let reader = Task {
            for await event in created.events {
                switch event {
                case .output(let data): await collected.append(data)
                case .exited: expectation.fulfill()
                }
            }
        }
        try await terminal.input(Data("printf '终端-ok\\n'\nexit\n".utf8), sessionID: created.id)
        await fulfillment(of: [expectation], timeout: 5)
        _ = await reader.result
        let data = await collected.data
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("终端-ok"))
    }

    func testStdioRuntimeClientRoundTripWhenHelperIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["MINIS_RUNTIME_TEST_EXECUTABLE"] else {
            throw XCTSkip("Set MINIS_RUNTIME_TEST_EXECUTABLE for the subprocess contract test.")
        }
        let client = StdioRuntimeClient(executableURL: URL(fileURLWithPath: path))
        let ready = try await client.request(RuntimeRequest(method: "initialize"))
        XCTAssertEqual(ready.first?.name, "runtime.ready")
        let eventStream = await client.events()
        let created = try await client.request(RuntimeRequest(method: "session.create", payload: .object(["title": .string("stdio client")])) )
        XCTAssertEqual(created.last?.name, "session.created")
        XCTAssertNotNil(created.last?.sessionID)
        var iterator = eventStream.makeAsyncIterator()
        let streamed = await iterator.next()
        XCTAssertEqual(streamed?.name, "session.created")
        await client.shutdown()
    }

    func testStdioRuntimeRestartsOnceAfterCrashWhenHelperIsProvided() async throws {
        guard let helper = ProcessInfo.processInfo.environment["MINIS_RUNTIME_TEST_EXECUTABLE"] else {
            throw XCTSkip("Set MINIS_RUNTIME_TEST_EXECUTABLE for the subprocess restart test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("restart-helper")
        let marker = directory.appendingPathComponent("did-crash").path
        let body = """
        #!/bin/zsh
        if [[ ! -e \(marker.debugDescription) ]]; then
          touch \(marker.debugDescription)
          exit 86
        fi
        exec \(helper.debugDescription)
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = StdioRuntimeClient(executableURL: script)
        do {
            _ = try await client.request(RuntimeRequest(method: "initialize"))
            XCTFail("The first helper process should crash")
        } catch {}

        var recovered = false
        for _ in 0..<20 where !recovered {
            do {
                let events = try await client.request(RuntimeRequest(method: "capabilities"))
                recovered = events.first?.name == "runtime.ready"
            } catch {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        XCTAssertTrue(recovered)
        // A delayed termination callback from the crashed generation must not
        // tear down the replacement helper after recovery.
        for _ in 0..<10 {
            let events = try await client.request(RuntimeRequest(method: "capabilities"))
            XCTAssertEqual(events.first?.name, "runtime.ready")
        }
        await client.shutdown()
    }

    func testStdioRuntimeEntersSafeModeAfterTwoImmediateCrashes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("always-crash")
        try Data("#!/bin/zsh\nexit 86\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = StdioRuntimeClient(executableURL: script)

        var enteredSafeMode = false
        for _ in 0..<50 where !enteredSafeMode {
            do {
                _ = try await client.request(RuntimeRequest(method: "initialize"))
            } catch let error as RuntimeClientError {
                if case .safeMode = error { enteredSafeMode = true }
            } catch {}
            if !enteredSafeMode { try? await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(enteredSafeMode)
        await client.shutdown()
    }
}

private actor MockProvider: ProviderRunner {
    private(set) var callCount = 0
    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: RuntimeProviderConfiguration) async throws -> String {
        callCount += 1
        return "response-\(callCount)"
    }
}

private actor ToolLoopProvider: ToolCallingProviderRunner {
    private var turns = 0

    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: RuntimeProviderConfiguration) async throws -> String {
        "done"
    }

    func complete(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: RuntimeProviderConfiguration) async throws -> ProviderTurn {
        turns += 1
        if turns == 1 {
            XCTAssertFalse(tools.contains(where: { $0.name == "shell_execute" }))
            return ProviderTurn(content: nil, toolCalls: [ProviderToolCall(id: "write-1", name: "file_write", arguments: #"{"path":"note.txt","content":"hello from agent"}"#)])
        }
        return ProviderTurn(content: "Created the note.")
    }
}

private actor ShellApprovalProvider: ToolCallingProviderRunner {
    private var turns = 0

    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: RuntimeProviderConfiguration) async throws -> String {
        "done"
    }

    func complete(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: RuntimeProviderConfiguration) async throws -> ProviderTurn {
        turns += 1
        XCTAssertTrue(tools.contains(where: { $0.name == "shell_execute" }))
        if turns == 1 {
            return ProviderTurn(content: nil, toolCalls: [ProviderToolCall(id: "shell-1", name: "shell_execute", arguments: #"{"command":"printf approved"}"#)])
        }
        return ProviderTurn(content: "The approved command completed.")
    }
}

private actor NativeInvocationProvider: ToolCallingProviderRunner {
    private var turns = 0

    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: RuntimeProviderConfiguration) async throws -> String {
        "done"
    }

    func complete(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: RuntimeProviderConfiguration) async throws -> ProviderTurn {
        turns += 1
        XCTAssertTrue(tools.contains(where: { $0.name == "clipboard_read" }))
        if turns == 1 {
            return ProviderTurn(content: nil, toolCalls: [ProviderToolCall(id: "native-1", name: "clipboard_read", arguments: "{}")])
        }
        XCTAssertTrue(messages.contains(where: { $0.role == "tool" && $0.content?.contains("copied value") == true }))
        return ProviderTurn(content: "Clipboard received.")
    }
}

private actor NativeSideEffectProvider: ToolCallingProviderRunner {
    private var turns = 0

    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: RuntimeProviderConfiguration) async throws -> String {
        "done"
    }

    func complete(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: RuntimeProviderConfiguration) async throws -> ProviderTurn {
        turns += 1
        if turns == 1 {
            return ProviderTurn(content: nil, toolCalls: [ProviderToolCall(
                id: "native-open-1",
                name: "system_open",
                arguments: #"{"target":"/tmp/outside.txt"}"#
            )])
        }
        return ProviderTurn(content: "Opened after approval.")
    }
}

private actor TerminalCollector {
    private(set) var data = Data()
    func append(_ value: Data) { data.append(value) }
}
