import Foundation
import AVFoundation

/// 音效链：AVAudioEngine + 七段 EQ + 轻失真（近似安卓的"音箱模拟"）。
/// ⚠️ iOS 平台限制：只有沙盒里的本地文件（file://）能进这条链；
/// 系统音乐库的歌是 ipod-library://，Apple 不允许第三方接 EQ，只能走 AVPlayer 原声播放。
/// 这与安卓"所有歌都过 GainProcessor"不同，是系统限制，设置页里已注明。
final class AudioEffects {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 7)
    private let distortion = AVAudioUnitDistortion()

    private var file: AVAudioFile?
    private var sampleRate: Double = 44100
    private(set) var isPlaying = false
    private var onFinished: (() -> Void)?
    private var pollTimer: Timer?
    private var duration: Double = 0
    private var settingsRef: SettingsStore?

    init() {
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(distortion)

        // 七段频率，和安卓一致
        let freqs: [Float] = [60, 150, 400, 1000, 2400, 6000, 15000]
        for (i, band) in eqNode.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = freqs[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        distortion.preGain = 0
        distortion.wetDryMix = 0

        engine.connect(playerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: distortion, format: nil)
        engine.connect(distortion, to: engine.mainMixerNode, format: nil)
        // 频谱：在最终输出挂 tap，拿到的是处理链之后的真实声音
        SpectrumStore.shared.attach(to: engine, node: engine.mainMixerNode)
        try? engine.start()
    }

    /// 把设置推给音频节点。均衡器关时整条 EQ 旁通；音箱模拟单独叠一条曲线 + 轻失真。
    func apply(settings: SettingsStore) {
        settingsRef = settings
        // 音箱模拟曲线：切一点超低频、抬中频、补一点高频（近似手机外放）
        let speakerCurve: [Float] = [-8, -6, -1, 3, 4, 2, 1]
        for (i, band) in eqNode.bands.enumerated() {
            var g: Float = 0
            if settings.eqEnabled {
                g += settings.eqBands[i]
                if i == 0 { g += settings.bassDb }
            }
            if settings.speakerOn { g += speakerCurve[i] }
            band.gain = g
            band.bypass = !(settings.eqEnabled || settings.speakerOn)
        }
        eqNode.globalGain = settings.eqEnabled ? settings.preampDb : 0
        distortion.wetDryMix = settings.speakerOn ? 12 : 0
        distortion.preGain = settings.speakerOn ? -6 : 0
    }

    var canHandle: Bool { settingsRef.map { $0.eqEnabled || $0.speakerOn } ?? false }

    func play(url: URL, settings: SettingsStore, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        stopInternal()
        guard let f = try? AVAudioFile(forReading: url) else { onFinished(); return }
        file = f
        sampleRate = f.processingFormat.sampleRate
        duration = Double(f.length) / sampleRate
        apply(settings: settings)

        playerNode.scheduleFile(f, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.onFinished?() }
        }
        do {
            try engine.start()
            playerNode.play()
            isPlaying = true
            startPoll()
        } catch {
            onFinished()
        }
    }

    func pause() {
        guard isPlaying else { return }
        playerNode.pause()
        isPlaying = false
        stopPoll()
    }

    func resume() {
        guard !isPlaying, file != nil else { return }
        playerNode.play()
        isPlaying = true
        startPoll()
    }

    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        playerNode.stop()
        isPlaying = false
        stopPoll()
        file = nil
    }

    var currentTime: Double {
        guard let t = playerNode.lastRenderTime, let pt = playerNode.playerTime(forNodeTime: t) else { return 0 }
        return Double(pt.sampleTime) / sampleRate
    }

    var currentDuration: Double { duration }

    func seek(to seconds: Double) {
        // AVAudioPlayerNode 不能精确 seek，采用停止+重新调度到指定采样点（近似）
        guard let f = file else { return }
        let wasPlaying = isPlaying
        playerNode.stop()
        let rate = f.processingFormat.sampleRate
        let offset = AVAudioFramePosition(max(0, min(seconds * rate, Double(f.length))))
        let frames = AVAudioFrameCount(f.length - offset)
        if frames > 0 {
            playerNode.scheduleSegment(f, startingFrame: offset, frameCount: frames, at: nil) { [weak self] in
                DispatchQueue.main.async { self?.onFinished?() }
            }
        }
        if wasPlaying { playerNode.play(); isPlaying = true; startPoll() }
    }

    /// 音量渐变（智能过渡用）
    func fade(to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let start = playerNode.volume
        let steps = max(1, Int(duration * 30))
        var i = 0
        Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { t in
            i += 1
            self.playerNode.volume = start + (target - start) * Float(i) / Float(steps)
            if i >= steps {
                t.invalidate()
                completion?()
            }
        }
    }

    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }

    private func startPoll() {
        stopPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.duration > 0 else { return }
            if self.currentTime >= self.duration - 0.05 {
                self.stopInternal()
                self.onFinished?()
            }
        }
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
