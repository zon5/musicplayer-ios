import Foundation
import SwiftUI

/// 全 App 设置：主题色 / 均衡器 / 音箱模拟 / 智能过渡 / 氛围画框。
/// 用 UserDefaults 持久化，和安卓端 Prefs 的口径保持一致。
final class SettingsStore: ObservableObject {
    // 七段频段，和安卓端 EqBands.FREQS 完全一致
    static let eqFreqs: [Int] = [60, 150, 400, 1000, 2400, 6000, 15000]
    static let eqPresetNames = ["自定义", "平直", "流行", "摇滚", "古典", "爵士", "人声", "重低音", "高音"]
    // 每个预设七段增益（dB），照抄安卓端 EqualizerController.PRESETS
    static let eqPresetBands: [[Float]] = [
        [0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0],
        [-1, 1.5, 3, 4, 2, 0, -1],
        [4, 2.5, -1, -2, 1, 3.5, 4.5],
        [3, 1.5, -1, -1.5, 0, 2, 3],
        [3, 1.5, 0, 1, -1, 1.5, 2.5],
        [-3, -1, 2, 4.5, 3.5, 1.5, -1],
        [6, 4.5, 2, 0, -1, -2, -2.5],
        [-2, -1.5, 0, 1.5, 3.5, 5, 5.5],
    ]

    static let accentNames = ["雾紫", "松绿", "海蓝", "落日", "石墨"]
    static let accentColors: [Color] = [
        Color(red: 0x68 / 255, green: 0x58 / 255, blue: 0xD1 / 255), // 雾紫（默认）
        Color(red: 0x2E / 255, green: 0x8B / 255, blue: 0x74 / 255), // 松绿
        Color(red: 0x3B / 255, green: 0x7D / 255, blue: 0xD8 / 255), // 海蓝
        Color(red: 0xE0 / 255, green: 0x61 / 255, blue: 0x3A / 255), // 落日
        Color(red: 0x5C / 255, green: 0x62 / 255, blue: 0x70 / 255), // 石墨
    ]

    @Published var accentIndex: Int = 0 { didSet { save() } }

    @Published var eqEnabled: Bool = false { didSet { save() } }
    @Published var eqPreset: Int = 0 { didSet { save() } }
    @Published var eqBands: [Float] = [0, 0, 0, 0, 0, 0, 0] { didSet { save() } }
    @Published var bassDb: Float = 0 { didSet { save() } }
    @Published var preampDb: Float = 0 { didSet { save() } }
    @Published var speakerOn: Bool = false { didSet { save() } }

    /// 智能过渡：双路交叉淡化；iOS 上用两条 AVAudioEngine 链各带音量渐变实现
    @Published var crossfadeOn: Bool = false { didSet { save() } }
    @Published var crossfadeSec: Float = 4 { didSet { save() } }

    /// 氛围画框开关
    @Published var atmosOn: Bool = true { didSet { save() } }

    /// 歌词字号倍率 0.8~1.6
    @Published var lyricFontScale: Float = 1.0 { didSet { save() } }
    /// 滚动列表震动反馈
    @Published var hapticsOn: Bool = true { didSet { save() } }
    /// 睡眠定时：距离停止的分钟数，0=关闭
    @Published var sleepMinutes: Int = 0 { didSet { save() } }
    /// 睡眠定时器到期时"放完当前曲再停"
    @Published var sleepFinishSong: Bool = false { didSet { save() } }
    /// 主题模式 0=跟随系统 1=浅色 2=深色
    @Published var themeMode: Int = 2 { didSet { save() } }
    /// 点歌方式 0=立即播放 1=下一首插播
    @Published var tapAction: Int = 0 { didSet { save() } }
    /// 沉浸式播放（串烧）：播到设定比例就淡出切下一首，0=关闭
    @Published var immersiveOn: Bool = false { didSet { save() } }
    @Published var immersiveRatio: Float = 0.65 { didSet { save() } }

    private let d = UserDefaults.standard
    private let kPrefix = "mplayer.settings."

    init() { load() }

    private func load() {
        accentIndex = int("accentIndex", 0).clamped(0...(Self.accentColors.count - 1))
        eqEnabled = bool("eqEnabled", false)
        eqPreset = int("eqPreset", 0).clamped(0...(Self.eqPresetNames.count - 1))
        let stored = array("eqBands")
        eqBands = stored.count == 7 ? stored : Self.eqPresetBands[0]
        bassDb = float("bassDb", 0).clamped(-12...12)
        preampDb = float("preampDb", 0).clamped(-12...12)
        speakerOn = bool("speakerOn", false)
        crossfadeOn = bool("crossfadeOn", false)
        crossfadeSec = float("crossfadeSec", 4).clamped(1...12)
        atmosOn = bool("atmosOn", true)
        lyricFontScale = float("lyricFontScale", 1.0).clamped(0.8...1.6)
        hapticsOn = bool("hapticsOn", true)
        sleepMinutes = int("sleepMinutes", 0)
        sleepFinishSong = bool("sleepFinishSong", false)
        themeMode = int("themeMode", 2).clamped(0...2)
        tapAction = int("tapAction", 0).clamped(0...1)
        immersiveOn = bool("immersiveOn", false)
        immersiveRatio = float("immersiveRatio", 0.65).clamped(0.3...0.95)
    }

    private func save() {
        d.set(accentIndex, forKey: k("accentIndex"))
        d.set(eqEnabled, forKey: k("eqEnabled"))
        d.set(eqPreset, forKey: k("eqPreset"))
        d.set(eqBands, forKey: k("eqBands"))
        d.set(bassDb, forKey: k("bassDb"))
        d.set(preampDb, forKey: k("preampDb"))
        d.set(speakerOn, forKey: k("speakerOn"))
        d.set(crossfadeOn, forKey: k("crossfadeOn"))
        d.set(crossfadeSec, forKey: k("crossfadeSec"))
        d.set(atmosOn, forKey: k("atmosOn"))
        d.set(lyricFontScale, forKey: k("lyricFontScale"))
        d.set(hapticsOn, forKey: k("hapticsOn"))
        d.set(sleepMinutes, forKey: k("sleepMinutes"))
        d.set(sleepFinishSong, forKey: k("sleepFinishSong"))
        d.set(themeMode, forKey: k("themeMode"))
        d.set(tapAction, forKey: k("tapAction"))
        d.set(immersiveOn, forKey: k("immersiveOn"))
        d.set(immersiveRatio, forKey: k("immersiveRatio"))
    }

    func applyPreset(_ index: Int) {
        eqPreset = index
        if index > 0 && index < Self.eqPresetBands.count {
            eqBands = Self.eqPresetBands[index]
        }
    }

    func setBand(_ i: Int, db: Float) {
        guard i >= 0, i < eqBands.count else { return }
        var b = eqBands
        b[i] = db.clamped(-12...12)
        eqBands = b
        eqPreset = 0 // 手动改任一段 → 自定义
    }

    var accent: Color { Self.accentColors[accentIndex] }

    private func k(_ key: String) -> String { kPrefix + key }
    private func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: k(key)) as? Bool ?? def }
    private func int(_ key: String, _ def: Int) -> Int { d.object(forKey: k(key)) as? Int ?? def }
    private func float(_ key: String, _ def: Float) -> Float { d.object(forKey: k(key)) as? Float ?? def }
    private func array(_ key: String) -> [Float] { d.object(forKey: k(key)) as? [Float] ?? [] }
}

private extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
