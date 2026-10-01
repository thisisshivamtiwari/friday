import SwiftUI

// MARK: - Design System
/// The single source of visual truth for the main application window. Every screen is built
/// from these tokens and primitives rather than styling itself, which is what stops the app
/// drifting into twelve slightly-different greys and nine slightly-different corner radii.
///
/// The palette is deliberately NEARLY MONOCHROME. Colour is reserved for two jobs only -
/// the accent (selection, the user's own choice) and lifecycle status (a small, bounded
/// vocabulary). Everything else is `.primary`/`.secondary` over native materials, so the app
/// reads as calm and native in both themes instead of as a dashboard. Semantic colours are used
/// throughout rather than fixed RGB, so light and dark are correct by construction.
enum DS {

    // MARK: Spacing — a 4pt scale. Nothing in the app should invent a spacing value.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 28
    }

    /// Vertical padding for a list row, scaled by the user's density preference. Read here so
    /// every row in the app responds to the setting without each screen knowing it exists - and
    /// so density changes rhythm only. Type sizes are deliberately NOT scaled: shrinking text to
    /// fit more rows makes an app denser AND harder to read, which is a bad trade.
    static var rowPaddingV: CGFloat { Space.s * SettingsStore.shared.density.scale }
    static var cardPadding: CGFloat { max(Space.s, Space.m * SettingsStore.shared.density.scale) }
    static var stackSpacing: CGFloat { max(Space.xxs, Space.xs * SettingsStore.shared.density.scale) }

    // MARK: Radius
    enum Radius {
        static let small: CGFloat = 5
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    // MARK: Typography — semantic, never ad-hoc point sizes at call sites.
    enum Font {
        static let display = SwiftUI.Font.system(size: 26, weight: .semibold, design: .default)
        static let title = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        /// Small, uppercase, tracked - section headers and field labels only.
        static let metadata = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
    }

    // MARK: Surfaces
    enum Surface {
        static let canvas = Color(nsColor: .textBackgroundColor)
        static let sidebar = Color(nsColor: .controlBackgroundColor)
        static let card = Color(nsColor: .controlBackgroundColor)
        static let hairline = Color.primary.opacity(0.08)
        static let hover = Color.primary.opacity(0.05)
    }

    // MARK: Lifecycle
    /// The ONE place a `ProjectItem.Status` becomes a colour and a label. Restrained on purpose:
    /// only the two states a founder must act on carry a hue (blocked = attention, active = in
    /// flight). Finished and abandoned work recedes into grey, which is the correct visual
    /// weight for something no longer needing attention.
    static func lifecycleTint(_ status: ProjectItem.Status) -> Color {
        switch status {
        case .blocked: return .orange
        case .active, .inProgress: return .accentColor
        case .completed, .achieved, .resolved: return .secondary
        case .abandoned: return .secondary.opacity(0.6)
        case .proposed, .planned: return .secondary
        }
    }

    static func lifecycleLabel(_ status: ProjectItem.Status) -> String {
        switch status {
        case .inProgress: return "in progress"
        default: return status.rawValue
        }
    }

    /// Work that still needs the founder's attention, as opposed to work that is finished or
    /// deliberately dropped. Used by Home and by every "outstanding" count in the app, so the
    /// definition cannot drift between screens.
    static func isOpen(_ status: ProjectItem.Status) -> Bool {
        switch status {
        case .proposed, .planned, .active, .inProgress, .blocked: return true
        case .completed, .achieved, .resolved, .abandoned: return false
        }
    }
}

// MARK: - Text helpers

extension Int {
    /// "1 decision" / "2 decisions". Trivial, and worth having in exactly one place: the app
    /// renders counts on almost every surface, and "1 messages" is the kind of detail that makes
    /// an otherwise careful product feel unfinished.
    func pluralised(_ singular: String, _ plural: String? = nil) -> String {
        "\(self) \(self == 1 ? singular : (plural ?? singular + "s"))"
    }
}

// MARK: - Primitives

/// A small status pill. Text-first: the tint is a supporting signal, never the only one, so it
/// still reads correctly in greyscale and for colour-blind users.
struct StatusBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.metadata)
            .foregroundColor(tint)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
            .accessibilityLabel("Status: \(text)")
    }
}

/// Section header used across every screen, so vertical rhythm is identical everywhere.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var accessory: AnyView?

    init(_ title: String, subtitle: String? = nil, accessory: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title.uppercased())
                    .font(DS.Font.metadata)
                    .foregroundColor(.secondary)
                if let subtitle {
                    Text(subtitle).font(DS.Font.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let accessory { accessory }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The app's one card container.
struct Card<Content: View>: View {
    var padding: CGFloat = DS.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).stroke(DS.Surface.hairline))
    }
}

/// A row that behaves like a native list row - hover, selection, keyboard focus - without each
/// screen reinventing it.
struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.rowPaddingV)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : (isHovering ? DS.Surface.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Every empty state in the app. Guidance, not an apology - each one tells the user what to do
/// next rather than just reporting absence.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary.opacity(0.7))
            Text(title).font(DS.Font.headline)
            Text(message)
                .font(DS.Font.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
        .accessibilityElement(children: .combine)
    }
}

/// A labelled value row, used by every detail/inspector surface. Omits itself entirely when the
/// value is absent - "no reason recorded" and "Reason: —" say different things, and only the
/// first is honest.
struct DetailField: View {
    let label: String
    let value: String?
    var labelWidth: CGFloat = 96

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                Text(label)
                    .font(DS.Font.caption)
                    .foregroundColor(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                Text(value)
                    .font(DS.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A count with a caption, for the compact statistic rows on Home and project headers.
struct StatTile: View {
    let value: String
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(value).font(DS.Font.title).foregroundColor(tint).monospacedDigit()
            Text(caption.uppercased()).font(DS.Font.metadata).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(caption)")
    }
}
