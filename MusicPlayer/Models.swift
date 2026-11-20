import Foundation

struct Song: Identifiable, Codable, Equatable {
    let fileName: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var addedAt: Date
    var artworkName: String?
    var lrcName: String?

    // 系统「音乐」App 同步进来的歌：systemID 非空，assetURL 是 ipod-library:// 地址
    // 这两个字段是 Optional，旧版 library.json 缺这两个键也能正常解码（不会崩）
    var systemID: String?
    var assetURL: String?

    // 发布年月 / 作词 / 作曲：与安卓 Models.kt 同名同口径。
    // 查不到就是 nil，绝不编；Optional 且带默认值，旧 library.json 缺这些键也能解码。
    /// 发布年月，形如 "2024.05"（标签年份 / 在线专辑发行时间）
    var releaseYm: String? = nil
    /// 作词人（界面显示成「词：X」）
    var writerLyric: String? = nil
    /// 作曲人（界面显示成「曲：X」）
    var writerMusic: String? = nil

    var id: String { systemID ?? fileName }
    var isSystem: Bool { systemID != nil }

    var fileURL: URL { LibraryStore.documents.appendingPathComponent(fileName) }

    /// 真正的播放地址：系统库的歌走 ipod-library://，本地导入的走沙盒文件
    var playURL: URL? {
        if isSystem { return assetURL.flatMap { URL(string: $0) } }
        return fileURL
    }

    var displayTitle: String { SongTitle.clean(title.isEmpty ? fileName : title) }

    var displayArtist: String { artist.isEmpty ? "未知歌手" : artist }
}

enum SongTitle {
    private static let audioExts: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "alac", "caf", "aiff", "ogg"]

    static func isAudio(_ ext: String) -> Bool { audioExts.contains(ext.lowercased()) }

    /// 去掉扩展名、开头的音轨号，和 Android 端 displayTitle 的口径保持一致
    static func clean(_ raw: String) -> String {
        var s = raw
        let ns = s as NSString
        let ext = ns.pathExtension.lowercased()
        if !ext.isEmpty, audioExts.contains(ext) {
            s = ns.deletingPathExtension
        }
        if let r = try? NSRegularExpression(pattern: "^\\s*\\d{1,3}\\s*[-._]\\s*") {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = r.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LrcLine {
    let time: Double
    let text: String
}

/// 某首歌的歌词/词曲/年月被后台补全后发出，object 是 song.id
extension Notification.Name {
    static let songMetaDidUpdate = Notification.Name("songMetaDidUpdate")
}
