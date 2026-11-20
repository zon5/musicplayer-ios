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

    var id: String { fileName }

    var fileURL: URL { LibraryStore.documents.appendingPathComponent(fileName) }

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
