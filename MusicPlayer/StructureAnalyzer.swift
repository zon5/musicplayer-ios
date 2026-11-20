import Foundation
import AVFoundation

// ============================================================================
// StructureAnalyzer —— 移植安卓 BeatAnalyzer.detectStructure
// 目的：沉浸式播放（串烧）要「听完一遍主歌 + 一遍副歌」才换歌，切点必须落在
//       人声收住的段落边界上，而不是随便按百分比截断。
//
// 算法（与安卓逐条对齐）：
//   1) 按小节统计 RMS 均值（10ms 帧取平均）→ ±1 小节平滑，得到小节级能量轮廓
//   2) 门限 = p25 + (p90 - p25) × CHORUS_LEVEL；连续高于门限的小节连成「高能量段」
//      （允许中间漏 1 小节：鼓过门会把能量临时压下去）
//   3) 先挑最响的一段当副歌模板，再从前往后找第一段「能量够像、长度够长」的 → 第一遍副歌
//   4) 切点 = 这段副歌的结束边界，吸附到小节线，收敛到 [45s, 110s]
//   5) 「让最后一句唱完」：边界处若 1 秒滑动平均还饱满，往后挪到真正收句的位置
//      （最多 2.5 小节 / 8s），避免把副歌最后一句硬淡掉
//   6) 副歌之后是「间奏」→ 淡出短一点(1.5 小节)；直接接主歌 → 淡出拉长(2.5 小节)
// ⚠️ 常量与安卓完全一致，别随手改，两端口径要相同。
// ⚠️ 系统库歌（ipod-library://）读不到 PCM → 返回 nil，上层退回按比例切。
// ============================================================================

struct SongStructure {
    var chorusStartMs: Int64 = 0
    var cutMs: Int64 = 0        // 退场点（切歌位置）
    var fadeMs: Int64 = 4000    // 交叉淡化时长
    var confidence: Float = 0
    var note: String = ""
    var valid: Bool { cutMs > 1000 }
}

final class StructureAnalyzer {
    static let shared = StructureAnalyzer()

    // ---- 与安卓一致的常量 ----
    private let HOP_MS = 10
    private let FALLBACK_BAR_MS: Double = 2000
    private let STRUCT_SCAN_MS: Int64 = 150_000
    private let CHORUS_LEVEL: Float = 0.32
    private let MIN_CHORUS_BARS = 6
    private let CHORUS_SIMILAR: Float = 0.75
    private let CHORUS_LEN_RATIO: Float = 0.30
    private let INTERLUDE_LEVEL: Float = 0.55
    private let INTERLUDE_MIN_BARS = 3
    private let FADE_BARS_INTERLUDE: Double = 1.5
    private let FADE_BARS_NORMAL: Double = 2.5
    private let FADE_MIN_MS: Int64 = 1500
    private let FADE_MAX_MS: Int64 = 7000
    private let EXIT_MAX_MS: Int64 = 130_000
    private let EXIT_MIN_MS: Int64 = 60_000
    private let TAIL_LOUD: Float = 0.75
    private let TAIL_QUIET: Float = 0.72
    private let TAIL_MAX_BARS: Double = 2.5
    private let TAIL_MAX_MS: Int64 = 8_000
    private let CUT_MIN_MS: Int64 = 45_000
    private let CUT_MAX_MS: Int64 = 110_000

    private var cache: [String: SongStructure] = [:]
    private let lock = NSLock()

    /// 分析一首歌的段落结构。失败返回 nil（上层退回按比例切歌）。
    func structure(for song: Song) -> SongStructure? {
        guard !song.isSystem else { return nil }
        lock.lock()
        if let c = cache[song.id] { lock.unlock(); return c.valid ? c : nil }
        lock.unlock()

        let bpm = BeatAnalyzer.shared.beat(for: song).bpm
        let r = detect(song: song, bpm: bpm, durationMs: Int64(song.duration * 1000))
        if let r = r {
            lock.lock(); cache[song.id] = r; lock.unlock()
        }
        return r
    }

