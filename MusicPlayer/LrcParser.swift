import Foundation

/// LRC 解析：移植自 Android 端 LrcParser 的核心逻辑
/// 支持一行多个时间标签、[mm:ss]、[mm:ss.xx]、[mm:ss.xxx]
enum LrcParser {
    private static let timePattern = "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"

    static func parse(_ raw: String) -> [LrcLine] {
        guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }
        var out: [LrcLine] = []

        for line in raw.components(separatedBy: .newlines) {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = regex.matches(in: line, options: [], range: full)
            if matches.isEmpty { continue }

            var text = regex.stringByReplacingMatches(in: line, options: [], range: full, withTemplate: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                let fr = m.range(at: 3)
                if fr.location != NSNotFound {
                    let digits = ns.substring(with: fr)
                    if let v = Double(digits) {
                        frac = v / pow(10.0, Double(digits.count))
                    }
                }
                let t = mm * 60.0 + ss + frac
                if t.isFinite { out.append(LrcLine(time: t, text: text)) }
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 读文本：先 UTF-8，再 GB18030（国内大量 lrc 是这个编码）
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .unicode)
    }

    /// 判断是否"可滚动"：有内容的行至少 2 行、首尾时间差 >= 3 秒（同 Android 端 LrcDoc.scrollable）
    static func scrollable(_ lines: [LrcLine]) -> Bool {
        let withText = lines.filter { !$0.text.isEmpty }
        guard withText.count >= 2, let first = lines.first, let last = lines.last else { return false }
        return last.time - first.time >= 3.0
    }

    /// 找一首歌的歌词文件并读出解析后的行（本地同名 .lrc / 联网缓存 net_*.lrc）
    static func lines(for song: Song) -> [LrcLine] {
        var candidates: [URL] = []
        if let name = song.lrcName {
            candidates.append(LibraryStore.documents.appendingPathComponent(name))
        }
        let base = (song.fileName as NSString).deletingPathExtension
        candidates.append(LibraryStore.documents.appendingPathComponent(base + ".lrc"))
        // 联网补词落盘的固定命名：即使 player 手里的 Song 副本没刷新也能读到
        candidates.append(LibraryStore.documents.appendingPathComponent("net_" + LibraryStore.stableHash(song.id) + ".lrc"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let raw = readText(url) { return parse(raw) }
        }
        return []
    }

    /// 当前进度对应的行号；未到第一句返回 -1（dock 会退回首句）
    static func index(at t: Double, in lines: [LrcLine]) -> Int {
        var idx = -1
        for (i, line) in lines.enumerated() where line.time <= t + 0.15 { idx = i }
        return idx
    }
}
