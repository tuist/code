#if os(iOS)
import SwiftUI

enum TuistCodeTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    func palette(for colorScheme: ColorScheme) -> TuistCodeThemePalette {
        switch self {
        case .system:
            colorScheme == .dark ? .dark : .light
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct TuistCodeThemePalette {
    let accent: Color
    let canvas: Color
    let surface: Color
    let selection: Color
    let textPrimary: Color
    let textSecondary: Color
    let textOnAccent: Color
    let separator: Color
    let danger: Color

    static let light = Self(
        accent: Color(red: 111 / 255, green: 44 / 255, blue: 1),
        canvas: Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255),
        surface: .white,
        selection: Color(red: 232 / 255, green: 225 / 255, blue: 1),
        textPrimary: Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255),
        textSecondary: Color(red: 96 / 255, green: 96 / 255, blue: 102 / 255),
        textOnAccent: .white,
        separator: Color(red: 210 / 255, green: 210 / 255, blue: 215 / 255),
        danger: Color(red: 192 / 255, green: 57 / 255, blue: 43 / 255)
    )

    static let dark = Self(
        accent: Color(red: 125 / 255, green: 72 / 255, blue: 1),
        canvas: Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255),
        surface: Color(red: 34 / 255, green: 34 / 255, blue: 36 / 255),
        selection: Color(red: 67 / 255, green: 49 / 255, blue: 111 / 255),
        textPrimary: Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255),
        textSecondary: Color(red: 174 / 255, green: 174 / 255, blue: 181 / 255),
        textOnAccent: .white,
        separator: Color(red: 66 / 255, green: 66 / 255, blue: 70 / 255),
        danger: Color(red: 1, green: 112 / 255, blue: 107 / 255)
    )
}

@MainActor
final class TuistCodeThemeStore: ObservableObject {
    @Published var selectedTheme: TuistCodeTheme {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "tuist-code-theme"

    init() {
        selectedTheme = UserDefaults.standard.string(forKey: Self.storageKey)
            .flatMap(TuistCodeTheme.init(rawValue:)) ?? .system
    }
}

private struct TuistCodeThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = TuistCodeTheme.system
}

extension EnvironmentValues {
    var tuistCodeTheme: TuistCodeTheme {
        get { self[TuistCodeThemeEnvironmentKey.self] }
        set { self[TuistCodeThemeEnvironmentKey.self] = newValue }
    }
}

extension View {
    func tuistCodeTheme(_ theme: TuistCodeTheme) -> some View {
        environment(\.tuistCodeTheme, theme)
            .preferredColorScheme(theme.preferredColorScheme)
    }
}
#endif
