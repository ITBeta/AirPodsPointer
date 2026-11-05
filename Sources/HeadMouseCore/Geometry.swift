import Foundation

/// 平台無關的 2D 點（屏幕坐標：原點左上，y 向下）。
public struct Vec2: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// 把角度差規範到 (-π, π]，處理 yaw 在 ±π 處的跳變。
public func wrapAngle(_ a: Double) -> Double {
    var v = a.truncatingRemainder(dividingBy: 2 * .pi)
    if v > .pi { v -= 2 * .pi }
    if v <= -.pi { v += 2 * .pi }
    return v
}
