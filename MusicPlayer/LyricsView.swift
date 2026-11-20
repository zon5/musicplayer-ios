import SwiftUI

struct LyricsView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: LibraryStore

    @State private var lines: [LrcLine] = []
    @State private var index: Int = -1
    /// 本首歌已经尝试过联网补词，避免反复请求
    @State private var enrichTriedFor: String? = nil

    private var fontSize: CGFloat { 16 * CGFloat(settings.lyricFontScale) }

    var body: some View {
        Group {
            if lines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(Theme.text3)
                    Text("这首歌还没有歌词")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text2)
                    Text("长按歌曲 →「补齐歌词和资料」可联网获取；也可把同名 .lrc 文件导入本 App")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.text3)
                        .padding(.horizontal, 20)
                }
                .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            ForEach(lines.indices, id: \.self) { i in
                                VStack(spacing: 3) {
                                    Text(lines[i].text.isEmpty ? "·" : lines[i].text)
                                        .font(.system(size: fontSize, weight: i == index ? .semibold : .regular))
                                        .foregroundColor(i == index ? Theme.text : Color.white.opacity(0.38))
                                    if let tr = lines[i].translation, !tr.isEmpty {
                                        Text(tr)
                                            .font(.system(size: fontSize * 0.68))
                                            .foregroundColor(i == index ? Theme.accent.opacity(0.9) : Color.white.opacity(0.28))
                                    }
                                }
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity)
                                .id(i)
                                .contentShape(Rectangle())
                                // 点击歌词行跳到该句（对齐安卓）
                                .onTapGesture { player.seek(to: lines[i].time) }
                                .animation(.easeInOut(duration: 0.2), value: index)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 150)
                    }
                    .onChange(of: index) { newValue in
                        guard newValue >= 0, newValue < lines.count else { return }
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: player.current?.id) { _ in reload() }
        .onChange(of: player.position) { _ in updateIndex() }
        .onReceive(NotificationCenter.default.publisher(for: .songMetaDidUpdate)) { note in
            if note.object as? String == player.current?.id { reload() }
        }
    }

    private func reload() {
        lines = []
        index = -1
        guard let song = player.current else { return }
        let parsed = LrcParser.lines(for: song)
        lines = parsed
        updateIndex()
        // 两段式取词：本地滚不动就主动联网重取（修「歌词没有」）
        if !LrcParser.scrollable(parsed), enrichTriedFor != song.id {
            enrichTriedFor = song.id
            let id = song.id
            Task.detached(priority: .utility) {
                await library.ensureScrollableLyrics(for: id)
            }
        }
    }

    private func updateIndex() {
        guard !lines.isEmpty else { return }
        let idx = LrcParser.index(at: player.position, in: lines)
        if idx != index { index = idx }
    }
}
