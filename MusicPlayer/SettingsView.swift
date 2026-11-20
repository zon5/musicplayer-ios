import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showEq = false
    @State private var enriching = false
    @State private var enrichProgress = 0
    @State private var enrichTotal = 0
    @State private var enrichDone = false

    private let sleepOptions: [(Int, String)] = [(0, "关闭"), (10, "10 分钟"), (20, "20 分钟"), (30, "30 分钟"),
                                                  (45, "45 分钟"), (60, "1 小时"), (90, "1.5 小时")]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("外观")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("主题色").font(.system(size: 14)).foregroundColor(Theme.text2)
                        HStack(spacing: 14) {
                            ForEach(0..<SettingsStore.accentColors.count, id: \.self) { i in
                                Button { settings.accentIndex = i } label: {
                                    ZStack {
                                        Circle().fill(SettingsStore.accentColors[i]).frame(width: 30, height: 30)
                                        if settings.accentIndex == i {
                                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Picker("主题模式", selection: $settings.themeMode) {
                        Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2)
                    }
                    Toggle("氛围画框", isOn: $settings.atmosOn).tint(settings.accent)
                    Toggle("列表滑动震动", isOn: $settings.hapticsOn).tint(settings.accent)
                }

                Section(header: Text("歌词")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("歌词字号")
                            Spacer()
                            Text(String(format: "%.1f×", settings.lyricFontScale)).foregroundColor(Theme.text3)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.lyricFontScale) },
                            set: { settings.lyricFontScale = Float($0) }
                        ), in: 0.8...1.6, step: 0.1).tint(settings.accent)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("播放"), footer: Text("沉浸式播放：每首歌播到设定比例就淡出接下一首，不停顿。")) {
                    Picker("点歌方式", selection: $settings.tapAction) {
                        Text("立即播放").tag(0); Text("下一首插播").tag(1)
                    }
                    NavigationLink(destination: ImmersiveView().environmentObject(settings)) {
                        HStack {
                            Image(systemName: "infinity").foregroundColor(settings.accent)
                            Text("沉浸式播放（串烧）")
                            Spacer()
                            if settings.immersiveOn {
                                Text("已开启").font(.system(size: 12)).foregroundColor(Theme.text3)
                            }
                        }
                    }
                }

                Section(header: Text("音效"), footer: Text("均衡器与音箱模拟对「导入到本 App 的本地歌曲」生效。系统「音乐」App 同步的歌受 iOS 限制无法接入音效。")) {
                    NavigationLink(destination: EqView().environmentObject(settings).environmentObject(player)) {
                        HStack {
                            Image(systemName: "slider.horizontal.3").foregroundColor(settings.accent)
                            Text("均衡器与音箱模拟")
                            Spacer()
                            if settings.eqEnabled || settings.speakerOn {
                                Text("已开启").font(.system(size: 12)).foregroundColor(Theme.text3)
                            }
                        }
                    }
                }

                Section(header: Text("智能过渡"), footer: Text("切歌时对旧歌淡出、新歌淡入。iOS 版为淡入淡出交叉，暂不支持安卓版的节拍自动对齐。")) {
                    Toggle("开启智能过渡", isOn: $settings.crossfadeOn).tint(settings.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("过渡时长")
                            Spacer()
                            Text(String(format: "%.0f 秒", settings.crossfadeSec)).foregroundColor(Theme.text3)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.crossfadeSec) },
                            set: { settings.crossfadeSec = Float($0) }
                        ), in: 1...12, step: 1).tint(settings.accent)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("睡眠定时"), footer: Text("到时间后暂停播放；「放完当前曲再停」会等这一首播完。")) {
                    Picker("定时关闭", selection: $settings.sleepMinutes) {
                        ForEach(sleepOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("放完当前曲再停", isOn: $settings.sleepFinishSong).tint(settings.accent)
                }

                Section(header: Text("曲库"), footer: Text("联网从网易云补齐歌词、词曲署名、发行年月；只填空缺，不覆盖已有信息。")) {
                    Button {
                        Task.detached(priority: .utility) { await library.enrichAll { done, total in
                            DispatchQueue.main.async { self.enrichProgress = done; self.enrichTotal = total }
                        }; DispatchQueue.main.async { self.enrichDone = true } }
                        enriching = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle").foregroundColor(settings.accent)
                            Text("一键补齐全库歌词与资料")
                            Spacer()
                            if enriching {
                                if enrichTotal > 0 {
                                    Text("\(enrichProgress)/\(enrichTotal)").font(.system(size: 12)).foregroundColor(Theme.text3)
                                } else {
                                    ProgressView()
                                }
                            }
                        }
                    }
                    .disabled(enriching)
                }

                Section(header: Text("关于")) {
                    HStack { Text("版本"); Spacer(); Text("1.0 · iOS 移植版").foregroundColor(Theme.text3) }
                    HStack { Text("曲库"); Spacer(); Text("系统音乐库 + 本地导入").foregroundColor(Theme.text3) }
                    HStack { Text("歌曲数"); Spacer(); Text("\(library.songs.count) 首").foregroundColor(Theme.text3) }
                    Text("本 App 为本地播放器：不上传你的音乐和歌单，仅歌词/词曲/年月缺失时联网查询公开曲库信息。")
                        .font(.system(size: 12)).foregroundColor(Theme.text3)
                }
            }
            .listStyle(.insetGrouped)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("补齐完成", isPresented: $enrichDone) {
                Button("好") { enriching = false }
            } message: {
                Text("已处理 \(enrichTotal) 首歌曲")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accent)
    }
}
