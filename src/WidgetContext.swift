import AppKit
import SwiftUI

// Read the supported host's reflected view/model metadata. Never write Swift
// object memory or depend on field offsets or desktop window coordinates.
private func field(_ value: Any, _ name: String) -> Any? {
    var mirror: Mirror? = Mirror(reflecting: value)
    while let current = mirror {
        if let child = current.children.first(where: { $0.label == name }) { return child.value }
        mirror = current.superclassMirror
    }
    return nil
}
private func unwrap(_ value: Any?) -> Any? {
    guard let value else { return nil }
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional ? mirror.children.first?.value : value
}
private func scalar<T>(_ value: Any?, as: T.Type, depth: Int = 0) -> T? {
    guard let value, depth < 7 else { return nil }
    if let result = value as? T { return result }
    let mirror = Mirror(reflecting: value)
    // Only descend through value/publisher storage, not arbitrary object graphs.
    for child in mirror.children where ["storage", "value", "publisher", "subject", "currentValue", "some", "wrappedValue"].contains(child.label ?? "") {
        if let result: T = scalar(child.value, as: T.self, depth: depth + 1) { return result }
    }
    return nil
}
private func reflectedController(_ value: Any, depth: Int = 0, budget: inout Int) -> Any? {
    guard depth < 8, budget > 0 else { return nil }; budget -= 1
    let mirror = Mirror(reflecting: value), name = String(reflecting: Swift.type(of: value))
    if mirror.displayStyle == .class && [".WaterController", ".DocumentController", ".AppController", ".WidgetifyController"].contains(where: { name.hasSuffix($0) }) { return value }
    guard mirror.displayStyle != .collection && mirror.displayStyle != .dictionary else { return nil }
    for child in mirror.children where child.label != "widget" {
        if let result = reflectedController(child.value, depth: depth + 1, budget: &budget) { return result }
    }
    return nil
}
private func hosting(_ view: NSView) -> NSView? {
    let type = String(reflecting: Swift.type(of: view))
    if type.contains("NSHostingView") && type.contains("GenericWidgetifyView") { return view }
    for child in view.subviews { if let found = hosting(child) { return found } }
    return nil
}
@_cdecl("WidgetifyCopyContext") public func copyContext(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    guard let host = hosting(view), var root = field(host, "_rootView") else { return nil }
    let type = String(reflecting: Swift.type(of: host))
    let kind: String
    if type.contains("WaterController") { kind = "water" }
    else if type.contains("DocumentController") { kind = "folder" }
    else if type.contains("AppController") { kind = "shortcuts" }
    else { return nil }
    for _ in 0..<20 {
        if let model = field(root, "widget"), let id = field(model, "id") as? String,
           id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil {
            var result: [String: Any] = ["id": id, "kind": kind]
            if let fixed = field(model, "isFixed") as? Bool { result["fixed"] = fixed }
            var budget = 100
            let controller = view.window.flatMap { unwrap(field($0, "currentDisplayController")) } ?? reflectedController(root, budget: &budget)
            if let controller {
                for (key, property) in [("accent", "_acColor"), ("base", "_baseColor"), ("background", "_backgroundColor")] {
                    if let color: Color = scalar(field(controller, property), as: Color.self) { result[key] = NSColor(color) }
                }
                if let blur: Bool = scalar(field(controller, "_backgroundBlurEnabled"), as: Bool.self) { result["blur"] = blur }
                if let dark: Bool = scalar(field(controller, "_isDarkMode"), as: Bool.self) { result["dark"] = dark }
            }
            return Unmanaged.passRetained(result as NSDictionary).toOpaque()
        }
        guard let next = field(root, "content") else { return nil }; root = next
    }
    return nil
}

@_cdecl("WidgetifyInvokeSettings") public func openSettings(_ pointer: UnsafeMutableRawPointer) -> Bool {
    let root = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    func find(_ view: NSView) -> Bool {
        if String(reflecting: Swift.type(of: view)) == "Widgetify.RightClickView",
           let action = field(view, "action") as? () -> Void { action(); return true }
        for child in view.subviews { if find(child) { return true } }; return false
    }
    return find(root)
}

