import AppKit
import Combine
import Foundation
import HeadMouseCore

/// 把頭部姿態、按壓、頭部手勢與鼠標輸出串起來。所有方法在主線程調用。
final class AppController: ObservableObject {
    // MARK: 狀態（供 UI 顯示）
    @Published var trackingEnabled = true
    @Published private(set) var motionStatus: HeadMotionSource.Status = .waitingForHeadphones
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var lastEvent = "—"
    @Published private(set) var live = LiveDiagnostics()
    @Published var showDebug = false
    @Published var settings: AppSettings {
        didSet {
            mapper.config = settings.pointer
            detector.config = settings.gestures
            presses.autoReclaim = settings.autoReclaimMediaKeys
            if rateSource.config != settings.motion {
                rateSource.config = settings.motion
                rateSource.reset()
            }
            SettingsStore.save(settings)
        }
    }

    // MARK: 組件
    private let motion = HeadMotionSource()
    private let presses = PressGestureSource()
    private let sink = MacInputSink()
    private var rateSource: HeadRateSource
    private var mapper: PointerMapper
    private var detector: HeadGestureDetector
    private var history = PositionHistory(span: 1.5)
    private var freezeUntil: Double = 0
    private var permissionTimer: Timer?
    private var lastUIUpdate: Double = 0
    private var pending: LiveDiagnostics?

    init() {
        let s = SettingsStore.load()
        _settings = Published(initialValue: s)
        mapper = PointerMapper(config: s.pointer)
        rateSource = HeadRateSource(config: s.motion)
        detector = HeadGestureDetector(config: s.gestures)
    }

    var statusSymbol: String {
        if !accessibilityGranted { return "exclamationmark.triangle" }
        switch motionStatus {
        case .unavailable, .notAuthorized: return "exclamationmark.triangle"
        case .waitingForHeadphones: return "airpodspro.chargingcase.wireless"
        case .streaming: return trackingEnabled ? "airpodspro" : "pause.circle"
        }
    }

    var statusText: String {
        if !accessibilityGranted { return "需要「輔助功能」權限才能控制鼠標" }
        switch motionStatus {
        case .unavailable: return "此 Mac 不支持耳機運動數據（需 macOS 14+）"
        case .notAuthorized: return "「運動與健身」權限被拒絕"
        case .waitingForHeadphones: return "等待 AirPods 連接並佩戴…"
        case .streaming: return trackingEnabled ? "頭控中" : "已暫停（搖頭或點菜單恢復）"
        }
    }

    // MARK: 生命週期

    func start() {
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.accessibilityGranted = Permissions.accessibilityGranted
            // 沒有樣本時也刷新診斷（例如授權狀態、重啟次數）。
            var d = self.pending ?? self.live
            d.motion = self.motion.diag
            if self.motionStatus != .streaming { d.reason = "沒有收到頭部數據" }
            self.live = d
            self.pending = nil
        }

