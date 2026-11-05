import Foundation

/// 觸發源：AirPods 按壓 或 頭部手勢。
public enum Trigger: String, Codable, CaseIterable, Sendable {
    case singlePress, doublePress, triplePress, nod, shake

    public var displayName: String {
        switch self {
        case .singlePress: return "單擊耳機柄"
        case .doublePress: return "雙擊耳機柄"
        case .triplePress: return "三擊耳機柄"
        case .nod: return "點頭"
        case .shake: return "搖頭"
        }
    }
}

public enum MouseAction: String, Codable, CaseIterable, Sendable {
    case none
    case leftClick, rightClick, doubleClick, middleClick
    case toggleDrag      // 按住左鍵 / 鬆開（拖拽）
    case copy, paste, cut, undo, selectAll
    case togglePause     // 暫停/恢復頭控
    case recenter        // 光標回到主屏中心

    public var displayName: String {
        switch self {
        case .none: return "無"
        case .leftClick: return "左鍵點擊"
        case .rightClick: return "右鍵點擊"
        case .doubleClick: return "左鍵雙擊"
        case .middleClick: return "中鍵點擊"
        case .toggleDrag: return "按住/鬆開左鍵（拖拽）"
        case .copy: return "複製"
        case .paste: return "粘貼"
        case .cut: return "剪切"
        case .undo: return "撤銷"
        case .selectAll: return "全選"
        case .togglePause: return "暫停/恢復頭控"
        case .recenter: return "光標回中"
        }
    }

    /// 是否是作用在光標位置上的動作（執行前需要穩定光標）。
    public var isPointerAction: Bool {
        switch self {
        case .leftClick, .rightClick, .doubleClick, .middleClick, .toggleDrag: return true
        default: return false
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var pointer = PointerConfig()
    public var gestures = GestureConfig()
    public var mapping: [Trigger: MouseAction] = AppSettings.defaultMapping
    /// AirPods 按壓上報有延遲（系統要等待判斷單/雙/三擊）；
    /// 點擊時光標回退到「按下那一刻」的位置，前提是期間移動小於 snapRadius。
    public var pressLatency: Double = 0.35
    public var snapRadius: Double = 40
    /// 點擊後凍結光標的時間（秒）。
    public var clickFreeze: Double = 0.15

    public static let defaultMapping: [Trigger: MouseAction] = [
        .singlePress: .leftClick,
        .doublePress: .rightClick,
        .triplePress: .copy,
        .nod: .paste,
        .shake: .togglePause,
    ]

    public init() {}

    public func action(for trigger: Trigger) -> MouseAction { mapping[trigger] ?? .none }

    // 舊版本存檔缺字段時用默認值補齊。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        pointer = try c.decodeIfPresent(PointerConfig.self, forKey: .pointer) ?? d.pointer
        gestures = try c.decodeIfPresent(GestureConfig.self, forKey: .gestures) ?? d.gestures
        mapping = try c.decodeIfPresent([Trigger: MouseAction].self, forKey: .mapping) ?? d.mapping
        pressLatency = try c.decodeIfPresent(Double.self, forKey: .pressLatency) ?? d.pressLatency
        snapRadius = try c.decodeIfPresent(Double.self, forKey: .snapRadius) ?? d.snapRadius
        clickFreeze = try c.decodeIfPresent(Double.self, forKey: .clickFreeze) ?? d.clickFreeze
    }
}
