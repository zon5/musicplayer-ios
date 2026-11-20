import SwiftUI
import UIKit

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    // 封面 = 0，歌词 = 1（和安卓一致：横向 Pager 两页）
    @State private var page = 0
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var dragOffset: CGFloat = 0
    @State private var showQueue = false
    @State private var showImmersive = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar

                    // 两页 Pager：封面 / 歌词，左右滑动翻页
                    TabView(selection: $page) {
                        coverPage(geo: geo).tag(0)
                        lyricsPage(geo: geo).tag(1)
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .never))
                    .frame(maxHeight: .infinity)

                    // 两个小圆点
                    HStack(spacing: 6) {
                        ForEach(0..<2) { i in
                            Circle()
                                .fill(page == i ? Theme.accent : Color.white.opacity(0.28))
                                .frame(width: page == i ? 7 : 6, height: page == i ? 7 : 6)
                        }
                    }
                    .padding(.vertical, 8)

                    infoBlock
                    progressBlock
                    controls
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                // 整页下滑：只在封面页启用（歌词页整页接管会吞掉歌词竖向滚动）
                .offset(y: page == 0 ? dragOffset : 0)
                .opacity(1.0 - (page == 0 ? min(dragOffset / 700.0, 0.35) : 0))
                .gesture(coverDismissDrag)
            }
        }
        .statusBar(hidden: false)
        .sheet(isPresented: $showQueue) {
            QueueView().environmentObject(player).environmentObject(library)
        }
    }

    // MARK: - 封面页：正方形专辑封面（安卓封面页是 1:1 album art，不是画框）
    private func coverPage(geo: GeometryProxy) -> some View {
        let size = min(geo.size.width - 72, min(geo.size.height * 0.42, 320))
        return VStack {
            Spacer(minLength: 0)
            ArtworkView(song: player.current, size: size)
                .shadow(color: Color.black.opacity(0.5), radius: 22, x: 0, y: 10)
                .onTapGesture { withAnimation { page = 1 } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 歌词页：4:3 氛围画框 + 歌词列表（和安卓歌词页一致）
    private func lyricsPage(geo: GeometryProxy) -> some View {
        let frameW = (geo.size.width - 48) * 0.94
        let frameH = frameW * 3.0 / 4.0
        return VStack(spacing: 6) {
            Group {
                if settings.atmosOn, let song = player.current {
                    AtmosScene(title: song.displayTitle, playing: player.isPlaying)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                } else {
                    ArtworkView(song: player.current, size: frameW)
                        .frame(width: frameW, height: frameH)
                }
            }
            .frame(width: frameW, height: frameH)
            .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 8)
            // 歌词页下滑只挂图框这一块，不吞歌词列表滚动
            .gesture(frameDismissDrag)

            LyricsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 背景：静态渐变（安卓整屏也是纯色，画框只在中间）。
    // ⚠️ 这里绝不能放 AtmosScene + blur(radius:40)：整屏高斯模糊叠加 30fps Canvas 会拖垮整机。
    private var background: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if settings.atmosOn {
                // 只取静态配色做一层柔和渐变烘托，不启动动画时钟、不做高斯模糊
                LinearGradient(
                    colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0.06), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            LinearGradient(
                colors: [Color.black.opacity(0.30), Color.black.opacity(0.08), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button { withAnimation { page = page == 0 ? 1 : 0 } } label: {
                VStack(spacing: 2) {
                    Text(player.current?.displayTitle ?? "")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.text2)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(player.current?.displayArtist ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.text3)
                            .lineLimit(1)
                        if let ym = player.current?.releaseYm, !ym.isEmpty {
                            Text("· \(ym)")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.accent)
                        }
                    }
                }
            }
            Spacer()
            HStack(spacing: 0) {
                // 沉浸式播放（串烧）开关：对齐安卓顶部 GraphicEq 按钮
                Button { showImmersive.toggle() } label: {
                    Image(systemName: "infinity")
                        .font(.system(size: 17))
                        .foregroundColor(settings.immersiveOn ? Theme.accent : Theme.text3)
                        .frame(width: 40, height: 44)
                }
                Button { showQueue = true } label: {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.text2)
                        .frame(width: 40, height: 44)
                }
            }
        }
        .frame(height: 48)
        .sheet(isPresented: $showImmersive) {
            ImmersiveView().environmentObject(settings)
        }
    }

    private var infoBlock: some View {
        VStack(spacing: 6) {
            Text(player.current?.displayTitle ?? "未在播放")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(player.current?.displayArtist ?? "")
                .font(.system(size: 13))
                .foregroundColor(Theme.text2)
                .lineLimit(1)
            if let album = player.current?.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text3)
                    .lineLimit(1)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .padding(.horizontal, 8)
    }

    private var progressBlock: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : min(player.position, max(player.duration, 0.001)) },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = player.position
                        scrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
            )
            .tint(Theme.accent)
            HStack {
                Text(fmt(scrubbing ? scrubValue : player.position))
                Spacer()
                Text(fmt(player.duration))
            }
            .font(Font.system(size: 11).monospacedDigit())
            .foregroundColor(Theme.text3)
        }
        .padding(.horizontal, 4)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(player.shuffle ? Theme.accent : Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            Button { player.prev() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 25))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 66, height: 66)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            Button { player.crossfadeToNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(player.repeatMode == .off ? Theme.text3 : Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - 下滑收起：封面页整页下滑；歌词页只挂图框，避免吞列表滚动
    private var coverDismissDrag: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { v in
                // 歌词页的整页下滑不接管（会让歌词列表滚不动），只有封面页跟手
                guard page == 0 else { return }
                if v.translation.height > 0 { dragOffset = min(v.translation.height, 420) }
            }
            .onEnded { v in
                guard page == 0 else { return }
                if v.translation.height > 120 { dismiss() }
                else { withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { dragOffset = 0 } }
            }
    }

    private var frameDismissDrag: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { v in
                // 只认向下占优的甩动；横向留给 TabView 翻页
                if v.translation.height > 140 && v.translation.height > abs(v.translation.width) {
                    dismiss()
                }
            }
    }
}
