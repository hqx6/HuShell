import SwiftUI

/// Native Liquid Glass on recent macOS, with a translucent material fallback.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = 10

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
