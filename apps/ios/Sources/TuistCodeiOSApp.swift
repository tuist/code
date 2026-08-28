import SwiftUI

@_silgen_name("tuist_code_app_name")
private func tuistCodeAppName() -> UnsafePointer<CChar>

@_silgen_name("tuist_code_brand_color")
private func tuistCodeBrandColor() -> UInt32

@main
struct TuistCodeiOSApp: App {
    var body: some Scene {
        WindowGroup {
            BrandScreen()
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
                .font(.title2.weight(.semibold))
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