    private func detect(song: Song, bpm: Float, durationMs: Int64) -> SongStructure? {
        let hasBeat = bpm > 40
        let barMs = hasBeat ? 60_000.0 / Double(bpm) * 4.0 : FALLBACK_BAR_MS
        if barMs < 500 { return nil }

        let hardEnd = durationMs > 0 ? durationMs : STRUCT_SCAN_MS
        let scanMs = min(hardEnd - 1500, STRUCT_SCAN_MS)
        if scanMs < 25_000 { return nil }
        guard let env = decode(url: song.fileURL, winMs: scanMs) else { return nil }
        let n = env.count
        if n < 400 { return nil }

        let origin: Int64 = 0
        let coveredEnd = Int64(n) * Int64(HOP_MS)
        let barCount = Int((coveredEnd - origin) / Int64(barMs))
        if barCount < 16 { return nil }

        // 1) 每小节 RMS 均值
        var bar = [Float](repeating: 0, count: barCount)
        for b in 0..<barCount {
            let i0 = max(0, Int((origin + Int64(Double(b) * barMs)) / Int64(HOP_MS)))
            let i1 = min(n, Int((origin + Int64(Double(b + 1) * barMs)) / Int64(HOP_MS)))
            if i1 <= i0 { bar[b] = 0; continue }
            var s = 0.0
            for i in i0..<i1 { s += Double(env[i]) }
            bar[b] = Float(s / Double(i1 - i0))
        }

        // 平滑 ±1 小节
        var g = [Float](repeating: 0, count: barCount)
        for b in 0..<barCount {
            var s: Float = 0
            var c = 0
            for k in (b - 1)...(b + 1) where k >= 0 && k < barCount { s += bar[k]; c += 1 }
            g[b] = c > 0 ? s / Float(c) : 0
        }

        // 2) 门限
        let voiced = g.filter { $0 > 0.005 }.sorted()
        if voiced.count < 12 { return nil }
        let p25 = voiced[min(voiced.count - 1, Int(Double(voiced.count) * 0.25))]
        let p90 = voiced[min(voiced.count - 1, Int(Double(voiced.count) * 0.90))]
        if p90 < p25 * 1.15 { return nil }   // 能量太平，分不出段落
        let thr = p25 + (p90 - p25) * CHORUS_LEVEL

        var high = (0..<barCount).map { g[$0] >= thr }
        if barCount > 2 {
            for b in 1..<(barCount - 1) where !high[b] && high[b - 1] && high[b + 1] { high[b] = true }
        }

        // 连续高能量段（闭区间）
        var runs: [(Int, Int)] = []
        var b = 0
        while b < barCount {
            if !high[b] { b += 1; continue }
            var e = b
            while e + 1 < barCount && high[e + 1] { e += 1 }
            runs.append((b, e))
            b = e + 1
        }
        let useful = runs.filter { $0.1 - $0.0 + 1 >= MIN_CHORUS_BARS }
        if useful.isEmpty { return nil }

        // 3) 最响的一段当模板 → 找第一遍副歌
        func meanOf(_ a: Int, _ z: Int) -> Float {
            var s: Float = 0
            for i in a...z { s += g[i] }
            return s / Float(z - a + 1)
        }
        let means = useful.map { meanOf($0.0, $0.1) }
        var loudest = 0
        for i in means.indices where means[i] > means[loudest] { loudest = i }
        let loudLen = useful[loudest].1 - useful[loudest].0 + 1
        var picked = loudest
        for i in useful.indices {
            let len = useful[i].1 - useful[i].0 + 1
            let needLen = max(MIN_CHORUS_BARS, Int(Double(loudLen) * Double(CHORUS_LEN_RATIO)))
            if means[i] >= means[loudest] * CHORUS_SIMILAR && len >= needLen { picked = i; break }
        }
        let chosen = useful[picked]
        let chorusMean = means[picked]

        let chorusStartMs = origin + Int64((Double(chosen.0) * barMs).rounded())
        let rawEnd = origin + Int64((Double(chosen.1 + 1) * barMs).rounded())

        // 4) 收敛到 [45s, 110s] 并吸附小节线
        let hiCap = durationMs > 0 ? min(CUT_MAX_MS, durationMs - 1500) : CUT_MAX_MS
        let clamped = max(CUT_MIN_MS, min(rawEnd, max(hiCap, CUT_MIN_MS)))
        let barsToCut = max(1, Int((Double(clamped - origin) / barMs).rounded()))
        var cutMs = origin + Int64((Double(barsToCut) * barMs).rounded())

        // 5) 让最后一句唱完：边界处还在饱满就往后挪到真正收句处
        cutMs = relaxToLineEnd(env: env, boundaryMs: cutMs, barMs: barMs,
                               chorusMean: chorusMean, hardEnd: hardEnd)

        // 6) 判定副歌之后是不是「间奏」，决定淡出长度
        let cutBar = Int(Double(cutMs - origin) / barMs)
        var isInterlude = false
        if cutBar + INTERLUDE_MIN_BARS <= barCount {
            let segMean = meanOf(cutBar, min(barCount - 1, cutBar + INTERLUDE_MIN_BARS - 1))
            let segHigh = (cutBar..<min(barCount, cutBar + INTERLUDE_MIN_BARS)).contains { high[$0] }
            isInterlude = !segHigh && segMean >= chorusMean * INTERLUDE_LEVEL
        }
        let fadeBars = isInterlude ? FADE_BARS_INTERLUDE : FADE_BARS_NORMAL
        let fadeMs = max(FADE_MIN_MS, min(FADE_MAX_MS, Int64((fadeBars * barMs).rounded())))

        return SongStructure(
            chorusStartMs: chorusStartMs,
            cutMs: max(EXIT_MIN_MS, min(EXIT_MAX_MS, cutMs)),
            fadeMs: fadeMs,
            confidence: means[picked] > 0 ? min(1, chorusMean / max(1e-5, means[loudest])) : 0,
            note: isInterlude ? "副歌收尾 → 间奏里淡出接歌" : "副歌收尾 → 淡出音乐再接歌"
        )
    }

