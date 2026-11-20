import SwiftUI

struct EqView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        List {
            Section {
                Toggle("启用均衡器", isOn: $settings.eqEnabled)
                    .tint(settings.accent)
                    .onChange(of: settings.eqEnabled) { _ in player.refreshEffects() }
                Toggle("音箱模拟", isOn: $settings.speakerOn)
                    .tint(settings.accent)
                    .onChange(of: settings.speakerOn) { _ in player.refreshEffects() }
            } footer: {
                Text("音箱模拟会切一点超低频、抬中频，近似手机外放的声音。")
            }

            Section(header: Text("预设")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<SettingsStore.eqPresetNames.count, id: \.self) { i in
                            Button {
                                settings.applyPreset(i)
                                player.refreshEffects()
                            } label: {
                                Text(SettingsStore.eqPresetNames[i])
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(settings.eqPreset == i
                                            ? settings.accent.opacity(0.9)
                                            : Theme.bg2)
                                    )
                                    .foregroundColor(settings.eqPreset == i ? .white : Theme.text2)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(header: Text("七段频段")) {
                ForEach(0..<SettingsStore.eqFreqs.count, id: \.self) { i in
                    VStack(spacing: 4) {
                        HStack {
                            Text(bandLabel(SettingsStore.eqFreqs[i]))
                                .font(.system(size: 13)).foregroundColor(Theme.text2)
                            Spacer()
                            Text(String(format: "%+.1f dB", settings.eqBands[i]))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundColor(settings.accent)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.eqBands[i]) },
                                set: { settings.setBand(i, db: Float($0)) }
                            ),
                            in: -12...12, step: 0.5
                        )
                        .tint(settings.accent)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(header: Text("低音增强 / 输出增益")) {
                sliderRow(title: "低音增强", value: Binding(
                    get: { Double(settings.bassDb) },
                    set: { settings.bassDb = Float($0); player.refreshEffects() }
                ))
                sliderRow(title: "输出增益", value: Binding(
                    get: { Double(settings.preampDb) },
                    set: { settings.preampDb = Float($0); player.refreshEffects() }
                ))
            }

            Section {
                Button("重置为平直") {
                    settings.applyPreset(1)
                    settings.bassDb = 0
                    settings.preampDb = 0
                    player.refreshEffects()
                }
                .foregroundColor(settings.accent)
            }
        }
        .listStyle(.insetGrouped)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("均衡器")
        .navigationBarTitleDisplayMode(.inline)
        .accentColor(settings.accent)
    }

    private func sliderRow(title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 14))
                Spacer()
                Text(String(format: "%+.1f dB", value.wrappedValue))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Theme.text3)
            }
            Slider(value: value, in: -12...12, step: 0.5).tint(settings.accent)
        }
        .padding(.vertical, 2)
    }

    private func bandLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }
}
