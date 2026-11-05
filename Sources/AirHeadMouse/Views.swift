import SwiftUI
import HeadMouseCore

struct MenuContentView: View {
    @ObservedObject var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: app.statusSymbol)
                Text(app.statusText).font(.headline)
            }

            if !app.accessibilityGranted {
                Button("打開「輔助功能」設置") { Permissions.openAccessibilitySettings() }
            }
            if app.motionStatus == .notAuthorized {
                Button("打開「運動與健身」設置") { Permissions.openMotionSettings() }
            }

            Toggle("頭控鼠標", isOn: Binding(
                get: { app.trackingEnabled },
                set: { if $0 != app.trackingEnabled { app.toggleTracking() } }
            ))
            .toggleStyle(.switch)

            HStack {
                Button("光標回中") { app.recenter() }
                Button("重新獲取耳機按鍵") { app.reclaimNowPlaying() }
                    .help("如果打開了音樂/視頻 App，耳機按壓可能被它們搶走，點此奪回")
            }

            Divider()
            Text("手勢").font(.subheadline).foregroundStyle(.secondary)
            ForEach(Trigger.allCases, id: \.self) { t in
                HStack {
                    Text(t.displayName)
                    Spacer()
                    Text(app.settings.action(for: t).displayName).foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Divider()
            Text("最近事件：\(app.lastEvent)").font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("調試數據", isExpanded: $app.showDebug) {
                DiagnosticsView(d: app.live,
                                nodThreshold: app.settings.gestures.nodThreshold,
                                shakeThreshold: app.settings.gestures.shakeThreshold)
                HStack {
                    Button("重啟頭部追蹤") { app.restartMotion() }
                    Button("運動與健身設置") { Permissions.openMotionSettings() }
                }
                .font(.caption)
            }
            .font(.caption)

            Divider()
            HStack {
                SettingsLink { Text("設置…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppController

    var body: some View {
        TabView {
            pointerTab.tabItem { Label("光標", systemImage: "cursorarrow.motionlines") }
            mappingTab.tabItem { Label("手勢映射", systemImage: "hand.tap") }
            gestureTab.tabItem { Label("頭部手勢", systemImage: "person.crop.circle") }
            motionTab.tabItem { Label("數據來源", systemImage: "gyroscope") }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private var pointerTab: some View {
        Form {
            slider("靈敏度", \.pointer.sensitivity, 300...3000, "%.0f")
            slider("加速度", \.pointer.acceleration, 0...3, "%.2f")
            slider("死區 (rad/s)", \.pointer.deadZone, 0...0.3, "%.2f")
            slider("垂直倍率", \.pointer.verticalScale, 0.5...3, "%.2f")
            Toggle("反轉水平", isOn: $app.settings.pointer.invertX)
            Toggle("反轉垂直", isOn: $app.settings.pointer.invertY)
            slider("按壓延遲補償 (s)", \.pressLatency, 0...0.8, "%.2f")
            slider("點擊吸附半徑 (px)", \.snapRadius, 0...120, "%.0f")
            Toggle("自動奪回耳機按鍵（防止音樂 App 搶走）", isOn: $app.settings.autoReclaimMediaKeys)
            Button("恢復默認設置") { app.resetSettings() }
        }
    }

    private var mappingTab: some View {
        Form {
            ForEach(Trigger.allCases, id: \.self) { t in
                Picker(t.displayName, selection: Binding(
                    get: { app.settings.action(for: t) },
                    set: { app.settings.mapping[t] = $0 }
                )) {
                    ForEach(MouseAction.allCases, id: \.self) { a in Text(a.displayName).tag(a) }
                }
            }
            Text("長按耳機柄由系統佔用（切換降噪），無法自定義。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var gestureTab: some View {
        Form {
            Toggle("啟用點頭", isOn: $app.settings.gestures.nodEnabled)
            slider("點頭速度閾值 (rad/s)", \.gestures.nodThreshold, 0.4...4, "%.2f")
            Text(String(format: "最近點頭峰值：%.2f", app.live.peakPitch))
                .font(.caption).foregroundStyle(app.live.peakPitch >= app.settings.gestures.nodThreshold ? Color.green : Color.secondary)
            Toggle("啟用搖頭", isOn: $app.settings.gestures.shakeEnabled)
            slider("搖頭速度閾值 (rad/s)", \.gestures.shakeThreshold, 0.4...4, "%.2f")
            Text(String(format: "最近搖頭峰值：%.2f", app.live.peakYaw))
                .font(.caption).foregroundStyle(app.live.peakYaw >= app.settings.gestures.shakeThreshold ? Color.green : Color.secondary)
            Stepper("搖頭擺動次數：\(app.settings.gestures.shakeSwings)",
                    value: $app.settings.gestures.shakeSwings, in: 2...5)
            slider("觸發冷卻 (s)", \.gestures.cooldown, 0.2...2, "%.1f")
            Text("先快速點頭/搖頭幾次，看上面的峰值，把閾值設到峰值的約 70%。閾值越高越不易誤觸。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var motionTab: some View {
        Form {
            Picker("角速度來源", selection: $app.settings.motion.mode) {
                ForEach(MotionSourceMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
            }
            axisPicker("轉頭（左右）軸", \.motion.yawAxis)
            axisPicker("點頭（上下）軸", \.motion.pitchAxis)
            Text("「自動」：姿態數據正常時用姿態；若姿態一直不變但陀螺儀有數據，自動改用陀螺儀。使用陀螺儀時，打開菜單「調試數據」轉頭/點頭，看 gyro 哪個軸變化最大，選對應的軸；方向反了就勾「反向」。")
                .font(.caption).foregroundStyle(.secondary)
            Text("當前：\(app.live.usingGyro ? "陀螺儀" : "姿態")")
                .font(.caption)
        }
    }

    private func axisPicker(_ title: String, _ kp: WritableKeyPath<AppSettings, AxisMapping>) -> some View {
        HStack {
            Picker(title, selection: Binding(get: { app.settings[keyPath: kp].axis },
                                             set: { app.settings[keyPath: kp].axis = $0 })) {
                ForEach(GyroAxis.allCases, id: \.self) { a in Text(a.rawValue.uppercased()).tag(a) }
            }
            Toggle("反向", isOn: Binding(get: { app.settings[keyPath: kp].inverted },
                                       set: { app.settings[keyPath: kp].inverted = $0 }))
        }
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<AppSettings, Double>,
                        _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: Binding(get: { app.settings[keyPath: kp] },
                                  set: { app.settings[keyPath: kp] = $0 }), in: range)
            Text(String(format: fmt, app.settings[keyPath: kp]))
                .font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
        }
    }
}

struct DiagnosticsView: View {
    let d: LiveDiagnostics
    var nodThreshold: Double = 1.0
    var shakeThreshold: Double = 1.2

    private func peakRow(_ k: String, _ peak: Double, _ threshold: Double) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(String(format: "%.2f / %.2f", peak, threshold))
                .foregroundStyle(peak >= threshold ? Color.green : Color.primary)
        }
    }

    private func deg(_ r: Double) -> String { String(format: "%+.1f°", r * 180 / .pi) }
    private func rate(_ r: Double) -> String { String(format: "%+.2f", r) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("授權", d.motion.authorization)
            row("可用 / 推送中 / 已連接",
                "\(d.motion.available ? "是" : "否") / \(d.motion.active ? "是" : "否") / \(d.motion.connected ? "是" : "否")")
            row("樣本數 / 頻率", "\(d.motion.sampleCount) / \(String(format: "%.1f", d.motion.sampleHz)) Hz")
            row("傳感器", d.motion.sensor)
            row("姿態 yaw/pitch/roll", "\(deg(d.sample.yaw)) \(deg(d.sample.pitch)) \(deg(d.sample.roll))")
            row("陀螺儀 x/y/z (rad/s)", "\(rate(d.sample.gyroX)) \(rate(d.sample.gyroY)) \(rate(d.sample.gyroZ))")
            row("數據來源", d.usingGyro ? "陀螺儀" : "姿態")
            row("角速度 yaw/pitch", "\(rate(d.yawRate)) \(rate(d.pitchRate))")
            peakRow("點頭峰值 / 閾值", d.peakPitch, nodThreshold)
            peakRow("搖頭峰值 / 閾值", d.peakYaw, shakeThreshold)
            row("本幀位移", "dx \(d.dx)  dy \(d.dy)")
            row("狀態", d.reason)
            if !d.motion.lastError.isEmpty { row("錯誤", d.motion.lastError) }
            if d.motion.restarts > 0 { row("重啟次數", "\(d.motion.restarts)") }
            if !d.motion.note.isEmpty { row("提示", d.motion.note) }
            if !d.motion.events.isEmpty {
                Text("最近事件").foregroundStyle(.secondary).padding(.top, 2)
                ForEach(Array(d.motion.events.enumerated()), id: \.offset) { _, e in
                    Text(e).lineLimit(2)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .textSelection(.enabled)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(v)
        }
    }
}
