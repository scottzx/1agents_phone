//
//  AgentSchedulesView.swift
//  Minis
//
//  Placeholder. The `agent_schedules` table exists so a later migration does
//  not have to backfill, but nothing schedules anything yet.
//
//  This screen deliberately shows no fake affordances. iOS gives the app no
//  way to wake itself on a timer, and the agent's own system prompt tells the
//  user exactly that ("There is no in-app scheduler ... use Apple Shortcuts").
//  A create button here would put the UI in direct contradiction with what the
//  agent says when asked. Android's ScheduledAgentRunner.kt is the reference
//  for when this is built for real.
//

import SwiftUI

struct AgentSchedulesView: View {
    let agentId: String

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "定时任务还没有做"))
                        .font(.headline)
                    Text(String(localized: "让 Agent 按时间自己跑起来，需要 App 能在后台被唤醒。iOS 目前不给这个能力，所以这里暂时是空的。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            Section {
                Label(String(localized: "现在可以用「快捷指令」自动化，在指定时间给这个 Agent 发一条消息。"),
                      systemImage: "arrow.triangle.branch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "替代方案"))
            }
        }
        .navigationTitle(String(localized: "定时任务"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
