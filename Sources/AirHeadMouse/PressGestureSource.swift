import AppKit
import AVFoundation
import Foundation
import MediaPlayer

enum PressKind { case single, double, triple }

/// 攔截 AirPods 按壓。
///
/// macOS 把耳機按壓轉成媒體命令發給「正在播放」(Now Playing) 的 App：
/// 單擊 → 播放/暫停，雙擊 → 下一首，三擊 → 上一首。
/// 所以本 App 循環播放一段靜音音頻，讓自己成為 Now Playing，再通過 MPRemoteCommandCenter 接收命令。
final class PressGestureSource {
    var onPress: ((PressKind) -> Void)?
    private var player: AVAudioPlayer?
    private var lastSingle: TimeInterval = 0
    private var targets: [(MPRemoteCommand, Any)] = []
    private var reclaimTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// 開啟後定時（及切換 App 時）重新成為 Now Playing，防止 Music 等 App 搶走耳機按鍵。
    var autoReclaim = false {
        didSet { if autoReclaim != oldValue { updateAutoReclaim() } }
    }

    func start() {
        startSilentPlayback()
        registerCommands()
        publishNowPlaying()
    }

    func stop() {
        autoReclaim = false
        for (cmd, token) in targets { cmd.removeTarget(token) }
        targets.removeAll()
        player?.stop()
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 其他 App（Music、Spotify、瀏覽器視頻）可能搶走 Now Playing，調用此方法重新奪回。
    func reclaim() {
        guard let p = player else { return }
        // 暫停再播放 = 重新「開始播放」，系統會把本 App 重新視為最近的 Now Playing。
        p.pause()
        p.currentTime = 0
        p.play()
        publishNowPlaying()
    }

    private func updateAutoReclaim() {
        reclaimTimer?.invalidate()
        reclaimTimer = nil
        if let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            activationObserver = nil
        }
        guard autoReclaim else { return }
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reclaim()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // 稍等片刻，讓對方 App 先完成它的播放狀態更新。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.reclaim() }
        }
    }

    private func startSilentPlayback() {
        do {
            let url = try Self.makeSilentWAV()
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.01
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            NSLog("AirHeadMouse: cannot start silent playback: \(error)")
        }
    }

    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "AirHeadMouse 頭控鼠標",
            MPMediaItemPropertyArtist: "按壓耳機柄 = 點擊",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        center.playbackState = .playing
    }

    private func registerCommands() {
        let cc = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ kind: PressKind) {
            cmd.isEnabled = true
            let token = cmd.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.handle(kind) }
                return .success
            }
            targets.append((cmd, token))
        }
        // 單擊在不同系統版本可能表現為 toggle / play / pause 中任意一個。
        on(cc.togglePlayPauseCommand, .single)
        on(cc.playCommand, .single)
        on(cc.pauseCommand, .single)
        on(cc.nextTrackCommand, .double)
        on(cc.previousTrackCommand, .triple)
        for cmd in [cc.skipForwardCommand, cc.skipBackwardCommand, cc.seekForwardCommand,
                    cc.seekBackwardCommand, cc.changePlaybackPositionCommand] {
            cmd.isEnabled = false
        }
    }

    private func handle(_ kind: PressKind) {
        if kind == .single {
            // 一次按壓偶爾會同時觸發 pause + toggle，去抖。
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSingle < 0.2 { return }
            lastSingle = now
        }
        // 保持「播放中」，下次單擊仍會發送命令。
        publishNowPlaying()
        if player?.isPlaying == false { player?.play() }
        onPress?(kind)
    }

    /// 生成 1 秒 16-bit 單聲道靜音 WAV。
    private static func makeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airheadmouse-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate: UInt32 = 44_100
        let numSamples = sampleRate
        let dataSize = numSamples * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        try d.write(to: url)
        return url
    }
}
