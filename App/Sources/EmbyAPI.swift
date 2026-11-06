import Foundation
import UIKit

enum APIError: LocalizedError {
    case badURL, http(Int), auth, decode(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .http(let c): return "服务器返回错误 \(c)"
        case .auth: return "用户名或密码错误"
        case .decode(let m): return "数据解析失败：\(m)"
        }
    }
}

enum ImageKind: String { case primary = "Primary", backdrop = "Backdrop", thumb = "Thumb", logo = "Logo", banner = "Banner" }

extension BaseItem {
    func tag(_ k: ImageKind) -> String? {
        let raw = k.rawValue
        let low = raw.prefix(1).lowercased() + raw.dropFirst()
        return imageTags?[low] ?? imageTags?[raw]
    }
}

final class EmbyClient {
    let base: String
    var token: String?
    var userId: String?
    static let clientName = "Yingxia"
    static let version = "1.0"
    static var deviceId: String = {
        if let d = UserDefaults.standard.string(forKey: "deviceId") { return d }
        let d = UUID().uuidString
        UserDefaults.standard.set(d, forKey: "deviceId")
        return d
    }()
    static let deviceName = "iPhone"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        return URLSession(configuration: c)
    }()

    init(base: String, token: String? = nil, userId: String? = nil) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.lowercased().hasPrefix("http") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.token = token
        self.userId = userId
    }

    var authHeader: String {
        let rest = "Client=\"\(Self.clientName)\", Device=\"\(Self.deviceName)\", DeviceId=\"\(Self.deviceId)\", Version=\"\(Self.version)\""
        if let u = userId { return "Emby UserId=\"\(u)\", " + rest }
        return "Emby " + rest
    }

    func url(_ path: String, _ q: [String: String?] = [:]) -> URL? {
        guard var c = URLComponents(string: base + path) else { return nil }
        let items = q.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { c.queryItems = (c.queryItems ?? []) + items.sorted { $0.name < $1.name } }
        return c.url
    }

    func absolute(_ path: String) -> URL? {
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        var p = path.hasPrefix("/") ? path : "/" + path
        if !p.lowercased().contains("api_key="), let t = token { p += (p.contains("?") ? "&" : "?") + "api_key=" + t }
        return URL(string: base + p)
    }

    func request(_ method: String, _ path: String, _ q: [String: String?] = [:], body: Any? = nil) async throws -> Data {
        guard let u = url(path, q) else { throw APIError.badURL }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        if let t = token { r.setValue(t, forHTTPHeaderField: "X-Emby-Token") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let b = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: b)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await Self.session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.auth }
        guard (200..<300).contains(code) else { throw APIError.http(code) }
        return data
    }

    func get<T: Decodable>(_ path: String, _ q: [String: String?] = [:]) async throws -> T {
        let d = try await request("GET", path, q)
        do { return try JSONDecoder.emby.decode(T.self, from: d) }
        catch { throw APIError.decode(String(describing: error).prefix(200).description) }
    }

    // MARK: Auth
    func publicInfo() async throws -> PublicSystemInfo {
        try await get("/System/Info/Public")
    }

    func login(user: String, password: String) async throws -> AuthResult {
        let d = try await request("POST", "/Users/AuthenticateByName", body: ["Username": user, "Pw": password])
        return try JSONDecoder.emby.decode(AuthResult.self, from: d)
    }

    func logout() async { _ = try? await request("POST", "/Sessions/Logout") }

    // MARK: Browse
    static let fields = "PrimaryImageAspectRatio,Overview,Genres,ProductionYear,CommunityRating,OfficialRating,BasicSyncInfo,UserData,EndDate,Status,ChildCount"
    var uid: String { userId ?? "" }

    func views() async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Users/\(uid)/Views")
        return r.items
    }

    func resume() async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Users/\(uid)/Items/Resume", ["MediaTypes": "Video", "Limit": "20", "Fields": Self.fields, "EnableImageTypes": "Primary,Backdrop,Thumb"])
        return r.items
    }

    func nextUp() async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Shows/NextUp", ["UserId": uid, "Limit": "20", "Fields": Self.fields])
        return r.items
    }

    func latest(parent: String) async throws -> [BaseItem] {
        try await get("/Users/\(uid)/Items/Latest", ["ParentId": parent, "Limit": "16", "Fields": Self.fields])
    }

    func items(parent: String? = nil, types: String? = nil, sortBy: String = "SortName", order: String = "Ascending",
               filters: String? = nil, genre: String? = nil, search: String? = nil, person: String? = nil,
               start: Int = 0, limit: Int = 60, recursive: Bool = true) async throws -> ItemsResult {
        try await get("/Users/\(uid)/Items", [
            "ParentId": parent, "IncludeItemTypes": types, "SortBy": sortBy, "SortOrder": order,
            "Filters": filters, "Genres": genre, "SearchTerm": search, "PersonIds": person,
            "StartIndex": String(start), "Limit": String(limit), "Recursive": recursive ? "true" : "false",
            "Fields": Self.fields, "ImageTypeLimit": "1", "EnableTotalRecordCount": "true"
        ])
    }

    func genres(parent: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Genres", ["ParentId": parent, "UserId": uid, "SortBy": "SortName"])
        return r.items
    }

    func item(_ id: String) async throws -> BaseItem {
        try await get("/Users/\(uid)/Items/\(id)", ["Fields": Self.fields + ",People,Studios,Taglines,MediaSources,RemoteTrailers"])
    }

    func seasons(series: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Shows/\(series)/Seasons", ["UserId": uid, "Fields": Self.fields])
        return r.items
    }

    func episodes(series: String, season: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Shows/\(series)/Episodes", ["UserId": uid, "SeasonId": season, "Fields": Self.fields + ",MediaSources"])
        return r.items
    }

    func similar(_ id: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("/Items/\(id)/Similar", ["UserId": uid, "Limit": "12", "Fields": Self.fields])
        return r.items
    }

    func setFavorite(_ id: String, _ on: Bool) async throws {
        _ = try await request(on ? "POST" : "DELETE", "/Users/\(uid)/FavoriteItems/\(id)")
    }

    func setPlayed(_ id: String, _ on: Bool) async throws {
        _ = try await request(on ? "POST" : "DELETE", "/Users/\(uid)/PlayedItems/\(id)")
    }

    // MARK: Images
    func imageURL(_ id: String, _ kind: ImageKind = .primary, tag: String? = nil, index: Int = 0, maxWidth: Int = 600) -> URL? {
        let p = kind == .backdrop ? "/Items/\(id)/Images/Backdrop/\(index)" : "/Items/\(id)/Images/\(kind.rawValue)"
        return url(p, ["maxWidth": String(maxWidth), "quality": "90", "tag": tag])
    }

    func poster(_ i: BaseItem, width: Int = 400) -> URL? {
        if let t = i.tag(.primary) { return imageURL(i.id, .primary, tag: t, maxWidth: width) }
        if let s = i.seriesId, let t = i.seriesPrimaryImageTag { return imageURL(s, .primary, tag: t, maxWidth: width) }
        return imageURL(i.id, .primary, maxWidth: width)
    }

    func backdrop(_ i: BaseItem, width: Int = 1280) -> URL? {
        if let t = i.backdropImageTags?.first { return imageURL(i.id, .backdrop, tag: t, maxWidth: width) }
        if let p = i.parentBackdropItemId, let t = i.parentBackdropImageTags?.first { return imageURL(p, .backdrop, tag: t, maxWidth: width) }
        if let t = i.tag(.thumb) { return imageURL(i.id, .thumb, tag: t, maxWidth: width) }
        if let p = i.parentThumbItemId, let t = i.parentThumbImageTag { return imageURL(p, .thumb, tag: t, maxWidth: width) }
        if let t = i.tag(.primary) { return imageURL(i.id, .primary, tag: t, maxWidth: width) }
        return nil
    }

    func thumb(_ i: BaseItem, width: Int = 640) -> URL? {
        if let t = i.tag(.thumb) { return imageURL(i.id, .thumb, tag: t, maxWidth: width) }
        if i.isEpisode, let t = i.tag(.primary) { return imageURL(i.id, .primary, tag: t, maxWidth: width) }
        return backdrop(i, width: width)
    }

    func logo(_ i: BaseItem) -> URL? {
        if let t = i.tag(.logo) { return imageURL(i.id, .logo, tag: t, maxWidth: 800) }
        return nil
    }

    func personImage(_ p: Person) -> URL? {
        guard let t = p.primaryImageTag else { return nil }
        return imageURL(p.id, .primary, tag: t, maxWidth: 300)
    }

    // MARK: Playback
    func playbackInfo(_ id: String, maxBitrate: Int, mediaSourceId: String?, audio: Int?, subtitle: Int?) async throws -> PlaybackInfo {
        let d = try await request("POST", "/Items/\(id)/PlaybackInfo", [
            "UserId": uid, "MaxStreamingBitrate": maxBitrate > 0 ? String(maxBitrate) : nil,
            "MediaSourceId": mediaSourceId, "AudioStreamIndex": audio.map { String($0) },
            "SubtitleStreamIndex": subtitle.map { String($0) }, "IsPlayback": "true", "AutoOpenLiveStream": "true"
        ], body: ["DeviceProfile": DeviceProfile.ios])
        return try JSONDecoder.emby.decode(PlaybackInfo.self, from: d)
    }

    func directURL(item: String, source: MediaSource, session: String?) -> URL? {
        url("/Videos/\(item)/stream.\(source.container ?? "mp4")", [
            "Static": "true", "MediaSourceId": source.id, "PlaySessionId": session,
            "DeviceId": Self.deviceId, "api_key": token
        ])
    }

    func hlsURL(item: String, source: MediaSource, session: String?, maxBitrate: Int, audio: Int?, burnSubtitle: Int?, hevc: Bool) -> URL? {
        let br = maxBitrate > 0 ? maxBitrate : 200_000_000
        let audioBr = 384_000
        return url("/Videos/\(item)/master.m3u8", [
            "MediaSourceId": source.id, "PlaySessionId": session, "DeviceId": Self.deviceId, "api_key": token,
            "VideoCodec": hevc ? "hevc,h264" : "h264", "AudioCodec": "aac,ac3,eac3,mp3",
            "SegmentContainer": hevc ? "mp4" : "ts",
            "MaxStreamingBitrate": String(br), "VideoBitrate": String(max(br - audioBr, 300_000)), "AudioBitrate": String(audioBr),
            "TranscodingMaxAudioChannels": "6", "BreakOnNonKeyFrames": "true",
            "AudioStreamIndex": audio.map { String($0) },
            "SubtitleStreamIndex": burnSubtitle.map { String($0) }, "SubtitleMethod": burnSubtitle == nil ? nil : "Encode",
            "MinSegments": "1", "ManifestSubtitles": nil
        ])
    }

    func subtitleURL(item: String, source: String, index: Int) -> URL? {
        url("/Videos/\(item)/\(source)/Subtitles/\(index)/Stream.srt", ["api_key": token])
    }

    func reportStart(item: String, source: String, session: String?, ticks: Int64, method: String, audio: Int?, subtitle: Int?) async {
        _ = try? await request("POST", "/Sessions/Playing", body: payload(item, source, session, ticks, false, method, audio, subtitle))
    }

    func reportProgress(item: String, source: String, session: String?, ticks: Int64, paused: Bool, method: String, audio: Int?, subtitle: Int?) async {
        var b = payload(item, source, session, ticks, paused, method, audio, subtitle)
        b["EventName"] = "TimeUpdate"
        _ = try? await request("POST", "/Sessions/Playing/Progress", body: b)
    }

    func reportStop(item: String, source: String, session: String?, ticks: Int64) async {
        _ = try? await request("POST", "/Sessions/Playing/Stopped", body: ["ItemId": item, "MediaSourceId": source, "PlaySessionId": session ?? "", "PositionTicks": ticks])
        if let s = session {
            _ = try? await request("DELETE", "/Videos/ActiveEncodings", ["DeviceId": Self.deviceId, "PlaySessionId": s])
        }
    }

    private func payload(_ item: String, _ source: String, _ session: String?, _ ticks: Int64, _ paused: Bool, _ method: String, _ audio: Int?, _ subtitle: Int?) -> [String: Any] {
        var b: [String: Any] = ["ItemId": item, "MediaSourceId": source, "PositionTicks": ticks, "IsPaused": paused,
                                "CanSeek": true, "PlayMethod": method, "PlaySessionId": session ?? ""]
        if let a = audio { b["AudioStreamIndex"] = a }
        if let s = subtitle { b["SubtitleStreamIndex"] = s }
        return b
    }
}

enum DeviceProfile {
    static let ios: [String: Any] = [
        "MaxStreamingBitrate": 200_000_000,
        "MaxStaticBitrate": 200_000_000,
        "MusicStreamingTranscodingBitrate": 384_000,
        "DirectPlayProfiles": [
            ["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3,alac,flac"]
        ],
        "TranscodingProfiles": [
            ["Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac,ac3,eac3,mp3", "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "6", "BreakOnNonKeyFrames": true]
        ],
        "SubtitleProfiles": [
            ["Format": "srt", "Method": "External"], ["Format": "ass", "Method": "External"], ["Format": "ssa", "Method": "External"],
            ["Format": "vtt", "Method": "External"], ["Format": "subrip", "Method": "External"],
            ["Format": "pgssub", "Method": "Encode"], ["Format": "dvdsub", "Method": "Encode"]
        ],
        "CodecProfiles": [], "ContainerProfiles": [], "ResponseProfiles": []
    ]
}
