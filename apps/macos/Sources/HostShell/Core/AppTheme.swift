import SwiftUI

// MARK: - App Theme
//
// A single source of truth for light/dark appearance. The selected mode is
// stored in UserDefaults and injected into the SwiftUI environment so that
// the sidebar and the main content area always resolve colors from the same
// scheme — no more dark sidebar against a light canvas.

public enum AppThemeMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

public enum AppTheme {
    public static let modeKey = "app.theme.mode"

    public static func mode(rawValue: String?) -> AppThemeMode {
        guard let rawValue, let mode = AppThemeMode(rawValue: rawValue) else { return .system }
        return mode
    }

    /// Resolve the concrete scheme to apply, given the user's preference and the system setting.
    public static func effectiveScheme(mode: AppThemeMode, system: ColorScheme) -> ColorScheme {
        switch mode {
        case .system: return system
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Brand accents (identical in both themes)

    public static let cyan = Color(red: 0.373, green: 0.894, blue: 0.871)   // #5fe4de
    public static let blue = Color(red: 0.286, green: 0.682, blue: 0.980)   // #49aefa
    public static let navy = Color(red: 0.051, green: 0.129, blue: 0.216)   // #0d2137
    public static let navy2 = Color(red: 0.078, green: 0.173, blue: 0.286)  // #142c49
    public static let deep = Color(red: 0.027, green: 0.075, blue: 0.125)   // #071320

    // MARK: - Proxy mode semantics (identical in both themes)

    public static let modeDirect = Color(red: 0.133, green: 0.773, blue: 0.369)     // #22c55e
    public static let modeProxyJump = Color(red: 0.231, green: 0.510, blue: 0.965)  // #3b82f6
    public static let modeCloudflare = Color(red: 0.659, green: 0.333, blue: 0.969) // #a855f7
    public static let modeProxyCommand = Color(red: 0.961, green: 0.620, blue: 0.043)// #f59e0b

    public static func proxyColor(_ mode: ProxyMode) -> Color {
        switch mode {
        case .direct: return modeDirect
        case .proxyJump: return modeProxyJump
        case .cloudflareAccess: return modeCloudflare
        case .proxyCommand: return modeProxyCommand
        }
    }

    // MARK: - Surfaces (theme-dependent)

    /// Main canvas behind lists and cards.
    public static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.043, green: 0.071, blue: 0.106)   // #0b1220
            : Color(hex: 0xF1F5F9)                            // n-100
    }

    /// Toolbar / header strip.
    public static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.078, green: 0.173, blue: 0.286)   // navy2
            : Color.white
    }

    /// Raised surface for groups and cards.
    public static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.078, green: 0.133, blue: 0.204)   // #142235
            : Color.white
    }

    /// Hairline separators / card borders.
    public static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    // MARK: - Sidebar (theme-dependent, unified with canvas)

    public static func sidebarGradient(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [navy2, deep], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(hex: 0xF8FAFC), Color(hex: 0xE8EEF6)], startPoint: .top, endPoint: .bottom)
    }

    public static func sidebarHeaderBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    public static func sidebarIcon(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? cyan : Color(hex: 0x2563EB)
    }

    public static func sidebarText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.90) : Color(hex: 0x1E293B)
    }

    public static func sidebarTextInactive(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.62) : Color(hex: 0x64748B)
    }

    public static func sidebarSectionTitle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.42) : Color(hex: 0x94A3B8)
    }

    public static func sidebarActiveBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? blue.opacity(0.18) : blue.opacity(0.14)
    }

    public static func sidebarActiveIcon(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? cyan : Color(hex: 0x1D4ED8)
    }
}

// Hex helper local to the theme module.
extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
