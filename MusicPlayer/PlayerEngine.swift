import Foundation
import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

final class PlayerEngine: NSObject, ObservableObject {
    @Published private(set) var current: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var position: Double = 0
    @Published var repeatMode: RepeatMode = .all
    @Published var shuffle = false {
        didSet {
            if oldValue != shuffle, let cur = current {
                let rest = queue.filter { $0.id != cur.id }
                queue = [cur] + (shuffle ? rest.shuffled() : rest)
                index = 0
            }
        }
    }

    // 播放后端：AVPlayer（系统库歌 / 无音效）与 AudioEffects（本地文件 + 音效）
    private var player: AVPlayer?
    private let effects = AudioEffects()
    private var useEffects = false
    weak var settings: SettingsStore?

    private var queue: [Song] = []
    private var index = 0
    private var ticker: Timer?
    private var attempts = 0

    private var endObserver: NSObjectProtocol?
    private var durationObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        registerRemoteCommands()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    /// 设置页改了音效参数后调用：即时生效（重推 EQ）或让下一首切换后端
    func refreshEffects() {
        if let s = settings {
            effects.apply(settings: s)
        }
        // 本地文件：按当前开关决定是否切到音效后端（保留进度）
        if let song = current, !song.isSystem, let s = settings {
            let want = s.eqEnabled || s.speakerOn
            if want != useEffects, let url = song.playURL {
                let pos = self.position
                let wasPlaying = isPlaying
                teardownAll()
                if want {
                    useEffects = true
                    effects.play(url: url, settings: s) { [weak self] in self?.next(auto: true) }
                    effects.seek(to: pos)
                    if wasPlaying { effects.resume() } else { effects.pause() }
                } else {
                    loadAVPlayer(url: url, song: song, at: pos, autoPlay: wasPlaying)
                }
                isPlaying = wasPlaying
            }
        }
    }

    // MARK: - 播放控制

    func play(_ songs: [Song], at i: Int) {
        guard songs.indices.contains(i) else { return }
        let start = songs[i]
        attempts = 0
        if shuffle {
            queue = [start] + songs.filter { $0.id != start.id }.shuffled()
            index = 0
        } else {
            queue = songs
            index = i
        }
        loadCurrent(autoPlay: true)
    }

    func togglePlay() {
        if useEffects {
            if isPlaying { effects.pause(); isPlaying = false; stopTicker() }
            else { effects.resume(); isPlaying = true; startTicker() }
        } else if let p = player {
            if isPlaying { p.pause(); isPlaying = false; stopTicker() }
            else { p.play(); isPlaying = true; startTicker() }
        } else if !queue.isEmpty {
            loadCurrent(autoPlay: true)
            return
        }
        refreshNowPlaying()
    }

    func seek(to t: Double) {
        let v = max(0, min(t, duration))
        if useEffects { effects.seek(to: v) }
        else { player?.seek(to: CMTime(seconds: v, preferredTimescale: 600)) }
        position = v
        refreshNowPlaying()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto, repeatMode == .one {
            if useEffects { effects.seek(to: 0); effects.resume(); isPlaying = true }
            else { player?.seek(to: .zero); player?.play(); isPlaying = true }
            position = 0
            startTicker()
            refreshNowPlaying()
            return
        }
        if index + 1 < queue.count {
            index += 1
            loadCurrent(autoPlay: true)
        } else if repeatMode == .all {
            if shuffle { queue = queue.shuffled() }
            index = 0
            loadCurrent(autoPlay: true)
        } else {
            teardownAll()
            isPlaying = false
            position = 0
            stopTicker()
            refreshNowPlaying()
        }
    }

    func prev() {
        guard !queue.isEmpty else { return }
        if position > 3.0 { seek(to: 0); return }
        if index > 0 {
            index -= 1
            loadCurrent(autoPlay: true)
        } else if repeatMode == .all {
            index = queue.count - 1
            loadCurrent(autoPlay: true)
        } else {
            seek(to: 0)
        }
    }

