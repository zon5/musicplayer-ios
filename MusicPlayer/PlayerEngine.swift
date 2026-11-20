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

    // AVPlayer 既支持沙盒文件，也支持系统音乐库的 ipod-library:// 地址；
    // 旧版用 AVAudioPlayer 只能播本地文件，读不到系统库的歌。
    private var player: AVPlayer?
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
        loadCurrent()
    }

    func togglePlay() {
        guard let p = player else {
            if !queue.isEmpty { loadCurrent() }
            return
        }
        if isPlaying {
            p.pause()
            isPlaying = false
            stopTicker()
        } else {
            p.play()
            isPlaying = true
            startTicker()
        }
        refreshNowPlaying()
    }

    func seek(to t: Double) {
        guard player != nil else { return }
        let v = max(0, min(t, duration))
        player?.seek(to: CMTime(seconds: v, preferredTimescale: 600))
        position = v
        refreshNowPlaying()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto, repeatMode == .one {
            player?.seek(to: .zero)
            player?.play()
            isPlaying = true
            position = 0
            startTicker()
            return
        }
        if index + 1 < queue.count {
            index += 1
            loadCurrent()
        } else if repeatMode == .all {
            if shuffle { queue = queue.shuffled() }
            index = 0
            loadCurrent()
        } else {
            teardownItem()
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
            loadCurrent()
        } else if repeatMode == .all {
            index = queue.count - 1
            loadCurrent()
        } else {
            seek(to: 0)
        }
    }

    // MARK: - 内部

    private func teardownItem() {
        player?.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        durationObs = nil
        statusObs = nil
        player = nil
    }

    private func loadCurrent() {
        guard queue.indices.contains(index) else { return }
        let song = queue[index]
        guard let url = song.playURL else {
            skipFailed()
            return
        }
        teardownItem()
        stopTicker()

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p

        // 曲子时长先用元数据里的值顶上（系统库/本地文件都有），加载完成后再校准
        current = song
        duration = song.duration
        position = 0

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

        p.play()
        isPlaying = true
        attempts = 0
        startTicker()
        refreshNowPlaying()
    }

    /// 文件坏 / 授权失效 / 地址打不开时跳过，最多绕队列一圈，避免死循环
    private func skipFailed() {
        attempts += 1
        if attempts < queue.count {
            index = (index + 1) % queue.count
            loadCurrent()
        } else {
            attempts = 0
            teardownItem()
            isPlaying = false
            stopTicker()
            refreshNowPlaying()
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying, self.player != nil else { return }
            let t = self.player?.currentTime().seconds ?? 0
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
            self?.next()
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
