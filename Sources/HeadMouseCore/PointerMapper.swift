import Foundation

public struct PointerConfig: Codable, Equatable, Sendable {
    /// 像素 / 弧度（低速時）。1200 ≈ 轉頭 60° 掃過約 1250px。
    public var sensitivity: Double = 1200
    /// 加速度：越大則快速轉頭移動越遠。0 = 線性。
    public var acceleration: Double = 0.8
    /// 死區（弧度/秒），低於此速度不移動，抑制漂移與呼吸微動。
    public var deadZone: Double = 0.06
    /// 垂直方向相對水平的倍率（低頭抬頭幅度通常比轉頭小）。
    public var verticalScale: Double = 1.3
    public var invertX: Bool = false
    public var invertY: Bool = false

    public init() {}
}

/// 頭部角速度 → 鼠標位移（像素）。保留亞像素餘數，慢速移動也平滑。
public struct PointerMapper {
    public var config: PointerConfig
    private var remainder = Vec2.zero

    public init(config: PointerConfig = PointerConfig()) { self.config = config }

    public mutating func reset() { remainder = .zero }

    /// 連續速度（像素/秒），不含取整。
    public func velocity(yawRate: Double, pitchRate: Double) -> Vec2 {
        let mag = (yawRate * yawRate + pitchRate * pitchRate).squareRoot()
        guard mag > config.deadZone, mag > 0 else { return .zero }
        let effective = mag - config.deadZone
        let speed = config.sensitivity * effective * (1 + config.acceleration * effective)
        // 屏幕：向左轉頭(yaw+) → 光標左移(x-)；抬頭(pitch+) → 光標上移(y-)
        var vx = -yawRate / mag * speed
        var vy = -pitchRate / mag * speed * config.verticalScale
        if config.invertX { vx = -vx }
        if config.invertY { vy = -vy }
        return Vec2(vx, vy)
    }

    /// 返回本幀整數像素位移。
    public mutating func delta(for rates: HeadRates) -> (dx: Int, dy: Int) {
        let v = velocity(yawRate: rates.yawRate, pitchRate: rates.pitchRate)
        if v == .zero { remainder = .zero; return (0, 0) }
        let total = remainder + Vec2(v.x * rates.dt, v.y * rates.dt)
        let dx = total.x.rounded(.towardZero)
        let dy = total.y.rounded(.towardZero)
        remainder = Vec2(total.x - dx, total.y - dy)
        return (Int(dx), Int(dy))
    }
}
