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
    if mirror.displayStyle == .class && [".WaterController", ".DocumentController", ".DisplayController"].contains(where: { name.hasSuffix($0) }) { return value }
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
