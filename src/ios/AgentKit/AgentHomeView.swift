//
//  AgentHomeView.swift
//  Minis
//
//  Everything about one agent that is not the conversation itself: who it is,
//  what it is allowed to do, what it remembers, what it is running, and what
//  it used to talk about.
//

import SwiftUI

struct AgentHomeView: View {
    let agentId: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AgentStore.shared

    @State private var agent: AgentProfile?
    @State private var persona: String = ""
    @State private var personaLoaded = false
    @State private var saveError: String?

    var body: some View {
        Form {
            if let agent {
                identitySection(agent)
                policySection(agent)
                personaSection
                memorySection(agent)
                workSection(agent)
                if agent.id != AgentProfile.defaultAgentId {
                    Section {
                        Button(role: .destructive) {
                            Task { await store.archive(agent.id); dismiss() }
                        } label: {
                            Text(String(localized: "归档这个 Agent"))
                        }
                    } footer: {
                        Text(String(localized: "归档后不再出现在列表里，会话记录保留。"))
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(agent?.name ?? String(localized: "Agent"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "完成")) { Task { await saveAndClose() } }
            }
        }
        .alert(String(localized: "保存失败"), isPresented: .constant(saveError != nil)) {
            Button(String(localized: "好")) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .task { await load() }
    }

    // MARK: - Sections

    private func identitySection(_ agent: AgentProfile) -> some View {
        Section(String(localized: "身份")) {
            HStack {
                Text(String(localized: "头像"))
                Spacer()
                TextField("🤖", text: field(\.emoji))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            TextField(String(localized: "名字"), text: field(\.name))
            TextField(String(localized: "头衔"), text: field(\.title))
            TextField(String(localized: "一句话介绍"), text: field(\.summary))
        }
    }

    /// Two-way binding onto one field of the locally-held profile.
    private func field(_ key: WritableKeyPath<AgentProfile, String>) -> Binding<String> {
        Binding(
            get: { agent?[keyPath: key] ?? "" },
            set: { next in mutate { $0[keyPath: key] = next } }
        )
    }

    private func policySection(_ agent: AgentProfile) -> some View {
        Section {
            Picker(String(localized: "工作方式"), selection: Binding(
                get: { agent.toolPolicy },
                set: { next in mutate { $0.toolPolicy = next } }
            )) {
                ForEach(AgentToolPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(agent.toolPolicy.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "工具权限"))
        } footer: {
            if agent.toolPolicy == .orchestrator {
                Text(String(localized: "总管拿不到 shell、文件写入和浏览器——这是机制上的限制，不是提示词约定。"))
            }
        }
    }

    private var personaSection: some View {
        Section {
            if personaLoaded {
                TextEditor(text: $persona).frame(minHeight: 140)
            } else {
                ProgressView()
            }
        } header: {
            Text(String(localized: "人设（SOUL.md）"))
        } footer: {
            let check = SoulStore.isOverLimit(persona)
            if check.isOverLimit {
                Text(String(localized: "超出长度上限，保存会被拒绝。"))
                    .foregroundStyle(.red)
            } else {
                Text(String(localized: "描述它是谁、说话风格、在意什么。它自己也能读到这份文件。"))
            }
        }
    }

    private func memorySection(_ agent: AgentProfile) -> some View {
        Section {
            Toggle(String(localized: "启用记忆"), isOn: Binding(
                get: { agent.memoryEnabled },
                set: { next in mutate { $0.memoryEnabled = next } }
            ))
        } header: {
            Text(String(localized: "记忆"))
        } footer: {
            Text(String(localized: "这个 Agent 的记忆存在 \(AgentProfile.linuxDirectory(for: agent.id))/memory/，与其它 Agent 互不相通。"))
                .font(.caption)
        }
    }

    private func workSection(_ agent: AgentProfile) -> some View {
        Section(String(localized: "工作")) {
            if let main = agent.mainSessionId {
                NavigationLink {
                    SubagentTaskListView(parentSessionId: main)
                } label: {
                    Label(String(localized: "后台任务"), systemImage: "list.bullet.rectangle")
                }
            }
            NavigationLink {
                AgentSchedulesView(agentId: agent.id)
            } label: {
                Label(String(localized: "定时任务"), systemImage: "clock")
            }
            NavigationLink {
                ContentView(agentFilter: agent.id)
            } label: {
                Label(String(localized: "历史会话"), systemImage: "clock.arrow.circlepath")
            }
        }
    }

    // MARK: - State plumbing

    /// Apply an edit to the local copy. Persistence happens once, on Done —
    /// a write per keystroke would bump `updatedAt` constantly and thrash the
    /// roster diff.
    private func mutate(_ change: (inout AgentProfile) -> Void) {
        guard var next = agent else { return }
        change(&next)
        agent = next
    }

    private func load() async {
        agent = await store.loadAgent(agentId)
        persona = SoulStore.load(for: agentId)?.body ?? ""
        personaLoaded = true
    }

    private func saveAndClose() async {
        guard let agent else { dismiss(); return }
        if SoulStore.isOverLimit(persona).isOverLimit {
            saveError = String(localized: "人设正文超出长度上限，请精简后再保存。")
            return
        }
        let existing = SoulStore.load(for: agentId)
        let metadata = SoulMetadata(
            name: agent.name,
            emoji: existing?.metadata.emoji ?? "",
            style: existing?.metadata.style ?? "",
            lang: existing?.metadata.lang ?? "auto"
        )
        do {
            try SoulStore.save(SoulFile(metadata: metadata, body: persona), for: agentId)
        } catch {
            saveError = error.localizedDescription
            return
        }
        await store.update(agent)
        dismiss()
    }
}
