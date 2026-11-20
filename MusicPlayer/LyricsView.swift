import SwiftUI

struct LyricsView: View {
    @EnvironmentObject var player: PlayerEngine

    @State private var lines: [LrcLine] = []
    @State private var index: Int = -1

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
                    Text("把同名 .lrc 文件放进「本地音乐」文件夹即可")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.text3)
                }
                .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 18) {
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i].text.isEmpty ? "·" : lines[i].text)
                                    .font(.system(size: 16, weight: i == index ? .semibold : .regular))
                                    .foregroundColor(i == index ? Theme.text : Color.white.opacity(0.38))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity)
                                    .id(i)
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
    }

    private func reload() {
        lines = []
        index = -1

        guard let song = player.current else { return }

        var url: URL? = nil
        if let name = song.lrcName {
            let u = LibraryStore.documents.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { url = u }
        }
        if url == nil {
            let base = (song.fileName as NSString).deletingPathExtension
            let guess = LibraryStore.documents.appendingPathComponent(base + ".lrc")
            if FileManager.default.fileExists(atPath: guess.path) { url = guess }
        }
        guard let lrcURL = url, let raw = LrcParser.readText(lrcURL) else { return }

        lines = LrcParser.parse(raw)
        updateIndex()
    }

    private func updateIndex() {
        guard !lines.isEmpty else { return }
        let t = player.position
        var idx = -1
        for (i, line) in lines.enumerated() {
            if line.time <= t + 0.15 { idx = i }
        }
        if idx != index { index = idx }
    }
}
