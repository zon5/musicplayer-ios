import SwiftUI
import UIKit

// ============================================================================
// AtmosScene —— 氛围画框（iOS / SwiftUI 版）
// 复刻安卓端 AtmosScene.kt 的取景逻辑：只看歌名，关键词加权命中，
// 每个维度一层均匀底色 BASE + 命中倾向 BIAS，随机种子稳定 → 同一首歌画面固定。
// 绘制用 SwiftUI Canvas，七种地貌 + 四时段配色 + 天气 + 天体 + 少量物件。
// ============================================================================

enum World: Int, CaseIterable { case mountains, sea, city, forest, field, desert, lake }
enum Phase: Int, CaseIterable { case dawn, day, dusk, night }
enum Precip: Int, CaseIterable { case none, rain, snow }
enum Mood: Int, CaseIterable { case neutral, sad, happy, love, calm, epic }

/// 稳定随机（L CG），同一 seed 每次得到同一序列
private struct Rng: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s ^ (s >> 33)
    }
    mutating func float() -> Float { Float(next() >> 41) / 8388608.0 } // 0..1
}

private struct Rule {
    let kws: [String]
    let w: Float
    let world: World?
    let phase: Phase?
    let precip: Precip?
    let mood: Mood?
    init(_ kws: String, _ w: Float = 1,
         world: World? = nil, phase: Phase? = nil, precip: Precip? = nil, mood: Mood? = nil) {
        self.kws = kws.split(separator: " ").map(String.init)
        self.w = w
        self.world = world; self.phase = phase; self.precip = precip; self.mood = mood
    }
}

private let RULES: [Rule] = [
    // 时段
    Rule("夜 晚上 深夜 午夜 星 月 梦里 晚安 黑夜 night moon star dream midnight dark nocturne", phase: .night),
    Rule("晨 晓 黎明 清晨 朝 日出 破晓 dawn morning sunrise aurora daybreak", phase: .dawn),
    Rule("黄昏 夕阳 落日 傍晚 暮 余晖 dusk sunset twilight sundown", phase: .dusk),
    Rule("晴 白天 阳光 午后 正午 蓝天 sunny sunshine noon afternoon bright daylight", phase: .day),
    // 天气
    Rule("雨 下雨 雨滴 暴雨 细雨 雨夜 阴雨 淋 rain rainy drizzle shower raindrop monsoon", precip: .rain),
    Rule("雪 下雪 初雪 飘雪 冬 冬季 冰雪 霜 圣诞 snow snowy winter frost ice frozen christmas", precip: .snow),
    Rule("雨 雨夜 雨滴 rain rainy shower", 0.25, world: .lake),
    Rule("雪 初雪 飘雪 snow snowy", 0.25, world: .mountains),
    // 地貌
    Rule("海 海洋 大海 岛 海岸 沙滩 浪 海浪 浪花 波涛 惊涛 潮 潮水 潮汐 海面 海水 港 湾 礁 sea ocean island shore beach wave tide surf harbor bay coast", world: .sea),
    Rule("山 山峰 山谷 高山 岭 崖 巅 雪峰 登山 mountain hill valley peak cliff ridge summit", world: .mountains),
    Rule("城 城市 街 街头 霓虹 地铁 大厦 巷 广场 city urban street town neon subway downtown avenue skyline", world: .city),
    Rule("林 森林 树 树林 竹 松 丛林 forest tree wood woods pine bamboo jungle", world: .forest),
    Rule("草原 田野 田 麦 稻 荒野 平原 牧场 field prairie meadow wheat grassland plain farm", world: .field),
    Rule("沙 沙漠 荒漠 戈壁 骆驼 sand desert dune oasis camel", world: .desert),
    Rule("江 河 湖 溪 泉 池 水 潭 river lake stream creek pond water spring brook", world: .lake),
    // 情绪
    Rule("伤感 悲伤 难过 失恋 眼泪 哭泣 孤单 孤独 sad lonely cry tears grief blue heartbreak", mood: .sad),
    Rule("开心 快乐 欢乐 喜悦 大笑 庆祝 happy joy laugh celebrate cheerful sunshine", mood: .happy),
    Rule("爱 爱情 恋 恋人 想你 亲爱的 love lover romance sweet kiss", mood: .love),
    Rule("平静 安静 宁静 温柔 舒缓 放松 慢慢 calm quiet gentle peace relax slow mellow", mood: .calm),
    Rule("史诗 摇滚 燃 热血 战争 英雄 力量 霸气 epic rock war hero power fire", mood: .epic),
]

