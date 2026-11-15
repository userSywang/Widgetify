import AppKit

let inspirationComponentID = String(repeating: "d1", count: 16)

/// Adds one native host without editing existing widget dictionaries.
func inspirationLayout(_ data: Data?, screenID: String, screen: NSRect) throws -> Data {
    var widgets: [[String: Any]] = []
    if let data {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        widgets = values
    }
    if widgets.contains(where: { $0["id"] as? String == inspirationComponentID }) { return try JSONSerialization.data(withJSONObject: widgets) }
    let width: CGFloat = 344, height: CGFloat = 359
    let safe = screen.insetBy(dx: 24, dy: 48)
    let occupied = widgets.compactMap { widget -> NSRect? in
        guard widget["screenID"] as? String == screenID,
              let parts = widget["winFrame"] as? [[Double]], parts.count == 2, parts.allSatisfy({ $0.count == 2 }) else { return nil }
        return NSRect(x: parts[0][0], y: parts[0][1], width: parts[1][0], height: parts[1][1])
    }
    var origin = NSPoint(x: safe.minX, y: max(safe.minY, safe.maxY - height))
    search: for y in stride(from: max(safe.minY, safe.maxY - height), through: safe.minY, by: -height - 20) {
        for x in stride(from: safe.minX, through: max(safe.minX, safe.maxX - width), by: width + 20) {
            let frame = NSRect(x: x, y: y, width: width, height: height)
            if !occupied.contains(where: { $0.intersects(frame) }) { origin = frame.origin; break search }
        }
    }
    widgets.append([
        "id": inspirationComponentID, "name": "widget_name_shortcuts", "brief": "widget_brief_shortcuts",
        "type": ["shortcuts": [:] as [String: String]], "needPro": false,
        "size": [["large": [:] as [String: String]]], "currentSize": ["large": [:] as [String: String]],
        "winFrame": [[origin.x, origin.y], [width, height]],
        "screenFrame": [[screen.minX, screen.minY], [screen.width, screen.height]], "screenID": screenID,
        "isPined": false, "isFixed": false
    ])
    return try JSONSerialization.data(withJSONObject: widgets)
}

@_cdecl("WidgetifyBootstrapInspiration") public func bootstrapInspiration() {
    guard Bundle.main.object(forInfoDictionaryKey: "WidgetifyInspirationEnabled") as? Bool == true,
          Bundle.main.object(forInfoDictionaryKey: "WidgetifyStylePreview") as? Bool != true else { return }
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "custom.inspiration.bootstrap.v1") || defaults.bool(forKey: "custom.inspiration.addOnLaunch") else { return }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let layout = support.appendingPathComponent("Widgetify/autosaved.widgetlist4")
    do {
        let fm = FileManager.default
        let original = fm.fileExists(atPath: layout.path) ? try Data(contentsOf: layout) : nil
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) else { return }
        let screenID = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
        let next = try inspirationLayout(original, screenID: screenID, screen: CGDisplayBounds(CGMainDisplayID()))
        let backupDirectory = support.appendingPathComponent("Widgetify/InspirationIntegration", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backupDirectory.appendingPathComponent("layout-before-v1.json")
        if let original, !fm.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path) }
        try next.write(to: layout, options: .atomic)
        defaults.set(true, forKey: "custom.inspiration.bootstrap.v1")
        defaults.set(false, forKey: "custom.inspiration.addOnLaunch")
        defaults.set([], forKey: inspirationComponentID)
        defaults.synchronize()
    } catch {
        // Leave the original layout intact. A menu entry can request a retry at next launch.
        defaults.set(true, forKey: "custom.inspiration.addOnLaunch")
    }
}
