import SwiftUI

/// 沉浸式播放（串烧）设置 —— 对齐安卓「沉浸式播放（串烧模式）」
struct ImmersiveView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("开启沉浸式播放（串烧）", isOn: Binding(
                        get: { settings.immersiveOn },
                        set: { on in
                            settings.immersiveOn = on
                            // 同安卓：串烧依赖衔接引擎，打开就自动开启「像 DJ 一样接歌」
                            if on { settings.crossfadeOn = true }
                        }
                    ))
                    .tint(Theme.accent)
                    .font(.system(size: 15))

                    Text("每首歌把「一遍主歌 + 一遍副歌」听完就换下一首：自动识别前奏 / 主歌 / 副歌 / 间奏，切点一定落在人声收住的段落边界上（优先在间奏里淡出，没有间奏就慢慢把音乐淡掉再接），之后照样做节拍对齐与交叉淡入淡出——不会把唱到一半的人声切断。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("兜底切歌位置")
                            Spacer()
                            Text("播到 \(Int(settings.immersiveRatio * 100))%")
                                .foregroundColor(Theme.text3)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.immersiveRatio) },
                            set: { settings.immersiveRatio = Float($0) }
                        ), in: 0.3...0.95, step: 0.05)
                        .tint(Theme.accent)
                        Text("只在段落结构分析失败时使用：整首响度太平、或这首歌来自系统「音乐」库读不到音频数据时，按这个比例切歌。正常情况下按副歌唱完的位置切，不受这里影响。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("沉浸式播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Theme.accent)
    }
}
