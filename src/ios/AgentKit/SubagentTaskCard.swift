//
//  SubagentTaskCard.swift
//  Minis
//
//  The window from the orchestrator's clean transcript into the messy one.
//
//  The parent session only ever holds a short status line for a dispatched
//  task; everything the subagent actually did — the shell output, the page
//  text, the file contents — lives in its own scratch session. The card is how
//  a user gets to that detail when they want it, without any of it landing in
//  the conversation they read every day.
//

import SwiftUI

// MARK: - Card

struct SubagentTaskCard: View {
    let task: ChatSession
    /// Live activity for a running task, if its session is currently looping.
    @ObservedObject private var activity = SessionActivityTracker.shared

    var body: some View {
        NavigationLink {
            SubagentTranscriptView(task: task)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(task.spawnTitle ?? task.title ?? String(localized: "后台任务"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(statusLabel)
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.15))
                        .foregroundStyle(tint)
                        .clipShape(Capsule())
                }

                if let detail = detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var state: String { task.spawnStatus ?? "running" }

    private var icon: String {
        switch state {
        case "done": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "stopped": return "stop.circle.fill"
        default: return "gearshape.2.fill"
        }
    }

    private var tint: Color {
        switch state {
        case "done": return .green
        case "failed": return .orange
        case "stopped": return .secondary
        default: return .accentColor
        }
    }

    private var statusLabel: String {
        switch state {
        case "done": return String(localized: "已完成")
        case "failed": return String(localized: "失败")
        case "stopped": return String(localized: "已停止")
        default: return String(localized: "运行中")
        }
    }

    private var detailLine: String? {
        if state == "running" {
            let info = activity.sessionToolInfo[task.id]
            let tool = info?.toolName ?? ""
            let steps = info?.loopIteration ?? 0
            if !tool.isEmpty {
                return String(localized: "正在 \(tool) · 第 \(steps) 步")
            }
            return String(localized: "正在准备…")
        }
        return task.spawnResult?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Task list

/// Every task an agent's main session has dispatched.
struct SubagentTaskListView: View {
    let parentSessionId: String

    @State private var tasks: [ChatSession] = []
    @State private var loaded = false

    var body: some View {
        List {
            if tasks.isEmpty && loaded {
                Text(String(localized: "还没有派出过任务。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(tasks.reversed()) { task in
                SubagentTaskCard(task: task)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "后台任务"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        tasks = await ChatStore.shared.subagentSessions(parentSessionId: parentSessionId)
        loaded = true
    }
}

// MARK: - Transcript

/// The subagent's own conversation, read-only in spirit: it is a scratch
/// session nobody should be typing into by hand.
struct SubagentTranscriptView: View {
    let task: ChatSession

    var body: some View {
        AIChatView(sessionId: task.id)
            .navigationTitle(task.spawnTitle ?? String(localized: "后台任务"))
            .navigationBarTitleDisplayMode(.inline)
    }
}
