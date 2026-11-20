import Foundation
import AVFoundation

/// 音效链 + 双 Deck 交叉淡化引擎（移植安卓 PlaybackController 双 Deck + GainProcessor 斜坡）
///
/// 结构：deckA / deckB 两条 AVAudioPlayerNode，各自接一条 EQ → 失真 → mainMixer。
/// 平时只有一条在响；串烧时把下一首预载到备用 deck，到过渡点做「等功率双斜坡」
/// （淡入 sin、淡出 cos），淡完备用 deck 变主 deck。这就是安卓「像 DJ 一样接歌」的核心。
///
/// ⚠️ iOS 限制：只有沙盒本地文件(file://)能进这条链；系统库 ipod-library:// 只能走 AVPlayer。
final class AudioEffects {

    private let engine = AVAudioEngine()
    // 两条 deck：主路 A / 备路 B
    private let deckA = AVAudioPlayerNode()
    private let deckB = AVAudioPlayerNode()
    private let eqA = AVAudioUnitEQ(numberOfBands: 7)
    private let eqB = AVAudioUnitEQ(numberOfBands: 7)
    private let distortionA = AVAudioUnitDistortion()
    private let distortionB = AVAudioUnitDistortion()

    private var activeIsA = true          // 当前哪条是主 deck
    private var active: AVAudioPlayerNode { activeIsA ? deckA : deckB }
    private var standby: AVAudioPlayerNode { activeIsA ? deckB : deckA }
    private var activeEq: AVAudioUnitEQ { activeIsA ? eqA : eqB }
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?
    private var activeFile: AVAudioFile? { activeIsA ? fileA : fileB }
    private var sampleRate: Double = 44100
    private(set) var isPlaying = false
    private var onFinished: (() -> Void)?
    private var pollTimer: Timer?
    private var mixTimer: Timer?
    private var duration: Double = 0
    private var settingsRef: SettingsStore?

    /// 串烧进行中（供外部查询/防止重复触发）
    private(set) var mixing = false
    /// 当前生效的过渡说明
    private(set) var mixLabel: String = ""

    init() {
        engine.attach(deckA); engine.attach(deckB)
        engine.attach(eqA); engine.attach(eqB)
        engine.attach(distortionA); engine.attach(distortionB)

        let freqs: [Float] = [60, 150, 400, 1000, 2400, 6000, 15000]
        for eq in [eqA, eqB] {
            for (i, band) in eq.bands.enumerated() {
                band.filterType = .parametric
                band.frequency = freqs[i]
                band.bandwidth = 1.0
                band.gain = 0
                band.bypass = false
            }
        }
        for d in [distortionA, distortionB] { d.preGain = 0; d.wetDryMix = 0 }

        // A 链 → eqA → distortionA → mixer；B 链 → eqB → distortionB → mixer
        engine.connect(deckA, to: eqA, format: nil)
        engine.connect(eqA, to: distortionA, format: nil)
        engine.connect(distortionA, to: engine.mainMixerNode, format: nil)
        engine.connect(deckB, to: eqB, format: nil)
        engine.connect(eqB, to: distortionB, format: nil)
        engine.connect(distortionB, to: engine.mainMixerNode, format: nil)

        SpectrumStore.shared.attach(to: engine, node: engine.mainMixerNode)
        try? engine.start()
    }

    /// 把设置推给两条 EQ（音箱模拟叠曲线 + 轻失真）
    func apply(settings: SettingsStore) {
        settingsRef = settings
        let speakerCurve: [Float] = [-8, -6, -1, 3, 4, 2, 1]
        for eq in [eqA, eqB] {
            for (i, band) in eq.bands.enumerated() {
                var g: Float = 0
                if settings.eqEnabled {
                    g += settings.eqBands[i]
                    if i == 0 { g += settings.bassDb }
                }
                if settings.speakerOn { g += speakerCurve[i] }
                band.gain = g
                band.bypass = !(settings.eqEnabled || settings.speakerOn)
            }
            eq.globalGain = settings.eqEnabled ? settings.preampDb : 0
        }
        for d in [distortionA, distortionB] {
            d.wetDryMix = settings.speakerOn ? 12 : 0
            d.preGain = settings.speakerOn ? -6 : 0
        }
    }

    var canHandle: Bool { settingsRef.map { $0.eqEnabled || $0.speakerOn } ?? false }

    // MARK: - 普通播放（单 deck）

