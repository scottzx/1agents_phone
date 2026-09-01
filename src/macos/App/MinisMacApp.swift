import SwiftUI
import AppKit

struct TerminalWindowRoute: Codable, Hashable {
    let tabID: UUID
}

@MainActor
final class MinisMacAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DesktopViewModel?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await model?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MinisMacApp: App {
    @NSApplicationDelegateAdaptor(MinisMacAppDelegate.self) private var appDelegate
    @StateObject private var model: DesktopViewModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let model = DesktopViewModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.model = model
    }

    var body: some Scene {
        WindowGroup("Yima") {
            DesktopRootView(model: model)
                .frame(minWidth: 1160, minHeight: 720)
                .task { await model.start() }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { Task { await model.createConversation() } }
                    .keyboardShortcut("n")
            }
            CommandMenu("Workspace") {
                Button("Choose Workspace…") { model.selectWorkspace() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Terminal") {
                Button("Show/Hide Inspector Terminal") { model.toggleInspectorTerminal() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("New Terminal Window") {
                    Task {
                        if let tabID = await model.openTerminal(showInInspector: false) {
                            openWindow(value: TerminalWindowRoute(tabID: tabID))
                        }
                    }
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                Divider()
                Button("Clear Terminal") { model.clearTerminal() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.selectedTerminalTabID == nil)
                Button("Close Terminal Tab") { Task { await model.closeSelectedTerminal() } }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.selectedTerminalTabID == nil)
            }
        }
        WindowGroup("Terminal", for: TerminalWindowRoute.self) { $route in
            TerminalWindowView(model: model, route: route)
                .frame(minWidth: 760, minHeight: 520)
        }
        Settings {
            ProviderSettingsView(model: model)
                .frame(width: 560, height: 320)
        }
    }
}
