import UIKit

/// 滚动列表震动反馈（对齐安卓 ScrollHaptics）：跨分组时给一次轻触感。
enum Haptics {
    static private var selection = UISelectionFeedbackGenerator()
    static private var impact = UIImpactFeedbackGenerator(style: .light)

    static func tick() {
        selection.prepare()
        selection.selectionChanged()
    }

    static func soft() {
        impact.prepare()
        impact.impactOccurred()
    }
}
