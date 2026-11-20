import Foundation
import AVFoundation

// ============================================================================
// BeatAnalyzer —— 移植安卓同名类的离线 BPM / downbeat 分析（纯算法，不碰播放器）
// 算法链：AVAudioFile 读 PCM → 10ms 能量包络 → onset 强度(局部均值减除+对数压缩)
//        → 梳状自相关求 BPM(带 120BPM 对数先验) → 4 拍找小节重音 downbeat
// ⚠️ 关键常量与安卓 BeatAnalyzer 完全一致，保证两端口径相同。
// 系统库 DRM 歌曲无法读 PCM → 返回 nil，串烧退化为固定淡入淡出。
// ============================================================================

struct BeatInfo {
    var bpm: Float = 0
    var firstBeatMs: Int64 = 0   // downbeat 的绝对毫秒位置
    var rmsDb: Float = -60
    var confidence: Float = 0

    static let unknown = BeatInfo()
    var valid: Bool { bpm > 0 }
}

private struct Envelope {
    let values: [Float]
    let count: Int
    let totalSq: Double
    let totalN: Int
    let startMs: Int64
}

private struct Tempo {
    let lag: Int
    let score: Double
    let second: Double
    var bpm: Float { 6000 / Float(lag) }
    var peakRatio: Float { Float(score / (second + 1e-9)) }
}

private struct TempoWin {
    let t: Tempo
    let onset: [Float]
    let count: Int
    let startMs: Int64
}

final class BeatAnalyzer {
    static let shared = BeatAnalyzer()

    private let HOP_MS = 10
    private let WIN_MS: Int64 = 26_000
    private let LAG_MIN = 30
    private let LAG_MAX = 110
    private let LN2 = 0.6931471805599453
    private let STRONG_PEAK_RATIO: Float = 1.8

    /// 进程内缓存：songID → BeatInfo。分析失败不缓存（换进程可重试，同安卓 attempted 语义）
    private var cache: [String: BeatInfo] = [:]
    private let lock = NSLock()

    /// 分析本地文件。系统库歌（ipod-library://）无 fileURL，返回 unknown。
    func beat(for song: Song) -> BeatInfo {
        guard !song.isSystem else { return .unknown }
        lock.lock()
        if let c = cache[song.id] { lock.unlock(); return c }
        lock.unlock()

        let info = analyze(url: song.fileURL, durationSec: song.duration) ?? .unknown
        if info.valid {
            lock.lock(); cache[song.id] = info; lock.unlock()
        }
        return info
    }

    private func analyze(url: URL, durationSec: Double) -> BeatInfo? {
        let durMs = Int64(durationSec * 1000)
        var starts: [Int64] = [0]
        if durMs > 100_000 {
            let mid = max(20_000, min(Int64(Double(durMs) * 0.40), max(durMs - WIN_MS, 20_000)))
            starts.append(mid)
        }

        var wins: [TempoWin] = []
        var rmsDb: Float = -60
        for (i, st) in starts.enumerated() {
            guard let env = decodeEnvelope(url: url, startMs: st, winMs: WIN_MS), env.count >= 400 else { continue }
            if i == 0 {
                let rms = sqrt(env.totalSq / Double(max(1, env.totalN)))
                rmsDb = Float(max(1e-5, min(1, rms)))
                rmsDb = Float(20.0 * log10(Double(rmsDb)))
            }
            let o = onsetStrength(env)
            guard let t = bestTempo(o, env.count) else { continue }
            wins.append(TempoWin(t: t, onset: o, count: env.count, startMs: env.startMs))
        }
        guard !wins.isEmpty else { return nil }

        // 八度折叠 + 加权中位数
        let folded = wins.map { octaveFold($0.t.bpm) }
        let weights = wins.map { $0.t.score }
        let order = folded.indices.sorted { folded[$0] < folded[$1] }
        let total = max(1e-9, weights.reduce(0, +))
        var acc = 0.0, medBpm = folded[0]
        for idx in order {
            acc += weights[idx]
            if acc >= total / 2 { medBpm = folded[idx]; break }
        }
        var agreeW = 0.0
        for i in folded.indices where abs(folded[i] - medBpm) / medBpm < 0.025 { agreeW += weights[i] }
        let agree = Float(agreeW / total)

        guard let best = wins.max(by: { $0.t.peakRatio < $1.t.peakRatio }) else { return nil }
        let lag = best.t.lag
        let o = best.onset
        let n = best.count

        // 相位：拍点落进 onset 最密处
        var bestPhase = 0, bestScore = -1.0
        for ph in 0..<lag {
            var s = 0.0, k = ph
            while k < n { s += Double(o[k]); k += lag }
            if s > bestScore { bestScore = s; bestPhase = ph }
        }
        // 小节重音：4 拍一组找最强拍 = 小节第 1 拍
        var accPerSlot = [Double](repeating: 0, count: 4)
        var j = 0, k = bestPhase
        while k < n { accPerSlot[j % 4] += Double(o[k]); j += 1; k += lag }
        var downSlot = 0
        for s in 1..<4 where accPerSlot[s] > accPerSlot[downSlot] { downSlot = s }
        var firstDown = bestPhase, jj = 0, kk = bestPhase
        while kk < n {
            if jj % 4 == downSlot { firstDown = kk; break }
            jj += 1; kk += lag
        }

        let rawConf: Float = agree * min(max(best.t.peakRatio, 0.6), 2.5) / 2.5
        let conf: Float = max(0, min(1, rawConf))

        var outBpm = Float(medBpm)
        if wins.count >= 2 && agree < 0.5 {
            if best.t.peakRatio < STRONG_PEAK_RATIO { return nil }
            outBpm = octaveFold(best.t.bpm)
        }
        if agree < 0.34 && best.t.peakRatio < 1.30 { return nil }

        return BeatInfo(
            bpm: (outBpm * 10).rounded(.down) / 10,
            firstBeatMs: best.startMs + Int64(firstDown) * Int64(HOP_MS),
            rmsDb: rmsDb,
            confidence: conf
        )
    }

