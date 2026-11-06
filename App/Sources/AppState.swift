import SwiftUI
import Network

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [ServerAccount] = []
    @Published var current: ServerAccount?
    @Published var client: EmbyClient?
    @Published var refreshToken = UUID()

    init() {
        if let d = UserDefaults.standard.data(forKey: "accounts"), let a = try? JSONDecoder().decode([ServerAccount].self, from: d) {
            accounts = a
        }
        if let cid = UserDefaults.standard.string(forKey: "currentAccount"), let a = accounts.first(where: { $0.id == cid }) {
            use(a)
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: "accounts") }
        UserDefaults.standard.set(current?.id, forKey: "currentAccount")
    }

    func use(_ a: ServerAccount) {
        current = a
        client = EmbyClient(base: a.url, token: a.token, userId: a.userId)
        save()
        refreshToken = UUID()
    }

    func add(_ a: ServerAccount) {
        accounts.removeAll { $0.id == a.id }
        accounts.append(a)
        use(a)
    }

    func remove(_ a: ServerAccount) {
        accounts.removeAll { $0.id == a.id }
        if current?.id == a.id {
            current = nil
            client = nil
            if let f = accounts.first { use(f) }
        }
        save()
    }

    func signOut() {
        guard let c = current else { return }
        let cl = client
        Task { await cl?.logout() }
        remove(c)
    }
}

struct BitrateOption: Identifiable, Hashable {
    let value: Int
    let label: String
    var id: Int { value }
    static let all: [BitrateOption] = [
        .init(value: 0, label: "原画（自动直连）"),
        .init(value: 120_000_000, label: "120 Mbps"),
        .init(value: 80_000_000, label: "80 Mbps · 4K"),
        .init(value: 40_000_000, label: "40 Mbps · 4K"),
        .init(value: 20_000_000, label: "20 Mbps · 1080p"),
        .init(value: 10_000_000, label: "10 Mbps · 1080p"),
        .init(value: 8_000_000, label: "8 Mbps · 1080p"),
        .init(value: 4_000_000, label: "4 Mbps · 720p"),
        .init(value: 2_000_000, label: "2 Mbps · 720p"),
        .init(value: 1_000_000, label: "1 Mbps · 480p"),
        .init(value: 720_000, label: "720 Kbps · 360p")
    ]
    static func label(_ v: Int) -> String { all.first { $0.value == v }?.label ?? "\(v / 1_000_000) Mbps" }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    @AppStorage("wifiBitrate") var wifiBitrate: Int = 0 { willSet { objectWillChange.send() } }
    @AppStorage("cellBitrate") var cellBitrate: Int = 8_000_000 { willSet { objectWillChange.send() } }
    @AppStorage("preferHEVC") var preferHEVC: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("preferDirect") var preferDirect: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("autoNext") var autoNext: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("audioLang") var audioLang: String = "chi" { willSet { objectWillChange.send() } }
    @AppStorage("subLang") var subLang: String = "chi" { willSet { objectWillChange.send() } }
    @AppStorage("subsDefaultOn") var subsDefaultOn: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("subSize") var subSize: Double = 20 { willSet { objectWillChange.send() } }
    @AppStorage("subBottom") var subBottom: Double = 36 { willSet { objectWillChange.send() } }
    @AppStorage("skipSeconds") var skipSeconds: Int = 10 { willSet { objectWillChange.send() } }
    @AppStorage("defaultSpeed") var defaultSpeed: Double = 1.0 { willSet { objectWillChange.send() } }

    var currentBitrate: Int { NetMonitor.shared.isCellular ? cellBitrate : wifiBitrate }
}

final class NetMonitor {
    static let shared = NetMonitor()
    private let monitor = NWPathMonitor()
    private(set) var isCellular = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.isCellular = p.usesInterfaceType(.cellular) && !p.usesInterfaceType(.wifi) }
        monitor.start(queue: DispatchQueue(label: "net"))
    }
}
