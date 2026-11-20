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
            if let raw = readText(url) {
                // 同名 .tlyric / net_*.tlyric 译文，按时间合并
                var trans: String? = nil
                let tName = (url.lastPathComponent as NSString).deletingPathExtension + ".tlyric"
                let tURL = LibraryStore.documents.appendingPathComponent(tName)
                if FileManager.default.fileExists(atPath: tURL.path) { trans = readText(tURL) }
                return parseBilingual(raw, translation: trans)
            }
        }
        return []
    }

    /// 读一首歌的歌词原文（编辑页用）
    static func rawText(for song: Song) -> String? {
        var candidates: [URL] = []
        if let name = song.lrcName {
            candidates.append(LibraryStore.documents.appendingPathComponent(name))
        }
        let base = (song.fileName as NSString).deletingPathExtension
        candidates.append(LibraryStore.documents.appendingPathComponent(base + ".lrc"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let raw = readText(url) { return raw }
        }
        return nil
    }

    /// 当前进度对应的行号；未到第一句返回 -1（dock 会退回首句）
    static func index(at t: Double, in lines: [LrcLine]) -> Int {
        var idx = -1
        for (i, line) in lines.enumerated() where line.time <= t + 0.15 { idx = i }
        return idx
    }

    /// 解析带翻译的双语歌词：stripped 主歌词行 + tlyric 译文行，按时间对齐。
    /// 网易云的 lrc 里译文在 [offset:...] 之后可能出现的 "[00:12.34]译文" 形式，
    /// 这里把两段拼在一起解析，同一时间戳的译文填进 LrcLine.translation。
    static func parseBilingual(_ main: String, translation: String?) -> [LrcLine] {
        var lines = parse(main)
        guard let tr = translation, !tr.isEmpty else { return lines }
        let transLines = parse(tr)
        // 用 0.2s 容差按时间就近匹配
        var used = Set<Int>()
        for t in transLines where !t.text.isEmpty {
            var best = -1, bestD = 0.25
            for (i, l) in lines.enumerated() where !used.contains(i) {
                let d = abs(l.time - t.time)
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0, lines[best].translation == nil {
                lines[best].translation = t.text
                used.insert(best)
            }
        }
        return lines
    }
}
