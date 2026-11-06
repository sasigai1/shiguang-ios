import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: Settings
    @State private var showAdd = false
    @State private var serverInfo: PublicSystemInfo?
    @State private var cacheSize = ""

    let langs: [(String, String)] = [("chi", "中文"), ("eng", "英语"), ("jpn", "日语"), ("kor", "韩语"), ("", "跟随文件默认")]

    var body: some View {
        List {
            Section {
                if let a = app.current {
                    HStack(spacing: 14) {
                        Text(String(a.userName.prefix(1)).uppercased()).font(.title2.bold())
                            .frame(width: 54, height: 54).background(Circle().fill(Theme.gradient))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.userName).font(.headline)
                            Text(serverInfo?.serverName ?? a.serverName).font(.subheadline).foregroundStyle(Theme.secondary)
                            Text(a.url + (serverInfo?.version.map { " · v\($0)" } ?? "")).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section("服务器与账号") {
                ForEach(app.accounts) { a in
                    Button { app.use(a) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(a.serverName).foregroundStyle(.white)
                                Text(a.userName).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if a.id == app.current?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { app.remove(a) } }
                }
                Button { showAdd = true } label: { Label("添加服务器", systemImage: "plus.circle.fill") }
                Button(role: .destructive) { app.signOut() } label: { Label("退出当前账号", systemImage: "rectangle.portrait.and.arrow.right") }
            }

            Section {
                Picker(selection: $settings.wifiBitrate) {
                    ForEach(BitrateOption.all) { Text($0.label).tag($0.value) }
                } label: { Label("Wi-Fi 码率", systemImage: "wifi") }
                Picker(selection: $settings.cellBitrate) {
                    ForEach(BitrateOption.all) { Text($0.label).tag($0.value) }
                } label: { Label("蜂窝网络码率", systemImage: "antenna.radiowaves.left.and.right") }
                Toggle(isOn: $settings.preferDirect) { Label("优先直接播放", systemImage: "bolt.fill") }
                Toggle(isOn: $settings.preferHEVC) { Label("转码使用 HEVC", systemImage: "cpu") }
                Toggle(isOn: $settings.autoNext) { Label("自动播放下一集", systemImage: "forward.end.alt") }
                Picker(selection: $settings.defaultSpeed) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text($0 == 1 ? "正常" : String(format: "%gx", $0)).tag($0) }
                } label: { Label("默认倍速", systemImage: "gauge.with.dots.needle.67percent") }
                Picker(selection: $settings.skipSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) 秒").tag($0) }
                } label: { Label("快进/快退", systemImage: "goforward") }
            } header: { Text("播放") } footer: {
                Text("「原画」会尽量直接播放原文件；MKV 等容器会自动无损封装为 HLS。选择具体码率时由服务器转码，需要服务器开启转码权限。")
            }

            Section("音频与字幕") {
                Picker(selection: $settings.audioLang) {
                    ForEach(langs, id: \.0) { Text($0.1).tag($0.0) }
                } label: { Label("首选音轨语言", systemImage: "waveform") }
                Toggle(isOn: $settings.subsDefaultOn) { Label("默认开启字幕", systemImage: "captions.bubble") }
                Picker(selection: $settings.subLang) {
                    ForEach(langs, id: \.0) { Text($0.1).tag($0.0) }
                } label: { Label("首选字幕语言", systemImage: "character.bubble") }
                VStack(alignment: .leading) {
                    Label("字幕大小 \(Int(settings.subSize))", systemImage: "textformat.size")
                    Slider(value: $settings.subSize, in: 12...40, step: 1)
                }
                Text("示例字幕 Sample").font(.system(size: settings.subSize, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
            }

            Section("存储") {
                HStack {
                    Label("图片缓存", systemImage: "photo.stack")
                    Spacer()
                    Text(cacheSize).foregroundStyle(Theme.secondary)
                }
                Button("清除图片缓存") {
                    EmbyClient.session.configuration.urlCache?.removeAllCachedResponses()
                    URLCache.shared.removeAllCachedResponses()
                    updateCache()
                }
            }

            Section {
                HStack { Text("版本"); Spacer(); Text("影匣 1.2").foregroundStyle(Theme.secondary) }
            } footer: {
                Text("影匣 · 为 Emby 打造的 iOS 客户端").frame(maxWidth: .infinity).padding(.top, 10)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("设置")
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                LoginView(embedded: true) { showAdd = false }
                    .navigationTitle("添加服务器")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showAdd = false } } }
            }
            .environmentObject(app)
        }
        .task {
            serverInfo = try? await app.client?.publicInfo()
            updateCache()
        }
    }

    func updateCache() {
        let b = (EmbyClient.session.configuration.urlCache?.currentDiskUsage ?? 0) + URLCache.shared.currentDiskUsage
        cacheSize = ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
