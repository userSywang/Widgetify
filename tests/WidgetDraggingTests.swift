import AppKit

private final class DragTestWindow: NSWindow {
    var origin = NSPoint(x: 250, y: 500)
    override var isVisible: Bool { true }
    override var frame: NSRect { NSRect(origin: origin, size: NSSize(width: 344, height: 359)) }
    override func setFrameOrigin(_ point: NSPoint) { origin = point }
}
@main struct WidgetDraggingTests {
    static func main() {
        _ = NSApplication.shared
        let window = DragTestWindow(contentRect: NSRect(x: 250, y: 500, width: 344, height: 359), styleMask: .borderless, backing: .buffered, defer: false)
        window.isMovable = false
        let view = WidgetDragView(frame: NSRect(x: 120, y: 280, width: 90, height: 28))
        window.contentView!.addSubview(view)
        let suite = "WidgetDragTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        view.positionDefaults = defaults; view.positionKey = "position"
        func event(_ kind: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let inside = NSPoint(x: 150, y: 294)
        precondition(view.track(event(.leftMouseDown, inside), pointer: NSPoint(x: 400, y: 800)) == nil)
        // The pointer may leave the header; tracking must continue while the mouse is held.
        precondition(view.track(event(.leftMouseDragged, .zero), pointer: NSPoint(x: 480, y: 730)) == nil)
        precondition(window.origin == NSPoint(x: 330, y: 430))
        precondition(view.track(event(.leftMouseUp, .zero), pointer: .zero) == nil)
        precondition(defaults.dictionary(forKey: "position")?["x"] as? Double == 330)
        window.origin = NSPoint(x: 100, y: 100)
        restoreWidgetPosition(window, key: "position", defaults: defaults)
        precondition(window.origin == NSPoint(x: 330, y: 430))
        // A fresh click outside the drag region must cancel any stale session.
        _ = view.track(event(.leftMouseDown, inside), pointer: NSPoint(x: 400, y: 800))
        _ = view.track(event(.leftMouseDown, .zero), pointer: .zero)
        precondition(view.track(event(.leftMouseDragged, inside), pointer: NSPoint(x: 900, y: 900)) != nil)
        precondition(window.origin == NSPoint(x: 330, y: 430))
        view.fixed = true
        precondition(view.track(event(.leftMouseDown, inside), pointer: .zero) != nil)
        _ = view.track(event(.leftMouseDragged, .zero), pointer: NSPoint(x: 900, y: 900))
        precondition(window.origin == NSPoint(x: 330, y: 430))
        view.fixed = false
        precondition(view.track(event(.leftMouseDown, NSPoint(x: 300, y: 294)), pointer: .zero) != nil)
        _ = view.track(event(.leftMouseDragged, inside), pointer: NSPoint(x: 900, y: 900))
        precondition(window.origin == NSPoint(x: 330, y: 430))
        let ownDown = NSEvent.mouseEvent(with: .leftMouseDown, location: inside, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        precondition(ownDown.window === window)
        precondition(view.track(ownDown, pointer: NSPoint(x: 2000, y: 2000)) == nil, "Queued mouse-down must use its own location, not a newer cursor position")
        _ = view.track(event(.leftMouseUp, inside), pointer: .zero)
        // Switch regions without a mouse-up (menu tracking/window changes can
        // intercept it). Only one region may own the subsequent drag.
        window.origin = NSPoint(x: 250, y: 500)
        let second = WidgetDragView(frame: NSRect(x: 220, y: 280, width: 90, height: 28))
        second.positionKey = "position"; second.positionDefaults = defaults
        window.contentView!.addSubview(second)
        let coordinator = WidgetDragCoordinator(window: window)
        coordinator.register(view); coordinator.register(second)
        precondition(coordinator.dispatch(event(.leftMouseDown, inside), pointer: NSPoint(x: 400, y: 794)) == nil)
        precondition(coordinator.dispatch(event(.leftMouseDragged, .zero), pointer: NSPoint(x: 410, y: 804)) == nil)
        precondition(window.origin == NSPoint(x: 260, y: 510))
        precondition(coordinator.dispatch(event(.leftMouseDown, .zero), pointer: NSPoint(x: 500, y: 804)) == nil)
        precondition(coordinator.dispatch(event(.leftMouseDragged, .zero), pointer: NSPoint(x: 520, y: 814)) == nil)
        precondition(window.origin == NSPoint(x: 280, y: 520), "Previous region must not steal the new region's drag")
        precondition(coordinator.dispatch(event(.leftMouseUp, .zero), pointer: .zero) == nil)
        precondition(coordinator.dispatch(event(.leftMouseDragged, .zero), pointer: NSPoint(x: 900, y: 900)) != nil)
        precondition(window.origin == NSPoint(x: 280, y: 520))
        // Clicking a button/outside all regions cancels the preceding drag.
        _ = coordinator.dispatch(event(.leftMouseDown, inside), pointer: NSPoint(x: 430, y: 814))
        precondition(coordinator.dispatch(event(.leftMouseDown, .zero), pointer: .zero) != nil)
        precondition(coordinator.dispatch(event(.leftMouseDragged, .zero), pointer: NSPoint(x: 900, y: 900)) != nil)
        precondition(window.origin == NSPoint(x: 280, y: 520))
        print("PASS: one window owner handles region switches, intercepted mouse-up and outside-button cancellation")
        print("PASS: delayed mouse-down uses historical event coordinates")
        print("PASS: nonmovable native window tracks header drag, continues outside region, persists/restores position, respects fixed state and preserves outside controls")
    }
}
