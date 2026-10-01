import SwiftUI

// MARK: - Onboarding
/// A first-run explanation, shown once. Four cards, no interaction beyond Next/Back, no account,
/// no setup wizard - the product needs the user to understand ONE idea (conversations become
/// connected, traceable knowledge) and the fastest way to teach that is to say it plainly and
/// get out of the way.
///
/// Deliberately NOT a feature tour. A tour of screens the user has no data in yet teaches
/// nothing; this explains the model so the empty screens make sense when they arrive.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(icon: "waveform",
             title: "It listens, so you don't take notes",
             body: "Founder Office Copilot follows your meetings and conversations. Nothing is uploaded anywhere except the text it needs to answer you, and everything it learns is stored on this Mac."),
        Page(icon: "square.stack.3d.up",
             title: "Conversations become structure",
             body: "It picks out the things that matter — the projects you're working on, the work in flight, the decisions you make and the people involved — and keeps them as real, connected records rather than a transcript you'd have to re-read."),
        Page(icon: "quote.bubble",
             title: "Ask, and see the receipts",
             body: "Ask what was decided, what's still outstanding, or why something changed. Every answer shows its sources — the decisions, work and conversations it came from — and you can open any of them."),
        Page(icon: "point.3.filled.connected.trianglepath.dotted",
             title: "Follow the connections",
             body: "A decision links to the work it affects, the people who made it and the conversation it came from. When a link doesn't exist, it says so rather than guessing."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: DS.Space.l) {
                Image(systemName: pages[page].icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.accentColor)
                    .frame(height: 56)
                    .accessibilityHidden(true)
                Text(pages[page].title)
                    .font(DS.Font.display)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pages[page].body)
                    .font(DS.Font.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.xxl)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(pages[page].title). \(pages[page].body)")

            Spacer()

            HStack(spacing: DS.Space.s) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityLabel("Step \(page + 1) of \(pages.count)")
            .padding(.bottom, DS.Space.l)

            HStack {
                Button("Back") { withAnimation { page -= 1 } }
                    .disabled(page == 0)
                    .opacity(page == 0 ? 0 : 1)
                Spacer()
                Button(page == pages.count - 1 ? "Get started" : "Next") {
                    if page == pages.count - 1 { finish() } else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(DS.Space.xl)
        }
        .frame(width: 620, height: 480)
        .background(DS.Surface.canvas)
    }
}
