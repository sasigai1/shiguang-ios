import SwiftUI

struct PlayRequest: Identifiable {
    let id = UUID()
    let item: BaseItem
    var fromStart = false
    var queue: [BaseItem] = []
}

struct DetailView: View {
    @EnvironmentObject var app: AppState
    let itemId: String
    var seed: BaseItem?
    @State private var item: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var season: BaseItem?
    @State private var episodes: [BaseItem] = []
    @State private var similar: [BaseItem] = []
    @State private var nextEpisode: BaseItem?
    @State private var play: PlayRequest?
    @State private var expanded = false
    @State private var error: String?
    @State private var showInfo = false

    var shown: BaseItem? { item ?? seed }

    var body: some View {
        ScrollView {
            if let i = shown {
                VStack(alignment: .leading, spacing: 22) {
                    header(i)
                    actions(i)
                    if let t = i.taglines?.first, !t.isEmpty {
                        Text("“\(t)”").font(.system(size: 15, weight: .medium)).italic().foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 20)
                    }
                    if let o = i.overview, !o.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(o).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).lineSpacing(4)
                                .lineLimit(expanded ? nil : 4)
                            Button(expanded ? "收起" : "展开") { withAnimation { expanded.toggle() } }.font(.footnote.bold())
                        }
                        .padding(.horizontal, 20)
                    }
                    if let g = i.genres, !g.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { ForEach(g, id: \.self) { Chip(text: $0) } }.padding(.horizontal, 20)
                        }
                    }
                    if i.isSeries { seasonSection(i) }
                    if i.isEpisode, let sid = i.seriesId {
                        NavigationLink(value: BaseItem(id: sid, name: i.seriesName, type: "Series")) {
                            HStack {
                                Image(systemName: "tv")
                                Text("查看整部剧：\(i.seriesName ?? "")").font(.subheadline.bold())
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(14).background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                        }
                        .buttonStyle(PressStyle()).padding(.horizontal, 20)
                    }
                    if let people = i.people, !people.isEmpty { castSection(people) }
                    if !similar.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "相似推荐")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(similar) { s in NavigationLink(value: s) { PosterCard(item: s) }.buttonStyle(PressStyle()) }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                    if let src = i.mediaSources?.first { mediaInfo(src, all: i.mediaSources ?? []) }
                }
                .padding(.bottom, 40)
            } else if let e = error {
                ErrorView(message: e) { Task { await load() } }.padding(.top, 200)
            } else {
                ProgressView().padding(.top, 300).frame(maxWidth: .infinity)
            }
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { if item == nil { await load() } }
        .fullScreenCover(item: $play, onDismiss: { Task { await load() } }) { r in
            PlayerScreen(item: r.item, fromStart: r.fromStart, queue: r.queue)
        }
    }

    // MARK: Header
    func header(_ i: BaseItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { g in
                let minY = g.frame(in: .global).minY
                RemoteImage(url: app.client?.backdrop(i))
                    .frame(width: g.size.width, height: 420 + max(0, minY))
                    .clipped()
                    .offset(y: minY > 0 ? -minY : -minY * 0.3)
            }
            .frame(height: 420)
            LinearGradient(colors: [.black.opacity(0.35), .clear, Theme.bg.opacity(0.7), Theme.bg], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 16) {
                if !i.isEpisode {
                    RemoteImage(url: app.client?.poster(i))
                        .frame(width: 110, height: 165)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
                        .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let l = app.client?.logo(i) {
                        RemoteImage(url: l, contentMode: .fit).frame(maxWidth: 200, maxHeight: 70, alignment: .leading)
                    } else {
                        if i.isEpisode, let s = i.seriesName { Text(s).font(.subheadline.bold()).foregroundStyle(Theme.accent) }
                        Text(i.name ?? "").font(.system(size: 26, weight: .heavy)).lineLimit(3)
                    }
                    if let o = i.originalTitle, o != i.name { Text(o).font(.footnote).foregroundStyle(Theme.secondary).lineLimit(1) }
                    metaRow(i)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 420)
    }

    func metaRow(_ i: BaseItem) -> some View {
        FlowLayout(spacing: 6) {
            if let e = i.episodeLabel { Chip(text: e) }
            if let y = i.yearText { Chip(text: y) }
            if let r = i.communityRating { Chip(text: String(format: "%.1f", r), icon: "star.fill") }
            if let r = i.officialRating { Chip(text: r) }
            if let t = i.runtimeText { Chip(text: t, icon: "clock") }
            if let v = i.mediaSources?.first?.videoStream {
                if let h = v.height { Chip(text: h >= 2000 ? "4K" : h >= 1000 ? "1080P" : "\(h)P") }
                if let r = v.videoRange, r != "SDR" { Chip(text: r) }
            }
            if i.isSeries, let c = i.childCount { Chip(text: "\(c) 季") }
        }
    }

    // MARK: Actions
    func actions(_ i: BaseItem) -> some View {
        VStack(spacing: 14) {
            if i.isPlayable || i.isSeries {
                Button {
                    if i.isSeries {
                        if let n = nextEpisode ?? episodes.first { play = PlayRequest(item: n, queue: queue(after: n)) }
                    } else { play = PlayRequest(item: i, queue: i.isEpisode ? queue(after: i) : []) }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text(playLabel(i)).bold()
                        }
                        .font(.system(size: 17))
                        if let p = i.progress, !i.isSeries {
                            ProgressBar(value: p).frame(width: 160).opacity(0.9)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.gradient))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 16, y: 6)
                    .foregroundStyle(.white)
                }
                .buttonStyle(PressStyle())
            }
            HStack(spacing: 0) {
                if i.resumeTicks > 0 && !i.isSeries {
                    GlassButton(icon: "arrow.counterclockwise", label: "从头播放") { play = PlayRequest(item: i, fromStart: true, queue: i.isEpisode ? queue(after: i) : []) }
                        .frame(maxWidth: .infinity)
                }
                GlassButton(icon: i.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle", label: i.userData?.played == true ? "已看过" : "标记已看", active: i.userData?.played == true) {
                    toggle(played: true)
                }
                .frame(maxWidth: .infinity)
                GlassButton(icon: i.userData?.isFavorite == true ? "heart.fill" : "heart", label: "收藏", active: i.userData?.isFavorite == true) {
                    toggle(played: false)
                }
                .frame(maxWidth: .infinity)
                if let s = i.mediaSources, !s.isEmpty {
                    GlassButton(icon: "info.circle", label: "媒体信息") { withAnimation { showInfo.toggle() } }
                        .frame(maxWidth: .infinity)
                }
                ShareLink(item: (i.name ?? "") + (i.overview.map { "\n" + $0 } ?? "")) {
                    VStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
                            .frame(width: 48, height: 48).background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().stroke(Theme.stroke))
                        Text("分享").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
    }

    func playLabel(_ i: BaseItem) -> String {
        if i.isSeries {
            if let n = nextEpisode { return "播放 \(n.episodeLabel ?? n.name ?? "")" }
            return "开始播放"
        }
        if i.resumeTicks > 0 { return "继续播放 \(formatTime(Double(i.resumeTicks) / 10_000_000))" }
        return "播放"
    }

    func queue(after e: BaseItem) -> [BaseItem] {
        guard let idx = episodes.firstIndex(where: { $0.id == e.id }) else { return [] }
        return Array(episodes.suffix(from: episodes.index(after: idx)))
    }

    // MARK: Seasons
    func seasonSection(_ i: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons) { s in
                            Button { season = s; Task { await loadEpisodes() } } label: {
                                Text(s.name ?? "").font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(Capsule().fill(season?.id == s.id ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.08))))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                }
            } else {
                SectionHeader(title: season?.name ?? "剧集")
            }
            LazyVStack(spacing: 12) {
                ForEach(episodes) { e in
                    Button { play = PlayRequest(item: e, queue: queue(after: e)) } label: { EpisodeRow(item: e) }
                        .buttonStyle(PressStyle())
                        .contextMenu {
                            Button { play = PlayRequest(item: e, fromStart: true, queue: queue(after: e)) } label: { Label("从头播放", systemImage: "arrow.counterclockwise") }
                            Button { Task { try? await app.client?.setPlayed(e.id, e.userData?.played != true); await loadEpisodes() } } label: {
                                Label(e.userData?.played == true ? "标记未看" : "标记已看", systemImage: "checkmark.circle")
                            }
                            NavigationLink(value: e) { Label("单集详情", systemImage: "info.circle") }
                        }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    func castSection(_ people: [Person]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "演职人员")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(people.prefix(30)) { p in
                        NavigationLink(value: PersonRoute(person: p)) {
                            VStack(spacing: 6) {
                                RemoteImage(url: app.client?.personImage(p))
                                    .frame(width: 76, height: 76).clipShape(Circle())
                                    .overlay(Circle().stroke(Theme.stroke))
                                Text(p.name ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(p.role ?? (p.type == "Director" ? "导演" : p.type ?? "")).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            .frame(width: 84)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder func mediaInfo(_ src: MediaSource, all: [MediaSource]) -> some View {
        if showInfo {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "媒体信息")
                ForEach(all) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.label).font(.subheadline.bold())
                        if let c = s.container { infoLine("容器", c.uppercased()) }
                        if let b = s.bitrate { infoLine("码率", String(format: "%.1f Mbps", Double(b) / 1_000_000)) }
                        if let sz = s.size { infoLine("大小", ByteCountFormatter.string(fromByteCount: sz, countStyle: .file)) }
                        ForEach(s.mediaStreams ?? [], id: \.index) { m in
                            infoLine(m.type == "Video" ? "视频" : m.type == "Audio" ? "音频" : m.type == "Subtitle" ? "字幕" : (m.type ?? ""), m.label)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                }
                .padding(.horizontal, 20)
            }
            .transition(.opacity)
        }
    }

    func infoLine(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(Theme.secondary).frame(width: 40, alignment: .leading)
            Text(v).font(.caption)
        }
    }

    // MARK: Data
    func load() async {
        guard let c = app.client else { return }
        do {
            let i = try await c.item(itemId)
            item = i
            error = nil
            if i.isSeries {
                seasons = (try? await c.seasons(series: i.id)) ?? []
                let nu = (try? await c.get("/Shows/NextUp", ["UserId": c.uid, "SeriesId": i.id, "Limit": "1", "Fields": EmbyClient.fields]) as ItemsResult)?.items.first
                nextEpisode = nu
                if season == nil {
                    season = seasons.first(where: { $0.id == nu?.seasonId }) ?? seasons.first
                }
                await loadEpisodes()
            } else if i.isEpisode, let sid = i.seriesId, let season = i.seasonId {
                episodes = (try? await c.episodes(series: sid, season: season)) ?? []
            }
            if similar.isEmpty, !i.isEpisode { similar = (try? await c.similar(i.id)) ?? [] }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadEpisodes() async {
        guard let c = app.client, let i = shown, let s = season else { return }
        episodes = (try? await c.episodes(series: i.id, season: s.id)) ?? []
    }

    func toggle(played: Bool) {
        guard let c = app.client, let i = shown else { return }
        Task {
            if played { try? await c.setPlayed(i.id, i.userData?.played != true) }
            else { try? await c.setFavorite(i.id, i.userData?.isFavorite != true) }
            let g = UIImpactFeedbackGenerator(style: .medium); g.impactOccurred()
            await load()
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var app: AppState
    let item: BaseItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: app.client?.thumb(item, width: 400)).frame(width: 150, height: 84)
                if let p = item.progress { ProgressBar(value: p).padding(6) }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) { PlayedBadge(item: item).padding(5) }
            .overlay { Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 6) }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.indexNumber.map { "\($0). " } ?? "")\(item.name ?? "")").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if let r = item.runtimeText { Text(r).font(.caption).foregroundStyle(Theme.secondary) }
                if let o = item.overview { Text(o).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
    }
}
