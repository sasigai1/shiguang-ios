import Foundation

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension JSONDecoder {
    static let emby: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let k = keys.last!.stringValue
            guard let f = k.first else { return AnyKey(stringValue: k) }
            return AnyKey(stringValue: f.lowercased() + k.dropFirst())
        }
        return d
    }()
}

struct ItemsResult: Decodable {
    var items: [BaseItem]
    var totalRecordCount: Int?
}

struct UserData: Decodable, Hashable {
    var playbackPositionTicks: Int64?
    var playedPercentage: Double?
    var isFavorite: Bool?
    var played: Bool?
    var unplayedItemCount: Int?
}

struct Person: Decodable, Hashable, Identifiable {
    var id: String
    var name: String?
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct NameId: Decodable, Hashable {
    var name: String?
    var id: String?
}

struct MediaStream: Decodable, Hashable {
    var index: Int
    var type: String?
    var codec: String?
    var language: String?
    var displayTitle: String?
    var title: String?
    var isDefault: Bool?
    var isExternal: Bool?
    var isTextSubtitleStream: Bool?
    var channels: Int?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var videoRange: String?
    var deliveryUrl: String?

    var label: String {
        if let d = displayTitle, !d.isEmpty { return d }
        var parts: [String] = []
        if let l = language { parts.append(l) }
        if let c = codec { parts.append(c.uppercased()) }
        return parts.isEmpty ? "轨道 \(index)" : parts.joined(separator: " · ")
    }
}

struct MediaSource: Decodable, Hashable, Identifiable {
    var id: String
    var name: String?
    var container: String?
    var bitrate: Int?
    var size: Int64?
    var path: String?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var mediaStreams: [MediaStream]?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var runTimeTicks: Int64?
    var transcodingUrl: String?
    var directStreamUrl: String?

    var videoStream: MediaStream? { mediaStreams?.first { $0.type == "Video" } }
    var audioStreams: [MediaStream] { mediaStreams?.filter { $0.type == "Audio" } ?? [] }
    var subtitleStreams: [MediaStream] { mediaStreams?.filter { $0.type == "Subtitle" } ?? [] }

    var label: String {
        if let n = name, !n.isEmpty { return n }
        var p: [String] = []
        if let v = videoStream {
            if let h = v.height { p.append(h >= 2000 ? "4K" : h >= 1000 ? "1080p" : h >= 700 ? "720p" : "\(h)p") }
            if let c = v.codec { p.append(c.uppercased()) }
        }
        if let c = container { p.append(c.uppercased()) }
        return p.joined(separator: " · ")
    }
}

struct PlaybackInfo: Decodable {
    var mediaSources: [MediaSource]
    var playSessionId: String?
}

struct BaseItem: Decodable, Hashable, Identifiable {
    var id: String
    var name: String?
    var originalTitle: String?
    var type: String?
    var collectionType: String?
    var overview: String?
    var productionYear: Int?
    var premiereDate: String?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var runTimeTicks: Int64?
    var genres: [String]?
    var taglines: [String]?
    var studios: [NameId]?
    var people: [Person]?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var seriesId: String?
    var seriesName: String?
    var seriesPrimaryImageTag: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var userData: UserData?
    var childCount: Int?
    var mediaSources: [MediaSource]?
    var mediaType: String?
    var isFolder: Bool?
    var status: String?
    var endDate: String?
    var primaryImageAspectRatio: Double?

    static func == (a: BaseItem, b: BaseItem) -> Bool { a.id == b.id && a.userData == b.userData }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }
    var isPlayable: Bool { mediaType == "Video" || type == "Movie" || type == "Episode" || type == "Video" || type == "MusicVideo" }
    var isFolderLike: Bool { isFolder == true && !isSeries }

    var runtimeText: String? {
        guard let t = runTimeTicks, t > 0 else { return nil }
        let m = Int(t / 600_000_000)
        return m >= 60 ? "\(m / 60)小时\(m % 60)分" : "\(m)分钟"
    }
    var episodeLabel: String? {
        guard isEpisode else { return nil }
        let s = parentIndexNumber.map { "S\($0)" } ?? ""
        let e = indexNumber.map { "E\($0)" } ?? ""
        return (s + e).isEmpty ? nil : s + e
    }
    var progress: Double? {
        guard let p = userData?.playedPercentage, p > 0, p < 100 else { return nil }
        return p / 100
    }
    var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }
    var yearText: String? {
        guard let y = productionYear else { return nil }
        if isSeries {
            if status == "Continuing" { return "\(y) - 至今" }
            if let e = endDate?.prefix(4), String(e) != String(y) { return "\(y) - \(e)" }
        }
        return "\(y)"
    }
}

struct AuthResult: Decodable {
    var accessToken: String
    var user: EmbyUser
    var serverId: String?
}

struct EmbyUser: Decodable {
    var id: String
    var name: String
    var primaryImageTag: String?
}

struct PublicSystemInfo: Decodable {
    var serverName: String?
    var version: String?
    var id: String?
}

struct ServerAccount: Codable, Identifiable, Hashable {
    var id: String { "\(url)|\(userId)" }
    var url: String
    var serverName: String
    var userId: String
    var userName: String
    var token: String
}
