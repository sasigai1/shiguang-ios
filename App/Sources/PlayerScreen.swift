import SwiftUI
import AVKit

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let model: PlayerModel
    let fill: Bool
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = model.player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        DispatchQueue.main.async { model.layer = v.playerLayer }
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerScreen: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let item: BaseItem
    var fromStart = false
    var queue: [BaseItem] = []

    var body: some View {
        if let c = app.client {
            PlayerContent(client: c, item: item, queue: queue, fromStart: fromStart)
        } else {
            Color.black.onAppear { dismiss() }
        }
    }
}

struct PlayerContent: View {
    @Environment(\.dismiss) var dismiss
    @StateObject var model: PlayerModel
    @ObservedObject var settings = Settings.shared
    @State private var showControls = true
    @State private var locked = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: String?
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var dragStart: CGPoint?
    @State private var dragMode: Int = 0 // 1 seek, 2 brightness

    init(client: EmbyClient, item: BaseItem, queue: [BaseItem], fromStart: Bool) {
        _model = StateObject(wrappedValue: PlayerModel(client: client, item: item, queue: queue, fromStart: fromStart))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(model: model, fill: model.fill).ignoresSafeArea()

                // subtitles
                if let t = model.cueText {
                    VStack {
                        Spacer()
                        Text(t)
                            .font(.system(size: settings.subSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black, radius: 1, x: 1, y: 1)
                            .shadow(color: .black, radius: 3)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                            .padding(.bottom, showControls && !locked ? max(settings.subBottom, 110) : settings.subBottom)
                            .animation(.easeOut(duration: 0.2), value: showControls)
                    }
                    .padding(.horizontal, 40)
                    .allowsHitTesting(false)
                }

                // gesture layer
                Color.clear.contentShape(Rectangle())
                    .gesture(dragGesture(geo.size))
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { v in
                            guard !locked else { return }
                            let left = v.location.x < geo.size.width / 2
                            model.skip(left ? -Double(settings.skipSeconds) : Double(settings.skipSeconds))
                            flash(left ? "⏪ \(settings.skipSeconds) 秒" : "\(settings.skipSeconds) 秒 ⏩")
                        }
                    )
                    .simultaneousGesture(TapGesture().onEnded { toggleControls() })

                if model.isBuffering && model.error == nil {
                    ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
                }

                if let f = seekFlash {
                    Text(f).font(.system(size: 18, weight: .bold)).padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(.ultraThinMaterial)).transition(.opacity).allowsHitTesting(false)
                }

                if showControls {
                    if locked {
                        HStack {
                            Button { locked = false; scheduleHide() } label: { circleIcon("lock.fill") }
                            Spacer()
                        }
                        .padding(.horizontal, 30)
                        .transition(.opacity)
                    } else {
                        controls.transition(.opacity)
                    }
                }