private let BASE: Float = 0.25
private let BIAS: Float = 0.24

private func scoreOf(_ kws: [String], _ title: String) -> Float {
    var sc: Float = 0
    for kw in kws where !kw.isEmpty {
        if title.contains(kw) { sc += 4 }
    }
    return sc
}

/// 和安卓 softmaxPick + pick 一致：BASE 打底 + 倾向乘以 BIAS，按权重轮盘赌
private func pick(_ scores: [Float], _ rnd: inout Rng) -> Int {
    let w = scores.map { BASE + $0 * BIAS }
    let total = w.reduce(0, +)
    var r = rnd.float() * total
    for i in w.indices {
        r -= w[i]
        if r <= 0 { return i }
    }
    return w.count - 1
}

private func hsl(_ h: Float, _ s: Float, _ l: Float) -> Color {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    var r: Float = 0, g: Float = 0, b: Float = 0
    switch Int(hp) {
    case 0: r = c; g = x
    case 1: r = x; g = c
    case 2: g = c; b = x
    case 3: g = x; b = c
    case 4: r = x; b = c
    default: r = c; b = x
    }
    let m = l - c / 2
    return Color(red: Double(r + m), green: Double(g + m), blue: Double(b + m))
}

private func lerp(_ a: Color, _ b: Color, _ t: Float) -> Color {
    let k = Double(max(0, min(1, t)))
    let r0 = Double(a.redValue), r1 = Double(b.redValue)
    let g0 = Double(a.greenValue), g1 = Double(b.greenValue)
    let b0 = Double(a.blueValue), b1 = Double(b.blueValue)
    let a0 = Double(a.opacity), a1 = Double(b.opacity)
    let rr = r0 + (r1 - r0) * k
    let gg = g0 + (g1 - g0) * k
    let bb = b0 + (b1 - b0) * k
    let aa = a0 + (a1 - a0) * k
    return Color(red: rr, green: gg, blue: bb, opacity: aa)
}

private extension Color {
    var components: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b), Double(a))
        }
        return (0, 0, 0, 1)
    }
    var redValue: Float { Float(components.r) }
    var greenValue: Float { Float(components.g) }
    var blueValue: Float { Float(components.b) }
}

private func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 5381
    for b in Array(s.utf8) { h = (h &* 33) &+ UInt64(b) }
    return h
}

/// 一首歌的画框规格：选景结果 + 配色 + 几何随机数据
struct AtmosSpec {
    let world: World
    let phase: Phase
    let precip: Precip
    let mood: Mood
    let skyTop: Color
    let skyHor: Color
    let groundFar: Color
    let groundNear: Color
    let cloudLit: Color
    let cloudShade: Color
    let water: Color
    let warm: Color
    let horizonY: Float
    let sunX: Float
    let sunY: Float
    let sunR: Float
    let nightFactor: Float
    let tempo: Float
    let wind: Float
    let cloudCover: Float
    let precipLevel: Float
    let seed: UInt64
    let snowy: Bool

