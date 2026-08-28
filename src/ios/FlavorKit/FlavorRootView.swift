import SwiftUI

/// Flavor-aware app root. Vertical packs can replace the standard chat list
/// with a scene home without forking `MinisApp`.
struct FlavorRootView: View {
    var body: some View {
        let flavor = FlavorRegistry.current
        switch flavor.rootExperience {
        case .agentRoster:
            AgentListView()
        case .standardChat, .chatWithRail:
            ContentView()
        case .sceneHome:
            switch flavor.flavorId {
            case "sales":
                SalesHomeView()
            default:
                ContentView()
            }
        }
    }
}
