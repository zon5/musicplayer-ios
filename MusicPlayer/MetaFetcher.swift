import Foundation

// MARK: - 数据结构（对齐安卓 MetaFetcher 的 Hit / Lyric / Detail）

struct MetaHit {
    var id: Int64 = 0
    var name: String = ""
    var artists: String = ""
    var album: String = ""
    var picUrl: String?
    var durationMs: Int64 = 0
}

/// 联网补一首歌的结果：歌词原文 + 词曲署名 + 发行年月 + 封面地址
struct SongMeta {
    var lrc: String?
    var writerLyric: String?
    var writerMusic: String?
    var releaseYm: String?
    var coverUrl: String?
    var matchedID: Int64?

    var isEmpty: Bool {
        lrc == nil && writerLyric == nil && writerMusic == nil && releaseYm == nil && coverUrl == nil
    }
}

/// 移植安卓 MetaFetcher：网易云搜索 / 歌词 / 详情接口。
/// 只用 https，带浏览器 UA + Referer + Cookie；所有失败都吞掉返回空，绝不阻塞界面。
final class MetaFetcher {
    static let shared = MetaFetcher()
    private let session = URLSession.shared

    private func headers(_ req: inout URLRequest) {
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("appver=2.0.2; os=pc", forHTTPHeaderField: "Cookie")
    }

