import SwiftUI

@main
struct TuistCodeiOSApp: App {
    @StateObject private var themeStore = TuistCodeThemeStore()
    @StateObject private var inferenceAccounts = InferenceAccountStore()
    @StateObject private var agentRuntime = AgentSessionRuntimeStore()

    var body: some Scene {
        WindowGroup {
            TuistCodeRootView()
                .environmentObject(themeStore)
                .environmentObject(inferenceAccounts)
                .environmentObject(agentRuntime)
                .tuistCodeTheme(themeStore.selectedTheme)
        }
    }
}
