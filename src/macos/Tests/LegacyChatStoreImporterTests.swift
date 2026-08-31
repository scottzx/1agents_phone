import Foundation
import SQLite3
import XCTest
@testable import MinisDesktopCore

final class LegacyChatStoreImporterTests: XCTestCase {
    func testImportsCurrentIOSChatStoreSchemaAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyURL = root.appendingPathComponent("ios-minis.db")
        try makeLegacyFixture(at: legacyURL)
        let desktop = try DesktopStore(baseURL: root.appendingPathComponent("desktop", isDirectory: true))
        let importer = LegacyChatStoreImporter(databaseURL: legacyURL)

        let first = try await importer.importInto(desktop)
        XCTAssertEqual(first.conversations, 4)
        XCTAssertEqual(first.agents, 1)
        XCTAssertEqual(first.groups, 1)
        XCTAssertEqual(first.messages, 3)

        let snapshot = try await desktop.snapshot()
        XCTAssertEqual(Set(snapshot.conversations.map(\.id)), ["s-normal", "s-main", "s-group", "s-member"])
        XCTAssertEqual(snapshot.conversations.first(where: { $0.id == "s-normal" })?.kind, .conversation)
        XCTAssertEqual(snapshot.conversations.first(where: { $0.id == "s-main" })?.kind, .agent)
        XCTAssertEqual(snapshot.conversations.first(where: { $0.id == "s-group" })?.kind, .group)
        XCTAssertEqual(snapshot.conversations.first(where: { $0.id == "s-member" })?.groupID, "g-team")

        let agent = try XCTUnwrap(snapshot.agents.first)
        XCTAssertEqual(agent.id, "a-planner")
        XCTAssertEqual(agent.mainSessionID, "s-main")
        XCTAssertEqual(agent.toolPolicy, "orchestrator")

        let group = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(group.id, "g-team")
        XCTAssertEqual(group.memberIDs, ["a-planner"])
        XCTAssertEqual(group.memberSessionIDs, ["a-planner": "s-member"])

        let normalMessages = try await desktop.messages(sessionID: "s-normal")
        XCTAssertEqual(normalMessages.map(\.id), ["m-normal-user", "m-normal-assistant"])
        XCTAssertEqual(normalMessages.map(\.text), ["hello from iOS", "hello from macOS"])
        let groupMessages = try await desktop.messages(sessionID: "s-group")
        XCTAssertEqual(groupMessages.first?.senderAgentID, "a-planner")
        XCTAssertEqual(groupMessages.first?.text, "team reply")

        let second = try await importer.importInto(desktop)
        XCTAssertEqual(second, LegacyChatStoreImportResult(conversations: 0, agents: 0, groups: 0, messages: 0))
        let reimportedNormalMessages = try await desktop.messages(sessionID: "s-normal")
        let reimportedGroupMessages = try await desktop.messages(sessionID: "s-group")
        XCTAssertEqual(reimportedNormalMessages.count, 2)
        XCTAssertEqual(reimportedGroupMessages.count, 1)
    }

    private func makeLegacyFixture(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw FixtureError.open
        }
        defer { sqlite3_close(db) }
        try exec(db, """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, title TEXT, model_id TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            agent_id TEXT, parent_session_id TEXT, spawn_role TEXT
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
            parts_json TEXT NOT NULL, created_at REAL NOT NULL, sort_order INTEGER NOT NULL,
            sender_agent_id TEXT
        );
        CREATE TABLE agents (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, emoji TEXT NOT NULL,
            title TEXT NOT NULL, summary TEXT NOT NULL, accent_color TEXT NOT NULL,
            main_session_id TEXT, default_model_entry TEXT, tool_policy TEXT NOT NULL,
            memory_enabled INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            archived_at REAL, sort_order INTEGER NOT NULL
        );
        CREATE TABLE agent_groups (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, title TEXT NOT NULL,
            emoji TEXT NOT NULL, accent_color TEXT NOT NULL, mode TEXT NOT NULL,
            owner_agent_id TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL, archived_at REAL
        );
        CREATE TABLE agent_group_members (
            group_id TEXT NOT NULL, agent_id TEXT NOT NULL, sort_order INTEGER NOT NULL, joined_at REAL NOT NULL,
            PRIMARY KEY (group_id, agent_id)
        );
        """)
        try exec(db, """
        INSERT INTO sessions VALUES
          ('s-normal', 'Legacy chat', 'model', 10, 20, NULL, NULL, NULL),
          ('s-main', 'Planner main', 'model', 11, 21, 'a-planner', NULL, 'main'),
          ('s-group', 'Roadmap', 'model', 12, 22, NULL, NULL, 'group'),
          ('s-member', 'Roadmap · Planner', 'model', 13, 23, 'a-planner', 's-group', 'group-member');
        INSERT INTO agents VALUES
          ('a-planner', 'Planner', '🧭', 'Product', 'Owns the plan', '#5B8DEF',
           's-main', 'model-entry', 'orchestrator', 1, 11, 21, NULL, 0);
        INSERT INTO agent_groups VALUES
          ('g-team', 's-group', 'Roadmap', '👥', '#5B8DEF', 'freeform', 'a-planner', 12, 22, NULL);
        INSERT INTO agent_group_members VALUES ('g-team', 'a-planner', 0, 12);
        INSERT INTO messages VALUES
          ('m-normal-user', 's-normal', 'user', '[{"type":"text","value":"hello from iOS"}]', 14, 3, NULL),
          ('m-normal-assistant', 's-normal', 'assistant', '[{"type":"text","value":"hello from macOS"}]', 15, 9, NULL),
          ('m-group-assistant', 's-group', 'assistant', '[{"type":"text","value":"team reply"}]', 16, 0, 'a-planner');
        """)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "fixture SQL failed"
            sqlite3_free(error)
            throw FixtureError.sql(message)
        }
    }
}

private enum FixtureError: Error {
    case open
    case sql(String)
}