                if let e = model.error {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text(e).multilineTextAlignment(.center).foregroundStyle(.white)
                        HStack {
                            Button("重试") { model.reopen() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button("关闭") { close() }.buttonStyle(.bordered)
                        }
                    }
                    .padding(24).background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial)).padding(40)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await model.start(); scheduleHide() }
        .onAppear { rotate(landscape: true); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { rotate(landscape: false); UIApplication.shared.isIdleTimerDisabled = false; UIScreen.main.brightness = brightness }
        .onChange(of: model.finished) { f in if f { close() } }
    }

    // MARK: Controls overlay
    var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                // top bar
                HStack(spacing: 14) {
                    Button { close() } label: { circleIcon("chevron.down") }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.item.isEpisode ? (model.item.seriesName ?? "") : (model.item.name ?? ""))
                            .font(.system(size: 16, weight: .bold)).lineLimit(1)
                        if model.item.isEpisode {
                            Text("\(model.item.episodeLabel ?? "") \(model.item.name ?? "")").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(methodLabel).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().stroke(.white.opacity(0.4)))
                    AirPlayButton().frame(width: 36, height: 36)
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        Button { model.togglePiP() } label: { circleIcon("pip.enter") }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 14)

                Spacer()

                // center
                HStack(spacing: 56) {
                    Button { model.skip(-Double(settings.skipSeconds)); scheduleHide() } label: {
                        Image(systemName: "gobackward.\(skipIcon)").font(.system(size: 30, weight: .medium))
                    }
                    Button { model.togglePlay(); scheduleHide() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40, weight: .bold))
                            .frame(width: 78, height: 78).background(Circle().fill(.ultraThinMaterial))
                    }
                    Button { model.skip(Double(settings.skipSeconds)); scheduleHide() } label: {
                        Image(systemName: "goforward.\(skipIcon)").font(.system(size: 30, weight: .medium))
                    }
                }
                .buttonStyle(PressStyle())

                Spacer()

                // bottom
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text(formatTime(scrubbing ? scrubValue : model.current)).font(.system(size: 12, weight: .medium).monospacedDigit())
                        Scrubber(value: scrubbing ? $scrubValue : .constant(model.current), buffered: model.buffered, total: max(model.duration, 1)) { editing, v in
                            if editing { scrubbing = true; scrubValue = v; hideTask?.cancel() }
                            else { scrubbing = false; model.seek(to: v); scheduleHide() }
                        }
                        Text("-" + formatTime(max(0, model.duration - (scrubbing ? scrubValue : model.current)))).font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    HStack(spacing: 6) {
                        Button { locked = true; scheduleHide() } label: { pill("lock.open", "锁定") }
                        audioMenu
                        subtitleMenu
                        videoMenu
                        speedMenu
                        Button { model.fill.toggle() } label: { pill(model.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", model.fill ? "适应" : "填充") }
                        Spacer()
                        if !model.queue.isEmpty {
                            Button { Task { await model.playNext() } } label: { pill("forward.end.fill", "下一集") }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 14)
            }
        }
        .foregroundStyle(.white)
    }

    var methodLabel: String {
        switch model.playMethod {
        case "DirectPlay": return "直接播放"
        case "DirectStream": return "直接串流"
        default: return "转码 · \(model.bitrate > 0 ? BitrateOption.label(model.bitrate) : "自动")"
        }
    }

    var skipIcon: String { [5, 10, 15, 30, 45, 60].contains(settings.skipSeconds) ? String(settings.skipSeconds) : "10" }

    // MARK: Menus
    var audioMenu: some View {
        Menu {
            if let s = model.source {
                ForEach(s.audioStreams, id: \.index) { a in
                    Button { model.selectAudio(a.index) } label: {
                        if a.index == model.audioIndex { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                    }
                }
            }
        } label: { pill("waveform", "音轨") }
    }

    var subtitleMenu: some View {
        Menu {
            Button { model.selectSubtitle(nil) } label: {
                if model.subtitleIndex == nil { Label("关闭字幕", systemImage: "checkmark") } else { Text("关闭字幕") }
            }
            if let s = model.source {
                ForEach(s.subtitleStreams, id: \.index) { st in
                    Button { model.selectSubtitle(st.index) } label: {
                        let name = st.label + (st.isExternal == true ? "（外挂）" : "") + (st.isTextSubtitleStream == true ? "" : "（图形·需转码）")
                        if st.index == model.subtitleIndex { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
            Divider()
            Menu("字幕大小") {
                ForEach([14.0, 17, 20, 24, 28, 34], id: \.self) { v in
                    Button { settings.subSize = v } label: {
                        if settings.subSize == v { Label("\(Int(v))", systemImage: "checkmark") } else { Text("\(Int(v))") }
                    }
                }
            }
            Menu("字幕位置") {
                ForEach([16.0, 36, 60, 90], id: \.self) { v in
                    Button { settings.subBottom = v } label: {
                        let n = v == 16 ? "最低" : v == 36 ? "默认" : v == 60 ? "偏高" : "高"
                        if settings.subBottom == v { Label(n, systemImage: "checkmark") } else { Text(n) }
                    }
                }
            }
        } label: { pill(model.subtitleIndex == nil ? "captions.bubble" : "captions.bubble.fill", "字幕") }
    }

    var videoMenu: some View {
        Menu {
            if model.sources.count > 1 {
                Section("版本") {
                    ForEach(model.sources) { s in
                        Button { model.selectSource(s.id) } label: {
                            if s.id == model.source?.id { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                }
            }
            Section("画质 / 码率") {
                ForEach(BitrateOption.all) { b in
                    Button { model.selectBitrate(b.value) } label: {
                        if b.value == model.bitrate { Label(b.label, systemImage: "checkmark") } else { Text(b.label) }
                    }
                }
            }
            Section("转码视频编码") {
                Button { model.selectHEVC(false) } label: {
                    if !model.hevc { Label("H.264（兼容性最好）", systemImage: "checkmark") } else { Text("H.264（兼容性最好）") }
                }
                Button { model.selectHEVC(true) } label: {
                    if model.hevc { Label("HEVC / H.265（更省流量）", systemImage: "checkmark") } else { Text("HEVC / H.265（更省流量）") }
                }
            }
            if let v = model.source?.videoStream {
                Section("当前源") {
                    Text(v.label)
                    if let b = model.source?.bitrate { Text(String(format: "%.1f Mbps · %@", Double(b) / 1_000_000, (model.source?.container ?? "").uppercased())) }
                }
            }
        } label: { pill("film", "视频") }
    }

    var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { s in
                Button { model.setSpeed(Float(s)) } label: {
                    let n = s == 1 ? "正常" : String(format: "%gx", s)
                    if abs(Double(model.speed) - s) < 0.01 { Label(n, systemImage: "checkmark") } else { Text(n) }
                }
            }
        } label: { pill("gauge.with.dots.needle.67percent", model.speed == 1 ? "倍速" : String(format: "%gx", model.speed)) }
    }

    func pill(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 11).frame(height: 34)
        .background(Capsule().fill(.ultraThinMaterial))
        .foregroundStyle(.white)
    }

    func circleIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .semibold))
            .frame(width: 40, height: 40).background(Circle().fill(.ultraThinMaterial))
            .foregroundStyle(.white)
    }

    // MARK: Behaviour
    func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && model.isPlaying && !scrubbing { withAnimation { showControls = false } }
        }
    }

    func flash(_ s: String) {
        withAnimation { seekFlash = s }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation { if seekFlash == s { seekFlash = nil } }
        }
    }

    func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard !locked else { return }
                if dragStart == nil {
                    dragStart = v.startLocation
                    dragMode = abs(v.translation.width) > abs(v.translation.height) ? 1 : (v.startLocation.x < size.width / 2 ? 2 : 0)
                    scrubValue = model.current
                    brightness = UIScreen.main.brightness
                }
                switch dragMode {
                case 1:
                    let delta = Double(v.translation.width / size.width) * min(model.duration, 600)
                    scrubbing = true
                    scrubValue = max(0, min(model.duration, model.current + delta))
                    seekFlash = "\(formatTime(scrubValue)) / \(formatTime(model.duration))"
                case 2:
                    let b = max(0, min(1, brightness - v.translation.height / size.height))
                    UIScreen.main.brightness = b
                    seekFlash = "☀︎ \(Int(b * 100))%"
                default: break
                }
            }
            .onEnded { _ in
                if dragMode == 1 { model.seek(to: scrubValue); scrubbing = false }
                if dragMode == 2 { brightness = UIScreen.main.brightness }
                dragStart = nil; dragMode = 0
                withAnimation { seekFlash = nil }
            }
    }

    func close() {
        hideTask?.cancel()
        Task { await model.close() }
        dismiss()
    }

    func rotate(landscape: Bool) {
        AppDelegate.orientationLock = landscape ? .landscape : .all
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

struct Scrubber: View {
    @Binding var value: Double
    let buffered: Double
    let total: Double
    let onEdit: (Bool, Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let p = CGFloat(min(max(value / total, 0), 1))
            let b = CGFloat(min(max(buffered / total, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: dragging ? 8 : 4)
                Capsule().fill(Color.white.opacity(0.35)).frame(width: w * b, height: dragging ? 8 : 4)
                Capsule().fill(Theme.gradient).frame(width: w * p, height: dragging ? 8 : 4)
                Circle().fill(.white).frame(width: dragging ? 20 : 14, height: dragging ? 20 : 14)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 6)
                    .offset(x: w * p - (dragging ? 10 : 7))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        onEdit(true, Double(min(max(v.location.x / w, 0), 1)) * total)
                    }
                    .onEnded { v in
                        dragging = false
                        onEdit(false, Double(min(max(v.location.x / w, 0), 1)) * total)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 30)
    }
}
