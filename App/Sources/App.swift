import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .all
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        _ = NetMonitor.shared
        URLCache.shared = URLCache(memoryCapacity: 100 << 20, diskCapacity: 600 << 20)
        return true
    }
}

@main
struct YingxiaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var app = AppState()
    @StateObject var settings = Settings.shared
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Group {
            if app.client != nil {
                MainTabs().id(app.refreshToken)
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut, value: app.current?.id)
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationStack { LibrariesView() }
                .tabItem { Label("媒体库", systemImage: "square.stack.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { FavoritesView() }
                .tabItem { Label("收藏", systemImage: "heart.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var app: AppState
    var embedded = false
    var onDone: (() -> Void)? = nil
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?
    @State private var serverName: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if !embedded {
                    VStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.gradient).frame(width: 88, height: 88)
                                .shadow(color: Theme.accent.opacity(0.6), radius: 24)
                            Image(systemName: "play.rectangle.fill").font(.system(size: 40)).foregroundStyle(.white)
                        }
                        Text("影匣").font(.system(size: 34, weight: .heavy))
                        Text("你的私人 Emby 影院").foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 60)
                }
                VStack(spacing: 14) {
                    field("服务器地址，如 http://192.168.1.2:8096", text: $server, icon: "server.rack", keyboard: .URL)
                    if let n = serverName { Label(n, systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6) }
                    field("用户名", text: $user, icon: "person.fill")
                    SecureField("", text: $pass, prompt: Text("密码（可留空）").foregroundColor(.white.opacity(0.35)))
                        .padding(.leading, 40).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                        .overlay(alignment: .leading) { Image(systemName: "lock.fill").foregroundStyle(Theme.secondary).padding(.leading, 14) }
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
                }
                if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
                Button(action: login) {
                    HStack { if busy { ProgressView().tint(.white) }; Text(busy ? "连接中…" : "登录").bold() }
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.gradient))
                        .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 6)
                }
                .buttonStyle(PressStyle())
                .disabled(busy || server.isEmpty || user.isEmpty)
                .opacity(server.isEmpty || user.isEmpty ? 0.5 : 1)
                if !app.accounts.isEmpty && !embedded {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已保存的服务器").font(.headline)
                        ForEach(app.accounts) { a in
                            Button { app.use(a) } label: { AccountRow(account: a) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .screenBackground()
        .foregroundStyle(.white)
        .onChange(of: server) { _ in serverName = nil }
    }

    func field(_ ph: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text, prompt: Text(ph).foregroundColor(.white.opacity(0.35)))
            .keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.leading, 40).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(alignment: .leading) { Image(systemName: icon).foregroundStyle(Theme.secondary).padding(.leading, 14) }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
    }

    func login() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            let c = EmbyClient(base: server)
            do {
                let info = try? await c.publicInfo()
                serverName = info?.serverName
                let r = try await c.login(user: user, password: pass)
                let a = ServerAccount(url: c.base, serverName: info?.serverName ?? c.base, userId: r.user.id, userName: r.user.name, token: r.accessToken)
                app.add(a)
                onDone?()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct AccountRow: View {
    let account: ServerAccount
    var body: some View {
        HStack(spacing: 12) {
            Text(String(account.userName.prefix(1)).uppercased()).font(.headline)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.serverName).font(.subheadline.bold()).foregroundStyle(.white)
                Text("\(account.userName) · \(account.url)").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
    }
}
