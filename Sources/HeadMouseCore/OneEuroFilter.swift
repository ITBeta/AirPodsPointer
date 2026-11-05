import Foundation

/// One Euro Filter (Casiez et al. 2012)：低速時強平滑去抖，高速時低延遲。
public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.02, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public mutating func reset() {
        lastValue = nil
        lastTime = nil
        lastDerivative = 0
    }

    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let prev = lastValue, let prevTime = lastTime, time > prevTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - prevTime
        let derivative = (value - prev) / dt
        let aD = Self.alpha(cutoff: dCutoff, dt: dt)
        let smoothedDerivative = aD * derivative + (1 - aD) * lastDerivative
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * prev
        lastValue = result
        lastDerivative = smoothedDerivative
        lastTime = time
        return result
    }
}
