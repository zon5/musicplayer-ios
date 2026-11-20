import SwiftUI

/// 迷你播放条下面的信息坞（对齐安卓 BottomDock）：
/// 左「歌词」= 当前句 + 下一句（跟随进度，只展示不跳转）；右「频谱」= 22 柱实时频谱。
struct DockInfo: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var spectrum: SpectrumStore

    @State private var lines: [LrcLine] = []
    @State private var line1: String? = nil
    @State private var line2: String? = nil

    private let labelTop: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // ---- 左：歌词 ----
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "text.alignleft").font(.system(size: 12))
                    Text("歌词").font(.system(size: 10))
                }
                .foregroundColor(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(line1 ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(line1 != nil ? Theme.text : Theme.text3)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(line2 ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, labelTop)
            .padding(.bottom, 8)

            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 42)

            // ---- 右：实时频谱 ----
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform").font(.system(size: 12))
                    Text("频谱").font(.system(size: 10))
                }
                .foregroundColor(Theme.accent)

                SpectrumBars(levels: spectrum.levels, playing: player.isPlaying)
                    .frame(height: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, labelTop)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 78)
        .onAppear { reload() }
        .onChange(of: player.current?.id) { _ in reload() }
        .onChange(of: player.position) { _ in updateLines() }
        // 补词完成后重新读歌词
        .onReceive(NotificationCenter.default.publisher(for: .songMetaDidUpdate)) { note in
            if note.object as? String == player.current?.id { reload() }
        }
    }

    private func reload() {
        guard let song = player.current else { lines = []; updateLines(); return }
        lines = LrcParser.lines(for: song)
        updateLines()
    }

    private func updateLines() {
        guard !lines.isEmpty else { line1 = nil; line2 = nil; return }
        var idx = LrcParser.index(at: player.position, in: lines)
        if idx < 0 { idx = lines.firstIndex { !$0.text.isEmpty } ?? -1 }
        guard idx >= 0 else { line1 = nil; line2 = nil; return }
        let a = lines[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        line1 = a.isEmpty ? nil : a
        if idx + 1 < lines.count {
            let b = lines[idx + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
            line2 = b.isEmpty ? nil : b
        } else {
            line2 = nil
        }
    }
}

/// 22 根柱子，快起慢落（平滑已在 SpectrumStore 内做）；暂停时缓慢回底
private struct SpectrumBars: View {
    let levels: [Float]
    let playing: Bool
    private let floor: CGFloat = 0.10

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let count = max(1, levels.count)
            let w = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<count, id: \.self) { i in
                    let v = playing ? CGFloat(levels[i]) : floor
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent)
                            .frame(width: w, height: max(2, geo.size.height * v))
                    }
                    .frame(height: geo.size.height)
                }
            }
        }
    }
}
