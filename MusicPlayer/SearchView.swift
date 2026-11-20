import SwiftUI

/// 本地搜索（对齐安卓 SearchScreen）：歌名 / 歌手 / 专辑，纯本地不联网。
struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var q: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var songHits: [Song] {
        guard !q.isEmpty else { return [] }
        return library.songs.filter {
            $0.displayTitle.lowercased().contains(q) ||
            $0.displayArtist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }
    private struct ArtistHit { let name: String; let count: Int; let song: Song }
    private var artistHits: [ArtistHit] {
        guard !q.isEmpty else { return [] }
        var map: [String: (Int, Song)] = [:]
        for s in library.songs where s.displayArtist.lowercased().contains(q) {
            let n = s.displayArtist
            if let e = map[n] { map[n] = (e.0 + 1, e.1) } else { map[n] = (1, s) }
        }
        return map.map { ArtistHit(name: $0.key, count: $0.value.0, song: $0.value.1) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.text3)
                    TextField("搜索歌曲、歌手、专辑", text: $query)
                        .foregroundColor(Theme.text)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Theme.text3)
                        }
                    }
                }
                .padding(10)
                .background(Theme.bg2)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if q.isEmpty {
                    Spacer()
                    Text("输入关键词搜索本地歌曲")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text3)
                    Spacer()
                } else if songHits.isEmpty && artistHits.isEmpty {
                    Spacer()
                    Text("没找到匹配的歌曲")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text3)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !songHits.isEmpty {
                                sectionTitle("歌曲 · \(songHits.count)")
                                ForEach(songHits) { s in
                                    HStack(spacing: 10) {
                                        ArtworkView(song: s, size: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(s.displayTitle).font(.system(size: 14)).foregroundColor(Theme.text).lineLimit(1)
                                            Text(s.displayArtist).font(.system(size: 12)).foregroundColor(Theme.text2).lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.playSong(s, from: library.songs)
                                        dismiss()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                }
                            }
                            if !artistHits.isEmpty {
                                sectionTitle("歌手 · \(artistHits.count)")
                                ForEach(artistHits, id: \.name) { a in
                                    HStack(spacing: 10) {
                                        ArtworkView(song: a.song, size: 40).clipShape(Circle())
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(a.name).font(.system(size: 14)).foregroundColor(Theme.text).lineLimit(1)
                                            Text("\(a.count) 首").font(.system(size: 12)).foregroundColor(Theme.text2)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.playSong(a.song, from: library.songs)
                                        dismiss()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("搜索")
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

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}
