import Foundation

// ============================================================================
// AutoMixer —— 移植安卓同名类，纯计算不碰播放器。
// 把两首歌的 BeatInfo 算出一份「过渡方案」：变速倍率、小节对齐的淡出起点、
// B 的进入点、响度补偿。常量与安卓完全一致，保证两端口径相同。
// ============================================================================

struct MixPlan {
    var crossfadeMs: Int64 = 6500
    var tempoRatio: Float = 1
    var seekBMs: Int64 = 0
    var fadeStartMs: Int64 = 0
    var gainB: Float = 1
    var beatMatched: Bool = false
    var label: String = ""
}

enum AutoMixer {
    private static let MIN_RATIO: Float = 0.93
    private static let MAX_RATIO: Float = 1.07
    private static let ACCEPT_LOW: Float = 0.85
    private static let ACCEPT_HIGH: Float = 1.18
    private static let REF_BARS = 3.0
    private static let FALLBACK_MS: Int64 = 6500
    private static let MAX_SEEK_B_MS: Int64 = 12_000
    private static let minMs: Int64 = 3000
    private static let maxMs: Int64 = 16_000

    /// 主入口：由 A(当前)/B(下一首) 的节拍信息 + A 的实际时长算出过渡方案
    static func plan(a: BeatInfo, aDurationMs: Int64, b: BeatInfo) -> MixPlan {
        let duration = aDurationMs > 0 ? aDurationMs : Int64.max / 4

        // 1) 速率：把 B 的 BPM 拉到 A（含「追不上就别硬追」）
        let ratio = tempoRatio(a, b)
        let beatMatched = abs(ratio - 1) > 0.004

        let periodA = a.bpm > 0 ? 60_000.0 / Double(a.bpm) : 0
        let barA = periodA * 4.0

        // 2) 重叠长度：匹配时 3 小节、不匹配时 2 小节；A 无 outro 且匹配则 +1 小节
        var bars = beatMatched ? REF_BARS : 2.0
        let hasOutro = false // iOS 首版未做 outro 结构分析 → 视为硬停
        if !hasOutro && beatMatched { bars += 1 }

        var overlap = barA > 1 ? Int64((barA * bars).rounded()) : FALLBACK_MS
        overlap = max(minMs, min(maxMs, overlap))
        // 重叠取整小节：小节线进、小节线出
        if barA > 1 {
            let minBars = max(1, Int(ceil(Double(minMs) / barA)))
            let maxBars = max(minBars, Int(Double(maxMs) / barA))
            let k = max(minBars, min(maxBars, Int(bars.rounded())))
            bars = Double(k)
            overlap = Int64((Double(k) * barA).rounded())
        }
        overlap = min(overlap, max(1000, duration - 1000))

        // 3) 淡出起点：曲尾往前推 overlap，并吸附到 A 的小节网格（downbeat 只取相位）
        let gridOrigin: Double = (periodA > 1 && a.firstBeatMs > 0)
            ? Double(a.firstBeatMs % Int64(max(1, Int64(barA)))) : 0
        var fadeStart = duration - overlap
        if barA > 1 {
            let snapped = Int64((gridOrigin + floor((Double(fadeStart) - gridOrigin) / barA) * barA).rounded())
            if snapped > 0 && duration - snapped >= 1500 { fadeStart = snapped }
        }
        fadeStart = max(0, min(duration, fadeStart))

        // 实际重叠 = 淡出起点到曲尾，钳制到合理范围
        var crossfade = max(1500, min(maxMs, duration - fadeStart))
        fadeStart = max(0, duration - crossfade)
        crossfade = max(500, duration - fadeStart)

        // 4) B 的进入点：对齐到 B 自己的小节线（downbeat 取相位），最多前移 12s
        let periodB = b.bpm > 0 ? 60_000.0 / Double(b.bpm) : 0
        let barB = periodB * 4.0
        let firstBeatB: Int64 = (b.bpm > 0 && barB > 1)
            ? b.firstBeatMs % Int64(max(1, Int64(barB))) : 0
        let seekB: Int64
        if barB > 1 {
            let k = Int64(((0 - Double(firstBeatB)) / barB).rounded())
            seekB = max(0, min(MAX_SEEK_B_MS, Int64((Double(firstBeatB) + Double(k) * barB).rounded())))
        } else {
            seekB = 0
        }

        // 5) 响度补偿（±5dB 内）
        let gainB: Float = (a.rmsDb > -60 && b.rmsDb > -60)
            ? Float(max(0.5, min(1.8, pow(10.0, Double(a.rmsDb - b.rmsDb) / 20.0)))) : 1

        var label = ""
        if beatMatched {
            label = String(format: "节拍匹配 %.0f→%.0f BPM · %.3f×", a.bpm, b.bpm * ratio, ratio)
        } else {
            label = "交叉淡入淡出（节拍差异较大）"
        }
        if barA > 1 { label += String(format: " · 约 %.0f 小节", Double(crossfade) / barA) }
        if abs(gainB - 1) > 0.08 { label += String(format: " · 音量补偿 %.2f×", gainB) }

        return MixPlan(crossfadeMs: crossfade, tempoRatio: ratio, seekBMs: seekB,
                       fadeStartMs: fadeStart, gainB: gainB, beatMatched: beatMatched, label: label)
    }

    /// 完全拿不到节拍信息时的兜底：歌尾按 6.5s 淡出，B 从 0 进入
    static func fallback(aDurationMs: Int64) -> MixPlan {
        let crossfade = max(minMs, min(maxMs, FALLBACK_MS))
        let duration = aDurationMs > 0 ? aDurationMs : Int64.max / 4
        return MixPlan(crossfadeMs: crossfade, tempoRatio: 1, seekBMs: 0,
                       fadeStartMs: max(0, duration - crossfade), gainB: 1,
                       beatMatched: false, label: String(format: "交叉淡入淡出 %.1fs", Double(crossfade) / 1000))
    }

    /// 把两首 BPM 拉齐：倍率容差 [0.85,1.18]（含 ×2/÷2），幅度 ±7%，
    /// 且「追不上就别硬追」——需变速超过 ±4% 干脆不匹配，避免鼓点持续错开。
    private static func tempoRatio(_ a: BeatInfo, _ b: BeatInfo) -> Float {
        guard a.bpm > 0, b.bpm > 0 else { return 1 }
        let raw = a.bpm / b.bpm
        guard let pick = [raw, raw * 2, raw / 2].first(where: { $0 >= ACCEPT_LOW && $0 <= ACCEPT_HIGH }) else { return 1 }
        let clamped = max(MIN_RATIO, min(MAX_RATIO, pick))
        if abs(clamped - pick) > 0.04 * pick { return 1 }
        return clamped
    }
}
