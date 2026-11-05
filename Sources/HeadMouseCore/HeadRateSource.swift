import Foundation

/// 角速度來源。
public enum MotionSourceMode: String, Codable, CaseIterable, Sendable {
    case auto      // 默認：姿態可用就用姿態，姿態恆定但陀螺儀有數據時改用陀螺儀
    case attitude  // 姿態差分
    case gyro      // 直接讀取陀螺儀 rotationRate

    public var displayName: String {
        switch self {
        case .auto: return "自動"
        case .attitude: return "姿態 (attitude)"
        case .gyro: return "陀螺儀 (rotationRate)"
        }
    }
}

public enum GyroAxis: String, Codable, CaseIterable, Sendable { case x, y, z }

/// 陀螺儀某一軸 + 是否取反。
public struct AxisMapping: Codable, Equatable, Sendable {
    public var axis: GyroAxis
    public var inverted: Bool
    public init(_ axis: GyroAxis, inverted: Bool = false) { self.axis = axis; self.inverted = inverted }

    public func value(in s: MotionSample) -> Double {
        let v: Double
        switch axis {
        case .x: v = s.gyroX
        case .y: v = s.gyroY
        case .z: v = s.gyroZ
        }
        return inverted ? -v : v
    }
}

public struct MotionConfig: Codable, Equatable, Sendable {
    public var mode: MotionSourceMode = .auto
    /// 轉頭（左右）對應的陀螺儀軸。向左轉頭應為正值。
    public var yawAxis = AxisMapping(.z)
    /// 點頭（上下）對應的陀螺儀軸。抬頭應為正值。
    public var pitchAxis = AxisMapping(.x)
    public init() {}
}

/// 把 MotionSample 序列轉成 HeadRates，支持姿態差分 / 陀螺儀 / 自動切換。
public struct HeadRateSource {
    public var config: MotionConfig
    /// 自動模式下是否已切換到陀螺儀。
    public private(set) var autoUsesGyro = false

    private var attitudeEstimator = RateEstimator()
    // 輕度平滑：去抖但保留點頭/搖頭的峰值。
    private var yawFilter = OneEuroFilter(minCutoff: 6, beta: 0.3)
    private var pitchFilter = OneEuroFilter(minCutoff: 6, beta: 0.3)
    private var lastTime: Double?

    // 自動判斷窗口
    private var windowStart: Double?
    private var lastAttitude: (yaw: Double, pitch: Double)?
    private var attitudeMovement: Double = 0
    private var gyroPeak: Double = 0
    public var decisionWindow: Double = 1.0

    public init(config: MotionConfig = MotionConfig()) { self.config = config }

    public var usingGyro: Bool {
        switch config.mode {
        case .auto: return autoUsesGyro
        case .attitude: return false
        case .gyro: return true
        }
    }

    public mutating func reset() {
        attitudeEstimator.reset()
        yawFilter.reset(); pitchFilter.reset()
        lastTime = nil
        windowStart = nil; lastAttitude = nil
        attitudeMovement = 0; gyroPeak = 0
    }

    public mutating func update(_ s: MotionSample) -> HeadRates? {
        let attitudeRates = attitudeEstimator.update(s)
        updateAutoDecision(s)

        let prevTime = lastTime
        lastTime = s.time
        let yaw = yawFilter.filter(config.yawAxis.value(in: s), at: s.time)
        let pitch = pitchFilter.filter(config.pitchAxis.value(in: s), at: s.time)

        guard usingGyro else { return attitudeRates }
        guard let pt = prevTime else { return nil }
        let dt = s.time - pt
        guard dt > 0.001, dt < 0.5 else { return nil }
        return HeadRates(time: s.time, dt: dt, yawRate: yaw, pitchRate: pitch)
    }

    private mutating func updateAutoDecision(_ s: MotionSample) {
        if let last = lastAttitude {
            attitudeMovement += abs(wrapAngle(s.yaw - last.yaw)) + abs(s.pitch - last.pitch)
        }
        lastAttitude = (s.yaw, s.pitch)
        gyroPeak = max(gyroPeak, s.gyroMagnitude)

        guard let start = windowStart else { windowStart = s.time; return }
        guard s.time - start >= decisionWindow else { return }
        if attitudeMovement < 0.001 && gyroPeak > 0.05 {
            autoUsesGyro = true          // 姿態凍結但陀螺儀在動
        } else if attitudeMovement > 0.01 {
            autoUsesGyro = false         // 姿態正常變化
        }
        windowStart = s.time
        attitudeMovement = 0
        gyroPeak = 0
    }
}
