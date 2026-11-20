import Foundation
import AVFoundation
import UIKit
import MediaPlayer

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

    /// 读取系统「音乐」App 里同步进来的歌（AMPod 能"识别"歌靠的就是这一步）。
    /// 首次会弹系统授权框，用户点「允许」后把歌合并进曲库；已存在的按 systemID 去重。
    func syncSystemLibrary() {
        let status = MPMediaLibrary.authorizationStatus()
        switch status {
        case .authorized:
            performSystemImport()
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized { self?.performSystemImport() }
                }
            }
        case .denied, .restricted:
            // 用户拒绝或受限：不打扰，仍可用"导入文件"那套
            break
        @unknown default:
            break
        }
    }

    private func performSystemImport() {
        let query = MPMediaQuery.songs()
        guard let items = query.items else { return }
        var changed = false
        for item in items {
            // 过滤掉云端的、没有本地文件的、以及受保护无法播放的曲子
            guard !item.isCloudItem,
                  let url = item.assetURL,
                  item.mediaType == .music else { continue }
            let pid = String(item.persistentID)
            if songs.contains(where: { $0.systemID == pid }) { continue }

            var artName: String? = nil
            if let art = item.artwork,
               let img = art.image(at: CGSize(width: 320, height: 320)),
               let data = img.jpegData(compressionQuality: 0.82) {
                let n = "sys_" + Self.stableHash(pid) + ".jpg"
                if (try? data.write(to: Self.artworkDir.appendingPathComponent(n))) != nil {
                    artName = n
                }
            }

            // 发行年月：系统库优先 releaseDate，退到 YEAR；都拿到时才格式化成 "2024.05"
            var ym: String? = nil
            if let rd = item.releaseDate {
                ym = LibraryStore.formatYearMonth(rd)
            } else if let y = (item.value(forProperty: "Year") as? NSNumber)?.intValue, y > 0 {
                ym = String(format: "%04d", y)
            }
            // 作曲：系统库只有 Composer 字段（作词人 Apple 没给），先兜底，联网补全时再覆盖
            let composer = item.value(forProperty: MPMediaItemPropertyComposer) as? String

            let song = Song(
                fileName: "sys_\(pid).m4a",
                title: item.title ?? "",
                artist: item.artist ?? "",
                album: item.albumTitle ?? "",
                duration: (item.value(forProperty: MPMediaItemPropertyPlaybackDuration) as? NSNumber)?.doubleValue ?? 0,
                addedAt: Date(),
                artworkName: artName,
                lrcName: nil,
                systemID: pid,
                assetURL: url.absoluteString,
                releaseYm: ym,
                writerLyric: nil,
                writerMusic: composer.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            )
            songs.append(song)
            changed = true
        }
        if changed {
            save()
        }
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
        // 系统库的歌没有本地文件可删，只从显示列表移除；下次"读取系统音乐库"会再出现（符合预期，那是系统库里的歌）
        if !song.isSystem {
            try? FileManager.default.removeItem(at: song.fileURL)
        }
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

    /// Date → "2024.05"（只有年份时给 "2024"），和安卓 releaseYmOf 同口径
    static func formatYearMonth(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        guard let y = c.year else { return "" }
        if let m = c.month { return String(format: "%04d.%02d", y, m) }
        return String(format: "%04d", y)
    }

    /// 给一首歌联网补「歌词 / 词曲 / 发行年月」，结果落盘到 library.json + lrc 缓存。
    /// 只补空字段，不覆盖已有值（用户手动填过的优先）；完整跑完自动 save。
    func enrichMissing(_ songID: String) async {
        guard let idx = songs.firstIndex(where: { $0.id == songID }) else { return }
        var song = songs[idx]
        let meta = await MetaFetcher.shared.enrich(song: song)
        guard !meta.isEmpty else { return }

        // 歌词落盘：写成同名 lrc 缓存，LyricsView / BottomDock 都从这里读
        if let lrc = meta.lrc, !lrc.isEmpty {
            let name = "net_" + Self.stableHash(song.id) + ".lrc"
            if (try? lrc.write(to: Self.documents.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil {
                song.lrcName = name
            }
        }
        if song.releaseYm == nil { song.releaseYm = meta.releaseYm }
        if song.writerLyric == nil { song.writerLyric = meta.writerLyric }
        if song.writerMusic == nil { song.writerMusic = meta.writerMusic }

        // @Published songs 必须主线程写，否则 SwiftUI 会警告 / 列表不刷新
        let finalSong = song // 显式快照，避免跨 await 捕获 var
        await MainActor.run {
            self.songs[idx] = finalSong
            self.save()
            // 通知歌词视图 / dock 重新读歌词（player 手里的 Song 副本不会随 library 刷新）
            NotificationCenter.default.post(name: .songMetaDidUpdate, object: finalSong.id, userInfo: ["song": finalSong])
        }
    }

    /// 首页/播放时按需补：缺任意一项就联网，串行避免打爆接口
    func needsEnrich(_ song: Song) -> Bool {
        song.lrcName == nil || song.releaseYm == nil || song.writerLyric == nil || song.writerMusic == nil
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

        // 词曲 / 发行年份：读文件标签（ID3 TCOM/TEXT/TYER、Vorbis COMPOSER/LYRICIST/DATE、MP4 ©wrt/©lyr/©day）
        var lyricist: String? = nil
        var composer: String? = nil
        var releaseYm: String? = nil
        for it in asset.metadata {
            let key = (it.key as? AVMetadataKey)?.rawValue ?? ""
            guard let v = it.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { continue }
            switch key {
            case "TCOM", "COMPOSER", "\u{00A9}wrt": composer = v
            case "TEXT", "LYRICIST", "\u{00A9}lyr": lyricist = v
            case "TYER", "TDRC", "DATE", "\u{00A9}day":
                if let ym = yearMonthOf(v) { releaseYm = ym }
            default: break
            }
        }

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
            lrcName: hasLrc ? lrcName : nil,
            releaseYm: releaseYm,
            writerLyric: lyricist,
            writerMusic: composer
        )
    }

    /// 从 "2013-05-20" / "2013/05" / "2013" 抠出 "2013.05" / "2013"
    private static func yearMonthOf(_ text: String) -> String? {
        let ns = text as NSString
        guard let yRe = try? NSRegularExpression(pattern: "(\\d{4})"),
              let ym = yRe.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let y = Int(ns.substring(with: ym.range(at: 1))), (1950...2100).contains(y) else { return nil }
        if let mRe = try? NSRegularExpression(pattern: "\\d{4}[-/.](\\d{1,2})"),
           let mm = mRe.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let mo = Int(ns.substring(with: mm.range(at: 1))), (1...12).contains(mo) {
            return String(format: "%04d.%02d", y, mo)
        }
        return String(format: "%04d", y)
    }

    private static func meta(_ items: [AVMetadataItem], _ key: AVMetadataKey) -> String? {
        guard let v = items.first(where: { $0.commonKey == key })?.stringValue else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
