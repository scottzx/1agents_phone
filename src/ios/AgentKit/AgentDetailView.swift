//
//  AgentDetailView.swift
//  Minis
//
//  Agent Profile & Details: identity, persona preview, fast message entry,
//  long-press context menu for editing, and related task queue.
//

import SwiftUI

struct AgentDetailView: View {
    let agentId: String
    var onSendMessage: ((String) -> Void)? = nil
    var onOpenSession: ((String) -> Void)? = nil
    var onOpenGroup: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AgentStore.shared

    @State private var agent: AgentProfile?
    @State private var persona: String = ""
    @State private var showingEditProfile = false
    @State private var showingEditPersona = false
    @State private var showingArchiveConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let agent {
                    // Profile Header Card
                    profileCard(agent)

                    // Primary Action: Send Message
                    sendMessageButton(agent)

                    // Persona & Memory Card
                    personaCard(agent)

                    // Related Tasks
                    tasksSection(agent)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(agent?.name ?? String(localized: "智能体"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEditProfile) {
            if let agent {
                NavigationStack {
                    AgentProfileEditorView(agent: agent) { updated in
                        self.agent = updated
                        showingEditProfile = false
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditPersona) {
            if let agent {
                NavigationStack {
                    AgentPersonaEditorView(agent: agent, initialPersona: persona) { updatedAgent, updatedPersona in
                        self.agent = updatedAgent
                        self.persona = updatedPersona
                        showingEditPersona = false
                    }
                }
            }
        }
        .alert(String(localized: "归档智能体"), isPresented: $showingArchiveConfirm) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "归档"), role: .destructive) {
                Task {
                    await store.archive(agentId)
                    dismiss()
                }
            }
        } message: {
            Text(String(localized: "归档后不再出现在通讯录列表中，历史会话记录仍将保留。"))
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Subviews

    private func profileCard(_ agent: AgentProfile) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                    .font(.system(size: 38))
                    .frame(width: 68, height: 68)
                    .background(AgentAccent.color(agent.accentColor).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)

                        if !agent.title.isEmpty {
                            Text(agent.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(agent.toolPolicy.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())

                        if agent.memoryEnabled {
                            Text(String(localized: "记忆已开启"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.1), in: Capsule())
                        }
                    }
                }
                Spacer()
            }

            if !agent.summary.isEmpty {
                Text(agent.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button {
                showingEditProfile = true
            } label: {
                Label(String(localized: "修改基本信息"), systemImage: "pencil")
            }

            Button {
                showingEditPersona = true
            } label: {
                Label(String(localized: "修改人设 (SOUL.md)"), systemImage: "doc.text")
            }

            if agent.id != AgentProfile.defaultAgentId {
                Divider()
                Button(role: .destructive) {
                    showingArchiveConfirm = true
                } label: {
                    Label(String(localized: "归档智能体"), systemImage: "archivebox")
                }
            }
        }
    }

    private func sendMessageButton(_ agent: AgentProfile) -> some View {
        Button {
            onSendMessage?(agent.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(String(localized: "发消息"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func personaCard(_ agent: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "人设与说明"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "长按可修改"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if persona.isEmpty {
                Text(agent.toolPolicy.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text(persona)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button {
                showingEditPersona = true
            } label: {
                Label(String(localized: "修改人设 (SOUL.md)"), systemImage: "doc.text")
            }
        }
    }

    private func tasksSection(_ agent: AgentProfile) -> some View {
        RelatedTasksView(filter: .agent(agent.id)) { entry in
            let session = entry.session
            if let group = GroupStore.shared.groups.first(where: { $0.sessionId == session.id }) {
                onOpenGroup?(group.id)
            } else {
                onOpenSession?(session.id)
            }
        }
    }

    private func loadData() async {
        agent = await store.loadAgent(agentId)
        persona = SoulStore.load(for: agentId)?.body ?? ""
    }
}

// MARK: - Editor Sheets

private struct AgentProfileEditorView: View {
    let agent: AgentProfile
    var onSaved: (AgentProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var title: String
    @State private var summary: String
    @State private var emoji: String
    @State private var accent: String
    @State private var policy: AgentToolPolicy

    private let palette = ["#5B8DEF", "#E0A33E", "#4CAF7D", "#C46BC4", "#E4694E", "#5AA9C4"]

    init(agent: AgentProfile, onSaved: @escaping (AgentProfile) -> Void) {
        self.agent = agent
        self.onSaved = onSaved
        _name = State(initialValue: agent.name)
        _title = State(initialValue: agent.title)
        _summary = State(initialValue: agent.summary)
        _emoji = State(initialValue: agent.emoji)
        _accent = State(initialValue: agent.accentColor)
        _policy = State(initialValue: agent.toolPolicy)
    }

    var body: some View {
        Form {
            Section(String(localized: "基本资料")) {
                TextField(String(localized: "名字"), text: $name)
                TextField(String(localized: "头衔"), text: $title)
                TextField(String(localized: "一句话介绍"), text: $summary)
            }

            Section(String(localized: "头像与配色")) {
                TextField(String(localized: "Emoji 头像"), text: $emoji)
                HStack(spacing: 10) {
                    ForEach(palette, id: \.self) { hex in
                        Circle()
                            .fill(AgentAccent.color(hex))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle().stroke(Color.primary, lineWidth: accent == hex ? 2 : 0)
                            )
                            .onTapGesture { accent = hex }
                    }
                }
            }

            Section(String(localized: "工作方式")) {
                Picker(String(localized: "工具权限"), selection: $policy) {
                    ForEach(AgentToolPolicy.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Text(policy.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "编辑智能体资料"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    var updated = agent
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.emoji = emoji.isEmpty ? "🤖" : emoji
                    updated.accentColor = accent
                    updated.toolPolicy = policy
                    Task {
                        await AgentStore.shared.update(updated)
                        onSaved(updated)
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct AgentPersonaEditorView: View {
    let agent: AgentProfile
    let initialPersona: String
    var onSaved: (AgentProfile, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var persona: String
    @State private var memoryEnabled: Bool
    @State private var saveError: String?

    init(agent: AgentProfile, initialPersona: String, onSaved: @escaping (AgentProfile, String) -> Void) {
        self.agent = agent
        self.initialPersona = initialPersona
        self.onSaved = onSaved
        _persona = State(initialValue: initialPersona)
        _memoryEnabled = State(initialValue: agent.memoryEnabled)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $persona)
                    .frame(minHeight: 160)
            } header: {
                Text(String(localized: "人设 (SOUL.md)"))
            } footer: {
                let check = SoulStore.isOverLimit(persona)
                if check.isOverLimit {
                    Text(String(localized: "超出长度上限，保存会被拒绝。"))
                        .foregroundStyle(.red)
                } else {
                    Text(String(localized: "描述它是谁、说话风格、在意什么。它自己也能读到这份文件。"))
                }
            }

            Section {
                Toggle(String(localized: "启用独立记忆"), isOn: $memoryEnabled)
            } header: {
                Text(String(localized: "记忆设置"))
            }
        }
        .navigationTitle(String(localized: "编辑人设与记忆"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    save()
                }
            }
        }
        .alert(String(localized: "保存失败"), isPresented: .constant(saveError != nil)) {
            Button(String(localized: "好")) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        if SoulStore.isOverLimit(persona).isOverLimit {
            saveError = String(localized: "人设正文超出长度上限，请精简后再保存。")
            return
        }
        let existing = SoulStore.load(for: agent.id)
        let metadata = SoulMetadata(
            name: agent.name,
            emoji: existing?.metadata.emoji ?? "",
            style: existing?.metadata.style ?? "",
            lang: existing?.metadata.lang ?? "auto"
        )
        do {
            try SoulStore.save(SoulFile(metadata: metadata, body: persona), for: agent.id)
        } catch {
            saveError = error.localizedDescription
            return
        }

        var updated = agent
        updated.memoryEnabled = memoryEnabled
        Task {
            await AgentStore.shared.update(updated)
            onSaved(updated, persona)
        }
    }
}
