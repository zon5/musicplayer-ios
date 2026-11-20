import SwiftUI

/// 歌曲长按菜单（对齐安卓 SongMenu）：立即播放/下一首播放/补齐资料/编辑信息。
struct SongMenu: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    let song: Song
    var onEdit: ((Song) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                    Text("\(song.displayArtist) · \(song.album.isEmpty ? "未知专辑" : song.album)")
                        .font(.system(size: 12)).foregroundColor(Theme.text2).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            Divider().background(Color.white.opacity(0.1))

            menuRow("play.fill", "立即播放") {
                player.playSong(song, from: library.songs)
                dismiss()
            }
            menuRow("text.insert", "下一首播放") {
                player.playNext(song)
                dismiss()
            }
            menuRow("arrow.down.circle", "补齐这首歌的歌词和资料") {
                let id = song.id
                Task.detached(priority: .utility) { await library.enrichMissing(id) }
                dismiss()
            }
            if onEdit != nil {
                menuRow("square.and.pencil", "编辑歌曲信息 / 歌词") {
                    onEdit?(song)
                    dismiss()
                }
            }
        }
        .padding(.bottom, 24)
        .background(Theme.bg2)
        .presentationDetentsIfAvailable()
    }

    @ViewBuilder
    private func menuRow(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.accent)
                    .frame(width: 26)
                Text(title).font(.system(size: 15)).foregroundColor(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// iOS 15 没有 presentationDetents，用空 View 占位保持兼容
private struct DetentCompat: ViewModifier {
    func body(content: Content) -> some View { content }
}
extension View {
    func presentationDetentsIfAvailable() -> some View { modifier(DetentCompat()) }
}
