import Foundation

/// 一幀頭部姿態（弧度）。time 為秒（單調時鐘，例如 systemUptime）。
public struct MotionSample: Equatable, Sendable {
    public var time: Double
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public init(time: Double, yaw: Double, pitch: Double, roll: Double) {
        self.time = time; self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }
}

/// 頭部角速度（弧度/秒）。yawRate > 0 = 向左轉頭；pitchRate > 0 = 抬頭。
public struct HeadRates: Equatable, Sendable {
    public var time: Double
    public var dt: Double
    public var yawRate: Double
    public var pitchRate: Double
    public init(time: Double, dt: Double, yawRate: Double, pitchRate: Double) {
        self.time = time; self.dt = dt; self.yawRate = yawRate; self.pitchRate = pitchRate
    }
}

/// 把姿態序列平滑後差分成角速度。用姿態差分而非原始 rotationRate，避免耳機坐標軸歧義。
public struct RateEstimator {
    private var yawFilter: OneEuroFilter
    private var pitchFilter: OneEuroFilter
    private var last: (time: Double, yaw: Double, pitch: Double)?
    private var unwrappedYaw: Double = 0
    private var lastRawYaw: Double?

    public init(minCutoff: Double = 1.5, beta: Double = 0.05) {
        yawFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        pitchFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    public mutating func reset() {
        yawFilter.reset(); pitchFilter.reset()
        last = nil; lastRawYaw = nil; unwrappedYaw = 0
    }

    /// 返回 nil 表示第一幀或時間戳異常（例如斷線重連後的大間隔）。
    public mutating func update(_ s: MotionSample) -> HeadRates? {
        if let raw = lastRawYaw { unwrappedYaw += wrapAngle(s.yaw - raw) } else { unwrappedYaw = s.yaw }
        lastRawYaw = s.yaw

        let yaw = yawFilter.filter(unwrappedYaw, at: s.time)
        let pitch = pitchFilter.filter(s.pitch, at: s.time)
        defer { last = (s.time, yaw, pitch) }
        guard let prev = last else { return nil }
        let dt = s.time - prev.time
        guard dt > 0.001, dt < 0.25 else { return nil }
        return HeadRates(time: s.time, dt: dt,
                         yawRate: (yaw - prev.yaw) / dt,
                         pitchRate: (pitch - prev.pitch) / dt)
    }
}