    static func build(title: String, accent: Color) -> AtmosSpec {
        var rnd = Rng(s: stableHash(title) ^ 0x9E3779B97F4A7C15)
        let t = title.lowercased()

        var wWorld = [Float](repeating: 0, count: World.allCases.count)
        var wPhase = [Float](repeating: 0, count: Phase.allCases.count)
        var wPrecip = [Float](repeating: 0, count: Precip.allCases.count)
        var wMood = [Float](repeating: 0, count: Mood.allCases.count)
        for r in RULES {
            let sc = scoreOf(r.kws, t)
            if sc <= 0 { continue }
            if let d = r.world { wWorld[d.rawValue] += sc * r.w }
            if let d = r.phase { wPhase[d.rawValue] += sc * r.w }
            if let d = r.precip { wPrecip[d.rawValue] += sc * r.w }
            if let d = r.mood { wMood[d.rawValue] += sc * r.w }
        }

        let world = World.allCases[pick(wWorld, &rnd)]
        let phase = Phase.allCases[pick(wPhase, &rnd)]
        let precip = Precip.allCases[pick(wPrecip, &rnd)]
        let mood = Mood.allCases[pick(wMood, &rnd)]
        let precipStrong = precip != .none && wPrecip[precip.rawValue] > 4

        let nightFactor: Float
        switch phase {
        case .night: nightFactor = 1
        case .dusk: nightFactor = 0.45
        case .dawn: nightFactor = 0.25
        case .day: nightFactor = 0
        }

        var top = hsl(204, 0.55, 0.60), hor = hsl(197, 0.48, 0.82)
        switch phase {
        case .day: top = hsl(204, 0.55, 0.60); hor = hsl(197, 0.48, 0.82)
        case .dawn: top = hsl(256, 0.36, 0.54); hor = hsl(20, 0.80, 0.74)
        case .dusk: top = hsl(276, 0.32, 0.32); hor = hsl(14, 0.78, 0.60)
        case .night: top = hsl(232, 0.46, 0.10); hor = hsl(224, 0.30, 0.24)
        }
        top = lerp(top, accent, 0.14)
        hor = lerp(hor, accent, 0.10)
        // 情绪染色
        switch mood {
        case .sad: top = desat(top, 0.42); hor = desat(hor, 0.34)
        case .happy: top = lerp(top, hsl(46, 1, 0.86), 0.13); hor = lerp(hor, hsl(48, 1, 0.88), 0.15)
        case .love: top = lerp(top, Color(red: 0.98, green: 0.62, blue: 0.74), 0.13); hor = lerp(hor, Color(red: 1, green: 0.80, blue: 0.86), 0.15)
        case .calm: top = desat(top, 0.22); hor = desat(hor, 0.16)
        case .epic: top = lerp(top, Color(red: 0.16, green: 0.10, blue: 0.22), 0.16); hor = lerp(hor, Color(red: 1, green: 0.62, blue: 0.30), 0.18)
        case .neutral: break
        }

        let groundNear = lerp(hsl(220, 0.25, 0.26), top, 0.22 + nightFactor * 0.10)
        let groundFar = lerp(groundNear, hor, 0.52)
        let cloudLit: Color
        switch phase {
        case .night: cloudLit = hsl(228, 0.20, 0.34)
        case .dusk: cloudLit = lerp(hsl(18, 0.45, 0.72), hor, 0.40)
        default: cloudLit = lerp(Color.white, hor, 0.10)
        }
        let cloudShade = lerp(cloudLit, Color(red: 0.18, green: 0.20, blue: 0.30), 0.45 + nightFactor * 0.2)
        let water = lerp(hsl(208, 0.50, 0.38), top, 0.32)
        let warm = Color(red: 1, green: 0.80, blue: 0.44)

        let sunX = 0.18 + rnd.float() * 0.64
        let sunY: Float
        switch phase {
        case .day: sunY = 0.18 + rnd.float() * 0.14
        case .night: sunY = 0.14 + rnd.float() * 0.22
        default: sunY = 0.44 + rnd.float() * 0.10
        }
        let sunR = (phase == .day || phase == .night) ? (0.052 + rnd.float() * 0.02) : (0.070 + rnd.float() * 0.026)

        let cloudCover: Float = precipStrong ? (0.68 + rnd.float() * 0.24) : (0.12 + rnd.float() * 0.5)
        let precipLevel: Float = precipStrong ? (0.62 + rnd.float() * 0.38) : ((precip != .none && rnd.float() < 0.5) ? (0.45 + rnd.float() * 0.55) : 0)

        let horizonY: Float
        switch world {
        case .sea: horizonY = 0.56 + rnd.float() * 0.05
        case .lake: horizonY = 0.58 + rnd.float() * 0.05
        case .city, .field, .desert: horizonY = 0.68 + rnd.float() * 0.05
        default: horizonY = 0.62 + rnd.float() * 0.06
        }

        let tempo: Float = 0.85 + rnd.float() * 0.3
        let wind: Float = 0.3 + rnd.float() * 0.9
        let snowy = (precip == .snow) || (world == .mountains && rnd.float() < 0.5)

        return AtmosSpec(world: world, phase: phase, precip: precip, mood: mood,
                         skyTop: top, skyHor: hor, groundFar: groundFar, groundNear: groundNear,
                         cloudLit: cloudLit, cloudShade: cloudShade, water: water, warm: warm,
                         horizonY: horizonY, sunX: sunX, sunY: sunY, sunR: sunR,
                         nightFactor: nightFactor, tempo: tempo, wind: wind,
                         cloudCover: cloudCover, precipLevel: precipLevel,
                         seed: stableHash(title), snowy: snowy)
    }
}

