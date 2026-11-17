import SwiftUI

struct GlassControlGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }
}

struct ArtworkBookmarkButton: View {
    let title: String
    let saved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if #available(iOS 26.0, *) {
                symbol.glassEffect(.regular.interactive(), in: .circle)
            } else {
                symbol.background(.regularMaterial, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(saved ? "Retirer \(title) de mes envies" : "Ajouter \(title) à mes envies")
        .accessibilityAddTraits(saved ? .isSelected : [])
    }

    private var symbol: some View {
        Image(systemName: saved ? "bookmark.fill" : "bookmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}
