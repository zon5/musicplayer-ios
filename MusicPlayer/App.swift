import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerEngine()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .onAppear { library.rescan() }
        }
    }
}

/// 统一配色（和 Android 端的雾紫主题接近）
enum Theme {
    static let accent = Color(red: 0.41, green: 0.35, blue: 0.82)
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let bg2 = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let text = Color.white
    static let text2 = Color.white.opacity(0.55)
    static let text3 = Color.white.opacity(0.32)
}
