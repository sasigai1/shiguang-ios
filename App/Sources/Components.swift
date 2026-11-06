import SwiftUI

enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.071)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.545, green: 0.42, blue: 1.0)
    static let accent2 = Color(red: 0.31, green: 0.78, blue: 1.0)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let secondary = Color.white.opacity(0.6)
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
            case .failure: placeholder.overlay(Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.25)))
            default: placeholder.overlay(ShimmerView())
            }
        }
    }
    var placeholder: some View {
        LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
    }
}

struct ShimmerView: View {
    @State private var x: CGFloat = -1
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.6)
                .offset(x: x * g.size.width * 1.6)
                .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { x = 1 } }
        }
        .clipped()
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.gradient).frame(width: max(4, g.size.width * value))
            }
        }
        .frame(height: 4)
    }
}

struct PlayedBadge: View {
    let item: BaseItem
    var body: some View {
        if item.userData?.played == true {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).padding(5)
                .background(Circle().fill(Theme.accent))
        } else if let n = item.userData?.unplayedItemCount, n > 0 {
            Text("\(n)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.accent))
        }
    }
}

struct PosterCard: View {
    @EnvironmentObject var app: AppState
    let item: BaseItem
    var width: CGFloat = 120
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: app.client?.poster(item))
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                .overlay(alignment: .topTrailing) { PlayedBadge(item: item).padding(6) }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressBar(value: p).padding(8) }
                }
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            Text(item.isEpisode ? (item.seriesName ?? item.name ?? "") : (item.name ?? ""))
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .frame(width: width)
    }
    var subtitle: String {
        if let e = item.episodeLabel { return e + " " + (item.name ?? "") }
        var p: [String] = []
        if let y = item.productionYear { p.append(String(y)) }
        if let r = item.communityRating { p.append(String(format: "★ %.1f", r)) }
        return p.joined(separator: "  ")
    }
}

struct ThumbCard: View {
    @EnvironmentObject var app: AppState
    let item: BaseItem
    var width: CGFloat = 260
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: app.client?.thumb(item))
                    .frame(width: width, height: width * 9 / 16)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "play.fill").font(.system(size: 11))
                        if let t = remaining { Text(t).font(.system(size: 11, weight: .medium)) }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    if let p = item.progress { ProgressBar(value: p) }
                }
                .padding(10)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            Text(item.isEpisode ? (item.seriesName ?? "") : (item.name ?? "")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if item.isEpisode {
                Text("\(item.episodeLabel ?? "") · \(item.name ?? "")").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
    }
    var remaining: String? {
        guard let total = item.runTimeTicks, total > 0 else { return nil }
        let left = Int((total - item.resumeTicks) / 600_000_000)
        return item.resumeTicks > 0 ? "剩余 \(left) 分钟" : item.runtimeText
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 20, weight: .bold))
            Spacer()
            if let a = action {
                Button(action: a) { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary) }
            }
        }
        .padding(.horizontal, 20)
    }
}

struct Chip: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let i = icon { Image(systemName: i).font(.system(size: 10)) }
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }
}

struct GlassButton: View {
    let icon: String
    var label: String? = nil
    var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(active ? Theme.accent : .white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                if let l = label { Text(l).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            }
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(Theme.secondary)
            Text(message).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    func screenBackground() -> some View {
        self.background(
            ZStack {
                Theme.bg
                RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 500)
            }
            .ignoresSafeArea()
        )
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}
