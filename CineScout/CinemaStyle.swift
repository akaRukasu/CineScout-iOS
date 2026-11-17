import SwiftUI

enum CinemaPalette {
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.075)
    static let violet = Color(red: 0.53, green: 0.39, blue: 0.98)
    static let coral = Color(red: 0.98, green: 0.43, blue: 0.34)
    static let gold = Color(red: 1, green: 0.77, blue: 0.38)
}

struct CinemaBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [CinemaPalette.ink, Color(red: 0.065, green: 0.055, blue: 0.11), .black]
                : [Color(red: 0.95, green: 0.94, blue: 1), Color(uiColor: .systemGroupedBackground)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct CinemaScore: View {
    let item: TMItem

    var body: some View {
        if let score = item.vote_average, score > 0 {
            Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(CinemaPalette.gold)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.black.opacity(0.72), in: Capsule())
                .accessibilityLabel("\(score.formatted(.number.precision(.fractionLength(1)))) sur 10 sur TMDb")
        }
    }
}

struct RouletteEntryCard: View {
    var artwork: [TMItem]

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Label("Roulette", systemImage: "die.face.5.fill").font(.title2.bold())
                Text("Jusqu’à 10 découvertes, à ton rythme.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.76))
                Image(systemName: "arrow.right")
                    .font(.body.bold())
                    .frame(width: 42, height: 36)
                    .background(.white.opacity(0.12), in: Capsule())
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                ForEach(Array(artwork.prefix(3).enumerated()), id: \.offset) { index, item in
                    Poster(path: item.poster_path, cornerRadius: 10)
                        .frame(width: 66)
                        .rotationEffect(.degrees(Double(index - 1) * 14))
                        .offset(x: CGFloat(index - 1) * 25, y: index == 1 ? -5 : 4)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 7)
                }
                if artwork.isEmpty {
                    Image(systemName: "die.face.5.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 110, height: 122)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background {
            LinearGradient(colors: [CinemaPalette.violet.opacity(0.8), Color(red: 0.21, green: 0.12, blue: 0.39)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(.rect(cornerRadius: 28))
        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12)) }
        .accessibilityElement(children: .combine)
    }
}