private func rectPath(_ r: CGRect) -> Path {
    var p = Path()
    p.addRect(r)
    return p
}

private func desat(_ c: Color, _ k: Float) -> Color {
    let l = 0.299 * c.redValue + 0.587 * c.greenValue + 0.114 * c.blueValue
    return lerp(c, Color(red: Double(l), green: Double(l), blue: Double(l)), k)
}

// MARK: - 绘制

struct AtmosScene: View {
    let title: String
    var playing: Bool = true

    @State private var spec: AtmosSpec = AtmosSpec.build(title: "", accent: Theme.accent)

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = playing ? Float(ctx.date.timeIntervalSinceReferenceDate) : 0
                drawScene(g: g, w: size.width, h: size.height, s: spec, t: t)
            }
        }
        .onChange(of: title) { newValue in
            spec = AtmosSpec.build(title: newValue, accent: Theme.accent)
        }
        .onAppear {
            spec = AtmosSpec.build(title: title, accent: Theme.accent)
        }
    }

    private func drawScene(g: GraphicsContext, w: CGFloat, h: CGFloat, s: AtmosSpec, t: Float) {
        let hz = CGFloat(s.horizonY) * h
        let ts = t * s.tempo

        // 天空
        let sky = LinearGradient(
            colors: [s.skyTop, s.skyHor],
            startPoint: .top, endPoint: .bottom
        )
        g.fill(rectPath(CGRect(x: 0, y: 0, width: w, height: h)), with: .style(sky))

        var rnd = Rng(s: s.seed)

        // 星星（夜）
        if s.nightFactor > 0.1 {
            let count = Int(40 * s.nightFactor)
            for _ in 0..<count {
                let x = rnd.float() * Float(w)
                let y = rnd.float() * Float(hz) * 0.85
                let r: CGFloat = CGFloat(0.6 + rnd.float() * 1.4)
                let tw = 0.55 + 0.45 * sin(ts * 1.5 + Float(x))
                g.fill(Path(ellipseIn: CGRect(x: CGFloat(x) - r, y: CGFloat(y) - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(Color.white.opacity(Double(s.nightFactor * tw * 0.9))))
            }
        }

        // 天体（太阳 / 月亮）
        let cx = CGFloat(s.sunX) * w
        let cy = CGFloat(s.sunY) * h
        let cr = CGFloat(s.sunR) * w
        let body: Color = (s.phase == .night) ? Color(red: 0.93, green: 0.94, blue: 0.90)
            : ((s.phase == .dusk || s.phase == .dawn) ? s.warm : Color(red: 1, green: 0.97, blue: 0.82))
        let glow = RadialGradient(colors: [body.opacity(0.42), body.opacity(0)],
                                  center: .center, startRadius: cr * 0.5, endRadius: cr * 3.4)
        g.fill(Path(ellipseIn: CGRect(x: cx - cr * 3.4, y: cy - cr * 3.4,
                                      width: cr * 6.8, height: cr * 6.8)), with: .style(glow))
        g.fill(Path(ellipseIn: CGRect(x: cx - cr, y: cy - cr, width: cr * 2, height: cr * 2)),
               with: .color(body.opacity(0.95)))

        // 云
        let cloudCount = 3 + Int(s.cloudCover * 4)
        for _ in 0..<cloudCount {
            let baseX = rnd.float() * Float(w)
            let baseY = rnd.float() * Float(hz) * 0.62
            let cw = CGFloat(0.14 + rnd.float() * 0.22) * w
            let ch = CGFloat(0.03 + rnd.float() * 0.05) * h
            let drift = CGFloat(sin(ts * 0.05 + baseX) * s.wind * 12)
            let x = CGFloat(baseX) + drift
            let op = Double(0.25 + s.cloudCover * 0.5)
            g.fill(ellipsePath(x: x - cw * 0.5, y: CGFloat(baseY), w: cw, h: ch),
                   with: .color(s.cloudLit.opacity(op)))
            g.fill(ellipsePath(x: x - cw * 0.28, y: CGFloat(baseY) - ch * 0.5, w: cw * 0.7, h: ch * 1.2),
                   with: .color(s.cloudLit.opacity(op * 0.9)))
            g.fill(ellipsePath(x: x, y: CGFloat(baseY) - ch * 0.8, w: cw * 0.5, h: ch),
                   with: .color(s.cloudLit.opacity(op * 0.8)))
        }

        // 远山（山脉 / 雪）
        if s.world == .mountains {
            drawRidge(g: g, w: w, h: h, baseY: hz, amp: h * 0.30, peaks: 6,
                      color: lerp(s.groundFar, Color(red: 0.26, green: 0.31, blue: 0.42), 0.8),
                      seed: s.seed, t: ts)
            drawRidge(g: g, w: w, h: h, baseY: hz + h * 0.06, amp: h * 0.20, peaks: 8,
                      color: lerp(s.groundNear, Color(red: 0.19, green: 0.24, blue: 0.33), 0.82),
                      seed: s.seed &+ 7, t: ts)
            if s.snowy {
                drawSnowCaps(g: g, w: w, h: h, baseY: hz, amp: h * 0.30, peaks: 6, seed: s.seed)
            }
        }

        // 地貌主体
        switch s.world {
        case .sea, .lake:
            drawWater(g: g, w: w, h: h, hz: hz, s: s, t: ts)
        case .city:
            drawCity(g: g, w: w, h: h, hz: hz, s: s)
        case .forest:
            drawForest(g: g, w: w, h: h, hz: hz, s: s)
        case .field:
            drawField(g: g, w: w, h: h, hz: hz, s: s, t: ts)
        case .desert:
            drawDunes(g: g, w: w, h: h, hz: hz, s: s)
        case .mountains:
            let grad = LinearGradient(colors: [s.groundFar, s.groundNear], startPoint: .top, endPoint: .bottom)
            g.fill(rectPath(CGRect(x: 0, y: CGFloat(hz), width: w, height: h - CGFloat(hz))), with: .style(grad))
        }

        // 天气
        if s.precip == .rain && s.precipLevel > 0 {
            drawRain(g: g, w: w, h: h, s: s, t: t)
        } else if s.precip == .snow && s.precipLevel > 0 {
            drawSnow(g: g, w: w, h: h, s: s, t: t)
        }

        // 飞鸟
        if s.seed % 3 == 0 {
            drawBirds(g: g, w: w, h: h, s: s, t: ts)
        }
    }

    private func ellipsePath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x, y: y, width: max(0, w), height: max(0, h)))
    }

    private func drawRidge(g: GraphicsContext, w: CGFloat, h: CGFloat, baseY: CGFloat,
                           amp: CGFloat, peaks: Int, color: Color, seed: UInt64, t: Float) {
        var rnd = Rng(s: seed)
        var p = Path()
        p.move(to: CGPoint(x: -w * 0.05, y: baseY))
        let n = max(2, peaks)
        for i in 0..<n {
            let tipX = CGFloat((Float(i) + 0.15 + rnd.float() * 0.7) / Float(n)) * w
            let tipY = baseY - amp * CGFloat(0.35 + rnd.float() * 0.6)
            p.addLine(to: CGPoint(x: tipX, y: tipY))
            if i < n - 1 {
                let vx = CGFloat(Float(i + 1) / Float(n)) * w
                let vy = baseY - amp * CGFloat(0.05 + rnd.float() * 0.15)
                p.addLine(to: CGPoint(x: vx, y: vy))
            }
        }
        p.addLine(to: CGPoint(x: w * 1.05, y: h))
        p.addLine(to: CGPoint(x: -w * 0.05, y: h))
        p.closeSubpath()
        g.fill(p, with: .color(color.opacity(0.95)))
    }

    private func drawSnowCaps(g: GraphicsContext, w: CGFloat, h: CGFloat, baseY: CGFloat,
                              amp: CGFloat, peaks: Int, seed: UInt64) {
        var rnd = Rng(s: seed)
        let snow = Color(red: 0.97, green: 0.98, blue: 1)
        let line: CGFloat = 0.58 // 雪线
        for i in 0..<max(2, peaks) {
            let tipX = CGFloat((Float(i) + 0.15 + rnd.float() * 0.7) / Float(peaks)) * w
            let tipY = baseY - amp * CGFloat(0.35 + rnd.float() * 0.6)
            _ = rnd.float()
            let snowY = baseY - amp * CGFloat(line)
            if tipY < snowY {
                let half = w / CGFloat(peaks) * 0.30
                var p = Path()
                p.move(to: CGPoint(x: tipX, y: tipY))
                p.addLine(to: CGPoint(x: tipX - half, y: snowY))
                p.addLine(to: CGPoint(x: tipX - half * 0.4, y: snowY + amp * 0.05))
                p.addLine(to: CGPoint(x: tipX, y: snowY + amp * 0.02))
                p.addLine(to: CGPoint(x: tipX + half * 0.5, y: snowY + amp * 0.06))
                p.addLine(to: CGPoint(x: tipX + half, y: snowY))
                p.closeSubpath()
                g.fill(p, with: .color(snow.opacity(0.92)))
            }
        }
    }

    private func drawWater(g: GraphicsContext, w: CGFloat, h: CGFloat, hz: CGFloat, s: AtmosSpec, t: Float) {
        let grad = LinearGradient(colors: [s.water, lerp(s.water, s.groundNear, 0.5)],
                                  startPoint: .top, endPoint: .bottom)
        g.fill(rectPath(CGRect(x: 0, y: hz, width: w, height: h - hz)), with: .style(grad))
        // 波光：⚠️ 相位必须是常量速度 t*sp，不能 t*f(t)，否则倒流
        let sp = s.tempo * 12
        var rnd = Rng(s: s.seed &+ 31)
        for _ in 0..<26 {
            let bx = rnd.float() * Float(w)
            let by = hz + CGFloat(rnd.float()) * (h - hz)
            let len = CGFloat(0.02 + rnd.float() * 0.06) * w
            let phase = (t * sp + Float(by) * 0.05).truncatingRemainder(dividingBy: 40)
            let x = CGFloat(bx) + CGFloat(phase.truncatingRemainder(dividingBy: 2)) - 1
            let shimmer = 0.25 + 0.35 * abs(sin(t * 0.8 + Float(bx)))
            g.stroke(Path { p in
                p.move(to: CGPoint(x: x, y: by))
                p.addLine(to: CGPoint(x: x + len, y: by))
            }, with: .color(s.warm.opacity(Double(shimmer * 0.5))), lineWidth: 1.4)
        }
    }

    private func drawCity(g: GraphicsContext, w: CGFloat, h: CGFloat, hz: CGFloat, s: AtmosSpec) {
        // 街谷底色必须暗，否则楼缝透出暖色光柱
        g.fill(rectPath(CGRect(x: 0, y: hz, width: w, height: h - hz)),
               with: .color(lerp(s.groundNear, Color.black, 0.30)))
        var rnd = Rng(s: s.seed &+ 17)
        var x: CGFloat = -w * 0.05
        while x < w {
            let bw = CGFloat(0.09 + rnd.float() * 0.13) * w
            let tall = rnd.float() < 0.16
            let bh = CGFloat(tall ? (0.55 + rnd.float() * 0.15) : (0.32 + rnd.float() * 0.18)) * h
            let top = max(hz - bh, h * 0.04)
            let shade = (rnd.float() - 0.5) * 0.24
            let base = lerp(s.groundNear, s.groundFar, 0.35)
            let col = Color(
                red: Double((base.redValue + shade).clamped(0...1)),
                green: Double((base.greenValue + shade).clamped(0...1)),
                blue: Double((base.blueValue + shade).clamped(0...1))
            )
            g.fill(rectPath(CGRect(x: x, y: top, width: bw, height: h - top)), with: .color(col))
            // 檐口亮线
            g.fill(rectPath(CGRect(x: x, y: top, width: bw, height: max(1, h * 0.004))),
                   with: .color(col.opacity(0.9)))
            // 窗格：昼夜都画
            let winCol = s.nightFactor > 0.4
                ? s.warm.opacity(0.75)
                : lerp(s.groundNear, s.skyHor, 0.34).opacity(0.32)
            let cols = max(1, Int(bw / (w * 0.032)))
            let rows = max(1, Int((h - top) / (h * 0.046)))
            let ww = w * 0.011, wh = h * 0.014
            for c in 0..<cols {
                for r in 0..<rows {
                    if rnd.float() < 0.42 { continue }
                    let wx = x + CGFloat(c) * w * 0.032 + w * 0.008
                    let wy = top + CGFloat(r) * h * 0.046 + h * 0.010
                    if wy < h - wh {
                        g.fill(rectPath(CGRect(x: wx, y: wy, width: ww, height: wh)), with: .color(winCol))
                    }
                }
            }
            x += bw
            if rnd.float() < 0.30 { x += w * CGFloat(0.012 + rnd.float() * 0.012) }
        }
    }

    private func drawForest(g: GraphicsContext, w: CGFloat, h: CGFloat, hz: CGFloat, s: AtmosSpec) {
        let grad = LinearGradient(colors: [s.groundFar, s.groundNear], startPoint: .top, endPoint: .bottom)
        g.fill(rectPath(CGRect(x: 0, y: hz, width: w, height: h - hz)), with: .style(grad))
        var rnd = Rng(s: s.seed &+ 23)
        // 两排针叶树
        for near in [false, true] {
            let base = near ? h * 0.96 : hz + h * 0.04
            let count = near ? 12 : 16
            let treeH = near ? h * 0.22 : h * 0.12
            let col = near ? lerp(s.groundNear, Color.black, 0.25) : lerp(s.groundFar, s.groundNear, 0.4)
            for i in 0..<count {
                let cx = (CGFloat(i) + 0.2 + CGFloat(rnd.float()) * 0.6) / CGFloat(count) * w
                let th = treeH * CGFloat(0.6 + rnd.float() * 0.7)
                let tw = th * 0.42
                var p = Path()
                p.move(to: CGPoint(x: cx - tw, y: base))
                p.addLine(to: CGPoint(x: cx, y: base - th * 0.6))
                p.addLine(to: CGPoint(x: cx + tw, y: base))
                p.closeSubpath()
                g.fill(p, with: .color(col))
                var p2 = Path()
                p2.move(to: CGPoint(x: cx - tw * 0.66, y: base - th * 0.32))
                p2.addLine(to: CGPoint(x: cx, y: base - th))
                p2.addLine(to: CGPoint(x: cx + tw * 0.66, y: base - th * 0.32))
                p2.closeSubpath()
                g.fill(p2, with: .color(col))
            }
        }
    }

    private func drawField(g: GraphicsContext, w: CGFloat, h: CGFloat, hz: CGFloat, s: AtmosSpec, t: Float) {
        let grad = LinearGradient(colors: [s.groundFar, s.groundNear], startPoint: .top, endPoint: .bottom)
        g.fill(rectPath(CGRect(x: 0, y: hz, width: w, height: h - hz)), with: .style(grad))
        let gust = s.wind * (0.75 + 0.42 * sin(t * 0.11))
        var rnd = Rng(s: s.seed &+ 41)
        let col = lerp(s.groundNear, Color(red: 0.28, green: 0.34, blue: 0.22), 0.45)
        for _ in 0..<70 {
            let bx = rnd.float() * Float(w)
            let by = hz + CGFloat(rnd.float()) * (h - hz)
            let sway = CGFloat(gust * sin(t * 0.9 + Float(bx)) * 4)
            g.stroke(Path { p in
                p.move(to: CGPoint(x: CGFloat(bx), y: by))
                p.addLine(to: CGPoint(x: CGFloat(bx) + sway, y: by - h * 0.02))
            }, with: .color(col.opacity(0.7)), lineWidth: 1.2)
        }
    }

    private func drawDunes(g: GraphicsContext, w: CGFloat, h: CGFloat, hz: CGFloat, s: AtmosSpec) {
        let grad = LinearGradient(colors: [s.groundFar, s.groundNear], startPoint: .top, endPoint: .bottom)
        g.fill(rectPath(CGRect(x: 0, y: hz, width: w, height: h - hz)), with: .style(grad))
        var rnd = Rng(s: s.seed &+ 53)
        let col = lerp(s.groundNear, Color(red: 0.72, green: 0.58, blue: 0.32), 0.45)
        for layer in 0..<2 {
            var p = Path()
            let base = hz + CGFloat(layer) * h * 0.06
            p.move(to: CGPoint(x: 0, y: base))
            var x: CGFloat = 0
            while x < w {
                let cw = CGFloat(0.22 + rnd.float() * 0.26) * w
                let nx = min(x + cw, w)
                p.addQuadCurve(to: CGPoint(x: nx, y: base - h * 0.04 * CGFloat(rnd.float())),
                               control: CGPoint(x: x + cw * 0.5, y: base - h * 0.14 * CGFloat(0.4 + rnd.float() * 0.6)))
                x = nx
            }
            p.addLine(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
            g.fill(p, with: .color(col.opacity(layer == 0 ? 0.75 : 0.95)))
        }
    }

    private func drawRain(g: GraphicsContext, w: CGFloat, h: CGFloat, s: AtmosSpec, t: Float) {
        // ⚠️ y = 相位 + t×常量速度，速度不含时变量，否则雨丝倒流
        let speed = s.tempo * 320
        var rnd = Rng(s: s.seed &+ 61)
        let count = Int(60 * s.precipLevel)
        let span = Float(h + 60)
        for _ in 0..<count {
            let bx = rnd.float() * Float(w)
            let ph = rnd.float() * span
            let y = (ph + t * speed).truncatingRemainder(dividingBy: span) - 30
            let len = CGFloat(10 + rnd.float() * 14)
            let lean = CGFloat(s.wind * 6)
            g.stroke(Path { p in
                p.move(to: CGPoint(x: CGFloat(bx), y: CGFloat(y)))
                p.addLine(to: CGPoint(x: CGFloat(bx) + lean, y: CGFloat(y) + len))
            }, with: .color(Color(red: 0.78, green: 0.84, blue: 0.94).opacity(0.45)), lineWidth: 1.2)
        }
    }

    private func drawSnow(g: GraphicsContext, w: CGFloat, h: CGFloat, s: AtmosSpec, t: Float) {
        let speed = s.tempo * 55
        var rnd = Rng(s: s.seed &+ 67)
        let count = Int(50 * s.precipLevel)
        let span = Float(h + 40)
        for _ in 0..<count {
            let bx = rnd.float() * Float(w)
            let ph = rnd.float() * span
            let y = (ph + t * speed).truncatingRemainder(dividingBy: span) - 20
            let r: CGFloat = CGFloat(1.2 + rnd.float() * 2.4)
            let sway = CGFloat(sin(t * 0.6 + Float(bx)) * s.wind * 10)
            g.fill(Path(ellipseIn: CGRect(x: CGFloat(bx) + sway - r, y: CGFloat(y) - r,
                                          width: r * 2, height: r * 2)),
                   with: .color(Color.white.opacity(0.85)))
        }
    }

    private func drawBirds(g: GraphicsContext, w: CGFloat, h: CGFloat, s: AtmosSpec, t: Float) {
        var rnd = Rng(s: s.seed &+ 71)
        let count = 3 + Int(rnd.float() * 3)
        let col: Color = s.nightFactor > 0.5 ? Color(red: 0.8, green: 0.82, blue: 0.88)
            : lerp(s.groundNear, Color.black, 0.35)
        for _ in 0..<count {
            let bx = rnd.float() * Float(w)
            let by = rnd.float() * Float(h) * 0.35
            let drift = CGFloat(sin(t * 0.2 + Float(bx)) * 14)
            let x = CGFloat(bx) + drift
            let flap = 3 + 2 * sin(t * 2.4 + Float(bx))
            g.stroke(Path { p in
                p.move(to: CGPoint(x: x - 6, y: CGFloat(by) + CGFloat(flap)))
                p.addQuadCurve(to: CGPoint(x: x, y: CGFloat(by)),
                               control: CGPoint(x: x - 3, y: CGFloat(by) - 2))
                p.addQuadCurve(to: CGPoint(x: x + 6, y: CGFloat(by) + CGFloat(flap)),
                               control: CGPoint(x: x + 3, y: CGFloat(by) - 2))
            }, with: .color(col.opacity(0.8)), lineWidth: 1.3)
        }
    }
}

private extension Float {
    func clamped(_ range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}
