import SwiftUI

enum RoulettePhase: Equatable {
    case idle
    case spinning(Date)
    case settling(Date)
    case revealed

    var isMoving: Bool {
        switch self {
        case .spinning, .settling: true
        case .idle, .revealed: false
        }
    }
}

struct RouletteStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let candidates: [TMItem]
    let winner: TMItem?
    let phase: RoulettePhase
    var status = "Prêt pour le tirage"
    @State private var artwork: [String: UIImage] = [:]

    private var artworkPaths: [String] {
        var paths = Set<String>()
        return ([winner].compactMap { $0 } + candidates).compactMap(\.poster_path)
            .filter { paths.insert($0).inserted }.prefix(18).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !phase.isMoving || reduceMotion)) { context in
                reels(at: context.date)
            }
            .frame(height: 240)
            .overlay(alignment: .top) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(CinemaPalette.gold)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                Text(phase == .revealed ? winner?.display ?? status : status)
                    .font(.title3.bold()).lineLimit(2).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                if phase == .revealed, let winner {
                    Text([winner.kindLabel, winner.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                } else {
                    Text("Films · séries · animation").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
        .background {
            ZStack {
                CinemaPalette.ink
                Ellipse().fill(CinemaPalette.violet.opacity(0.45))
                    .frame(width: 270, height: 160).blur(radius: 55).offset(x: -80, y: -55)
                Ellipse().fill(CinemaPalette.coral.opacity(0.23))
                    .frame(width: 190, height: 150).blur(radius: 55).offset(x: 140, y: 15)
            }
            .clipped()
        }
        .clipShape(.rect(cornerRadius: 30))
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.03)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .task(id: artworkPaths) { await loadArtwork() }
        .sensoryFeedback(.success, trigger: phase == .revealed)
    }

    private func position(at date: Date) -> Double {
        guard !reduceMotion else { return winner == nil ? 0 : 18 }
        switch phase {
        case .idle: return 0
        case .spinning(let start): return max(0, date.timeIntervalSince(start)) * 7
        case .settling(let start): return Roulette.reelPosition(elapsed: date.timeIntervalSince(start))
        case .revealed: return 18
        }
    }

    private func reels(at date: Date) -> some View {
        let position = position(at: date)
        let nearest = Int(position.rounded())
        return GeometryReader { geometry in
            ZStack {
                ForEach((nearest - 3)...(nearest + 3), id: \.self) { index in
                    let distance = Double(index) - position
                    face(at: index)
                        .frame(width: 118, height: 174)
                        .clipShape(.rect(cornerRadius: 15))
                        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.15)) }
                        .scaleEffect(1 - min(0.18, abs(distance) * 0.075))
                        .rotation3DEffect(.degrees(-distance * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        .opacity(max(0.2, 1 - abs(distance) * 0.18))
                        .offset(x: CGFloat(distance) * 136)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(CinemaPalette.gold.opacity(0.8), lineWidth: 1.5)
                .frame(width: 130, height: 188)
                .shadow(color: CinemaPalette.gold.opacity(0.2), radius: 12)
                .allowsHitTesting(false)
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.13),
                                   .init(color: .black, location: 0.87), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func face(at index: Int) -> some View {
        let isFinalSlot = index == 18 && winner != nil
        let item = isFinalSlot ? winner : candidates.isEmpty ? nil
            : candidates[((index % candidates.count) + candidates.count) % candidates.count]
        if let path = item?.poster_path, let image = artwork[path] {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 118, height: 174).clipped()
        } else {
            let symbols = ["film.fill", "tv.fill", "sparkles.tv.fill", "theatermasks.fill", "play.rectangle.fill"]
            let colors = [CinemaPalette.violet, CinemaPalette.coral, Color.teal, Color.indigo, CinemaPalette.gold]
            let value = ((index % symbols.count) + symbols.count) % symbols.count
            ZStack {
                LinearGradient(colors: [colors[value].opacity(0.65), CinemaPalette.ink],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 14) {
                    Image(systemName: symbols[value]).font(.system(size: 34, weight: .light))
                    if let item {
                        Text(item.display).font(.caption.bold()).lineLimit(3).multilineTextAlignment(.center)
                    }
                }.foregroundStyle(.white).padding(12)
            }
        }
    }

    private func loadArtwork() async {
        let retainedPaths = Set(artworkPaths)
        artwork = artwork.filter { retainedPaths.contains($0.key) }
        let paths = artworkPaths.filter { artwork[$0] == nil }
        await withTaskGroup(of: (String, Data?).self) { group in
            for path in paths {
                group.addTask {
                    guard let url = URL(string: "https://image.tmdb.org/t/p/w342" + path) else { return (path, nil) }
                    let data = try? await URLSession.shared.data(from: url).0
                    return (path, data)
                }
            }
            for await (path, data) in group {
                guard !Task.isCancelled else { return }
                if let data, let image = UIImage(data: data) { artwork[path] = image }
            }
        }
    }
}
