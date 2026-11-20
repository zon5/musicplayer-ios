import Foundation
import AVFoundation
import UIKit

final class LibraryStore: ObservableObject {
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let artworkDir: URL = documents.appendingPathComponent("artwork", isDirectory: true)

    @Published var songs: [Song] = []
    @Published var importing = false

    private var jsonURL: URL { Self.documents.appendingPathComponent("library.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.artworkDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: jsonURL),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            songs = list
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(songs) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    /// 扫 Documents 里新出现的音频文件（用 iTunes / 访达拖进来的歌靠这个入库）
    func rescan() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Self.documents,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return }
        var changed = false
        for url in items {
            guard SongTitle.isAudio(url.pathExtension) else { continue }
            let name = url.lastPathComponent
            if songs.contains(where: { $0.fileName == name }) { continue }
            if let song = SongFactory.make(url: url) {
                songs.append(song)
                changed = true
            }
        }
        songs.sort { $0.addedAt < $1.addedAt }
        if changed { save() }
    }

    /// 从"文件"App / 其它 App 导入
    func importFiles(_ urls: [URL]) {
        importing = true
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            let dst = Self.documents.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: u, to: dst)
            if scoped { u.stopAccessingSecurityScopedResource() }
        }
        rescan()
        importing = false
    }

    func delete(at offsets: IndexSet) {
        let victims = offsets.compactMap { songs.indices.contains($0) ? songs[$0] : nil }
        for s in victims { delete(s) }
    }

    func delete(_ song: Song) {
        try? FileManager.default.removeItem(at: song.fileURL)
        if let art = song.artworkName {
            try? FileManager.default.removeItem(at: Self.artworkDir.appendingPathComponent(art))
        }
        songs.removeAll { $0.id == song.id }
        save()
    }

    // MARK: - 封面缓存

    private static var artCache: [String: UIImage] = [:]

    static func artworkImage(for song: Song) -> UIImage? {
        guard let name = song.artworkName else { return nil }
        if let cached = artCache[name] { return cached }
        let url = artworkDir.appendingPathComponent(name)
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        artCache[name] = img
        return img
    }

    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in Array(s.utf8) { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }
}

enum SongFactory {
    static func make(url: URL) -> Song? {
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata
        let name = url.lastPathComponent

        var title = meta(items, .commonKeyTitle) ?? ""
        var artist = meta(items, .commonKeyArtist) ?? ""
        let album = meta(items, .commonKeyAlbumName) ?? ""

        // 标签里没歌名时从文件名猜："歌手 - 歌名.mp3"
        if title.isEmpty {
            let base = SongTitle.clean(name)
            let parts = base.components(separatedBy: " - ")
            if parts.count >= 2 {
                artist = artist.isEmpty ? parts[0] : artist
                title = parts[1]
            } else {
                title = base
            }
        }

        let seconds = asset.duration.seconds
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0

        var artName: String? = nil
        if let artData = items.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue {
            let n = LibraryStore.stableHash(name) + ".jpg"
            let dst = LibraryStore.artworkDir.appendingPathComponent(n)
            if (try? artData.write(to: dst)) != nil { artName = n }
        }

        let base = (name as NSString).deletingPathExtension
        let lrcName = base + ".lrc"
        let hasLrc = FileManager.default.fileExists(
            atPath: LibraryStore.documents.appendingPathComponent(lrcName).path
        )

        return Song(
            fileName: name,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            addedAt: Date(),
            artworkName: artName,
            lrcName: hasLrc ? lrcName : nil
        )
    }

    private static func meta(_ items: [AVMetadataItem], _ key: AVMetadataKey) -> String? {
        guard let v = items.first(where: { $0.commonKey == key })?.stringValue else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
