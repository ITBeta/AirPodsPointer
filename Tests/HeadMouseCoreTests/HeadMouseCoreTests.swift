import XCTest
@testable import HeadMouseCore

/// 生成 25Hz 的角速度序列。rateFn(t) 返回 (yawRate, pitchRate)。
private func rates(duration: Double, start: Double = 0, hz: Double = 25,
                   _ fn: (Double) -> (Double, Double)) -> [HeadRates] {
    let dt = 1 / hz
    return stride(from: 0.0, to: duration, by: dt).map { t in
        let (y, p) = fn(t)
        return HeadRates(time: start + t, dt: dt, yawRate: y, pitchRate: p)
    }
}

private func run(_ d: inout HeadGestureDetector, _ rs: [HeadRates]) -> [HeadGestureEvent] {
    rs.compactMap { d.process($0) }
}

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
        for i in 0..<30 { total += m.delta(for: HeadRates(time: Double(i) * 0.04, dt: 0.04, yawRate: -0.1, pitchRate: 0)).dx }
        XCTAssertEqual(total, 1)
    }
}

final class HeadGestureDetectorTests: XCTestCase {
    /// 正弦波瓣：在 [t0, t0+dur] 內 amp*sin
    private func lobe(_ t: Double, _ t0: Double, _ dur: Double, _ amp: Double) -> Double {
        guard t >= t0, t <= t0 + dur else { return 0 }
        return amp * sin(.pi * (t - t0) / dur)
    }

    func testNodDetected() {
        var d = HeadGestureDetector()
        let rs = rates(duration: 1.0, start: 10) { t in
            (0.1, self.lobe(t, 0.1, 0.2, -2.5) + self.lobe(t, 0.3, 0.2, 2.5))
        }
        let ev = run(&d, rs)
        XCTAssertEqual(ev.map(\.gesture), [.nod])
        XCTAssertLessThan(ev[0].startTime, 10.1)
    }

    func testUpThenDownNodAlsoDetected() {
        var d = HeadGestureDetector()
        let rs = rates(duration: 1.0) { t in (0, self.lobe(t, 0.1, 0.2, 2.5) + self.lobe(t, 0.3, 0.2, -2.5)) }
        XCTAssertEqual(run(&d, rs).map(\.gesture), [.nod])
    }

    func testSlowLookDownAndUpIsNotNod() {
        var d = HeadGestureDetector()
        // 慢慢低頭看鍵盤再抬頭：峰值 0.8 rad/s，低於閾值
        let rs = rates(duration: 2.0) { t in (0, self.lobe(t, 0.0, 0.6, -0.8) + self.lobe(t, 1.0, 0.6, 0.8)) }
        XCTAssertTrue(run(&d, rs).isEmpty)
    }

    func testShakeDetected() {
        var d = HeadGestureDetector()
        let rs = rates(duration: 1.2) { t in
            (self.lobe(t, 0.0, 0.2, 3) + self.lobe(t, 0.2, 0.2, -3) + self.lobe(t, 0.4, 0.2, 3), 0.2)
        }
        XCTAssertEqual(run(&d, rs).map(\.gesture), [.shake])
    }

    func testSingleFastTurnIsNotShake() {
        var d = HeadGestureDetector()
        // 快速轉頭看副屏再轉回來（只有 2 次擺動）
        let rs = rates(duration: 2.0) { t in (self.lobe(t, 0.0, 0.3, 3) + self.lobe(t, 0.8, 0.3, -3), 0) }
        let ev = run(&d, rs)
        XCTAssertFalse(ev.contains { $0.gesture == .shake })
        XCTAssertFalse(ev.contains { $0.gesture == .nod })
    }

    func testShakeIsNotReportedAsNod() {
        var d = HeadGestureDetector()
        // 搖頭時伴隨少量俯仰
        let rs = rates(duration: 1.2) { t in
            let y = self.lobe(t, 0.0, 0.2, 3) + self.lobe(t, 0.2, 0.2, -3) + self.lobe(t, 0.4, 0.2, 3)
            return (y, y * 0.2)
        }
        XCTAssertEqual(run(&d, rs).map(\.gesture), [.shake])
    }

    func testDiagonalFlickIsNotNod() {
        var d = HeadGestureDetector()
        let rs = rates(duration: 1.0) { t in
            let p = self.lobe(t, 0.1, 0.2, -2.5) + self.lobe(t, 0.3, 0.2, 2.5)
            return (p * 1.2, p)
        }
        XCTAssertFalse(run(&d, rs).contains { $0.gesture == .nod })
    }

    func testCooldownPreventsDoubleFire() {
        var d = HeadGestureDetector()
        let rs = rates(duration: 1.2) { t in
            (0, self.lobe(t, 0.0, 0.2, -2.5) + self.lobe(t, 0.2, 0.2, 2.5)
                + self.lobe(t, 0.4, 0.2, -2.5) + self.lobe(t, 0.6, 0.2, 2.5))
        }
        XCTAssertEqual(run(&d, rs).count, 1)
    }

    func testDisabledGesture() {
        var c = GestureConfig(); c.nodEnabled = false
        var d = HeadGestureDetector(config: c)
        let rs = rates(duration: 1.0) { t in (0, self.lobe(t, 0.1, 0.2, -2.5) + self.lobe(t, 0.3, 0.2, 2.5)) }
        XCTAssertTrue(run(&d, rs).isEmpty)
    }
}

final class PositionHistoryTests: XCTestCase {
    func testLookup() {
        var h = PositionHistory(span: 1.0)
        for i in 0..<50 { h.record(Vec2(Double(i), 0), at: Double(i) * 0.04) }
        XCTAssertEqual(h.position(at: 1.01)?.x, 25)
        XCTAssertEqual(h.position(at: 100)?.x, 49)
        // 超出記錄範圍返回最早保留的點（約 1 秒前）
        let earliest = try! XCTUnwrap(h.position(at: 0)).x
        XCTAssertTrue((23...25).contains(earliest))
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
