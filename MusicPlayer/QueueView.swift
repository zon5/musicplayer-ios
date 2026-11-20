import SwiftUI

/// 待播队列面板（对齐安卓 QueueScreen）：当前曲置顶、可拖动排序、移除、清空、点击跳播。
struct QueueView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        NavigationView {
            List {
                let snap = player.queueSnapshot
                let list = snap.0
                let cur = snap.1
                ForEach(list.indices, id: \.self) { i in
                    row(song: list[i], index: i, currentIndex: cur)
                }
                .onMove { from, to in player.moveInQueue(from: from, to: to) }
                .onDelete { idx in
                    // 从后往前删，避免下标越界；跳过当前曲
                    for i in idx.sorted(by: >) { player.removeFromQueue(at: i) }
                }
            }
            .listStyle(.insetGrouped)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("待播队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { player.clearQueue() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Theme.accent)
    }

    @ViewBuilder
    private func row(song: Song, index: Int, currentIndex: Int) -> some View {
        let isCur = index == currentIndex
        HStack(spacing: 12) {
            ArtworkView(song: song, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayTitle)
                    .font(.system(size: 14, weight: isCur ? .semibold : .regular))
                    .foregroundColor(isCur ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text2)
                    .lineLimit(1)
            }
            Spacer()
            if isCur {
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.accent)
            } else if index == currentIndex + 1 {
                Text("下一首")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isCur { player.jumpToQueue(at: index) }
        }
    }
}
