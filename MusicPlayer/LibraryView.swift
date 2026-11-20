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
    @State private var tab = 0 // 0 歌曲 / 1 歌手
    @State private var importError: String?

    private var importTypes: [UTType] {
        var types: [UTType] = [.audio]
        if let lrc = UTType(filenameExtension: "lrc") { types.append(lrc) }
        return types
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                tabBar
                if tab == 0 { songList } else { artistList }
                Spacer(minLength: 0)
            }

            // 底部 dock：迷你条 + 歌词/频谱展示（安卓 142dp 那一整条）
            if player.current != nil { dock }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(SpectrumStore.shared)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls)
            case .failure(let err): importError = err.localizedDescription
            }
        }
        .alert(isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Alert(title: Text("导入失败"), message: Text(importError ?? ""), dismissButton: .default(Text("好")))
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings).environmentObject(player)
        }
    }

    // MARK: 顶部标题带（浅主题色）
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("音乐库")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.black.opacity(0.88))
                Text("\(library.songs.count) 首")
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.5))
            }
            Spacer()
            Button { library.syncSystemLibrary() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16))
                    .foregroundColor(.black.opacity(0.7))
                    .frame(width: 38, height: 38)
            }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .foregroundColor(.black.opacity(0.7))
                    .frame(width: 38, height: 38)
            }
            Button { showImporter = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18))
                    .foregroundColor(.black.opacity(0.7))
                    .frame(width: 38, height: 38)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(tintSurface)
    }

    private var tintSurface: some View {
        LinearGradient(
            colors: [Theme.accent.opacity(0.26), Theme.accent.opacity(0.12)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: 歌曲 / 歌手 tab
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<2) { i in
                Button { withAnimation { tab = i } } label: {
                    VStack(spacing: 6) {
                        Text(i == 0 ? "歌曲" : "歌手")
                            .font(.system(size: 14, weight: tab == i ? .semibold : .regular))
                            .foregroundColor(tab == i ? Theme.accent : Theme.text2)
                        Rectangle()
                            .fill(tab == i ? Theme.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .background(tintSurface)
    }

    // MARK: 歌曲列表（A-Z 分组）
    private var songList: some View {
        Group {
            if library.songs.isEmpty { emptyState }
            else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped, id: \.letter) { group in
                            Section(header: letterHeader(group.letter)) {
                                ForEach(group.songs) { song in
                                    songRow(song)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 120)
                }
            }
        }
    }

    private struct Group2 { let letter: String; let songs: [Song] }
    private var grouped: [Group2] {
        let sorted = library.songs.sorted { a, b in
            displayFirst(a) < displayFirst(b)
        }
        var map: [String: [Song]] = [:]
        for s in sorted {
            let key = displayFirst(s)
            map[key, default: []].append(s)
        }
        return map.keys.sorted().map { Group2(letter: $0, songs: map[$0]!) }
    }
    private func displayFirst(_ s: Song) -> String {
        let t = s.displayTitle.uppercased()
        guard let c = t.first else { return "#" }
        let str = String(c)
        return str >= "A" && str <= "Z" ? str : "#"
    }
    private func letterHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 5)
            .background(Theme.bg)
    }
    private func songRow(_ song: Song) -> some View {
        let isCurrent = player.current?.id == song.id
        let isPlaying = isCurrent && player.isPlaying
        return HStack(spacing: 12) {
            ArtworkView(song: song, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.accent)
                    }
                    Text(song.displayTitle)
                        .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? Theme.accent : Theme.text)
                        .lineLimit(1)
                }
                Text(song.displayArtist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // 词 / 曲 / 发行年月（对齐安卓 CreditBlock：三行纵向、左对齐、贴时长左边）
            creditBlock(song)
            if song.duration > 0 {
                Text(fmt(song.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.text3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = library.songs.firstIndex(of: song) {
                player.play(library.songs, at: idx)
            }
            showPlayer = true
            triggerEnrich(song)
        }
    }

    /// 右侧「词：X / 曲：X / 2024.05」三行小块。三项都缺就不画。
    /// 用 layoutPriority 保证歌名让位给词曲（和安卓「词曲优先」一致）。
    @ViewBuilder
    private func creditBlock(_ song: Song) -> some View {
        let lyric = song.writerLyric?.trimmingCharacters(in: .whitespacesAndNewlines)
        let music = song.writerMusic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ym = song.releaseYm?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasL = !(lyric?.isEmpty ?? true)
        let hasM = !(music?.isEmpty ?? true)
        let hasY = !(ym?.isEmpty ?? true)
        if hasL || hasM || hasY {
            VStack(alignment: .leading, spacing: 1) {
                if hasL { creditLine("词：\(lyric ?? "")", dim: false) }
                if hasM { creditLine("曲：\(music ?? "")", dim: false) }
                if hasY { creditLine(ym ?? "", dim: true) }
            }
            .frame(maxWidth: 128, alignment: .leading)
            .layoutPriority(1)
        }
    }

    private func creditLine(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(dim ? Theme.text3.opacity(0.7) : Theme.text2)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 后台补词：缺资料就联网补，结果落盘后 @Published songs 变化会自动刷新列表
    private func triggerEnrich(_ song: Song) {
        guard library.needsEnrich(song) else { return }
        Task.detached(priority: .utility) {
            await library.enrichMissing(song.id)
        }
    }

    // MARK: 歌手列表
    private var artistList: some View {
        Group {
            if artists.isEmpty { emptyState }
            else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(artists, id: \.name) { a in
                            HStack(spacing: 12) {
                                ArtworkView(song: a.song, size: 46)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(a.name)
                                        .font(.system(size: 15))
                                        .foregroundColor(Theme.text)
                                    Text("\(a.count) 首 · 歌手")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.text2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let idx = library.songs.firstIndex(of: a.song) {
                                    player.play(library.songs, at: idx)
                                }
                                showPlayer = true
                            }
                        }
                    }.padding(.bottom, 120)
                }
            }
        }
    }
    private struct Artist { let name: String; let count: Int; let song: Song }
    private var artists: [Artist] {
        var map: [String: (Int, Song)] = [:]
        for s in library.songs {
            let n = s.displayArtist
            if let e = map[n] { map[n] = (e.0 + 1, e.1) }
            else { map[n] = (1, s) }
        }
        return map.map { Artist(name: $0.key, count: $0.value.0, song: $0.value.1) }
            .sorted { $0.name < $1.name }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.text3)
            Text("还没有歌曲")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.text2)
            Text("打开时会问「允许访问音乐库」，点允许即可读出同步的歌。\n如没弹出，点上方 ↻ 重新读取；也可点 + 从「文件」导入。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 80)
    }

    // MARK: 底部 dock：迷你播放条 + 歌词/频谱展示条
    private var dock: some View {
        VStack(spacing: 0) {
            // 迷你条
            HStack(spacing: 10) {
                ArtworkView(song: player.current, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? "")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text).lineLimit(1)
                    Text(player.current?.displayArtist ?? "")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text2).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.text).frame(width: 40, height: 40)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.text).frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 60)
            .contentShape(Rectangle())
            .onTapGesture { showPlayer = true }

            Divider().background(Color.white.opacity(0.08))

            // 歌词 / 频谱展示条（对齐安卓 BottomDock：左当前句+下一句，右实时频谱）
            DockInfo()
        }
        .background(Theme.bg2)
        .overlay(Rectangle().fill(Theme.accent.opacity(0.5)).frame(height: 2), alignment: .top)
    }

    private func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ArtworkView: View {
    let song: Song?
    let size: CGFloat

    var body: some View {
        Group {
            if let s = song, let img = LibraryStore.artworkImage(for: s) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.85), Theme.accent.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.32, weight: .light))
                        .foregroundColor(.white.opacity(0.75))
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}
