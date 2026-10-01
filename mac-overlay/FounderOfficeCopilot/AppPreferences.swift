import AppKit

// MARK: - App Preferences
// The user-facing customisation the app actually supports. Kept OUT of the SwiftUI view that
// presents it: these are preference VALUES that `SettingsStore` persists and tests exercise, and
// burying them in a view file makes them unavailable to both. (This is the second time a model
// type hid inside a view here - see `EntityReference`.)

// MARK: - Appearance

/// The customisation the app actually supports. Deliberately short: every entry here changes
/// something visible, and options that would merely look like configurability are omitted.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Row density. Affects the workspace's vertical rhythm only - it does not change type sizes,
/// because shrinking text to fit more rows makes an app denser AND harder to read.
enum AppDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Multiplier applied to the design system's vertical spacing.
    var scale: CGFloat { self == .compact ? 0.7 : 1.0 }
}