    /// 用 AVAudioFile 读取指定窗口的 PCM，算出 10ms 一帧的 RMS 能量包络
    private func decodeEnvelope(url: URL, startMs: Int64, winMs: Int64) -> Envelope? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate
        let channels = f.processingFormat.channelCount
        let hop = Int(sr * Double(HOP_MS) / 1000.0)          // 每 10ms 的采样数
        let winFrames = Int64(sr * Double(winMs) / 1000.0)   // 窗口总帧数
        let startFrame = AVAudioFramePosition(Double(startMs) / 1000.0 * sr)
        guard startFrame < f.length, hop > 0 else { return nil }
        let readFrames = AVAudioFrameCount(min(Int64(f.length) - startFrame, winFrames))
        guard readFrames > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: readFrames) else { return nil }
        do {
            // AVAudioFile 没有 seek，直接设 framePosition 再读
            f.framePosition = startFrame
            try f.read(into: buf, frameCount: readFrames)
        } catch { return nil }

        guard let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength) / hop
        guard n > 0 else { return nil }
        var values = [Float](repeating: 0, count: n)
        var totalSq = 0.0, totalN = 0
        for frame in 0..<n {
            let base = frame * hop
            var sum: Float = 0
            for i in 0..<hop {
                var s: Float = 0
                for c in 0..<Int(channels) { s += ch[Int(c)][base + i] }
                s /= Float(max(1, Int(channels)))
                sum += s * s
            }
            let rms = sqrt(sum / Float(hop))
            values[frame] = rms
            totalSq += Double(sum)
            totalN += hop
        }
        return Envelope(values: values, count: n, totalSq: totalSq, totalN: totalN, startMs: startMs)
    }

    /// onset 强度：局部均值减除 + 对数压缩（弱拍也抬起来，节拍网格才稳）
    private func onsetStrength(_ env: Envelope) -> [Float] {
        let n = env.count
        var o = [Float](repeating: 0, count: n)
        let win = 12
        var peak: Float = 0
        for i in 1..<n {
            var sum: Float = 0, c = 0
            var k = max(0, i - win)
            while k < i { sum += env.values[k]; c += 1; k += 1 }
            let local = c > 0 ? sum / Float(c) : 0
            let v = max(0, env.values[i] - local)
            o[i] = v
            if v > peak { peak = v }
        }
        if peak > 0 {
            let g: Float = 8 / peak
            for i in 0..<n { o[i] = Float(log(1.0 + Double(o[i] * g))) }
        }
        return o
    }

    /// 梳状自相关求最佳拍长（带 120BPM 对数先验）
    private func bestTempo(_ o: [Float], _ n: Int) -> Tempo? {
        let lo = LAG_MIN
        let hi = min(LAG_MAX, n / 4)
        if hi <= lo + 4 { return nil }
        let maxLag = hi * 3
        var ac = [Double](repeating: 0, count: maxLag + 1)
        var e0 = 0.0
        for i in 0..<n { e0 += Double(o[i]) * Double(o[i]) }
        if e0 <= 1e-9 { return nil }
        for lag in 1...maxLag {
            var a = 0.0, i = lag
            while i < n { a += Double(o[i]) * Double(o[i - lag]); i += 1 }
            ac[lag] = a / Double(n - lag)
        }
        func score(_ lag: Int) -> Double {
            let s = ac[lag] + 0.6 * ac[min(2 * lag, maxLag)] + 0.4 * ac[min(3 * lag, maxLag)]
            let bpm = 6000.0 / Double(lag)
            let prior = exp(-0.5 * pow(log(bpm / 120.0) / LN2 / 0.85, 2))
            return s / e0 * prior
        }
        var bestLag = -1, bestScore = -1.0
        for lag in lo...hi {
            let s = score(lag)
            if s > bestScore { bestScore = s; bestLag = lag }
        }
        guard bestLag >= 0 else { return nil }
        var second = 0.0
        let gap = max(2, bestLag / 8)
        for lag in lo...hi {
            if abs(lag - bestLag) <= gap { continue }
            let s = score(lag)
            if s > second { second = s }
        }
        return Tempo(lag: bestLag, score: bestScore, second: second)
    }

    private func octaveFold(_ bpmIn: Float) -> Float {
        var b = bpmIn, guard1 = 0
        while b < 70 && guard1 < 8 { b *= 2; guard1 += 1 }
        while b >= 140 && guard1 < 16 { b /= 2; guard1 += 1 }
        return b
    }
}