// Attach to the native content surface, inside its monochrome processing
// hierarchy. Never replace/reparent the window's root or reproduce its backdrop.
func nativeWidgetSurface(_ view: NSView) -> NSView? {
    if NSStringFromClass(type(of: view)) == "Widgetify.WidgetMonochromeHostingView" { return view }
    for child in view.subviews { if let surface = nativeWidgetSurface(child) { return surface } }
    return nil
}
func hideNativeWidgetScrolls(_ view: NSView, excluding presentation: NSView) {
    if view === presentation { return }
    if view is NSScrollView { view.alphaValue = 0; view.isHidden = true; view.setAccessibilityHidden(true); return }
    for child in view.subviews { hideNativeWidgetScrolls(child, excluding: presentation) }
}

// Native controls retain their own events. Inspiration uses window-level tracking
// because its SwiftUI host and the vendor's desktop window suppress native drags.
final class WidgetDragView: NSView {
    var fixed = false
    var positionKey: String? { didSet { if oldValue != positionKey { installMonitor() } } }
    var positionDefaults = UserDefaults.standard
    private var monitor: Any?
    private var start: (pointer: NSPoint, origin: NSPoint)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installMonitor() }
    private func installMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil, positionKey != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            // Once started, keep tracking even when AppKit associates the
            // drag/up event with a different window or with no window.
            guard event.type == .leftMouseDown ? event.window === window : self.start != nil else { return event }
            return self.track(event, pointer: NSEvent.mouseLocation)
        }
    }
    // Separated from event delivery so locked, outside-region and persistence
    // behavior can be tested without synthesizing desktop input.
    func track(_ event: NSEvent, pointer: NSPoint) -> NSEvent? {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, positionKey != nil else { return event }
        if Bundle.main.object(forInfoDictionaryKey: "WidgetifyIntegrationTest") as? Bool == true && [.leftMouseDown, .leftMouseUp].contains(event.type) {
            let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("inspiration-drag-diagnostics.json")
            var trace = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            trace.append(["event": event.type.rawValue, "inside": bounds.contains(convert(event.locationInWindow, from: nil)), "fixed": fixed, "nativeMovable": window.isMovable, "tracking": start != nil, "origin": [window.frame.origin.x, window.frame.origin.y]])
            if let data = try? JSONSerialization.data(withJSONObject: Array(trace.suffix(12))) { try? data.write(to: file, options: .atomic) }
        }
        if fixed { start = nil; return event }
        switch event.type {
        case .leftMouseDown:
            start = nil
            guard !event.modifierFlags.contains(.control), bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
            start = (pointer, window.frame.origin)
            return nil
        case .leftMouseDragged:
            guard let start else { return event }
            window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x, y: start.origin.y + pointer.y - start.pointer.y))
            return nil
        case .leftMouseUp:
            guard start != nil, let positionKey else { return event }
            start = nil
            positionDefaults.set(["x": window.frame.origin.x, "y": window.frame.origin.y], forKey: positionKey)
            positionDefaults.synchronize()
            return nil
        default: return event
        }
    }
    override func mouseDown(with event: NSEvent) {
        if positionKey == nil && !fixed { window?.performDrag(with: event) }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
struct WidgetDragHandle: NSViewRepresentable {
    let fixed: Bool
    var positionKey: String? = nil
    func makeNSView(context: Context) -> WidgetDragView { WidgetDragView() }
    func updateNSView(_ view: WidgetDragView, context: Context) { view.fixed = fixed; view.positionKey = positionKey }
}
func restoreWidgetPosition(_ window: NSWindow, key: String, defaults: UserDefaults = .standard) {
    guard let stored = defaults.dictionary(forKey: key), let x = stored["x"] as? Double, let y = stored["y"] as? Double, x.isFinite, y.isFinite else { return }
    var origin = NSPoint(x: x, y: y)
    let proposed = NSRect(origin: origin, size: window.frame.size)
    if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(proposed) }), let screen = NSScreen.main {
        origin.x = min(max(origin.x, screen.visibleFrame.minX), max(screen.visibleFrame.minX, screen.visibleFrame.maxX - window.frame.width))
        origin.y = min(max(origin.y, screen.visibleFrame.minY), max(screen.visibleFrame.minY, screen.visibleFrame.maxY - window.frame.height))
    }
    window.setFrameOrigin(origin)
}
