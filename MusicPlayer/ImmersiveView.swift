import SwiftUI

/// 沉浸式播放（串烧）设置：开启后每首歌播到设定比例就淡出切下一首，不等整首放完。
struct ImmersiveView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("开启沉浸式播放（串烧）", isOn: $settings.immersiveOn)
                    .tint(Theme.accent)
                    .font(.system(size: 15))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("切歌位置")
                        Spacer()
                        Text("播到 \(Int(settings.immersiveRatio * 100))%")
                            .foregroundColor(Theme.text3)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.immersiveRatio) },
                        set: { settings.immersiveRatio = Float($0) }
                    ), in: 0.3...0.95, step: 0.05)
                    .tint(Theme.accent)
                    Text("每首歌播放到这个比例就淡出接下一首。iOS 无法识别前奏/副歌段落，用固定比例近似安卓的「一遍主歌+副歌就切」。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text3)
                }
                Spacer()
            }
            .padding(20)
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
