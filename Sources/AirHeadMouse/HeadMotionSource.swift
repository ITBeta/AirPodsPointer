import AppKit
import CoreMotion
import Foundation
import HeadMouseCore
import os

let motionLog = Logger(subsystem: "com.example.airheadmouse", category: "motion")

/// 封裝 CMHeadphoneMotionManager（macOS 14+）。回調均在主線程。
///
/// 注意：stop/start 推送本身會觸發系統的 didDisconnect/didConnect 回調，
/// 所以絕不能在這些回調裡重啟推送，否則會形成死循環。
final class HeadMotionSource: NSObject, CMHeadphoneMotionManagerDelegate {
    enum Status: Equatable {
        case unavailable          // 設備/系統不支持
        case notAuthorized        // 用戶拒絕了「運動與健身」權限
        case waitingForHeadphones // 已開始，但耳機未連接/未佩戴/沒有數據
        case streaming
    }

    struct Diagnostics {
        var authorization = "—"
        var available = false
        var active = false
        var connected = false
        var sampleCount = 0
        var sampleHz = 0.0
        var lastError = ""
        var sensor = "—"
        var restarts = 0
        var note = ""
        var events: [String] = []
    }

    private let manager = CMHeadphoneMotionManager()
    var onSample: ((MotionSample) -> Void)?
    var onStatusChange: ((Status) -> Void)?
    private(set) var status: Status = .waitingForHeadphones {
        didSet {
            if status != oldValue {
                motionLog.info("status -> \(String(describing: self.status), privacy: .public)")
                onStatusChange?(status)
            }
        }
    }
    private(set) var diag = Diagnostics()

    private var watchdog: Timer?
    private var updatesRequested = false
    private var isRestarting = false
    private var startUptime: Double = 0
    private var lastSampleUptime: Double = 0
    private var lastRestartUptime: Double = -1000
    /// 開始推送後，耳機通常要幾秒才送來第一幀；這段時間絕不重啟。
    private let firstSampleGrace: Double = 15
    /// 數據中斷（曾經有數據、後來停了）多久後重啟。
    private let interruptionTimeout: Double = 3
    /// 兩次自動重啟的最小間隔。
    private let autoRestartGap: Double = 10
    private var hzWindowStart: Double = 0
    private var hzWindowCount = 0

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: 生命週期

    func start() {
        diag.available = manager.isDeviceMotionAvailable
        diag.authorization = Self.describe(CMHeadphoneMotionManager.authorizationStatus())
        event("start（授權：\(diag.authorization)）")
        guard manager.isDeviceMotionAvailable else { status = .unavailable; return }

        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = .notAuthorized
            return
        case .notDetermined:
            // 無 Dock 的菜單欄 App 需要先激活，系統權限彈窗才會顯示在前台。
            NSApp.activate(ignoringOtherApps: true)
        default: break
        }

