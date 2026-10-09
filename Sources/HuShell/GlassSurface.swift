import SwiftUI

/// Native Liquid Glass on recent macOS, with a translucent material fallback.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = 10
    @State private var isHovered = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            styled(content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius)))
        } else {
            styled(content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius)))
        }
    }

    private func styled<V: View>(_ content: V) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.accentColor.opacity(isHovered ? 0.10 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor.opacity(isHovered ? 0.28 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}
