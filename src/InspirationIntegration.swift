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

// Only recover an unambiguous single-display layout. Disconnected multi-display
// layouts remain untouched so reconnecting a display preserves its arrangement.
func recoveredScreenLayout(_ data: Data, screens: [(id: String, frame: CGRect)]) throws -> Data? {
    guard let widgets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
    guard screens.count == 1, !widgets.isEmpty else { return nil }
    let current = screens[0]
    let ids = Set(widgets.compactMap { $0["screenID"] as? String })
    guard ids.count == 1, let previous = ids.first, previous != current.id,
          widgets.allSatisfy({ $0["screenID"] as? String == previous }) else { return nil }
    var result = widgets
    for i in result.indices {
        guard let saved = result[i]["screenFrame"] as? [[Double]], saved.count == 2,
              saved.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isFinite }) }),
              let window = result[i]["winFrame"] as? [[Double]], window.count == 2,
              window.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isFinite }) }) else { throw CocoaError(.fileReadCorruptFile) }
        let oldFrame = CGRect(x: saved[0][0], y: saved[0][1], width: saved[1][0], height: saved[1][1])
        guard oldFrame.width > 0, oldFrame.height > 0, window[1][0] > 0, window[1][1] > 0 else { throw CocoaError(.fileReadCorruptFile) }
        result[i]["screenID"] = current.id
        if oldFrame != current.frame {
            let x = current.frame.minX + (window[0][0] - oldFrame.minX)
            let y = current.frame.minY + (window[0][1] - oldFrame.minY)
            result[i]["winFrame"] = [[min(max(x, current.frame.minX), max(current.frame.minX, current.frame.maxX - window[1][0])), min(max(y, current.frame.minY), max(current.frame.minY, current.frame.maxY - window[1][1]))], window[1]]
            result[i]["screenFrame"] = [[current.frame.minX, current.frame.minY], [current.frame.width, current.frame.height]]
        }
    }
    return try JSONSerialization.data(withJSONObject: result)
}

func recoverStartupScreenBinding() {
    // Active displays only: no NSScreen/AppKit initialization during constructor.
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count == 1 else { return }
    var display: CGDirectDisplayID = 0
    guard CGGetActiveDisplayList(1, &display, &count) == .success, count == 1,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display) else { return }
    let screenID = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let layout = support.appendingPathComponent("Widgetify/autosaved.widgetlist4")
    guard fm.fileExists(atPath: layout.path) else { return }
    do {
        let original = try Data(contentsOf: layout)
        guard let recovered = try recoveredScreenLayout(original, screens: [(screenID, CGDisplayBounds(display))]) else { return }
        let directory = support.appendingPathComponent("Widgetify/ScreenRecovery", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = directory.appendingPathComponent("layout-before-" + UUID().uuidString + ".json")
        try original.write(to: backup, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        // Do not overwrite a concurrent layout edit made during preparation.
        guard try Data(contentsOf: layout) == original else { return }
        try recovered.write(to: layout, options: .atomic)
    } catch {
        NSLog("Widgetify: screen recovery skipped; original layout retained (%@)", String(describing: type(of: error)))
    }
}

@_cdecl("WidgetifyBootstrapInspiration") public func bootstrapInspiration() {
    guard Bundle.main.object(forInfoDictionaryKey: "WidgetifyInspirationEnabled") as? Bool == true,
          Bundle.main.object(forInfoDictionaryKey: "WidgetifyStylePreview") as? Bool != true else { return }
    recoverStartupScreenBinding()
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
