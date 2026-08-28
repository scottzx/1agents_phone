import SwiftUI

/// Static landing for the 销售助手 flavor. First-pass scene home so the
/// vertical package is visually distinct from the original Minis chat list.
struct SalesHomeView: View {
    private let flavor = FlavorRegistry.current
    @ObservedObject private var pack = RolePackRuntime.shared
    @State private var showAgent = false
    @State private var tappedAction: RolePackQuickAction?

    private let pipeline: [(title: String, count: String, icon: String)] = [
        ("线索", "12", "sparkle.magnifyingglass"),
        ("跟进", "5", "phone.badge.checkmark"),
        ("报价", "3", "doc.text"),
        ("成交", "1", "checkmark.seal.fill"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    pipelineStrip
                    actionsSection
                    bindingsSection
                    enterAgentButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(SalesPalette.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(flavor.displayName)
                        .font(.headline)
                }
            }
            .sheet(item: $tappedAction) { action in
                SalesActionPreview(action: action)
                    .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showAgent) {
                NavigationStack {
                    ContentView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("返回销售首页") { showAgent = false }
                            }
                        }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(SalesPalette.accent)
                        .frame(width: 64, height: 64)
                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(flavor.branding.onboardingTitle ?? flavor.displayName)
                        .font(.title2.bold())
                    Text("独立包 · \(flavor.flavorId)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SalesPalette.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(SalesPalette.accent)
                }
            }

            Text(flavor.branding.onboardingBody ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("这不是原始 Minis。Bundle：\(Bundle.main.bundleIdentifier ?? "—")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    private var pipelineStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本周管道")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(pipeline, id: \.title) { item in
                    VStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(SalesPalette.accent)
                        Text(item.count)
                            .font(.title3.bold().monospacedDigit())
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷动作")
                .font(.headline)
            let actions = pack.quickActions.isEmpty ? Self.fallbackActions : pack.quickActions
            ForEach(actions) { action in
                Button {
                    tappedAction = action
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: action.icon ?? "bolt.fill")
                            .font(.title3)
                            .foregroundStyle(SalesPalette.accent)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let subtitle = action.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统权威源")
                .font(.headline)
            HStack(spacing: 8) {
                bindingChip("提醒事项", "checklist")
                bindingChip("日历", "calendar")
                bindingChip("通讯录", "person.crop.circle")
            }
        }
    }

    private func bindingChip(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(Color(UIColor.secondarySystemBackground))
            )
    }

    private var enterAgentButton: some View {
        Button {
            showAgent = true
        } label: {
            Text("进入完整 Agent")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(SalesPalette.accent)
    }

    private static let fallbackActions: [RolePackQuickAction] = [
        RolePackQuickAction(
            id: "today_followups",
            title: "今日跟进",
            subtitle: "从提醒事项列出今天该联系的事项",
            icon: "phone.badge.checkmark",
            kind: "prompt",
            prompt: nil,
            skillHint: nil
        ),
        RolePackQuickAction(
            id: "quote_from_image",
            title: "从图片报价",
            subtitle: "识别价目表或需求图",
            icon: "doc.text.viewfinder",
            kind: "prompt",
            prompt: nil,
            skillHint: nil
        ),
        RolePackQuickAction(
            id: "sleeping_top",
            title: "沉睡客户",
            subtitle: "梳理久未联系的客户线索",
            icon: "person.crop.circle.badge.moon",
            kind: "prompt",
            prompt: nil,
            skillHint: nil
        ),
    ]
}

private enum SalesPalette {
    static let accent = Color(red: 0.83, green: 0.39, blue: 0.16)
    static let canvas = Color(UIColor.systemGroupedBackground)
}

private struct SalesActionPreview: View {
    let action: RolePackQuickAction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label(action.title, systemImage: action.icon ?? "bolt.fill")
                    .font(.title3.bold())
                    .foregroundStyle(SalesPalette.accent)
                Text(action.subtitle ?? "静态演示动作")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let prompt = action.prompt {
                    Text(prompt)
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(UIColor.secondarySystemBackground))
                        )
                }
                Text("这是销售包的静态页预览，还没有接到会话预填。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(20)
            .navigationTitle("动作预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
