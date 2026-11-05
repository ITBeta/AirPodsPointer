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
                let a = app.attitude
                Text(String(format: "yaw %+.1f°  pitch %+.1f°  roll %+.1f°",
                            a.yaw * 180 / .pi, a.pitch * 180 / .pi, a.roll * 180 / .pi))
                    .font(.caption.monospacedDigit())
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
        .frame(width: 320)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppController

    var body: some View {
        TabView {
            pointerTab.tabItem { Label("光標", systemImage: "cursorarrow.motionlines") }
            mappingTab.tabItem { Label("手勢映射", systemImage: "hand.tap") }
            gestureTab.tabItem { Label("頭部手勢", systemImage: "person.crop.circle") }
        }
        .padding(20)
        .frame(width: 480, height: 400)
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
            slider("點頭速度閾值 (rad/s)", \.gestures.nodThreshold, 0.8...4, "%.2f")
            Toggle("啟用搖頭", isOn: $app.settings.gestures.shakeEnabled)
            slider("搖頭速度閾值 (rad/s)", \.gestures.shakeThreshold, 0.8...4, "%.2f")
            Stepper("搖頭擺動次數：\(app.settings.gestures.shakeSwings)",
                    value: $app.settings.gestures.shakeSwings, in: 2...5)
            slider("觸發冷卻 (s)", \.gestures.cooldown, 0.2...2, "%.1f")
            Text("閾值越高越不易誤觸，但需要更用力的動作。")
                .font(.caption).foregroundStyle(.secondary)
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
