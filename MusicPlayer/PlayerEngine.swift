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
                if shuffle {
                    queue = [cur] + rest.shuffled()
                    index = 0
                } else {
                    queue = [cur] + rest
                    index = 0
                }
            }
        }
    }

    private var audio: AVAudioPlayer?
    private var queue: [Song] = []
    private var index = 0
    private var ticker: Timer?
    private var attempts = 0

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
        guard let p = audio else {
            if !queue.isEmpty { loadCurrent() }
            return
        }
        if p.isPlaying {
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
        guard let p = audio else { return }
        let v = max(0, min(t, duration))
        p.currentTime = v
        position = v
        refreshNowPlaying()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto, repeatMode == .one {
            audio?.currentTime = 0
            audio?.play()
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
            audio?.stop()
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

    private func loadCurrent() {
        guard queue.indices.contains(index) else { return }
        let song = queue[index]
        audio?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: song.fileURL)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else { return }
            audio = p
            current = song
            duration = p.duration
            position = 0
            isPlaying = true
            attempts = 0
            startTicker()
            refreshNowPlaying()
        } catch {
            // 文件坏了就跳过，最多绕队列一圈
            attempts += 1
            if attempts < queue.count {
                index = (index + 1) % queue.count
                loadCurrent()
            } else {
                attempts = 0
                isPlaying = false
            }
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.audio, p.isPlaying else { return }
            self.position = p.currentTime
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

extension PlayerEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        next(auto: true)
    }
}
