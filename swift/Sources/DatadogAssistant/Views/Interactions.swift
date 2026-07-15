import SwiftUI

/// Press feedback for every tappable surface: a subtle scale-down (and slight
/// dim) on press, eased out ~140ms. Apple/Emil-Kowalski guidance: pressables
/// get `scale(0.95–0.98)` in ~100–160ms — the single biggest tactile-polish
/// win. Behaves like `.plain` otherwise (no default chrome), and honors Reduce
/// Motion (no scale, just the dim).
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    // A nested view so @Environment resolves correctly (reading environment
    // directly in a ButtonStyle is unreliable).
    func makeBody(configuration: Configuration) -> some View {
        PressLabel(configuration: configuration, scale: scale)
    }

    private struct PressLabel: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// `.plain` + a press scale — use for custom rows, chips, and icon buttons.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension View {
    /// The standard fade for hover highlights — a short ease-out so fills
    /// materialize rather than snap ("hover/color changes use ease").
    func hoverFade(_ hovering: Bool) -> some View {
        animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Reduce-Motion-aware spring: the given spring normally, a quick opacity-
    /// friendly ease when the user asked for less motion.
    func animatedContent<V: Equatable>(_ value: V, reduceMotion: Bool,
                                       response: Double = 0.4,
                                       damping: Double = 0.85) -> some View {
        animation(reduceMotion ? .easeOut(duration: 0.2)
                               : .spring(response: response, dampingFraction: damping),
                  value: value)
    }

    /// A single, non-repeating SF Symbol bounce keyed on `value` — plays only
    /// when `value` changes while the view is on screen (e.g. favoriting a
    /// monitor). macOS 14+ only, and suppressed under Reduce Motion; a plain
    /// no-op everywhere else so call-sites don't repeat the availability and
    /// accessibility gates.
    @ViewBuilder
    func symbolBounceIfAvailable<V: Equatable>(on value: V, reduceMotion: Bool) -> some View {
        if #available(macOS 14.0, *), !reduceMotion {
            symbolEffect(.bounce, options: .nonRepeating, value: value)
        } else {
            self
        }
    }

    /// A single, non-repeating SF Symbol bounce that fires once as the view
    /// appears (e.g. the connection-success checkmark). macOS 14+ only, and
    /// suppressed under Reduce Motion; a no-op everywhere else. Uses the
    /// value-keyed effect (flipped in `onAppear`) so it plays reliably on
    /// insertion and avoids the discrete/indefinite overload ambiguity.
    @ViewBuilder
    func symbolBounceOnAppearIfAvailable(reduceMotion: Bool) -> some View {
        if #available(macOS 14.0, *), !reduceMotion {
            modifier(SymbolBounceOnAppear())
        } else {
            self
        }
    }
}

@available(macOS 14.0, *)
private struct SymbolBounceOnAppear: ViewModifier {
    @State private var trigger = false

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .nonRepeating, value: trigger)
            .onAppear { trigger = true }
    }
}
