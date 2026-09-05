import Sparkle
import SwiftUI

@_silgen_name("tuist_code_app_name")
private func tuistCodeAppName() -> UnsafePointer<CChar>

@_silgen_name("tuist_code_brand_color")
private func tuistCodeBrandColor() -> UInt32

@main
struct TuistCodeDesktopApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            BrandScreen()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            self?.canCheckForUpdates = updater.canCheckForUpdates
        }
    }
}

private struct BrandScreen: View {
    private let name = String(cString: tuistCodeAppName())
    private let brandColor = Color(rgb: tuistCodeBrandColor())

    var body: some View {
        VStack(spacing: 20) {
            Image("TuistLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)

            Text(name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255))
        .tint(brandColor)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