        startUpdates()
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        manager.stopDeviceMotionUpdates()
        updatesRequested = false
    }

    /// 只在尚未開始時開始推送（不會先 stop）。
    private func startUpdates() {
        guard !updatesRequested else { return }
        updatesRequested = true
        startUptime = now
        if status != .streaming { status = .waitingForHeadphones }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            self?.handle(motion: motion, error: error)
        }
    }

    /// 停止後延遲 0.5s 重新開始推送。帶防重入與 10s 節流。
    /// - Parameter manual: 用戶點擊按鈕觸發（不計入自動重啟次數）。
    func restart(manual: Bool = false) {
        guard !isRestarting else { return }
        let minGap = manual ? 3 : autoRestartGap
        guard now - lastRestartUptime >= minGap else {
            if manual { diag.note = "剛剛已重啟，請稍等幾秒" }
            return
        }
        diag.note = ""
        isRestarting = true
        lastRestartUptime = now
        diag.restarts += 1
        event(manual ? "手動重啟" : "自動重啟")

        manager.stopDeviceMotionUpdates()
        updatesRequested = false
        status = .waitingForHeadphones
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.isRestarting = false
            self.startUpdates()
        }
    }

    // MARK: 數據

    private func handle(motion: CMDeviceMotion?, error: Error?) {
        if let error {
            diag.lastError = error.localizedDescription
            event("錯誤：\(error.localizedDescription)")
            if CMHeadphoneMotionManager.authorizationStatus() == .denied { status = .notAuthorized }
            return
        }
        guard let m = motion, !isRestarting else { return }

        let t = now
        if diag.sampleCount == 0 {
            event(String(format: "首幀 姿態(%.3f, %.3f, %.3f) 陀螺儀(%.3f, %.3f, %.3f)",
                         m.attitude.yaw, m.attitude.pitch, m.attitude.roll,
                         m.rotationRate.x, m.rotationRate.y, m.rotationRate.z))
        }
        if status != .streaming && diag.sampleCount > 0 { event("數據恢復") }
        diag.sampleCount += 1
        lastSampleUptime = t
        hzWindowCount += 1
        if t - hzWindowStart >= 1 {
            diag.sampleHz = Double(hzWindowCount) / (t - hzWindowStart)
            hzWindowStart = t
            hzWindowCount = 0
        }
        diag.sensor = Self.describe(m.sensorLocation)
        status = .streaming

        let a = m.attitude
        let r = m.rotationRate
        // CMDeviceMotion.timestamp 與 ProcessInfo.systemUptime 同一時基。
        onSample?(MotionSample(time: m.timestamp, yaw: a.yaw, pitch: a.pitch, roll: a.roll,
                               gyroX: r.x, gyroY: r.y, gyroZ: r.z))
    }

    // MARK: 看門狗

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        let t = now
        diag.active = manager.isDeviceMotionActive
        diag.authorization = Self.describe(CMHeadphoneMotionManager.authorizationStatus())
        let silentFor = t - max(lastSampleUptime, startUptime)
        if silentFor > 1 { diag.sampleHz = 0 }

        guard status != .notAuthorized, status != .unavailable, updatesRequested, !isRestarting else { return }
        if status == .streaming && silentFor > interruptionTimeout {
            event("超過 \(Int(interruptionTimeout)) 秒沒有數據")
            status = .waitingForHeadphones
        }
        if hadDataSinceStart {
            // 曾經有數據、後來中斷 → 較快重啟。
            if silentFor > interruptionTimeout { restart() }
        } else if t - startUptime > firstSampleGrace {
            // 開始後很久都沒有第一幀 → 重啟一次試試（每 10 秒最多一次）。
            restart()
        }
    }

    /// 本次 start 之後是否收到過樣本。
    private var hadDataSinceStart: Bool { lastSampleUptime >= startUptime && lastSampleUptime > 0 }

    /// 外部提示（例如切換了 App）：若 1 秒內沒有新樣本，立即嘗試重啟。
    func nudge() {
        guard updatesRequested, !isRestarting,
              status != .notAuthorized, status != .unavailable else { return }
        // 只在「曾經有數據、現在中斷」時重啟；還在等第一幀時不要打斷。
        if hadDataSinceStart && now - lastSampleUptime > interruptionTimeout { restart() }
    }

    // MARK: 連接回調（只記錄狀態，不重啟）

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.diag.connected = true
            guard !self.isRestarting else { return }
            self.event("耳機已連接")
            if !self.manager.isDeviceMotionActive { self.startUpdates() }
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.diag.connected = false
            guard !self.isRestarting else { return }
            self.event("耳機已斷開")
            self.status = .waitingForHeadphones
        }
    }

    // MARK: 工具

    /// 供外部寫入「最近事件」。
    func noteEvent(_ s: String) { event(s) }

    private func event(_ s: String) {
        motionLog.info("\(s, privacy: .public)")
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        diag.events.append("\(f.string(from: Date())) \(s)")
        if diag.events.count > 5 { diag.events.removeFirst(diag.events.count - 5) }
    }

    private static func describe(_ s: CMAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "未決定"
        case .restricted: return "受限"
        case .denied: return "已拒絕"
        case .authorized: return "已授權"
        @unknown default: return "未知(\(s.rawValue))"
        }
    }

    private static func describe(_ l: CMDeviceMotion.SensorLocation) -> String {
        switch l {
        case .default: return "默認"
        case .headphoneLeft: return "左耳"
        case .headphoneRight: return "右耳"
        @unknown default: return "未知"
        }
    }
}