    func play(url: URL, settings: SettingsStore, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        stopInternal()
        guard let f = try? AVAudioFile(forReading: url) else { onFinished(); return }
        fileA = f
        fileB = nil
        activeIsA = true
        sampleRate = f.processingFormat.sampleRate
        duration = Double(f.length) / sampleRate
        apply(settings: settings)

        deckA.stop(); deckB.stop()
        deckA.rate = 1; deckB.rate = 1
        deckA.volume = 1; deckB.volume = 0
        deckA.scheduleFile(f, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.onFinished?() }
        }
        do {
            try engine.start()
            deckA.play()
            isPlaying = true
            startPoll()
        } catch { onFinished() }
    }

    func pause() {
        guard isPlaying else { return }
        active.pause(); standby.pause()
        isPlaying = false
        stopPoll(); stopMixTimer()
    }

    func resume() {
        guard !isPlaying, activeFile != nil else { return }
        active.play()
        isPlaying = true
        startPoll()
    }

    func stop() { stopInternal() }

    private func stopInternal() {
        deckA.stop(); deckB.stop()
        deckA.rate = 1; deckB.rate = 1
        deckA.volume = 1; deckB.volume = 0
        mixing = false; mixLabel = ""
        isPlaying = false
        stopPoll(); stopMixTimer()
        fileA = nil; fileB = nil
        activeIsA = true
    }

    var currentTime: Double {
        guard let t = active.lastRenderTime, let pt = active.playerTime(forNodeTime: t) else { return 0 }
        // 换算成「播放进度秒数」，变速时 playerTime.sampleTime 已是播放采样位置，除以原采样率即可
        return Double(pt.sampleTime) / max(1, sampleRate)
    }
    var currentDuration: Double { duration }

    func seek(to seconds: Double) {
        guard let f = activeFile else { return }
        let wasPlaying = isPlaying
        stopMixTimer(); mixing = false
        active.stop()
        let rate = f.processingFormat.sampleRate
        let offset = AVAudioFramePosition(max(0, min(seconds * rate, Double(f.length))))
        let frames = AVAudioFrameCount(f.length - offset)
        active.volume = 1
        active.rate = 1
        if frames > 0 {
            active.scheduleSegment(f, startingFrame: offset, frameCount: frames, at: nil) { [weak self] in
                DispatchQueue.main.async { self?.onFinished?() }
            }
        }
        if wasPlaying { active.play(); isPlaying = true; startPoll() }
    }

    /// 音量渐变（手动切歌淡出用）
    func fade(to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let node = active
        let start = node.volume
        let steps = max(1, Int(duration * 30))
        var i = 0
        Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { t in
            i += 1
            node.volume = start + (target - start) * Float(i) / Float(steps)
            if i >= steps { t.invalidate(); completion?() }
        }
    }

    var volume: Float {
        get { active.volume }
        set { active.volume = newValue }
    }

    // MARK: - 双 Deck 串烧（核心）

    /// 预载下一首到备用 deck：seek 到进入点、设变速倍率、音量 0 待命
    /// - Returns: 是否预载成功（系统库歌/读取失败返回 false）
    func prepareStandby(url: URL, seekSec: Double, tempoRatio: Float, gainB: Float) -> Bool {
        guard let f = try? AVAudioFile(forReading: url) else { return false }
        let sr = f.processingFormat.sampleRate
        let offset = AVAudioFramePosition(max(0, min(seekSec * sr, Double(f.length))))
        let frames = AVAudioFrameCount(f.length - offset)
        guard frames > 0 else { return false }
        if activeIsA { fileB = f } else { fileA = f }
        standby.stop()
        standby.rate = max(Float(0.5), min(Float(2.0), tempoRatio))
        standby.volume = 0
        standby.scheduleSegment(f, startingFrame: offset, frameCount: frames, at: nil)
        return true
    }

    /// 执行交叉淡化：备用 deck 从 0 起播，等功率双斜坡（淡入 sin / 淡出 cos），
    /// 淡完把备用 deck 切成主 deck，取消变速、恢复音量。
    /// - Parameters:
    ///   - seconds: 交叉淡化时长（秒）
    ///   - gainB: 新曲响度补偿
    ///   - onSwapped: 淡化完成、新曲成为主曲后回调（用于更新 index/UI）
    func performCrossfade(seconds: Double, gainB: Float, onSwapped: @escaping () -> Void) {
        guard activeFile != nil else { return }
        stopMixTimer()
        mixing = true
        let incoming = standby
        let outgoing = active
        incoming.volume = 0
        incoming.play()
        // 等功率曲线：淡入 sin(k·π/2)、淡出 cos(k·π/2)，两者平方和恒为 1
        let steps = max(8, Int(seconds * 50))   // 50Hz 更新，足够平滑
        let dt = seconds / Double(steps)
        var i = 0
        mixTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            i += 1
            let k = min(1, Double(i) / Double(steps))
            let sinK = sin(k * .pi / 2)
            let cosK = cos(k * .pi / 2)
            incoming.volume = Float(sinK) * gainB
            outgoing.volume = Float(cosK)
            if i >= steps {
                t.invalidate()
                self.mixTimer = nil
                self.finishMix(incoming: incoming, outgoing: outgoing, gainB: gainB)
                onSwapped()
            }
        }
    }

    private func finishMix(incoming: AVAudioPlayerNode, outgoing: AVAudioPlayerNode, gainB: Float) {
        // 停止旧曲、清掉它的文件，主备互换
        outgoing.stop()
        outgoing.volume = 0
        if activeIsA { fileA = nil; activeIsA = false } else { fileB = nil; activeIsA = true }
        incoming.volume = 1
        incoming.rate = 1
        // ⚠️ 用新主曲的文件重算时长/采样率，否则 poll 会用旧曲时长误判播放结束
        if let nf = activeFile {
            sampleRate = nf.processingFormat.sampleRate
            duration = Double(nf.length) / sampleRate
        }
        mixing = false
        mixLabel = ""
        startPoll()
    }

    /// 取消串烧（用户手动切歌/拖动进度时）：清掉备路、主路音量复位
    func abortMix() {
        stopMixTimer()
        if mixing {
            standby.stop()
            standby.volume = 0
            active.volume = 1
            active.rate = 1
            mixing = false
            mixLabel = ""
        }
    }

    private func stopMixTimer() { mixTimer?.invalidate(); mixTimer = nil }

    private func startPoll() {
        stopPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.duration > 0, !self.mixing else { return }
            if self.currentTime >= self.duration - 0.05 {
                self.stopInternal()
                self.onFinished?()
            }
        }
    }
    private func stopPoll() { pollTimer?.invalidate(); pollTimer = nil }
}
