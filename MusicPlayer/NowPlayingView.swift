import SwiftUI
import UIKit

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var showLyrics = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 72, min(geo.size.height * 0.42, 320))

            ZStack {
                background.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 8)

                    ZStack {
                        // 封面页：氛围画框（和安卓的歌词图框同源），无封面/关闭画框时退回静态封面
                        Group {
                            if settings.atmosOn, let song = player.current {
                                AtmosScene(title: song.displayTitle, playing: player.isPlaying)
                                    .clipShape(RoundedRectangle(cornerRadius: artSize * 0.09, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: artSize * 0.09, style: .continuous)
                                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                    )
                            } else {
                                ArtworkView(song: player.current, size: artSize)
                            }
                        }
                        .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 10)
                        .opacity(showLyrics ? 0 : 1)
                        .gesture(dismissDrag)
                        .onTapGesture { toggleLyrics() }

                        LyricsView()
                            .opacity(showLyrics ? 1 : 0)
                            .allowsHitTesting(showLyrics)
                    }
                    .frame(width: artSize, height: artSize)

                    Spacer(minLength: 8)

                    infoBlock
                    progressBlock
                    controls
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .offset(y: dragOffset)
                .opacity(1.0 - min(dragOffset / 700.0, 0.35))
            }
        }
        .statusBar(hidden: false)
    }

    private func toggleLyrics() {
        withAnimation(.easeInOut(duration: 0.28)) { showLyrics.toggle() }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { v in
                if v.translation.height > 0 {
                    dragOffset = min(v.translation.height, 420)
                }
            }
            .onEnded { v in
                if v.translation.height > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var background: some View {
        ZStack {
            // 底层永远是主题深色。安卓播放页整屏也是纯色，画框只在中间一个图框里画。
            Theme.bg.ignoresSafeArea()

            if settings.atmosOn, let song = player.current {
                // 整屏只做「氛围色烘托」：重度模糊 + 压暗，绝不清晰显示楼/窗，
                // 否则会和中间的清晰图框叠成「楼中楼」，文字也全压在亮窗户上看不清。
                AtmosScene(title: song.displayTitle, playing: player.isPlaying)
                    .ignoresSafeArea()
                    .blur(radius: 34)
                    .opacity(0.26)
            } else if let song = player.current, let img = LibraryStore.artworkImage(for: song) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .opacity(0.30)
            }

            // 上/下压暗遮罩，保证顶部专辑名与底部控件在亮色氛围上也清楚
            LinearGradient(
                colors: [Color.black.opacity(0.42), Color.black.opacity(0.10), Color.black.opacity(0.58)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(albumText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.text2)
                    .lineLimit(1)
                Text("正在播放")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.text3)
            }

            Spacer()

            Button {
                toggleLyrics()
            } label: {
                Image(systemName: showLyrics ? "photo" : "text.alignleft")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.text)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(height: 48)
        .simultaneousGesture(dismissDrag)
    }

    private var albumText: String {
        guard let album = player.current?.album, !album.isEmpty else { return "本地音乐" }
        return album
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
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
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
            Button {
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(player.shuffle ? Theme.accent : Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }

            Button {
                player.prev()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 25))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }

            Button {
                player.togglePlay()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 66, height: 66)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }

            Button {
                player.crossfadeToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }

            Button {
                cycleRepeat()
            } label: {
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
}
