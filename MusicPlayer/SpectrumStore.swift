import Foundation
import AVFoundation
import Combine

/// 实时频谱数据（对齐安卓 SpectrumTap.BANDS = 22）。
/// 从 AVAudioEngine 的 mainMixerNode 挂 tap 拿 PCM，做 1024 点 FFT，映射到 22 个对数频段，
/// 「快起慢落」平滑；界面 ~20fps 读 levels 画柱。
final class SpectrumStore: ObservableObject {
    static let BANDS = 22
    static let shared = SpectrumStore()

    /// [0,1]，界面只读。@Published 触发 dock 重绘。
    @Published var levels: [Float] = [Float](repeating: 0.06, count: SpectrumStore.BANDS)

    // ---- FFT 工作区（只在 tap 音频线程访问）----
    private let n = 1024
    private var window: [Float] = []
    private var re: [Float] = []
    private var im: [Float] = []
    private var buf: [Float] = []
    private var filled = 0
    private var bandStart: [Int] = []
    private var smooth: [Float] = []
    private var sampleRate: Double = 44100

    // ---- 待显示的一帧（音频线程写，定时器读）----
    private var frame: [Float] = [Float](repeating: 0, count: SpectrumStore.BANDS)
    private let frameLock = NSLock()
    private var display: [Float] = [Float](repeating: 0.06, count: SpectrumStore.BANDS)

    private var tapInstalled = false
    private var timer: Timer?

    init() {
        let denom = Double(n - 1)
        window = (0..<n).map { i in
            let phase = 2.0 * .pi * Double(i) / denom
            return 0.5 - 0.5 * cos(phase)
        }
        re = [Float](repeating: 0, count: n)
        im = [Float](repeating: 0, count: n)
        buf = [Float](repeating: 0, count: n)
        smooth = [Float](repeating: 0, count: SpectrumStore.BANDS)
        rebuildBands()
    }

    /// 在音效引擎的输出节点挂 tap（开 EQ/音箱模拟时那条链）
    func attach(to engine: AVAudioEngine, node: AVAudioNode) {
        guard !tapInstalled else { return }
        let format = node.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        rebuildBands()
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcm, _ in
            self?.consume(pcm)
        }
        tapInstalled = true
        startTimer()
    }

    func detach() {
        // 引擎重建时由 AudioEffects 负责 removeTap；这里只停 UI 定时器
        tapInstalled = false
        stopTimer()
    }

    /// 喂 PCM（系统库歌走 AVPlayer，没有引擎链时用这条）：单声道 float 样本
    func feed(mono samples: [Float]) {
        var s = samples
        consumeRaw(&s, count: s.count)
    }

    private func consume(_ pcm: AVAudioPCMBuffer) {
        guard let ch = pcm.floatChannelData else { return }
        // 采样率以实际 PCM 为准（引擎输出格式在 start 前可能是默认 48k）
        let sr = pcm.format.sampleRate
        if sr > 0, abs(sr - sampleRate) > 1 {
            sampleRate = sr
            rebuildBands()
        }
        let count = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        // 混成单声道（和安卓 GainProcessor 喂频谱口径一致）
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            let ptr = ch[c]
            for i in 0..<count { mono[i] += ptr[i] / Float(max(1, channels)) }
        }
        consumeRaw(&mono, count: count)
    }

    private func consumeRaw(_ samples: inout [Float], count: Int) {
        var off = 0
        var remaining = count
        while remaining > 0 {
            let take = min(n - filled, remaining)
            for i in 0..<take { buf[filled + i] = samples[off + i] }
            filled += take
            off += take
            remaining -= take
            if filled == n {
                analyze()
                filled = 0
            }
        }
    }

    private func rebuildBands() {
        let bins = n / 2
        let binHz = sampleRate / Double(n)
        let lo = 50.0
        let hi = min(14000.0, sampleRate / 2.0 * 0.95)
        let ratio = pow(hi / lo, 1.0 / Double(SpectrumStore.BANDS))
        var f = lo
        bandStart = []
        for _ in 0...SpectrumStore.BANDS {
            bandStart.append(Int(f / binHz).clamped(0, bins - 1))
            f *= ratio
        }
        for i in 1..<bandStart.count where bandStart[i] <= bandStart[i - 1] {
            bandStart[i] = bandStart[i - 1] + 1
        }
        bandStart[bandStart.count - 1] = min(bandStart[bandStart.count - 1], bins)
    }

    private func analyze() {
        for i in 0..<n {
            re[i] = buf[i] * window[i]
            im[i] = 0
        }
        fft()
        let scale: Float = 4.0 / Float(n)
        for b in 0..<SpectrumStore.BANDS {
            let s = bandStart[b]
            let e = bandStart[b + 1]
            var mag: Float = 0
            for k in s..<e {
                let m = sqrt(re[k] * re[k] + im[k] * im[k])
                if m > mag { mag = m }
            }
            let db = 20.0 * log10(max(mag * scale, 1e-5))
            let v = ((db + 58.0) / 58.0).clamped(0, 1)
            let curved = v * v * (3.0 - 2.0 * v)
            let prev = smooth[b]
            smooth[b] = curved > prev ? curved : prev * 0.76 + curved * 0.24
        }
        frameLock.lock()
        frame = smooth
        frameLock.unlock()
    }

    /// 标准迭代 radix-2 FFT（原地）
    private func fft() {
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2.0 * .pi / Double(len)
            let wr = Float(cos(ang))
            let wi = Float(sin(ang))
            var i = 0
            while i < n {
                var cwr: Float = 1, cwi: Float = 0
                let half = len >> 1
                for k in 0..<half {
                    let a = i + k, b = a + half
                    let vr = re[b] * cwr - im[b] * cwi
                    let vi = re[b] * cwi + im[b] * cwr
                    let ur = re[a], ui = im[a]
                    re[a] = ur + vr; im[a] = ui + vi
                    re[b] = ur - vr; im[b] = ui - vi
                    let nwr = cwr * wr - cwi * wi
                    cwi = cwr * wi + cwi * wr
                    cwr = nwr
                }
                i += len
            }
            len <<= 1
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.frameLock.lock()
            let live = self.frame
            self.frameLock.unlock()
            var moved = false
            for i in 0..<SpectrumStore.BANDS {
                let target = live[i]
                let next = target > self.display[i] ? target : self.display[i] * 0.82 + target * 0.18
                if abs(next - self.display[i]) > 0.004 { moved = true }
                self.display[i] = next
            }
            if moved { self.levels = self.display }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self {
        min(max(self, lo), hi)
    }
}
