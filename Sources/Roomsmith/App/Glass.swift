import SwiftUI

/// Window snapshots of the test hooks (`ROOMSMITH_SNAPSHOT`) draw the view tree into a bitmap, where glass and
/// materials stay empty; they get a flat panel colour instead.
enum GlassMode {
    static let flat = AppDefaults.isTestMode && !(ProcessInfo.processInfo.environment["ROOMSMITH_SNAPSHOT"] ?? "").isEmpty
}

/// Liquid Glass on macOS 26 and later, a material background otherwise. Used for floating bars and the status bar.
extension View {
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if GlassMode.flat {
            self.background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        } else if #available(macOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

/// Groups neighbouring glass panels so they blend and share one sampling pass (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
