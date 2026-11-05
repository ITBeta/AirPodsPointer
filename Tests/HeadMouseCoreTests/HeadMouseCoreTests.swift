import XCTest
@testable import HeadMouseCore

/// 一個正弦波瓣：在 [t0, t0+dur] 內 amp * sin。
private struct Seg {
    var t0: Double
    var dur: Double
    var amp: Double
    init(_ t0: Double, _ dur: Double, _ amp: Double) { self.t0 = t0; self.dur = dur; self.amp = amp }
}

private func signal(_ t: Double, _ segs: [Seg]) -> Double {
    var v: Double = 0
    for s in segs where t >= s.t0 && t <= s.t0 + s.dur {
        v += s.amp * sin(Double.pi * (t - s.t0) / s.dur)
    }
    return v
}

/// 生成 25Hz 角速度序列。
/// yawFromPitch / pitchFromYaw：把另一軸信號按比例混入（模擬斜向運動）。
private func makeRates(duration: Double, start: Double = 0,
                       yaw: [Seg] = [], pitch: [Seg] = [],
                       yawBias: Double = 0, pitchBias: Double = 0,
                       yawFromPitch: Double = 0, pitchFromYaw: Double = 0) -> [HeadRates] {
    let dt: Double = 0.04
    var out: [HeadRates] = []
    var i = 0
    while Double(i) * dt < duration {
        let t = Double(i) * dt
        let y0 = signal(t, yaw)
        let p0 = signal(t, pitch)
        let y = y0 + yawBias + p0 * yawFromPitch
        let p = p0 + pitchBias + y0 * pitchFromYaw
        out.append(HeadRates(time: start + t, dt: dt, yawRate: y, pitchRate: p))
        i += 1
    }
    return out
}

private func run(_ d: inout HeadGestureDetector, _ rs: [HeadRates]) -> [HeadGestureEvent] {
    var events: [HeadGestureEvent] = []
    for r in rs {
        if let e = d.process(r) { events.append(e) }
    }
    return events
}

private func gestures(_ evs: [HeadGestureEvent]) -> [HeadGesture] { evs.map { $0.gesture } }

final class OneEuroFilterTests: XCTestCase {
    func testConstantSignalPassesThrough() {
        var f = OneEuroFilter()
        var out = 0.0
        for i in 0..<100 { out = f.filter(5, at: Double(i) * 0.04) }
        XCTAssertEqual(out, 5, accuracy: 1e-9)
    }

    func testReducesJitter() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        var maxDev = 0.0
        for i in 0..<200 {
            let noisy = (i % 2 == 0) ? 0.01 : -0.01
            let v = f.filter(noisy, at: Double(i) * 0.04)
            if i > 20 { maxDev = max(maxDev, abs(v)) }
        }
        XCTAssertLessThan(maxDev, 0.01)
    }
}

final class RateEstimatorTests: XCTestCase {
    func testYawWrapAround() {
        var e = RateEstimator(minCutoff: 1000, beta: 0) // 幾乎不平滑
        // 以 1 rad/s 穿過 +π → -π
        var last: HeadRates?
        for i in 0..<20 {
            let t = Double(i) * 0.04
            let yaw = wrapAngle(3.0 + t)
            if let r = e.update(MotionSample(time: t, yaw: yaw, pitch: 0, roll: 0)) { last = r }
            if let r = last { XCTAssertEqual(r.yawRate, 1, accuracy: 0.05, "frame \(i)") }
        }
    }

    func testRejectsLargeGap() {
        var e = RateEstimator()
        _ = e.update(MotionSample(time: 0, yaw: 0, pitch: 0, roll: 0))
        XCTAssertNil(e.update(MotionSample(time: 5, yaw: 1, pitch: 0, roll: 0)))
    }
}

final class PointerMapperTests: XCTestCase {
    func testDeadZone() {
        let m = PointerMapper()
        XCTAssertEqual(m.velocity(yawRate: 0.03, pitchRate: 0.02), .zero)
    }

    func testDirections() {
        let m = PointerMapper()
        let left = m.velocity(yawRate: 0.5, pitchRate: 0)
        XCTAssertLessThan(left.x, 0, "向左轉頭 → 光標左移")
        XCTAssertEqual(left.y, 0, accuracy: 1e-9)
        let up = m.velocity(yawRate: 0, pitchRate: 0.5)
        XCTAssertLessThan(up.y, 0, "抬頭 → 光標上移")
    }

    func testInvert() {
        var c = PointerConfig(); c.invertX = true; c.invertY = true
        let m = PointerMapper(config: c)
        let v = m.velocity(yawRate: 0.5, pitchRate: 0.5)
        XCTAssertGreaterThan(v.x, 0)
        XCTAssertGreaterThan(v.y, 0)
    }

    func testAccelerationIsSuperlinear() {
        let m = PointerMapper()
        let slow = abs(m.velocity(yawRate: 0.3, pitchRate: 0).x)
        let fast = abs(m.velocity(yawRate: 0.6, pitchRate: 0).x)
        XCTAssertGreaterThan(fast, slow * 2)
    }

