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
}
