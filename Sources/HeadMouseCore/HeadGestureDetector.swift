import Foundation

public enum HeadGesture: String, Codable, Sendable {
    case nod    // 點頭：快速 下→上（或 上→下）
    case shake  // 搖頭：快速 左→右→左（或 右→左→右）
}

public struct HeadGestureEvent: Equatable, Sendable {
    public var gesture: HeadGesture
    /// 手勢開始前的時間點，用於把光標還原到手勢前位置。
    public var startTime: Double
    public var endTime: Double
}

public struct GestureConfig: Codable, Equatable, Sendable {
    public var nodEnabled = true
    public var shakeEnabled = true
    /// 點頭判定的俯仰角速度閾值（弧度/秒）。≈ 86°/s
    public var nodThreshold: Double = 1.5
    /// 搖頭判定的偏航角速度閾值（弧度/秒）。≈ 100°/s
    public var shakeThreshold: Double = 1.75
    public var nodWindow: Double = 0.7
    public var shakeWindow: Double = 1.1
    /// 搖頭需要的交替擺動次數（3 = 左右左）。
    public var shakeSwings: Int = 3
    /// 觸發後冷卻時間，避免一次動作觸發多次。
    public var cooldown: Double = 0.8
    public init() {}
}

/// 基於角速度「波瓣」（lobe）的點頭/搖頭識別狀態機。
///
/// 每當某軸角速度絕對值超過閾值即開始一個波瓣，降到閾值一半以下結束。
/// 點頭 = pitch 軸兩個相反方向的波瓣，且期間 yaw 幅度明顯更小；
/// 搖頭 = yaw 軸 N 個交替方向波瓣，且期間 pitch 幅度明顯更小。
public struct HeadGestureDetector {
    struct Lobe {
        var sign: Int
        var start: Double
        var end: Double
        var peak: Double
        var crossPeak: Double // 同期另一軸的最大幅度
    }

    struct AxisTracker {
        var lobes: [Lobe] = []
        var active: Lobe?

        mutating func feed(rate: Double, cross: Double, time: Double, threshold: Double) {
            let mag = abs(rate)
            let sign = rate >= 0 ? 1 : -1
            if var a = active {
                if mag < threshold * 0.5 || sign != a.sign {
                    lobes.append(a)
                    active = nil
                } else {
                    a.end = time
                    a.peak = max(a.peak, mag)
                    a.crossPeak = max(a.crossPeak, abs(cross))
                    active = a
                    return
                }
            }
            if mag >= threshold {
                active = Lobe(sign: sign, start: time, end: time, peak: mag, crossPeak: abs(cross))
            }
        }

        var all: [Lobe] { active.map { lobes + [$0] } ?? lobes }

        mutating func prune(before t: Double) { lobes.removeAll { $0.end < t } }
        mutating func clear() { lobes.removeAll(); active = nil }
    }

    public var config: GestureConfig
    private var pitch = AxisTracker()
    private var yaw = AxisTracker()
    private var cooldownUntil: Double = -.infinity
    /// 回溯量：手勢第一個波瓣之前的這段時間也算作手勢的一部分。
    public var leadIn: Double = 0.15

    public init(config: GestureConfig = GestureConfig()) { self.config = config }

    public mutating func reset() { pitch.clear(); yaw.clear(); cooldownUntil = -.infinity }

    /// 當前是否處於可能構成手勢的高速運動中（可用於暫停光標輸出）。
    public var isInFastMotion: Bool { pitch.active != nil || yaw.active != nil }

    public mutating func process(_ r: HeadRates) -> HeadGestureEvent? {
        pitch.feed(rate: r.pitchRate, cross: r.yawRate, time: r.time, threshold: config.nodThreshold)
        yaw.feed(rate: r.yawRate, cross: r.pitchRate, time: r.time, threshold: config.shakeThreshold)
        pitch.prune(before: r.time - config.nodWindow)
        yaw.prune(before: r.time - config.shakeWindow)

        guard r.time >= cooldownUntil else { return nil }

        // 搖頭優先判斷（它的波瓣更多，更不容易誤判）。
        if config.shakeEnabled, let ev = detectShake(now: r.time) { return fire(ev, now: r.time) }
        if config.nodEnabled, let ev = detectNod(now: r.time) { return fire(ev, now: r.time) }
        return nil
    }

    private mutating func fire(_ ev: HeadGestureEvent, now: Double) -> HeadGestureEvent {
        pitch.clear(); yaw.clear()
        cooldownUntil = now + config.cooldown
        return ev
    }

    private func detectNod(now: Double) -> HeadGestureEvent? {
        // 只用已結束的波瓣，確保點頭完整完成。
        let ls = pitch.lobes
        guard ls.count >= 2 else { return nil }
        let a = ls[ls.count - 2], b = ls[ls.count - 1]
        guard a.sign != b.sign, b.end - a.start <= config.nodWindow else { return nil }
        let peak = min(a.peak, b.peak)
        let cross = max(a.crossPeak, b.crossPeak)
        guard cross < peak * 0.6 else { return nil } // 斜向甩頭不算點頭
        return HeadGestureEvent(gesture: .nod, startTime: a.start - leadIn, endTime: b.end)
    }

    private func detectShake(now: Double) -> HeadGestureEvent? {
        let ls = yaw.all
        let n = config.shakeSwings
        guard n >= 2, ls.count >= n else { return nil }
        let seq = Array(ls.suffix(n))
        for i in 1..<seq.count where seq[i].sign == seq[i - 1].sign { return nil }
        guard seq.last!.end - seq.first!.start <= config.shakeWindow else { return nil }
        let peak = seq.map(\.peak).min()!
        let cross = seq.map(\.crossPeak).max()!
        guard cross < peak * 0.7 else { return nil }
        return HeadGestureEvent(gesture: .shake, startTime: seq.first!.start - leadIn, endTime: seq.last!.end)
    }
}