        motion.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.motionStatus = status
            if status != .streaming {
                self.resetMotionState()
                self.showDebug = true   // 沒有數據時自動展開診斷
            }
        }
        motion.onSample = { [weak self] s in self?.handle(sample: s) }
        motion.start()

        presses.onPress = { [weak self] kind in self?.handle(press: kind) }
        presses.start()
        presses.autoReclaim = settings.autoReclaimMediaKeys
    }

    func stop() {
        sink.releaseDragIfNeeded()
        motion.stop()
        presses.stop()
        permissionTimer?.invalidate()
    }

    func toggleTracking() { setTracking(!trackingEnabled) }

    func recenter() {
        sink.centerOnMainDisplay()
        resetMotionState()
    }

    func restartMotion() {
        resetMotionState()
        motion.restart(manual: true)
        note("已重啟頭部追蹤")
    }

    func reclaimNowPlaying() {
        presses.reclaim()
        note("已重新獲取媒體按鍵控制")
    }

    func resetSettings() { settings = AppSettings() }

    // MARK: 頭部運動

    private func handle(sample: MotionSample) {
        let now = sample.time
        var d = live
        d.sample = sample
        d.usingGyro = rateSource.usingGyro

        guard let r = rateSource.update(sample) else {
            d.reason = "等待第二幀數據"
            publish(d, now: now)
            return
        }
        d.yawRate = r.yawRate
        d.pitchRate = r.pitchRate
        d.dx = 0; d.dy = 0

        let gesture = detector.process(r)
        let peak = detector.recentPeak
        d.peakYaw = peak.yaw
        d.peakPitch = peak.pitch
        if let g = gesture {
            motionLog.info("gesture \(g.gesture.rawValue, privacy: .public)")
            handle(gesture: g)
            d.reason = "識別到\(g.gesture == .nod ? "點頭" : "搖頭")"
            publish(d, now: now, force: true)
            return
        }

        if !trackingEnabled {
            d.reason = "頭控已暫停"
        } else if !accessibilityGranted {
            d.reason = "缺少輔助功能權限"
        } else if now < freezeUntil {
            d.reason = "點擊後短暫凍結"
        } else {
            let (dx, dy) = mapper.delta(for: r)
            d.dx = dx; d.dy = dy
            if dx != 0 || dy != 0 {
                let current = sink.cursorLocation
                sink.move(to: Vec2(current.x + Double(dx), current.y + Double(dy)))
                d.reason = "移動中"
            } else if mapper.velocity(yawRate: r.yawRate, pitchRate: r.pitchRate) == .zero {
                d.reason = "速度低於死區（頭沒動，或數據恆定）"
            } else {
                d.reason = "累積亞像素中"
            }
        }
        history.record(sink.cursorLocation, at: now)
        publish(d, now: now)
    }

    /// 診斷信息約 5Hz 刷新，避免頻繁重繪 UI。
    private func publish(_ d: LiveDiagnostics, now: Double, force: Bool = false) {
        var d = d
        d.motion = motion.diag
        if force || now - lastUIUpdate > 0.2 {
            live = d
            lastUIUpdate = now
        } else {
            pending = d
        }
    }

    private func handle(gesture g: HeadGestureEvent) {
        let trigger: Trigger = g.gesture == .nod ? .nod : .shake
        let action = settings.action(for: trigger)
        // 手勢本身會帶動光標，把光標還原到手勢開始前。
        if trackingEnabled, let p = history.position(at: g.startTime) { sink.move(to: p) }
        // 暫停時只響應「暫停/恢復」，避免誤觸其他動作。
        if !trackingEnabled && action != .togglePause { return }
        // 提示音（暫停/恢復有自己的提示音）。
        if action != .togglePause { NSSound(named: "Tink")?.play() }
        perform(action, trigger: trigger)
    }

    // MARK: 按壓

    private func handle(press kind: PressKind) {
        let trigger: Trigger
        switch kind {
        case .single: trigger = .singlePress
        case .double: trigger = .doublePress
        case .triple: trigger = .triplePress
        }
        let action = settings.action(for: trigger)
        guard trackingEnabled || action == .togglePause || !action.isPointerAction else {
            note("\(trigger.displayName)（頭控已暫停，忽略）")
            return
        }
        if action.isPointerAction { stabilizeForPress() }
        perform(action, trigger: trigger)
    }

    /// 系統上報按壓有延遲；若期間頭部只是微動，就把光標回退到按下那一刻的位置。
    private func stabilizeForPress() {
        let now = ProcessInfo.processInfo.systemUptime
        let current = sink.cursorLocation
        if let p = history.position(at: now - settings.pressLatency),
           (p - current).length <= settings.snapRadius {
            sink.move(to: p)
        }
    }

    // MARK: 動作執行

    private func perform(_ action: MouseAction, trigger: Trigger) {
        guard accessibilityGranted || action == .togglePause else {
            note("缺少輔助功能權限"); return
        }
        switch action {
        case .none: break
        case .leftClick: sink.click(.left)
        case .rightClick: sink.click(.right)
        case .middleClick: sink.click(.center)
        case .doubleClick: sink.click(.left, count: 2)
        case .toggleDrag: sink.toggleDrag()
        case .copy: sink.commandKey(KeyCode.c)
        case .paste: sink.commandKey(KeyCode.v)
        case .cut: sink.commandKey(KeyCode.x)
        case .undo: sink.commandKey(KeyCode.z)
        case .selectAll: sink.commandKey(KeyCode.a)
        case .togglePause: toggleTracking()
        case .recenter: recenter()
        }
        if action.isPointerAction {
            freezeUntil = ProcessInfo.processInfo.systemUptime + settings.clickFreeze
        }
        note("\(trigger.displayName) → \(action.displayName)")
    }

    private func setTracking(_ on: Bool) {
        trackingEnabled = on
        if !on { sink.releaseDragIfNeeded() }
        resetMotionState()
        NSSound(named: on ? "Pop" : "Bottle")?.play()
    }

    private func resetMotionState() {
        rateSource.reset()
        mapper.reset()
        history.clear()
    }

    private func note(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lastEvent = "\(f.string(from: Date()))  \(s)"
    }
}

enum SettingsStore {
    private static let key = "AirHeadMouse.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    static func save(_ s: AppSettings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct LiveDiagnostics {
    var motion = HeadMotionSource.Diagnostics()
    var sample = MotionSample(time: 0, yaw: 0, pitch: 0, roll: 0)
    var usingGyro = false
    var yawRate = 0.0
    var pitchRate = 0.0
    var dx = 0
    var dy = 0
    var reason = "—"
    var peakYaw = 0.0
    var peakPitch = 0.0
}
