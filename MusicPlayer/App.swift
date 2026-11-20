import SwiftUI
import UIKit

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
                .onAppear {
                    Theme.sync(from: settings)
                    player.settings = settings
                    library.rescan()
                    library.syncSystemLibrary()
                }
                .onChange(of: settings.accentIndex) { _ in Theme.sync(from: settings) }
                .onChange(of: settings.themeMode) { _ in Theme.sync(from: settings) }
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
/// themeMode：0 跟随系统 / 1 浅色 / 2 深色（默认深色，和安卓一致）。
enum Theme {
    static var accent: Color = Color(red: 0.41, green: 0.35, blue: 0.82)
    static var isLight = false

    static var bg: Color { isLight ? Color(red: 0.96, green: 0.96, blue: 0.98) : Color(red: 0.07, green: 0.07, blue: 0.09) }
    static var bg2: Color { isLight ? Color.white : Color(red: 0.11, green: 0.11, blue: 0.14) }
    static var text: Color { isLight ? Color(red: 0.12, green: 0.12, blue: 0.16) : .white }
    static var text2: Color { isLight ? Color.black.opacity(0.6) : Color.white.opacity(0.55) }
    static var text3: Color { isLight ? Color.black.opacity(0.38) : Color.white.opacity(0.32) }

    static func sync(from settings: SettingsStore) {
        accent = settings.accent
        isLight = (settings.themeMode == 1)
        applyInterfaceStyle(settings.themeMode)
    }

    /// 0=跟随系统、1=浅色、2=深色；写 window.overrideUserInterfaceStyle 全局生效
    private static func applyInterfaceStyle(_ mode: Int) {
        let style: UIUserInterfaceStyle
        switch mode {
        case 1: style = .light
        case 2: style = .dark
        default: style = .unspecified
        }
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let win = scene as? UIWindowScene else { continue }
                for w in win.windows { w.overrideUserInterfaceStyle = style }
            }
        }
    }
}
