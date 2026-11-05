import AppKit
import CoreMotion
import Foundation
import HeadMouseCore
import os

let motionLog = Logger(subsystem: "com.example.airheadmouse", category: "motion")

/// 封裝 CMHeadphoneMotionManager（macOS 14+）。回調均在主線程。
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
    private var lastSampleUptime: Double = 0
    private var lastRestartUptime: Double = 0
    private var hzWindowStart: Double = 0
    private var hzWindowCount = 0

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        diag.available = manager.isDeviceMotionAvailable
        diag.authorization = Self.describe(CMHeadphoneMotionManager.authorizationStatus())
        motionLog.info("start: available=\(self.diag.available) auth=\(self.diag.authorization, privacy: .public)")
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

        if status != .streaming { status = .waitingForHeadphones }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            self?.handle(motion: motion, error: error)
        }
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        manager.stopDeviceMotionUpdates()
    }

    /// 停止後重新開始推送（耳機重連、數據中斷時使用）。
    func restart() {
        motionLog.info("restart")
        diag.restarts += 1
        lastRestartUptime = ProcessInfo.processInfo.systemUptime
        manager.stopDeviceMotionUpdates()
        lastSampleUptime = 0
        status = .waitingForHeadphones
        start()
    }

    private func handle(motion: CMDeviceMotion?, error: Error?) {
        diag.authorization = Self.describe(CMHeadphoneMotionManager.authorizationStatus())
        if let error {
            diag.lastError = error.localizedDescription
            motionLog.error("motion error: \(error.localizedDescription, privacy: .public)")
            if CMHeadphoneMotionManager.authorizationStatus() == .denied { status = .notAuthorized }
            return
        }
        guard let m = motion else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if diag.sampleCount == 0 {
            motionLog.info("first sample: att=(\(m.attitude.yaw), \(m.attitude.pitch), \(m.attitude.roll)) gyro=(\(m.rotationRate.x), \(m.rotationRate.y), \(m.rotationRate.z))")
        }
        diag.sampleCount += 1
        lastSampleUptime = now
        hzWindowCount += 1
        if now - hzWindowStart >= 1 {
            diag.sampleHz = Double(hzWindowCount) / (now - hzWindowStart)
            hzWindowStart = now
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

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        diag.active = manager.isDeviceMotionActive
        if diag.sampleHz > 0, ProcessInfo.processInfo.systemUptime - lastSampleUptime > 1 { diag.sampleHz = 0 }
        guard status != .notAuthorized, status != .unavailable else { return }
        let silentFor = ProcessInfo.processInfo.systemUptime - lastSampleUptime
        if status == .streaming && silentFor > 3 {
            motionLog.info("no samples for \(silentFor)s")
            status = .waitingForHeadphones
        }
        // 已連接但沒有數據（或推送已停止）→ 重新開始。
        let sinceRestart = ProcessInfo.processInfo.systemUptime - lastRestartUptime
        if status == .waitingForHeadphones && (diag.connected || !manager.isDeviceMotionActive)
            && silentFor > 3 && sinceRestart > 6 {
            restart()
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            motionLog.info("headphones connected")
            self.diag.connected = true
            self.restart()
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            motionLog.info("headphones disconnected")
            self.diag.connected = false
            self.status = .waitingForHeadphones
        }
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
