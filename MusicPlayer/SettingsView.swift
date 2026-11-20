import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showEq = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("外观")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("主题色").font(.system(size: 14)).foregroundColor(Theme.text2)
                        HStack(spacing: 14) {
                            ForEach(0..<SettingsStore.accentColors.count, id: \.self) { i in
                                Button {
                                    settings.accentIndex = i
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(SettingsStore.accentColors[i])
                                            .frame(width: 30, height: 30)
                                        if settings.accentIndex == i {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Toggle("氛围画框", isOn: $settings.atmosOn)
                        .tint(settings.accent)
                }

                Section(header: Text("音效"), footer: Text("均衡器与音箱模拟对「导入到本 App 的本地歌曲」生效。系统「音乐」App 同步过来的歌受 iOS 限制无法接入音效，会原声播放。")) {
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

                Section(header: Text("智能过渡"), footer: Text("切歌时对旧歌淡出、新歌淡入，避免突兀。iOS 版为淡入淡出交叉，暂不支持安卓版的节拍自动对齐。")) {
                    Toggle("开启智能过渡", isOn: $settings.crossfadeOn)
                        .tint(settings.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("过渡时长")
                            Spacer()
                            Text(String(format: "%.0f 秒", settings.crossfadeSec))
                                .foregroundColor(Theme.text3)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.crossfadeSec) },
                            set: { settings.crossfadeSec = Float($0) }
                        ), in: 1...12, step: 1)
                            .tint(settings.accent)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("关于")) {
                    HStack { Text("版本"); Spacer(); Text("1.0 · iOS 移植版").foregroundColor(Theme.text3) }
                    HStack { Text("曲库"); Spacer(); Text("系统音乐库 + 本地导入").foregroundColor(Theme.text3) }
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
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accent)
    }
}
