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