    /// 智能过渡开关/时长变化时调用，仅对 AVPlayer 后端生效（两套后端同时交叉淡化会互相抢输出）
    func refreshCrossfade() {
        // 参数在 loadCurrent 里读取，这里无需额外动作；保留接口供设置页调用
    }

    // MARK: - 内部

    private func teardownAll() {
        player?.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        durationObs = nil
        statusObs = nil
        player = nil
        effects.stop()
        useEffects = false
    }

    private func loadCurrent(autoPlay: Bool) {
        guard queue.indices.contains(index) else { return }
        let song = queue[index]
        guard let url = song.playURL else { skipFailed(); return }
        teardownAll()
        stopTicker()

        current = song
        duration = song.duration
        position = 0

        // 只有本地文件 + 开启音效 才走 AVAudioEngine；系统库歌 Apple 不允许接 EQ
        let wantEffects = !song.isSystem && (settings?.eqEnabled == true || settings?.speakerOn == true)
        if wantEffects {
            useEffects = true
            effects.apply(settings: settings!)
            effects.play(url: url, settings: settings!) { [weak self] in
                self?.next(auto: true)
            }
            duration = effects.currentDuration > 0 ? effects.currentDuration : song.duration
            isPlaying = autoPlay
            if !autoPlay { effects.pause() }
            startTicker()
            refreshNowPlaying()
            attempts = 0
        } else {
            loadAVPlayer(url: url, song: song, at: 0, autoPlay: autoPlay)
        }
    }

    private func loadAVPlayer(url: URL, song: Song, at pos: Double, autoPlay: Bool) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        useEffects = false

        if pos > 0 { p.seek(to: CMTime(seconds: pos, preferredTimescale: 600)) }
        duration = song.duration
        position = pos

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.next(auto: true)
        }
        durationObs = item.observe(\.duration, options: [.initial, .new]) { [weak self] it, _ in
            let d = it.duration.seconds
            if d.isFinite && d > 0 {
                DispatchQueue.main.async { self?.duration = d }
            }
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .failed {
                DispatchQueue.main.async { self?.skipFailed() }
            }
        }

        // 智能过渡：新曲从 0 音量淡入
        if settings?.crossfadeOn == true && autoPlay {
            p.volume = 0
            fade(avPlayer: p, to: 1, duration: TimeInterval(max(1, settings?.crossfadeSec ?? 4) / 2))
        } else {
            p.volume = 1
        }
        if autoPlay { p.play(); isPlaying = true; startTicker() }
        else { isPlaying = false }
        refreshNowPlaying()
        attempts = 0
    }

    /// 切歌前对当前后端做淡出，then 切到下一首。用 crossfadeSec 的一半作淡出。
    func crossfadeToNext() {
        guard settings?.crossfadeOn == true, isPlaying else { next(); return }
        let half = TimeInterval(max(1, settings?.crossfadeSec ?? 4) / 2)
        if useEffects {
            effects.fade(to: 0, duration: half) { [weak self] in
                self?.effects.volume = 1
                self?.next()
            }
        } else if let p = player {
            fade(avPlayer: p, to: 0, duration: half) { [weak self] in
                self?.next()
            }
        } else {
            next()
        }
    }

    private func fade(avPlayer p: AVPlayer, to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let start = p.volume
        let steps = max(1, Int(duration * 30))
        var i = 0
        Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { t in
            i += 1
            p.volume = start + (target - start) * Float(i) / Float(steps)
            if i >= steps { t.invalidate(); completion?() }
        }
    }

    private func skipFailed() {
        attempts += 1
        if attempts < queue.count {
            index = (index + 1) % queue.count
            loadCurrent(autoPlay: true)
        } else {
            attempts = 0
            teardownAll()
            isPlaying = false
            stopTicker()
            refreshNowPlaying()
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            let t = self.useEffects ? self.effects.currentTime : (self.player?.currentTime().seconds ?? 0)
            if t.isFinite { self.position = t }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - 锁屏 / 控制中心

    private func refreshNowPlaying() {
        guard let song = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let img = LibraryStore.artworkImage(for: song) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying { self.togglePlay() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.togglePlay() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.crossfadeToNext()
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.prev()
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            if isPlaying { togglePlay() }
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }
}
