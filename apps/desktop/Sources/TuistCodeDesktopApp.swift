import SwiftUI

@main
struct TuistCodeDesktopApp: App {
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
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            TuistCodeSettingsView()
                .environmentObject(themeStore)
                .environmentObject(inferenceAccounts)
                .environmentObject(agentRuntime)
                .tuistCodeTheme(themeStore.selectedTheme)
        }
    }
}
