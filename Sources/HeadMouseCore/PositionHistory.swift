import Foundation

/// 最近一段時間的光標位置記錄，用於手勢觸發後把光標還原到手勢之前。
public struct PositionHistory {
    public let span: Double
    private var items: [(time: Double, pos: Vec2)] = []

    public init(span: Double = 1.5) { self.span = span }

    public mutating func record(_ pos: Vec2, at time: Double) {
        items.append((time, pos))
        let cutoff = time - span
        if let idx = items.firstIndex(where: { $0.time >= cutoff }), idx > 0 {
            items.removeFirst(idx)
        }
    }

    /// 返回時間 t 時（或之前最近一次）的位置；早於記錄範圍則返回最早位置。
    public func position(at t: Double) -> Vec2? {
        guard !items.isEmpty else { return nil }
        var result = items[0].pos
        for item in items {
            if item.time <= t { result = item.pos } else { break }
        }
        return result
    }

    public mutating func clear() { items.removeAll() }
}