    private func getJSON(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        headers(&req)
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: 搜索

    func search(_ keyword: String, limit: Int = 8) async -> [MetaHit] {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let urls = [
            "https://music.163.com/api/cloudsearch/pc?s=\(q)&type=1&offset=0&limit=\(limit)",
            "https://music.163.com/api/search/get/web?csrf_token=&s=\(q)&type=1&offset=0&total=true&limit=\(limit)",
            "https://music.163.com/api/search/get?s=\(q)&type=1&offset=0&limit=\(limit)",
        ]
        for u in urls {
            guard let root = await getJSON(u),
                  let result = root["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]] else { continue }
            let hits = songs.map { parseHit($0) }.filter { !$0.name.isEmpty }
            if !hits.isEmpty { return hits }
        }
        return []
    }

    private func parseHit(_ s: [String: Any]) -> MetaHit {
        var h = MetaHit()
        h.id = (s["id"] as? NSNumber)?.int64Value ?? 0
        h.name = s["name"] as? String ?? ""
        let artists = s["artists"] as? [[String: Any]] ?? s["ar"] as? [[String: Any]] ?? []
        h.artists = artists.compactMap { $0["name"] as? String }.joined(separator: "/")
        let album = s["album"] as? [String: Any] ?? s["al"] as? [String: Any]
        h.album = album?["name"] as? String ?? ""
        let pic = album?["picUrl"] as? String
        h.picUrl = pic.flatMap { $0.isEmpty || $0 == "null" ? nil : normalizeCover($0) }
        h.durationMs = (s["duration"] as? NSNumber)?.int64Value
            ?? (s["dt"] as? NSNumber)?.int64Value ?? 0
        return h
    }

    private func normalizeCover(_ url: String) -> String {
        if url.hasPrefix("http://") { return "https://" + url.replacingOccurrences(of: "http://", with: "") }
        return url
    }

    // MARK: 歌词

    func lyric(_ id: Int64) async -> String? {
        guard id > 0 else { return nil }
        let u = "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1"
        guard let root = await getJSON(u) else { return nil }
        func read(_ key: String) -> String? {
            guard let box = root[key] as? [String: Any] else { return nil }
            return box["lyric"] as? String
        }
        return read("lrc") ?? read("klyric")
    }

    // MARK: 详情（发行年月 + 封面）

    func detail(_ id: Int64) async -> (cover: String?, releaseYm: String?) {
        guard id > 0 else { return (nil, nil) }
        let u = "https://music.163.com/api/song/detail?ids=%5B\(id)%5D"
        guard let root = await getJSON(u),
              let songs = root["songs"] as? [[String: Any]],
              let first = songs.first,
              let album = first["album"] as? [String: Any] else { return (nil, nil) }
        let cover = (album["picUrl"] as? String).flatMap { normalizeCover($0) }
        var ym: String? = nil
        if let ms = (album["publishTime"] as? NSNumber)?.doubleValue, ms > 0 {
            ym = releaseYm(fromMillis: ms)
        }
        return (cover, ym)
    }

    private func releaseYm(fromMillis ms: Double) -> String? {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: date)
        guard let y = comps.year, (1950...2100).contains(y) else { return nil }
        if let m = comps.month { return String(format: "%04d.%02d", y, m) }
        return String(format: "%04d", y)
    }

    // MARK: 防错配：歌名近似 + 时长接近（对齐安卓 sameSong 的宽松口径）

    func sameSong(title: String, artist: String, duration: Double, hit: MetaHit) -> Bool {
        let a = SongTitle.clean(title).lowercased()
        let b = SongTitle.clean(hit.name).lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }

        // 歌名：全等 / 包含 / 相似度 >= 0.7
        var nameOK = a == b || a.contains(b) || b.contains(a)
        if !nameOK { nameOK = similarity(a, b) >= 0.7 }
        guard nameOK else { return false }

        // 时长：两边都有且在 ±5s 内；在线没时长就放行
        if duration > 0, hit.durationMs > 0 {
            let d = abs(duration - Double(hit.durationMs) / 1000.0)
            if d > 5 { return false }
        }

        // 歌手：都有且完全不搭界时拒绝（包含或互为子串即放行）
        let ar = artist.lowercased()
        let hr = hit.artists.lowercased()
        if !ar.isEmpty, !hr.isEmpty,
           !ar.contains(hr), !hr.contains(ar),
           similarity(ar, hr) < 0.5 { return false }
        return true
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 0...x.count {
            cur[0] = i
            for j in 0...y.count {
                if j == 0 { continue }
                cur[j] = min(cur[j - 1] + 1, prev[j] + 1,
                             prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        let dist = Double(prev[y.count])
        return max(0, 1 - dist / Double(max(x.count, y.count)))
    }

    // MARK: 一站式补全：搜索 → 选匹配 → 歌词 + 详情 + 词曲署名

    func enrich(song: Song) async -> SongMeta {
        let keyword = song.displayTitle + (song.artist.isEmpty ? "" : " " + song.artist)
        let hits = await search(keyword)
        guard let hit = hits.first(where: { sameSong(title: song.title,
                                                      artist: song.artist,
                                                      duration: song.duration,
                                                      hit: $0) }) ?? hits.first else {
            return SongMeta()
        }
        let lrcText = await lyric(hit.id)
        let d = await detail(hit.id)
        let credits = Self.credits(lrcText)
        return SongMeta(
            lrc: lrcText,
            writerLyric: credits.lyric,
            writerMusic: credits.music,
            releaseYm: d.releaseYm,
            coverUrl: d.cover ?? hit.picUrl,
            matchedID: hit.id
        )
    }

    // MARK: 从歌词署名行抠词曲（移植安卓 LrcParser.credits）

    static func credits(_ raw: String?) -> (lyric: String?, music: String?) {
        guard let raw = raw, !raw.isEmpty else { return (nil, nil) }
        var lyric: String? = nil
        var music: String? = nil
        let timeTag = try? NSRegularExpression(pattern: "\\[\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?\\]")

        for line in raw.split(separator: "\n").prefix(60) {
            var s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let re = timeTag {
                let ns = s as NSString
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if s.isEmpty { continue }

            guard let colonIdx = s.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let head = String(s[..<colonIdx]).replacingOccurrences(of: " ", with: "").lowercased()
            var value = String(s[s.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“” "))
            if value.isEmpty || value.count > 60 { continue }
            if value.contains("暂无") || value.contains("未知") { continue }
            if head.count > 10 { continue }

            // 一行写两项：「词：A 曲：B」
            var splitAt: Int? = nil
            for tag in ["作曲：", "作曲:", "曲：", "曲:"] {
                if let i = value.range(of: tag)?.lowerBound {
                    let pos = value.distance(from: value.startIndex, to: i)
                    if pos > 0 { splitAt = min(splitAt ?? pos, pos) }
                }
            }
            if let p = splitAt {
                let idx = value.index(value.startIndex, offsetBy: p)
                let tail = String(value[idx...])
                    .replacingOccurrences(of: "作曲：", with: "").replacingOccurrences(of: "作曲:", with: "")
                    .replacingOccurrences(of: "曲：", with: "").replacingOccurrences(of: "曲:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if music == nil, !tail.isEmpty { music = tail }
                value = String(value[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                if lyric == nil, !value.isEmpty { lyric = value }
                continue
            }

            let both = head.contains("词") && head.contains("曲")
            if both {
                if lyric == nil { lyric = value }
                if music == nil { music = value }
            } else if head.contains("词") || head.hasPrefix("lyric") {
                if lyric == nil { lyric = value }
            } else if head.contains("曲") && !head.contains("编") {
                if music == nil { music = value }
            } else if head.hasPrefix("compos") || head == "music" || head == "musicby" {
                if music == nil { music = value }
            }
            if lyric != nil && music != nil { break }
        }
        return (cleanCredit(lyric), cleanCredit(music))
    }

    /// 「词：无」「曲：-」这类占位当成没查到；真名不受影响
    private static func cleanCredit(_ raw: String?) -> String? {
        guard let v = raw else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let placeholders = ["无", "-", "--", "—", "未知", "暂无", "N/A", "n/a", "不详"]
        if placeholders.contains(t) { return nil }
        return t
    }
}