    /// 「让最后一句唱完」：副歌最后一句常是「人声还在拖长音、编曲先薄下去」，
    /// 边界会落在句头。这里往后找 1 秒滑动平均真正掉下来的位置（最多 2.5 小节 / 8s）。
    private func relaxToLineEnd(env: [Float], boundaryMs: Int64, barMs: Double,
                                chorusMean: Float, hardEnd: Int64) -> Int64 {
        let n = env.count
        if n < 40 || chorusMean <= 0 { return boundaryMs }
        // 1 秒滑动平均（10ms 一帧 → 100 帧）
        let w = 100
        var ma = [Float](repeating: 0, count: n)
        var acc: Float = 0
        for i in 0..<n {
            acc += env[i]
            if i >= w { acc -= env[i - w] }
            ma[i] = acc / Float(min(i + 1, w))
        }
        let i0 = Int(boundaryMs / Int64(HOP_MS))
        if i0 < 0 || i0 >= n { return boundaryMs }
        if ma[i0] < chorusMean * TAIL_LOUD { return boundaryMs }   // 边界已收住，别动
        let quiet = chorusMean * TAIL_QUIET
        let maxShiftFrames = min(Int(TAIL_MAX_MS / Int64(HOP_MS)),
                                 max(1, Int(Double(TAIL_MAX_BARS) * barMs / Double(HOP_MS))))
        var k = 0
        while k < maxShiftFrames {
            let i = i0 + k
            if i + w >= n { break }
            if ma[i] < quiet && ma[i + w] < quiet {
                return min(hardEnd - 500, boundaryMs + Int64(k * HOP_MS))
            }
            k += 1
        }
        return boundaryMs
    }

    /// 分块解码 PCM，每 10ms 出一帧 RMS。分块是为了不把 150 秒音频一次性读进内存。
    private func decode(url: URL, winMs: Int64) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        let channels = Int(f.processingFormat.channelCount)
        let hop = Int(sr * Double(HOP_MS) / 1000.0)
        guard hop > 0 else { return nil }
        let totalFrames = min(Int64(f.length), Int64(Double(winMs) / 1000.0 * sr))
        guard totalFrames > Int64(hop) * 100 else { return nil }

        var values: [Float] = []
        values.reserveCapacity(Int(totalFrames / Int64(hop)) + 8)
        let chunk = hop * 1000                    // 10 秒一块（hop 的整数倍，不会有半帧残留）
        var remaining = totalFrames
        f.framePosition = 0

        while remaining > 0 {
            let want = Int(min(Int64(chunk), remaining))
            guard want > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                             frameCapacity: AVAudioFrameCount(want)) else { break }
            do { try f.read(into: buf, frameCount: AVAudioFrameCount(want)) } catch { break }
            let got = Int(buf.frameLength)
            if got <= 0 { break }
            guard let ch = buf.floatChannelData else { break }
            let inv = 1.0 / Float(max(1, channels))
            var frameStart = 0
            while frameStart + hop <= got {
                var sum: Float = 0
                for i in 0..<hop {
                    var s: Float = 0
                    for c in 0..<channels { s += ch[c][frameStart + i] }
                    s *= inv
                    sum += s * s
                }
                values.append(Float(sqrt(Double(sum) / Double(hop))))
                frameStart += hop
            }
            remaining -= Int64(got)
            if got < want { break }
        }
        return values.isEmpty ? nil : values
    }
}
