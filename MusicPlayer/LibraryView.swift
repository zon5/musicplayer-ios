import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine

    @EnvironmentObject var settings: SettingsStore
    @State private var showPlayer = false
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importError: String?

    private var importTypes: [UTType] {
        var types: [UTType] = [.audio]
        if let lrc = UTType(filenameExtension: "lrc") { types.append(lrc) }
        return types
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                Theme.bg.ignoresSafeArea()

                if library.songs.isEmpty {
                    emptyState
                } else {
                    songList
                }

                if player.current != nil {
                    MiniBar { showPlayer = true }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
            .navigationTitle("音乐库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        library.syncSystemLibrary()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                library.importFiles(urls)
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        .alert(isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Alert(title: Text("导入失败"), message: Text(importError ?? ""), dismissButton: .default(Text("好")))
        }
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(player)
        }
    }

    private var songList: some View {
        List {
            ForEach(library.songs) { song in
                Button {
                    if let idx = library.songs.firstIndex(of: song) {
                        player.play(library.songs, at: idx)
                    }
                    showPlayer = true
                } label: {
                    SongRow(
                        song: song,
                        isCurrent: player.current?.id == song.id,
                        isPlaying: player.current?.id == song.id && player.isPlaying
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onDelete { library.delete(at: $0) }

            Color.clear
                .frame(height: player.current != nil ? 96 : 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .background(Theme.bg)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.text3)
            Text("还没有歌曲")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.text2)
            Text("打开时会问「允许访问音乐库」，点允许即可读出你同步的歌。\n如没弹出，点左上角 ↻ 重新读取；也可点右上角 + 从「文件」导入。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 60)
    }
}

struct SongRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(song: song, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayTitle)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ArtworkView: View {
    let song: Song?
    let size: CGFloat

    var body: some View {
        Group {
            if let s = song, let img = LibraryStore.artworkImage(for: s) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.85), Theme.accent.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.32, weight: .light))
                        .foregroundColor(.white.opacity(0.75))
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}

struct MiniBar: View {
    @EnvironmentObject var player: PlayerEngine
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(song: player.current, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? "")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(player.current?.displayArtist ?? "")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text2)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Spacer(minLength: 4)

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19))
                    .foregroundColor(Theme.text)
                    .frame(width: 40, height: 40)
            }

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.text)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.bg2)
                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
        )
    }
}
