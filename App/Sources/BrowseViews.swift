import SwiftUI

struct LibrariesView: View {
    @EnvironmentObject var app: AppState
    @State private var views: [BaseItem] = []
    @State private var error: String?
    let cols = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            if let e = error, views.isEmpty {
                ErrorView(message: e) { Task { await load() } }
            }
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(views) { v in
                    NavigationLink(value: v) {
                        ZStack(alignment: .bottomLeading) {
                            RemoteImage(url: app.client?.poster(v, width: 600)).frame(height: 100)
                            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                            Text(v.name ?? "").font(.system(size: 16, weight: .bold)).padding(12)
                        }
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("媒体库")
        .task { if views.isEmpty { await load() } }
        .refreshable { await load() }
        .itemDestinations()
    }

    func load() async {
        guard let c = app.client else { return }
        do { views = try await c.views(); error = nil } catch { self.error = error.localizedDescription }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case name = "SortName", added = "DateCreated", premiere = "PremiereDate", rating = "CommunityRating", played = "DatePlayed", random = "Random", runtime = "Runtime"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "名称"
        case .added: return "加入日期"
        case .premiere: return "上映日期"
        case .rating: return "评分"
        case .played: return "最近播放"
        case .random: return "随机"
        case .runtime: return "时长"
        }
    }
}

enum FilterOption: String, CaseIterable, Identifiable {
    case all = "", unplayed = "IsUnplayed", played = "IsPlayed", favorite = "IsFavorite", resumable = "IsResumable"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .unplayed: return "未看"
        case .played: return "已看"
        case .favorite: return "收藏"
        case .resumable: return "看了一半"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    let route: LibraryRoute
    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var sort: SortOption = .added
    @State private var ascending = false
    @State private var filter: FilterOption = .all
    @State private var genre: String?
    @State private var genres: [String] = []
    @State private var error: String?
    @AppStorage("gridDense") private var dense = false

    var cols: [GridItem] { [GridItem(.adaptive(minimum: dense ? 96 : 120), spacing: 14, alignment: .top)] }

    var types: String? {
        switch route.library.collectionType {
        case "movies": return "Movie"
        case "tvshows": return "Series"
        case "boxsets": return "BoxSet"
        case "musicvideos": return "MusicVideo"
        case "homevideos": return "Video,Photo"
        default: return route.library.type == "BoxSet" ? nil : "Movie,Series,Video"
        }
    }
    var recursive: Bool { route.library.type == "BoxSet" || route.library.type == "Folder" ? false : true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            genreChip(nil, "全部类型")
                            ForEach(genres, id: \.self) { g in genreChip(g, g) }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                Text("\(total) 部").font(.footnote).foregroundStyle(Theme.secondary).padding(.horizontal, 20)
                if let e = error, items.isEmpty { ErrorView(message: e) { Task { await reload() } } }
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(items) { i in
                        NavigationLink(value: i) { PosterCard(item: i, width: dense ? 96 : 120) }
                            .buttonStyle(PressStyle())
                            .onAppear { if i.id == items.last?.id { Task { await more() } } }
                    }
                }
                .padding(.horizontal, 16)
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 10)
        }
        .screenBackground()
        .navigationTitle(route.title ?? route.genre ?? route.library.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("排序", selection: $sort) { ForEach(SortOption.allCases) { Text($0.label).tag($0) } }
                    Toggle(isOn: $ascending) { Label("升序", systemImage: "arrow.up") }
                    Divider()
                    Picker("筛选", selection: $filter) { ForEach(FilterOption.allCases) { Text($0.label).tag($0) } }
                    Divider()
                    Toggle(isOn: $dense) { Label("紧凑网格", systemImage: "square.grid.3x3") }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .task {
            if items.isEmpty {
                genre = route.genre
                if let f = route.filter, let fo = FilterOption(rawValue: f) { filter = fo }
                await reload()
                if route.genre == nil, let c = app.client, route.library.type != "BoxSet" {
                    genres = ((try? await c.genres(parent: route.library.id)) ?? []).compactMap { $0.name }
                }
            }
        }
        .onChange(of: sort) { _ in Task { await reload() } }
        .onChange(of: ascending) { _ in Task { await reload() } }
        .onChange(of: filter) { _ in Task { await reload() } }
        .onChange(of: genre) { _ in Task { await reload() } }
        .refreshable { await reload() }
    }

    func genreChip(_ g: String?, _ label: String) -> some View {
        Button { genre = g } label: {
            Text(label).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(genre == g ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.08))))
        }
        .buttonStyle(PressStyle())
    }

    func fetch(start: Int) async throws -> ItemsResult {
        guard let c = app.client else { throw APIError.badURL }
        return try await c.items(parent: route.library.id, types: types, sortBy: sort == .name ? "SortName" : "\(sort.rawValue),SortName",
                                 order: ascending ? "Ascending" : "Descending", filters: filter.rawValue.isEmpty ? nil : filter.rawValue,
                                 genre: genre, start: start, limit: 60, recursive: recursive)
    }

    func reload() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await fetch(start: 0)
            items = r.items; total = r.totalRecordCount ?? r.items.count; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func more() async {
        guard !loading, items.count < total else { return }
        loading = true
        defer { loading = false }
        if let r = try? await fetch(start: items.count) { items += r.items }
    }
}

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var suggestions: [BaseItem] = []
    @State private var searching = false
    @AppStorage("searchHistory") private var historyRaw = ""
    var history: [String] { historyRaw.split(separator: "\n").map(String.init) }
    let cols = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if query.isEmpty {
                    if !history.isEmpty {
                        HStack {
                            Text("最近搜索").font(.headline)
                            Spacer()
                            Button("清除") { historyRaw = "" }.font(.footnote)
                        }
                        FlowLayout(spacing: 8) {
                            ForEach(history, id: \.self) { h in Button { query = h } label: { Chip(text: h) }.buttonStyle(.plain) }
                        }
                    }
                    if !suggestions.isEmpty {
                        Text("随便看看").font(.headline)
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(suggestions) { i in NavigationLink(value: i) { PosterCard(item: i, width: 110) }.buttonStyle(PressStyle()) }
                        }
                    }
                } else if searching && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if results.isEmpty {
                    Text("没有找到「\(query)」").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(results) { i in NavigationLink(value: i) { PosterCard(item: i, width: 110) }.buttonStyle(PressStyle()) }
                    }
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("搜索")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "电影、剧集、演员")
        .onSubmit(of: .search) { addHistory(query) }
        .task(id: query) {
            guard !query.isEmpty, let c = app.client else { results = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            searching = true
            let r = try? await c.items(types: "Movie,Series,Episode,BoxSet", sortBy: "SortName", search: query, limit: 60)
            if !Task.isCancelled { results = r?.items ?? [] }
            searching = false
        }
        .task {
            if suggestions.isEmpty, let c = app.client {
                suggestions = (try? await c.items(types: "Movie,Series", sortBy: "Random", limit: 18))?.items ?? []
            }
        }
        .itemDestinations()
    }

    func addHistory(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var h = history.filter { $0 != t }
        h.insert(t, at: 0)
        historyRaw = h.prefix(12).joined(separator: "\n")
    }
}

