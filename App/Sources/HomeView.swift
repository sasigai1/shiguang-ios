import SwiftUI

struct PersonRoute: Hashable { let person: Person }
struct LibraryRoute: Hashable { let library: BaseItem; var genre: String? = nil; var filter: String? = nil; var title: String? = nil }

extension View {
    func itemDestinations() -> some View {
        self
            .navigationDestination(for: BaseItem.self) { item in
                if item.isFolderLike || item.type == "CollectionFolder" || item.type == "UserView" || item.type == "BoxSet" || item.type == "Folder" {
                    LibraryView(route: LibraryRoute(library: item))
                } else {
                    DetailView(itemId: item.id, seed: item)
                }
            }
            .navigationDestination(for: PersonRoute.self) { r in PersonView(person: r.person) }
            .navigationDestination(for: LibraryRoute.self) { r in LibraryView(route: r) }
    }
}

@MainActor
final class HomeModel: ObservableObject {
    @Published var views: [BaseItem] = []
    @Published var resume: [BaseItem] = []
    @Published var nextUp: [BaseItem] = []
    @Published var latest: [(BaseItem, [BaseItem])] = []
    @Published var hero: [BaseItem] = []
    @Published var error: String?
    @Published var loaded = false

    func load(_ c: EmbyClient) async {
        do {
            let v = try await c.views()
            views = v
            resume = (try? await c.resume()) ?? []
            nextUp = (try? await c.nextUp()) ?? []
            var rows: [(BaseItem, [BaseItem])] = []
            await withTaskGroup(of: (Int, [BaseItem]).self) { g in
                for (i, lib) in v.enumerated() where ["movies", "tvshows", "homevideos", "musicvideos", "mixed", nil].contains(lib.collectionType) {
                    g.addTask { (i, (try? await c.latest(parent: lib.id)) ?? []) }
                }
                var tmp: [Int: [BaseItem]] = [:]
                for await (i, items) in g { tmp[i] = items }
                for i in tmp.keys.sorted() where !(tmp[i] ?? []).isEmpty { rows.append((v[i], tmp[i]!)) }
            }
            latest = rows
            let pool = rows.flatMap { $0.1 }.filter { !($0.backdropImageTags ?? []).isEmpty || $0.parentBackdropItemId != nil }
            hero = Array(pool.shuffled().prefix(6))
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loaded = true
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @StateObject var model = HomeModel()
    @State private var playItem: BaseItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let e = model.error, model.views.isEmpty {
                    ErrorView(message: e) { Task { await reload() } }.padding(.top, 120)
                } else if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
                } else {
                    if !model.hero.isEmpty { HeroCarousel(items: model.hero, play: { playItem = $0 }) }
                    if !model.views.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(model.views) { v in
                                    NavigationLink(value: v) { LibraryTile(item: v) }.buttonStyle(PressStyle())
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    if !model.resume.isEmpty {
                        row("继续观看") {
                            ForEach(model.resume) { i in
                                Button { playItem = i } label: { ThumbCard(item: i) }.buttonStyle(PressStyle())
                                    .contextMenu { NavigationLink(value: i) { Label("查看详情", systemImage: "info.circle") } }
                            }
                        }
                    }
                    if !model.nextUp.isEmpty {
                        row("接下来") {
                            ForEach(model.nextUp) { i in
                                NavigationLink(value: i) { ThumbCard(item: i, width: 220) }.buttonStyle(PressStyle())
                            }
                        }
                    }
                    ForEach(model.latest, id: \.0.id) { lib, items in
                        VStack(alignment: .leading, spacing: 12) {
                            NavigationLink(value: lib) {
                                HStack {
                                    Text("最新 · \(lib.name ?? "")").font(.system(size: 20, weight: .bold))
                                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                            }
                            .buttonStyle(.plain)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(items) { i in NavigationLink(value: i) { PosterCard(item: i) }.buttonStyle(PressStyle()) }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .ignoresSafeArea(edges: model.hero.isEmpty ? [] : .top)
        .toolbar(model.hero.isEmpty ? .visible : .hidden, for: .navigationBar)
        .navigationTitle("首页")
        .refreshable { await reload() }
        .task { if !model.loaded { await reload() } }
        .itemDestinations()
        .fullScreenCover(item: $playItem, onDismiss: { Task { await reload() } }) { i in PlayerScreen(item: i) }
    }

    func reload() async { if let c = app.client { await model.load(c) } }

    func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }.padding(.horizontal, 20)
            }
        }
    }
}

struct LibraryTile: View {
    @EnvironmentObject var app: AppState
    let item: BaseItem
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: app.client?.poster(item, width: 500)).frame(width: 150, height: 84)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(item.name ?? "").font(.system(size: 13, weight: .bold)).lineLimit(1)
            }
            .padding(10)
        }
        .frame(width: 150, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
        .foregroundStyle(.white)
    }
    var icon: String {
        switch item.collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "boxsets": return "square.stack.3d.up"
        case "livetv": return "antenna.radiowaves.left.and.right"
        default: return "folder"
        }
    }
}

struct HeroCarousel: View {
    @EnvironmentObject var app: AppState
    let items: [BaseItem]
    let play: (BaseItem) -> Void
    @State private var index = 0
    let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.1.id) { idx, item in
                    ZStack(alignment: .bottomLeading) {
                        RemoteImage(url: app.client?.backdrop(item)).frame(width: g.size.width, height: h).clipped()
                        LinearGradient(colors: [.black.opacity(0.3), .clear, Theme.bg.opacity(0.85), Theme.bg], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 10) {
                            if let l = app.client?.logo(item) {
                                RemoteImage(url: l, contentMode: .fit).frame(maxWidth: 220, maxHeight: 80, alignment: .leading)
                            } else {
                                Text(item.isEpisode ? (item.seriesName ?? "") : (item.name ?? "")).font(.system(size: 30, weight: .heavy)).lineLimit(2)
                            }
                            HStack(spacing: 8) {
                                if let y = item.productionYear { Chip(text: String(y)) }
                                if let r = item.communityRating { Chip(text: String(format: "%.1f", r), icon: "star.fill") }
                                if let gn = item.genres?.first { Chip(text: gn) }
                            }
                            HStack(spacing: 12) {
                                Button { play(item) } label: {
                                    Label("播放", systemImage: "play.fill").font(.system(size: 15, weight: .bold))
                                        .padding(.horizontal, 22).frame(height: 44)
                                        .background(Capsule().fill(.white)).foregroundStyle(.black)
                                }
                                NavigationLink(value: item) {
                                    Label("详情", systemImage: "info.circle").font(.system(size: 15, weight: .semibold))
                                        .padding(.horizontal, 18).frame(height: 44)
                                        .background(Capsule().fill(.ultraThinMaterial))
                                }
                            }
                            .buttonStyle(PressStyle())
                        }
                        .padding(.horizontal, 20).padding(.bottom, 34)
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .bottom) {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule().fill(i == index ? Color.white : Color.white.opacity(0.3)).frame(width: i == index ? 18 : 6, height: 6)
                    }
                }
                .animation(.spring(), value: index)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 520)
        .onReceive(timer) { _ in withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % max(items.count, 1) } }
    }
}