    func testSubpixelAccumulation() {
        var c = PointerConfig(); c.acceleration = 0; c.deadZone = 0; c.sensitivity = 10
        var m = PointerMapper(config: c)
        // 0.1 rad/s * 10 px/rad = 1 px/s；每幀 0.04 px，30 幀累積 1.2px → 輸出 1px
        var total = 0
        for i in 0..<30 {
            let r = HeadRates(time: Double(i) * 0.04, dt: 0.04, yawRate: -0.1, pitchRate: 0)
            total += m.delta(for: r).dx
        }
        XCTAssertEqual(total, 1)
    }
}

final class HeadGestureDetectorTests: XCTestCase {
    private let nodDownUp: [Seg] = [Seg(0.1, 0.2, -2.5), Seg(0.3, 0.2, 2.5)]
    private let shake3: [Seg] = [Seg(0.0, 0.2, 3), Seg(0.2, 0.2, -3), Seg(0.4, 0.2, 3)]

    func testNodDetected() {
        var d = HeadGestureDetector()
        let ev = run(&d, makeRates(duration: 1.0, start: 10, pitch: nodDownUp, yawBias: 0.1))
        XCTAssertEqual(gestures(ev), [.nod])
        XCTAssertLessThan(ev.first?.startTime ?? 99, 10.1)
    }

    func testUpThenDownNodAlsoDetected() {
        var d = HeadGestureDetector()
        let segs: [Seg] = [Seg(0.1, 0.2, 2.5), Seg(0.3, 0.2, -2.5)]
        XCTAssertEqual(gestures(run(&d, makeRates(duration: 1.0, pitch: segs))), [.nod])
    }

    func testSlowLookDownAndUpIsNotNod() {
        var d = HeadGestureDetector()
        // 慢慢低頭看鍵盤再抬頭：峰值 0.8 rad/s，低於閾值
        let segs: [Seg] = [Seg(0.0, 0.6, -0.8), Seg(1.0, 0.6, 0.8)]
        XCTAssertTrue(run(&d, makeRates(duration: 2.0, pitch: segs)).isEmpty)
    }

    func testShakeDetected() {
        var d = HeadGestureDetector()
        let ev = run(&d, makeRates(duration: 1.2, yaw: shake3, pitchBias: 0.2))
        XCTAssertEqual(gestures(ev), [.shake])
    }

    func testSingleFastTurnIsNotShake() {
        var d = HeadGestureDetector()
        // 快速轉頭看副屏再轉回來（只有 2 次擺動）
        let segs: [Seg] = [Seg(0.0, 0.3, 3), Seg(0.8, 0.3, -3)]
        XCTAssertTrue(run(&d, makeRates(duration: 2.0, yaw: segs)).isEmpty)
    }

    func testShakeIsNotReportedAsNod() {
        var d = HeadGestureDetector()
        // 搖頭時伴隨少量俯仰
        let ev = run(&d, makeRates(duration: 1.2, yaw: shake3, pitchFromYaw: 0.2))
        XCTAssertEqual(gestures(ev), [.shake])
    }

    func testDiagonalFlickIsNotNod() {
        var d = HeadGestureDetector()
        let ev = run(&d, makeRates(duration: 1.0, pitch: nodDownUp, yawFromPitch: 1.2))
        XCTAssertFalse(gestures(ev).contains(.nod))
    }

    func testCooldownPreventsDoubleFire() {
        var d = HeadGestureDetector()
        let segs: [Seg] = [Seg(0.0, 0.2, -2.5), Seg(0.2, 0.2, 2.5), Seg(0.4, 0.2, -2.5), Seg(0.6, 0.2, 2.5)]
        XCTAssertEqual(run(&d, makeRates(duration: 1.2, pitch: segs)).count, 1)
    }

    func testDisabledGesture() {
        var c = GestureConfig()
        c.nodEnabled = false
        var d = HeadGestureDetector(config: c)
        XCTAssertTrue(run(&d, makeRates(duration: 1.0, pitch: nodDownUp)).isEmpty)
    }
}

final class PositionHistoryTests: XCTestCase {
    func testLookup() {
        var h = PositionHistory(span: 1.0)
        for i in 0..<50 { h.record(Vec2(Double(i), 0), at: Double(i) * 0.04) }
        XCTAssertEqual(h.position(at: 1.01)?.x, 25)
        XCTAssertEqual(h.position(at: 100)?.x, 49)
        // 超出記錄範圍返回最早保留的點（約 1 秒前）
        let earliest: Double = h.position(at: 0)?.x ?? -1
        XCTAssertGreaterThanOrEqual(earliest, 23)
        XCTAssertLessThanOrEqual(earliest, 25)
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = AppSettings()
        s.mapping[.nod] = .undo
        s.pointer.sensitivity = 999
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), s)
    }

    func testDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.action(for: .singlePress), .leftClick)
        XCTAssertEqual(s.action(for: .doublePress), .rightClick)
        XCTAssertEqual(s.action(for: .triplePress), .copy)
        XCTAssertEqual(s.action(for: .nod), .paste)
        XCTAssertEqual(s.action(for: .shake), .togglePause)
    }

    func testMissingFieldsUseDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s, AppSettings())
    }
}