struct FavoritesView: View {
    @EnvironmentObject var app: AppState
    @State private var movies: [BaseItem] = []
    @State private var series: [BaseItem] = []
    @State private var episodes: [BaseItem] = []
    @State private var people: [BaseItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if loaded && movies.isEmpty && series.isEmpty && episodes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "heart").font(.system(size: 44)).foregroundStyle(Theme.secondary)
                        Text("还没有收藏，在详情页点 ♥ 就能加进来").foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 140)
                }
                section("电影", movies)
                section("剧集", series)
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "单集")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(episodes) { i in NavigationLink(value: i) { ThumbCard(item: i, width: 220) }.buttonStyle(PressStyle()) }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .screenBackground()
        .navigationTitle("收藏")
        .task { await load() }
        .refreshable { await load() }
        .itemDestinations()
    }

    @ViewBuilder func section(_ t: String, _ items: [BaseItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: t)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { i in NavigationLink(value: i) { PosterCard(item: i) }.buttonStyle(PressStyle()) }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    func load() async {
        guard let c = app.client else { return }
        movies = (try? await c.items(types: "Movie", sortBy: "SortName", filters: "IsFavorite", limit: 100))?.items ?? []
        series = (try? await c.items(types: "Series", sortBy: "SortName", filters: "IsFavorite", limit: 100))?.items ?? []
        episodes = (try? await c.items(types: "Episode", sortBy: "SortName", filters: "IsFavorite", limit: 100))?.items ?? []
        loaded = true
    }
}

struct PersonView: View {
    @EnvironmentObject var app: AppState
    let person: Person
    @State private var items: [BaseItem] = []
    @State private var detail: BaseItem?
    let cols = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                RemoteImage(url: app.client?.personImage(person))
                    .frame(width: 140, height: 140).clipShape(Circle())
                    .overlay(Circle().stroke(Theme.gradient, lineWidth: 3))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 20)
                Text(person.name ?? "").font(.title.bold())
                if let o = detail?.overview, !o.isEmpty {
                    Text(o).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(6).padding(.horizontal, 20)
                }
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(items) { i in NavigationLink(value: i) { PosterCard(item: i, width: 110) }.buttonStyle(PressStyle()) }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 20)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let c = app.client else { return }
            detail = try? await c.item(person.id)
            items = (try? await c.items(types: "Movie,Series", sortBy: "PremiereDate", order: "Descending", person: person.id, limit: 100))?.items ?? []
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
