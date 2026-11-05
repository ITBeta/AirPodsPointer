import CoreMotion
import Foundation
import HeadMouseCore

/// 封裝 CMHeadphoneMotionManager（macOS 14+）。回調均在主線程。
final class HeadMotionSource: NSObject, CMHeadphoneMotionManagerDelegate {
    enum Status: Equatable {
        case unavailable          // 設備/系統不支持
        case notAuthorized        // 用戶拒絕了「運動與健身」權限
        case waitingForHeadphones // 已開始，但耳機未連接/未佩戴
        case streaming
    }

    private let manager = CMHeadphoneMotionManager()
    var onSample: ((MotionSample) -> Void)?
    var onStatusChange: ((Status) -> Void)?
    private(set) var status: Status = .waitingForHeadphones {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard manager.isDeviceMotionAvailable else { status = .unavailable; return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = .notAuthorized
            return
        default: break
        }
        status = .waitingForHeadphones
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                NSLog("AirHeadMouse motion error: \(error)")
                if CMHeadphoneMotionManager.authorizationStatus() == .denied { self.status = .notAuthorized }
                return
            }
            guard let m = motion else { return }
            self.status = .streaming
            let a = m.attitude
            // CMDeviceMotion.timestamp 與 ProcessInfo.systemUptime 同一時基。
            self.onSample?(MotionSample(time: m.timestamp, yaw: a.yaw, pitch: a.pitch, roll: a.roll))
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { if self.status != .streaming { self.status = .waitingForHeadphones } }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { self.status = .waitingForHeadphones }
    }
}
