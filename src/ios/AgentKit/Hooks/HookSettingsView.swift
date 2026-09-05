//
//  HookSettingsView.swift
//  Minis
//
//  `/hooks` — what rules are running on this session, and where they came from.
//
//  The scope label is the point of the screen. A rule a user cannot find in
//  session settings but which is still shaping every turn is the failure mode
//  this UI exists to prevent, so each row says which layer declared it and
//  turning one off writes to that layer.
//

import SwiftUI

struct HookSettingsView: View {
    let sessionId: String?
    let agentId: String?

    @ObservedObject private var store = HookConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: [ResolvedHookBinding] = []
    @State private var editingScope: HookScope?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(String(localized: "Enable hooks"), isOn: $store.isEnabled)
                } footer: {
                    Text(String(localized: "Off means no rule runs, whatever is configured below."))
                }

                if resolved.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(String(localized: "No hooks configured"), systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.headline)
                            Text(String(localized: "Rules are declared in hooks/global.json, hooks/agents/<id>.json or hooks/sessions/<id>.json."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    ForEach(HookEvent.allCases, id: \.self) { event in
                        let rows = resolved.filter { $0.binding.event == event }
                        if !rows.isEmpty {
                            Section(header: Text(title(for: event))) {
                                ForEach(rows) { row in
                                    HookRowView(row: row) { enabled in
                                        setEnabled(enabled, for: row)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(String(localized: "Edit global rules")) { editingScope = .global }
                    if agentId != nil {
                        Button(String(localized: "Edit this agent's rules")) { editingScope = .agent }
                    }
                    if sessionId != nil {
                        Button(String(localized: "Edit this chat's rules")) { editingScope = .session }
                    }
                } header: {
                    Text(String(localized: "Configuration"))
                } footer: {
                    Text(String(localized: "A narrower layer wins: redeclare a rule's id here to change or switch off one inherited from a broader layer."))
                }
            }
            .navigationTitle(String(localized: "Hooks"))
            .sheet(item: $editingScope) { scope in
                HookJSONEditor(
                    scope: scope,
                    id: id(for: scope),
                    onSave: reload
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .onChange(of: store.isEnabled) { _ in reload() }
        }
    }

    private func reload() {
        // Read the layers directly rather than through `resolvedBindings`,
        // which returns nothing while the master switch is off — the list must
        // still show what WOULD run, or turning hooks back on is a blind step.
        resolved = HookEngine.merge(
            global: store.config(scope: .global),
            agent: agentId.map { store.config(scope: .agent, id: $0) } ?? .empty,
            session: sessionId.map { store.config(scope: .session, id: $0) } ?? .empty
        )
    }

    private func setEnabled(_ enabled: Bool, for row: ResolvedHookBinding) {
        store.setEnabled(enabled, bindingID: row.binding.id, scope: row.scope, id: id(for: row.scope))
        reload()
    }

    private func id(for scope: HookScope) -> String? {
        switch scope {
        case .global: return nil
        case .agent: return agentId
        case .session: return sessionId
        }
    }

    private func title(for event: HookEvent) -> String {
        switch event {
        case .turnWillStart: return String(localized: "When a turn starts")
        case .toolsWillBeSent: return String(localized: "Before tools are offered")
        case .willRunTool: return String(localized: "Before a tool runs")
        case .didRunTool: return String(localized: "After a tool runs")
        case .turnWillEnd: return String(localized: "Before a turn ends")
        }
    }
}

private struct HookRowView: View {
    let row: ResolvedHookBinding
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { row.binding.enabled }, set: onToggle)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.binding.id).font(.body)
                    Text(row.binding.handler)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Label(scopeLabel, systemImage: scopeIcon)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                if let wake = row.binding.match.wakeSource, !wake.isEmpty {
                    Text(wake.map(\.rawValue).joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let tools = row.binding.match.toolName, !tools.isEmpty {
                    Text(tools.joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var scopeLabel: String {
        switch row.scope {
        case .global: return String(localized: "Global")
        case .agent: return String(localized: "This agent")
        case .session: return String(localized: "This chat")
        }
    }

    private var scopeIcon: String {
        switch row.scope {
        case .global: return "globe"
        case .agent: return "person"
        case .session: return "bubble.left"
        }
    }
}


extension HookScope: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// The authoring surface: one layer's file as JSON.
///
/// Deliberately raw rather than a form builder. A binding is five fields and a
/// free-form params object whose shape belongs to the handler, so a form would
/// either constrain params to what today's handlers happen to take, or become a
/// worse JSON editor. Saving validates by decoding — malformed text is refused
/// here rather than silently disabling a layer at the next turn.
private struct HookJSONEditor: View {
    let scope: HookScope
    let id: String?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var title: String {
        switch scope {
        case .global: return String(localized: "Global rules")
        case .agent: return String(localized: "Agent rules")
        case .session: return String(localized: "Chat rules")
        }
    }

    private func load() {
        let config = HookConfigStore.shared.config(scope: scope, id: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if config.bindings.isEmpty {
            text = Self.template
        } else if let data = try? encoder.encode(config), let string = String(data: data, encoding: .utf8) {
            text = string
        }
    }

    private func save() {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let config = try JSONDecoder().decode(HookConfig.self, from: data)
            for binding in config.bindings where HookRegistry.handler(id: binding.handler) == nil {
                error = String(localized: "Unknown handler \"\(binding.handler)\" in rule \"\(binding.id)\".")
                return
            }
            HookConfigStore.shared.save(config, scope: scope, id: id)
            onSave()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Shown for an empty layer: the shape, with the one registered handler.
    private static let template = """
    {
      "version": 1,
      "bindings": [
        {
          "id": "trace-everything",
          "handler": "trace",
          "event": "willRunTool",
          "enabled": true,
          "match": {},
          "params": { "label": "trace" },
          "order": 100
        }
      ]
    }
    """
}
