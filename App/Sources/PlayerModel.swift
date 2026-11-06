import Foundation
import AVFoundation
import AVKit
import SwiftUI
import MediaPlayer

struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

enum SRT {
    static func parse(_ s: String) -> [SubtitleCue] {
        let norm = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in norm.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1]) else { continue }
            var text = lines[(ti + 1)...].joined(separator: "\n")
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\N", with: "\n")
            if !text.isEmpty { cues.append(SubtitleCue(start: a, end: b, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }
    static func time(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let p = t.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count >= 2 else { return nil }
        var v = 0.0
        for x in p { guard let d = Double(x) else { return nil }; v = v * 60 + d }
        return v
    }
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let client: EmbyClient
    let settings = Settings.shared
    @Published var item: BaseItem
    @Published var queue: [BaseItem]
    let player = AVPlayer()

    @Published var sources: [MediaSource] = []
    @Published var source: MediaSource?
    @Published var audioIndex: Int?
    @Published var subtitleIndex: Int?
    @Published var bitrate: Int
    @Published var hevc: Bool
    @Published var speed: Float
    @Published var fill = false

    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var error: String?
    @Published var cueText: String?
    @Published var playMethod = "DirectPlay"
    @Published var finished = false

    private var playSession: String?
    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var bufferObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var lastReport = Date.distantPast
    private var startSeconds: Double = 0
    var pip: AVPictureInPictureController?
    var layer: AVPlayerLayer? {
        didSet {
            if let l = layer, AVPictureInPictureController.isPictureInPictureSupported() {
                pip = AVPictureInPictureController(playerLayer: l)
                pip?.canStartPictureInPictureAutomaticallyFromInline = true
                pip?.delegate = self
            }
        }
    }

    init(client: EmbyClient, item: BaseItem, queue: [BaseItem], fromStart: Bool) {
        self.client = client
        self.item = item
        self.queue = queue
        self.bitrate = Settings.shared.currentBitrate
        self.hevc = Settings.shared.preferHEVC
        self.speed = Float(Settings.shared.defaultSpeed)
        super.init()
        startSeconds = fromStart ? 0 : Double(item.resumeTicks) / 10_000_000
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t.seconds) }
        }
        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                self?.isPlaying = p.timeControlStatus == .playing
                self?.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        setupRemote()
    }

    // MARK: Start / switch
    func start() async {
        await open(itemId: item.id, sourceId: nil, keepSelections: false, at: startSeconds)
    }

    func open(itemId: String, sourceId: String?, keepSelections: Bool, at seconds: Double) async {
        error = nil
        isBuffering = true
        do {
            let info = try await client.playbackInfo(itemId, maxBitrate: bitrate, mediaSourceId: sourceId,
                                                     audio: keepSelections ? audioIndex : nil, subtitle: keepSelections ? subtitleIndex : nil)
            playSession = info.playSessionId
            if !keepSelections || sources.isEmpty { sources = info.mediaSources }
            guard let src = info.mediaSources.first(where: { $0.id == sourceId }) ?? info.mediaSources.first else {
                error = "没有可播放的媒体源"; return
            }
            source = src
            if !keepSelections {
                audioIndex = pickAudio(src)
                subtitleIndex = pickSubtitle(src)
            }
            let usedDefaults = keepSelections || (audioIndex == (src.defaultAudioStreamIndex ?? audioIndex) && subtitleIndex == src.defaultSubtitleStreamIndex)
            candidates = buildCandidates(src, serverUrlOK: usedDefaults)
            attempts = []
            guard await playFirstWorking(at: seconds) else {
                error = "播放失败，已尝试 \(attempts.count) 种方式：\n" + attempts.joined(separator: "\n") + "\n\n可在「视频」菜单换个码率，或检查服务器是否允许该用户转码/串流"
                isBuffering = false
                return
            }
            await loadSubtitles()
            updateNowPlaying()
            await client.reportStart(item: item.id, source: src.id, session: playSession, ticks: Int64(seconds * 10_000_000),
                                     method: playMethod, audio: audioIndex, subtitle: subtitleIndex)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func pickAudio(_ s: MediaSource) -> Int? {
        let a = s.audioStreams
        if let m = a.first(where: { lang($0.language) == lang(settings.audioLang) }) { return m.index }
        return s.defaultAudioStreamIndex ?? a.first(where: { $0.isDefault == true })?.index ?? a.first?.index
    }

    func pickSubtitle(_ s: MediaSource) -> Int? {
        guard settings.subsDefaultOn else { return nil }
        let subs = s.subtitleStreams
        let want = lang(settings.subLang)
        let matching = subs.filter { lang($0.language) == want || ($0.displayTitle ?? "").contains("中") || ($0.title ?? "").contains("中") }
        if let t = matching.first(where: { $0.isTextSubtitleStream == true }) ?? matching.first { return t.index }
        if let d = s.defaultSubtitleStreamIndex, d >= 0 { return d }
        return nil
    }

    func lang(_ l: String?) -> String {
        guard let l = l?.lowercased() else { return "" }
        if ["chi", "zho", "zh", "chs", "cht", "cmn", "yue"].contains(l) { return "chi" }
        if ["eng", "en"].contains(l) { return "eng" }
        if ["jpn", "ja"].contains(l) { return "jpn" }
        if ["kor", "ko"].contains(l) { return "kor" }
        return l
    }

    var selectedSubtitle: MediaStream? { source?.subtitleStreams.first { $0.index == subtitleIndex } }
    var burnSubtitle: Int? {
        guard let s = selectedSubtitle, s.isTextSubtitleStream != true else { return nil }
        return s.index
    }

    struct Candidate { let url: URL; let method: String; let name: String }
    private var candidates: [Candidate] = []
    private var attempts: [String] = []
    private var resumeAt: Double = 0

    func buildCandidates(_ src: MediaSource, serverUrlOK: Bool) -> [Candidate] {
        var list: [Candidate] = []
        let container = (src.container ?? "").lowercased()
        let vcodec = (src.videoStream?.codec ?? "").lowercased()
        let defaultAudio = src.defaultAudioStreamIndex ?? src.audioStreams.first?.index
        let audioOK = audioIndex == nil || audioIndex == defaultAudio || src.audioStreams.count <= 1
        let acodec = (src.audioStreams.first { $0.index == (audioIndex ?? defaultAudio) }?.codec ?? "aac").lowercased()
        let audioCodecOK = ["aac", "ac3", "eac3", "mp3", "alac", "flac"].contains(acodec)
        let canDirect = settings.preferDirect && bitrate == 0 && ["mp4", "m4v", "mov"].contains(container)
            && ["h264", "hevc", "h265", "avc"].contains(vcodec) && audioOK && audioCodecOK && burnSubtitle == nil
        if canDirect, let u = client.directURL(item: item.id, source: src, session: playSession) {
            list.append(Candidate(url: u, method: "DirectPlay", name: "直接播放"))
        }
        if hevc, let u = client.hlsURL(item: item.id, source: src, session: playSession, maxBitrate: bitrate, audio: audioIndex, burnSubtitle: burnSubtitle, hevc: true) {
            list.append(Candidate(url: u, method: bitrate == 0 ? "DirectStream" : "Transcode", name: "HLS (HEVC)"))
        }
        if serverUrlOK, let t = src.transcodingUrl, let u = client.absolute(t) {
            list.append(Candidate(url: u, method: "Transcode", name: "服务器转码地址"))
        }
        if let u = client.hlsURL(item: item.id, source: src, session: playSession, maxBitrate: bitrate, audio: audioIndex, burnSubtitle: burnSubtitle, hevc: false) {
            list.append(Candidate(url: u, method: bitrate == 0 && burnSubtitle == nil ? "DirectStream" : "Transcode", name: "HLS (H.264)"))
        }
        if !canDirect, ["mp4", "m4v", "mov"].contains(container), let u = client.directURL(item: item.id, source: src, session: playSession) {
            list.append(Candidate(url: u, method: "DirectPlay", name: "直接播放"))
        }
        return list
    }

    /// Preflight each candidate over HTTP, then hand the first good one to AVPlayer.
    func playFirstWorking(at seconds: Double) async -> Bool {
        resumeAt = seconds
        while !candidates.isEmpty {
            let c = candidates.removeFirst()
            let check = await preflight(c.url)
            if let problem = check {
                attempts.append("· \(c.name)：\(problem)")
                continue
            }
            playMethod = c.method
            let asset = AVURLAsset(url: c.url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["X-Emby-Token": client.token ?? ""]])
            let pi = AVPlayerItem(asset: asset)
            pi.preferredForwardBufferDuration = 15
            currentCandidate = c.name
            observe(pi)
            player.replaceCurrentItem(with: pi)
            if seconds > 1 { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            player.defaultRate = speed
            player.play()
            player.rate = speed
            return true
        }
        return false
    }
    private var currentCandidate = ""

    func preflight(_ url: URL) async -> String? {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue(client.token, forHTTPHeaderField: "X-Emby-Token")
        r.setValue(client.authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let isHLS = url.path.lowercased().hasSuffix(".m3u8")
        if !isHLS { r.setValue("bytes=0-1", forHTTPHeaderField: "Range") }
        do {
            let (d, resp) = try await EmbyClient.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let body = String(data: d.prefix(160), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "HTTP \(code)" + (body.isEmpty ? "" : " \(body)")
            }
            if isHLS {
                let text = String(data: d, encoding: .utf8) ?? ""
                if !text.contains("#EXTM3U") { return "返回的不是播放列表" }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// AVPlayer itself failed on a URL that passed preflight: move on to the next candidate.
    func playerFailed(_ message: String) async {
        attempts.append("· \(currentCandidate)：\(message)")
        if await playFirstWorking(at: max(current, resumeAt)) { return }
        error = "播放失败，已尝试 \(attempts.count) 种方式：\n" + attempts.joined(separator: "\n") + "\n\n可在「视频」菜单换个码率，或检查服务器是否允许该用户转码/串流"
        isBuffering = false
    }

    func reopen(sourceId: String? = nil) {
        let pos = current
        let sid = sourceId ?? source?.id
        let changingSource = sourceId != nil && sourceId != source?.id
        Task {
            await stopReport()
            await open(itemId: item.id, sourceId: sid, keepSelections: !changingSource, at: pos)
        }
    }

    // MARK: Selection
    func selectAudio(_ idx: Int) { guard idx != audioIndex else { return }; audioIndex = idx; reopen() }
    func selectSubtitle(_ idx: Int?) {
        guard idx != subtitleIndex else { return }
        let wasBurn = burnSubtitle != nil
        subtitleIndex = idx
        if wasBurn || burnSubtitle != nil { reopen() } else { Task { await loadSubtitles() } }
    }
    func selectSource(_ id: String) { reopen(sourceId: id) }
    func selectBitrate(_ b: Int) { guard b != bitrate else { return }; bitrate = b; reopen() }
    func selectHEVC(_ on: Bool) { guard on != hevc else { return }; hevc = on; reopen() }
    func setSpeed(_ s: Float) { speed = s; player.defaultRate = s; if isPlaying { player.rate = s } }

    func loadSubtitles() async {
        cues = []; cueText = nil
        guard let s = selectedSubtitle, s.isTextSubtitleStream == true, let src = source,
              let url = client.subtitleURL(item: item.id, source: src.id, index: s.index) else { return }
        var req = URLRequest(url: url)
        req.setValue(client.token, forHTTPHeaderField: "X-Emby-Token")
        if let r = try? await EmbyClient.session.data(for: req) {
            let d = r.0
            let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) ?? ""
            cues = SRT.parse(text)
        }
    }

    // MARK: Ticking
    func tick(_ t: Double) {
        guard t.isFinite else { return }
        current = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        else if let r = source?.runTimeTicks ?? item.runTimeTicks { duration = Double(r) / 10_000_000 }
        if !cues.isEmpty {
            let c = cues.last { $0.start <= t && t <= $0.end }
            if c?.text != cueText { cueText = c?.text }
        } else if cueText != nil { cueText = nil }
        if Date().timeIntervalSince(lastReport) > 10, let src = source {
            lastReport = Date()
            let paused = !isPlaying
            Task { await client.reportProgress(item: item.id, source: src.id, session: playSession, ticks: Int64(t * 10_000_000), paused: paused, method: playMethod, audio: audioIndex, subtitle: subtitleIndex) }
            updateNowPlaying()
        }
    }

    func observe(_ pi: AVPlayerItem) {
        statusObs = pi.observe(\.status, options: [.new]) { [weak self] i, _ in
            Task { @MainActor in
                if i.status == .failed {
                    let ns = i.error as NSError?
                    let under = (ns?.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
                    await self?.playerFailed((i.error?.localizedDescription ?? "未知错误") + under)
                }
            }
        }
        bufferObs = pi.observe(\.loadedTimeRanges, options: [.new]) { [weak self] i, _ in
            Task { @MainActor in
                if let r = i.loadedTimeRanges.first?.timeRangeValue { self?.buffered = (r.start + r.duration).seconds }
            }
        }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.ended() }
        }
    }

    func ended() async {
        await stopReport(markEnd: true)
        if settings.autoNext, !queue.isEmpty { await playNext() } else { finished = true }
    }

    func playNext() async {
        guard !queue.isEmpty else { return }
        if source != nil { await stopReport() }
        item = queue.removeFirst()
        startSeconds = Double(item.resumeTicks) / 10_000_000
        sources = []
        await open(itemId: item.id, sourceId: nil, keepSelections: false, at: startSeconds)
    }

    // MARK: Controls
    func togglePlay() { isPlaying ? player.pause() : player.play() }
    func seek(to s: Double) {
        let v = max(0, min(s, duration > 0 ? duration - 1 : s))
        current = v
        player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func skip(_ d: Double) { seek(to: current + d) }
    func togglePiP() {
        guard let p = pip else { return }
        p.isPictureInPictureActive ? p.stopPictureInPicture() : p.startPictureInPicture()
    }

    func stopReport(markEnd: Bool = false) async {
        guard let src = source else { return }
        let t = markEnd ? duration : current
        await client.reportStop(item: item.id, source: src.id, session: playSession, ticks: Int64(t * 10_000_000))
    }

    func close() async {
        player.pause()
        await stopReport()
        player.replaceCurrentItem(with: nil)
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Now playing / remote
    func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil); c.pauseCommand.removeTarget(nil); c.togglePlayPauseCommand.removeTarget(nil)
        c.skipForwardCommand.removeTarget(nil); c.skipBackwardCommand.removeTarget(nil); c.changePlaybackPositionCommand.removeTarget(nil)
        c.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(15) }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { Task { @MainActor in self?.seek(to: e.positionTime) } }
            return .success
        }
    }

    func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: current,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0
        ]
        if let s = item.seriesName { info[MPMediaItemPropertyArtist] = s }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler h: @escaping (Bool) -> Void) {
        h(true)
    }
}
