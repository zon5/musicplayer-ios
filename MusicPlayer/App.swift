import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerEngine()
    @StateObject private var settings = SettingsStore()
    @StateObject private var spectrum = SpectrumStore.shared

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(spectrum)
                .preferredColorScheme(.dark)
                .onAppear {
                    Theme.sync(from: settings)
                    player.settings = settings
                    library.rescan()
                    library.syncSystemLibrary()
                }
                .onChange(of: settings.accentIndex) { _ in Theme.sync(from: settings) }
                // 切歌后台补词：有缺就联网补（歌词/词曲/年月），串行、失败静默
                .onChange(of: player.current?.id) { _ in
                    guard let song = player.current, library.needsEnrich(song) else { return }
                    let id = song.id
                    Task.detached(priority: .utility) { await library.enrichMissing(id) }
                }
        }
    }
}

/// 统一配色。accent 为动态强调色，启动时和设置页切换时由 Theme.sync 刷新。
enum Theme {
    static var accent: Color = Color(red: 0.41, green: 0.35, blue: 0.82)
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let bg2 = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let text = Color.white
    static let text2 = Color.white.opacity(0.55)
    static let text3 = Color.white.opacity(0.32)

    static func sync(from settings: SettingsStore) {
        accent = settings.accent
    }
}
