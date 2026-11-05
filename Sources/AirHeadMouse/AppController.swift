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
    @Published private(set) var attitude = (yaw: 0.0, pitch: 0.0, roll: 0.0)
    @Published var showDebug = false
    @Published var settings: AppSettings {
        didSet {
            mapper.config = settings.pointer
            detector.config = settings.gestures
            SettingsStore.save(settings)
        }
    }

    // MARK: 組件
    private let motion = HeadMotionSource()
    private let presses = PressGestureSource()
    private let sink = MacInputSink()
    private var rates = RateEstimator()
    private var mapper: PointerMapper
    private var detector: HeadGestureDetector
    private var history = PositionHistory(span: 1.5)
    private var freezeUntil: Double = 0
    private var permissionTimer: Timer?
    private var lastUIUpdate: Double = 0

    init() {
        let s = SettingsStore.load()
        _settings = Published(initialValue: s)
        mapper = PointerMapper(config: s.pointer)
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
            self?.accessibilityGranted = Permissions.accessibilityGranted
        }

        motion.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.motionStatus = status
            if status != .streaming { self.resetMotionState() }
        }
        motion.onSample = { [weak self] s in self?.handle(sample: s) }
        motion.start()

        presses.onPress = { [weak self] kind in self?.handle(press: kind) }
        presses.start()
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

    func reclaimNowPlaying() {
        presses.reclaim()
        note("已重新獲取媒體按鍵控制")
    }

    func resetSettings() { settings = AppSettings() }

    // MARK: 頭部運動

    private func handle(sample: MotionSample) {
        let now = sample.time
        if showDebug, now - lastUIUpdate > 0.1 {
            attitude = (sample.yaw, sample.pitch, sample.roll)
            lastUIUpdate = now
        }

        guard let r = rates.update(sample) else { return }

        if let g = detector.process(r) {
            handle(gesture: g)
            return
        }

        guard trackingEnabled, accessibilityGranted, now >= freezeUntil else {
            history.record(sink.cursorLocation, at: now)
            return
        }

        let (dx, dy) = mapper.delta(for: r)
        let current = sink.cursorLocation
        if dx != 0 || dy != 0 {
            let target = Vec2(current.x + Double(dx), current.y + Double(dy))
            sink.move(to: target)
        }
        history.record(sink.cursorLocation, at: now)
    }

    private func handle(gesture g: HeadGestureEvent) {
        let trigger: Trigger = g.gesture == .nod ? .nod : .shake
        let action = settings.action(for: trigger)
        // 手勢本身會帶動光標，把光標還原到手勢開始前。
        if trackingEnabled, let p = history.position(at: g.startTime) { sink.move(to: p) }
        // 暫停時只響應「暫停/恢復」，避免誤觸其他動作。
        if !trackingEnabled && action != .togglePause { return }
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
        rates.reset()
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
