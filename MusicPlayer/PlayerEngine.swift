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

    // ---- 双 Deck 串烧（移植安卓 PlaybackController）----
    /// 当前过渡方案（后台算好），nil 表示还没排/不该串烧
    private var pendingPlan: MixPlan?
    /// 串烧专用备路播放器（系统库歌用：本地歌走 AudioEffects 的双 deck）
    private var standbyPlayer: AVPlayer?
    private var mixActive = false
    /// 本首歌是否已排过方案，避免 tick 里重复排
    private var plannedForSongID: String? = nil

    private var endObserver: NSObjectProtocol?
    private var durationObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?
    private var sleepTimer: Timer?
    private var sleepDeadline: Date?
    private var sleepArmed = false

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
        // 后台补词完成后，同步刷新队列/当前曲里的词曲年月（Song 是值类型副本）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetaUpdate(_:)),
            name: .songMetaDidUpdate,
            object: nil
        )
    }

    @objc private func handleMetaUpdate(_ note: Notification) {
        guard let song = note.userInfo?["song"] as? Song else { return }
        if let qi = queue.firstIndex(where: { $0.id == song.id }) {
            queue[qi] = song
        }
        if current?.id == song.id {
            current = song
            refreshNowPlaying()
        }
    }

    /// 设置页改了音效参数后调用：即时生效（重推 EQ）或让下一首切换后端
    func refreshEffects() {
        if let s = settings {
            effects.apply(settings: s)
        }
        // 本地文件：一律走 AVAudioEngine 后端（真实频谱 + EQ/音箱模拟）。
        // ⚠️ 2026-11-20：以前只在开 EQ 时才走引擎，导致本地歌默认用假的动态频谱；
        // 现在本地歌始终走引擎拿真实 FFT，EQ 关闭时引擎内 EQ 节点旁通即可。
        if let song = current, !song.isSystem, let s = settings {
            let want = true
            if want != useEffects, let url = song.playURL {
                let pos = self.position
                let wasPlaying = isPlaying
                teardownAll()
                if want {
                    useEffects = true
                    SpectrumStore.shared.simulate = false
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
        if isPlaying { abortMix() } // 暂停中断串烧
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

    /// 中断正在进行的串烧（对齐安卓 abortMix：清备路、主路音量/速率复位）
    private func abortMix() {
        if mixActive {
            effects.abortMix()
            standbyPlayer?.pause()
            standbyPlayer = nil
            mixActive = false
            pendingPlan = nil
            plannedForSongID = nil
        }
    }

    func seek(to t: Double) {
        abortMix()
        let v = max(0, min(t, duration))
        if useEffects { effects.seek(to: v) }
        else { player?.seek(to: CMTime(seconds: v, preferredTimescale: 600)) }
        position = v
        refreshNowPlaying()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        abortMix()
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
        abortMix()
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

    // MARK: - 队列操作（对齐安卓 QueueScreen：查看/插播/移除/排序/跳播）

    /// 当前播放队列的只读快照（含 index），供队列面板显示
    var queueSnapshot: ([Song], Int) { (queue, index) }

    /// 下一首播放（插播）：把这首歌放到当前曲之后，不动正在播的曲子
    func playNext(_ song: Song) {
        guard queue.indices.contains(index) else {
            // 队列为空：直接起播这一首
            play([song], at: 0)
            return
        }
        let insertAt = index + 1
        if let exist = queue.firstIndex(where: { $0.id == song.id }) {
            if exist == insertAt { return }
            queue.remove(at: exist)
            let adj = exist < insertAt ? insertAt - 1 : insertAt
            queue.insert(song, at: min(adj, queue.count))
        } else {
            queue.insert(song, at: min(insertAt, queue.count))
        }
    }

    /// 立即播放单曲：若已在队列里跳过去，否则插到当前曲之后并跳过去
    func playSong(_ song: Song, from allSongs: [Song]? = nil) {
        if let qi = queue.firstIndex(where: { $0.id == song.id }) {
            index = qi
            loadCurrent(autoPlay: true)
            return
        }
        if let all = allSongs, let ai = all.firstIndex(where: { $0.id == song.id }) {
            play(all, at: ai)
        } else {
            play([song], at: 0)
        }
    }

    /// 跳到队列中的某一首
    func jumpToQueue(at i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        loadCurrent(autoPlay: true)
    }

    /// 从队列移除（不能移除当前曲）
    func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
    }

    /// 队列内拖动排序
    func moveInQueue(from: Int, to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != index, to != index else { return }
        let s = queue.remove(at: from)
        queue.insert(s, at: to)
        if from == index { index = to } // 防御：正常被 guard 挡掉
    }

    func clearQueue() {
        guard let cur = current else { return }
        queue = [cur]
        index = 0
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
        abortMix()
        teardownAll()
        stopTicker()
        pendingPlan = nil
        plannedForSongID = nil

        current = song
        duration = song.duration
        position = 0

        // 本地文件一律走 AVAudioEngine（真实频谱 + EQ 旁通由引擎内部处理）；系统库歌 Apple 限制走 AVPlayer
        let wantEffects = !song.isSystem
        if wantEffects {
            useEffects = true
            SpectrumStore.shared.simulate = false // 引擎链有真实 PCM
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
        // 系统库走 AVPlayer：ipod-library:// 受 Apple 限制拿不到真实 PCM，频谱用动态兜底
        SpectrumStore.shared.simulate = true
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

    // MARK: - 双 Deck 串烧（移植安卓 AutoMix + PlaybackController）

    /// 是否启用真串烧：设置里「像 DJ 一样接歌」开启 + 有下一首 + 正在播放
    private var mixEnabled: Bool {
        settings?.crossfadeOn == true && isPlaying && index + 1 < queue.count
    }

    /// 后台预分析两首歌的节拍，排出过渡方案（不阻塞播放线程）
    private func planAhead() {
        guard mixEnabled, let song = current else { return }
        if plannedForSongID == song.id { return }
        plannedForSongID = song.id
        let a = song
        let b = queue[index + 1]
        Task.detached(priority: .utility) { [weak self] in
            let ba = BeatAnalyzer.shared.beat(for: a)
            let bb = BeatAnalyzer.shared.beat(for: b)
            let plan: MixPlan
            if ba.valid || bb.valid {
                plan = AutoMixer.plan(a: ba, aDurationMs: Int64(a.duration * 1000), b: bb)
            } else {
                plan = AutoMixer.fallback(aDurationMs: Int64(a.duration * 1000))
            }
            DispatchQueue.main.async {
                guard let self = self, self.current?.id == a.id, self.mixEnabled else { return }
                self.pendingPlan = plan
            }
        }
    }

    /// 每次 tick 检查：进度是否到了淡出起点，到点就启动交叉淡化
    private func maybeStartMix(_ t: Double) {
        guard mixEnabled, !mixActive, let plan = pendingPlan else { return }
        // 用实测时长重排淡出起点（媒体库时长常有误差），对齐安卓 retune 思路
        let dur = duration
        guard dur > 1 else { return }
        let fadeStart = min(Double(plan.fadeStartMs) / 1000.0, dur - 0.6)
        guard t >= fadeStart else { return }

        let nextSong = queue[index + 1]
        let crossSec = max(0.5, min(Double(plan.crossfadeMs) / 1000.0, Double(settings?.crossfadeSec ?? 8)))
        let ratio = plan.tempoRatio
        let gainB = plan.gainB
        let seekSec = Double(plan.seekBMs) / 1000.0

        if useEffects {
            // 本地歌：AudioEffects 双 deck，真实等功率交叉淡化 + 变速
            guard let url = nextSong.playURL,
                  effects.prepareStandby(url: url, seekSec: seekSec, tempoRatio: ratio, gainB: gainB) else {
                pendingPlan = nil
                return
            }
            mixActive = true
            effects.performCrossfade(seconds: crossSec, gainB: gainB) { [weak self] in
                self?.finishMix()
            }
        } else if let curPlayer = player, let url = nextSong.playURL {
            // 系统库歌：双 AVPlayer 交叉淡化（拿不到 PCM，但交叉淡化本身是真的）
            let item = AVPlayerItem(url: url)
            let standby = AVPlayer(playerItem: item)
            if seekSec > 0 { standby.seek(to: CMTime(seconds: seekSec, preferredTimescale: 600)) }
            standby.rate = ratio
            standby.volume = 0
            standby.play()
            standbyPlayer = standby
            mixActive = true
            crossfadeAV(from: curPlayer, to: standby, seconds: crossSec, gainB: gainB) { [weak self] in
                self?.finishMix()
            }
        }
    }

    /// 交叉淡化完成：切到下一首为当前曲，清理备用路
    private func finishMix() {
        let nextIdx = index + 1
        guard queue.indices.contains(nextIdx) else { mixActive = false; return }
        // 停掉旧主路（effects 内部已 swap；AVPlayer 路这里停旧的）
        if !useEffects {
            player?.pause()
            player = standbyPlayer
            standbyPlayer = nil
        }
        index = nextIdx
        current = queue[nextIdx]
        mixActive = false
        pendingPlan = nil
        plannedForSongID = nil
        duration = current?.duration ?? 0
        position = 0
        refreshNowPlaying()
        // 新曲成为主曲后，立刻为「下下首」预排方案，形成连续 DJ 串烧
        planAhead()
    }

    /// 双 AVPlayer 等功率交叉淡化（系统库歌）
    private func crossfadeAV(from a: AVPlayer, to b: AVPlayer, seconds: Double, gainB: Float, completion: @escaping () -> Void) {
        let steps = max(8, Int(seconds * 50))
        let dt = seconds / Double(steps)
        var i = 0
        Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { t in
            i += 1
            let k = min(1, Double(i) / Double(steps))
            b.volume = Float(sin(k * .pi / 2)) * gainB
            a.volume = Float(cos(k * .pi / 2))
            if i >= steps { t.invalidate(); completion() }
        }
    }

    /// 用户手动点「下一首」时：若串烧开着且有方案，用真交叉淡化；否则普通淡出切歌
    func crossfadeToNext() {
        if mixEnabled, let plan = pendingPlan, !mixActive {
            let crossSec = max(0.5, min(Double(plan.crossfadeMs) / 1000.0, Double(settings?.crossfadeSec ?? 8)))
            let nextSong = queue[index + 1]
            if useEffects, let url = nextSong.playURL,
               effects.prepareStandby(url: url, seekSec: Double(plan.seekBMs) / 1000.0,
                                      tempoRatio: plan.tempoRatio, gainB: plan.gainB) {
                mixActive = true
                effects.performCrossfade(seconds: crossSec, gainB: plan.gainB) { [weak self] in self?.finishMix() }
                return
            }
        }
        // 降级：普通淡出切歌
        guard settings?.crossfadeOn == true, isPlaying else { next(); return }
        let half = TimeInterval(max(1, settings?.crossfadeSec ?? 4) / 2)
        if useEffects {
            effects.fade(to: 0, duration: half) { [weak self] in
                self?.effects.volume = 1
                self?.next()
            }
        } else if let p = player {
            fade(avPlayer: p, to: 0, duration: half) { [weak self] in self?.next() }
        } else { next() }
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
        SpectrumStore.shared.playing = true
        // 串烧排好后加快到 0.1s 以便精确落到淡出点；平时 0.5s 驱动进度/歌词/信息坞
        let interval: TimeInterval = (settings?.crossfadeOn == true) ? 0.1 : 0.5
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            let t = self.useEffects ? self.effects.currentTime : (self.player?.currentTime().seconds ?? 0)
            guard t.isFinite else { return }
            self.position = t
            guard let s = self.settings else { return }
            // 睡眠定时
            self.checkSleep(s)
            // 真串烧：后台预排方案 + 到点交叉淡化
            if s.crossfadeOn {
                self.planAhead()
                self.maybeStartMix(t)
            }
            // 沉浸式播放（串烧模式）：在设定的歌曲比例处提前进入过渡
            if s.immersiveOn, !self.mixActive, self.duration > 1,
               t >= self.duration * Double(s.immersiveRatio), self.pendingPlan == nil {
                // 沉浸式用比例覆盖淡出起点：把方案里的 fadeStart 提前到该比例
                if var p = self.pendingPlan {
                    p.fadeStartMs = Int64(self.duration * Double(s.immersiveRatio) * 1000)
                    self.pendingPlan = p
                } else {
                    // 还没排好方案时，造一个「在该比例淡出」的方案
                    let durMs = Int64(self.duration * 1000)
                    var p = AutoMixer.fallback(aDurationMs: durMs)
                    p.fadeStartMs = Int64(self.duration * Double(s.immersiveRatio) * 1000)
                    self.pendingPlan = p
                }
            }
        }
    }

    // MARK: 睡眠定时

    private var lastSleepMinutes: Int = -1

    private func checkSleep(_ s: SettingsStore) {
        // 检测到用户改了定时分钟数 → 重新布防
        if s.sleepMinutes != lastSleepMinutes {
            lastSleepMinutes = s.sleepMinutes
            sleepTimer?.invalidate(); sleepTimer = nil
            sleepArmed = false
            if s.sleepMinutes > 0 {
                sleepDeadline = Date().addingTimeInterval(Double(s.sleepMinutes) * 60)
                sleepArmed = true
            } else {
                sleepDeadline = nil
            }
        }
        guard sleepArmed, let deadline = sleepDeadline, Date() >= deadline else { return }
        // 到点了
        sleepArmed = false
        sleepDeadline = nil
        if s.sleepFinishSong {
            // 放完当前曲再停：标记，等 endObserver 触发 next 时暂停
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkSleepFinish() }
        } else {
            DispatchQueue.main.async { self.togglePlay() }
        }
    }

    @objc private func checkSleepFinish() {
        // 曲子结束会自动 next() 切歌；这里在切歌后的一刻暂停
        // 通过检测 position 回退到接近 0 判断"刚切歌"
        guard position < 1.0 else { return }
        sleepTimer?.invalidate(); sleepTimer = nil
        DispatchQueue.main.async { if self.isPlaying { self.togglePlay() } }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        SpectrumStore.shared.playing = false
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
