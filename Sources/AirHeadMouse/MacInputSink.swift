import AppKit
import CoreGraphics
import HeadMouseCore

/// 通過 CGEvent 注入鼠標/鍵盤事件。需要「輔助功能」權限。
final class MacInputSink {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var isDragging = false

    var cursorLocation: Vec2 {
        let p = CGEvent(source: nil)?.location ?? .zero
        return Vec2(Double(p.x), Double(p.y))
    }

    /// 移動光標到 p（全局 CG 坐標，原點主屏左上），自動限制在屏幕範圍內。
    func move(to p: Vec2) {
        let target = clampToDisplays(CGPoint(x: p.x, y: p.y), from: cursorCGPoint)
        let type: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func click(_ button: CGMouseButton, count: Int = 1) {
        let pos = cursorCGPoint
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case .right: return (.rightMouseDown, .rightMouseUp)
            case .center: return (.otherMouseDown, .otherMouseUp)
            default: return (.leftMouseDown, .leftMouseUp)
            }
        }()
        for i in 1...max(1, count) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e.post(tap: .cghidEventTap)
            }
        }
    }

    func toggleDrag() {
        let pos = cursorCGPoint
        let type: CGEventType = isDragging ? .leftMouseUp : .leftMouseDown
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        isDragging.toggle()
    }

    func releaseDragIfNeeded() { if isDragging { toggleDrag() } }

    /// 發送 ⌘ + key。
    func commandKey(_ keyCode: CGKeyCode) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
        }
    }

    func centerOnMainDisplay() {
        let b = CGDisplayBounds(CGMainDisplayID())
        move(to: Vec2(Double(b.midX), Double(b.midY)))
    }

    // MARK: - 屏幕範圍

    private var cursorCGPoint: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func clampToDisplays(_ p: CGPoint, from current: CGPoint) -> CGPoint {
        let displays = displayBounds()
        if displays.contains(where: { $0.contains(p) }) { return p }
        // 超出所有屏幕：限制在當前光標所在屏幕內。
        let home = displays.first(where: { $0.contains(current) }) ?? displays.first ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }
}

enum KeyCode {
    static let a: CGKeyCode = 0x00
    static let z: CGKeyCode = 0x06
    static let x: CGKeyCode = 0x07
    static let c: CGKeyCode = 0x08
    static let v: CGKeyCode = 0x09
}
