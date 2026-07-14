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
}
