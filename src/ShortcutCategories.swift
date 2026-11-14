import AppKit
import SwiftUI

private struct LaunchGroup: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var apps: [String] = []
}
private struct LaunchCategories: Codable {
    var groups: [LaunchGroup] = []
    mutating func assign(_ app: String, to group: String?) {
        for i in groups.indices { groups[i].apps.removeAll { $0 == app } }
        if let i = groups.firstIndex(where: { $0.id == group }) { groups[i].apps.append(app) }
    }
}
private func categoryKey(_ id: String) -> String { "custom.component.\(id).launchCategories.v1" }
private func loadCategories(_ id: String) -> LaunchCategories {
    guard let data = UserDefaults.standard.data(forKey: categoryKey(id)), let value = try? JSONDecoder().decode(LaunchCategories.self, from: data) else { return LaunchCategories(groups: [LaunchGroup(name: "常用"), LaunchGroup(name: "工作"), LaunchGroup(name: "开发"), LaunchGroup(name: "娱乐")]) }
    return value
}
private func saveCategories(_ value: LaunchCategories, id: String) {
    if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: categoryKey(id)) }
}
private func appTitle(_ string: String) -> String {
    guard let url = URL(string: string) else { return string }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}
private final class CategoryActions: NSObject {
    let id: String
    weak var window: NSWindow?
    init(_ id: String, window: NSWindow) { self.id = id; self.window = window }
    @objc func open(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let url = URL(string: value), url.isFileURL, url.pathExtension == "app" else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func settings(_ sender: Any?) { if let window { _ = invokeOriginalSettings(window.contentView) } }
}
private func invokeOriginalSettings(_ view: NSView?) -> Bool { guard let view else { return false }; return openSettings(Unmanaged.passUnretained(view).toOpaque()) }
private struct CategorySettings: View {
    let id: String
    @State private var data: LaunchCategories
    @State private var name = ""
    @State private var notice = ""
    init(id: String) { self.id = id; _data = State(initialValue: loadCategories(id)) }
    var apps: [String] { UserDefaults.standard.stringArray(forKey: id) ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("右键卡片，按分类启动应用").font(.system(size: 12, weight: .medium))
                HStack { TextField("新分类名称", text: $name).onSubmit(add); Button("添加", action: add).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(Array(data.groups.enumerated()), id: \.element.id) { index, group in
                    HStack {
                        TextField("分类名称", text: Binding(get: { group.name }, set: { value in if let i = data.groups.firstIndex(where: { $0.id == group.id }) { data.groups[i].name = value; persist() } }))
                        Button { move(group.id, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("上移分类")
                        Button { move(group.id, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == data.groups.count - 1).help("下移分类")
                        Button { data.groups.removeAll { $0.id == group.id }; persist() } label: { Image(systemName: "minus.circle") }.help("删除分类，应用保留在未分类中")
                    }.buttonStyle(.borderless)
                }
                Divider()
                if apps.isEmpty { Text("先在原组件设置中选择应用。").foregroundColor(.secondary) }
                ForEach(apps, id: \.self) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: URL(string: app)?.path ?? "")).resizable().frame(width: 24, height: 24)
                        Text(appTitle(app)).lineLimit(1); Spacer()
                        Picker("\(appTitle(app))的分类", selection: Binding(get: { data.groups.first { $0.apps.contains(app) }?.id ?? "" }, set: { group in data.assign(app, to: group.isEmpty ? nil : group); persist() })) {
                            Text("未分类").tag("")
                            ForEach(data.groups) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 105)
                    }
                }
                Text(notice.isEmpty ? "自动保存。删除分类不删除应用，原网格和原应用排序保持不变。" : notice).font(.system(size: 11)).foregroundColor(.secondary)
            }.font(.system(size: 12)).padding(16)
        }
    }
    func persist() {
        let names = data.groups.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty && $0.count <= 24 }), Set(names).count == names.count else { notice = "名称不能为空、重复或超过 24 字；有效后才保存。"; return }
        for i in data.groups.indices { data.groups[i].name = names[i] }
        notice = ""; saveCategories(data, id: id)
    }
    func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 24, data.groups.count < 20 else { notice = "最多 20 个分类，每个名称不超过 24 字。"; return }
        guard !data.groups.contains(where: { $0.name == value }) else { notice = "已有同名分类。"; return }
        data.groups.append(LaunchGroup(name: value)); name = ""; notice = ""; persist()
    }
    func move(_ id: String, by offset: Int) { guard let i = data.groups.firstIndex(where: { $0.id == id }), data.groups.indices.contains(i + offset) else { return }; data.groups.swapAt(i, i + offset); persist() }
}
@_cdecl("WidgetifyCreateCategorySettings")
public func createCategorySettings(_ identifier: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let id = Unmanaged<NSString>.fromOpaque(identifier).takeUnretainedValue() as String
    let view = NSHostingView(rootView: CategorySettings(id: id)); view.frame = NSRect(x: 0, y: 0, width: 328, height: 450)
    return Unmanaged.passRetained(view).toOpaque()
}
@_cdecl("WidgetifyShowCategoryMenu")
public func showCategoryMenu(_ identifier: UnsafeMutableRawPointer, _ windowPointer: UnsafeMutableRawPointer, _ eventPointer: UnsafeMutableRawPointer) {
    let id = Unmanaged<NSString>.fromOpaque(identifier).takeUnretainedValue() as String
    let window = Unmanaged<NSWindow>.fromOpaque(windowPointer).takeUnretainedValue()
    let event = Unmanaged<NSEvent>.fromOpaque(eventPointer).takeUnretainedValue()
    let actions = CategoryActions(id, window: window), menu = NSMenu()
    let apps = UserDefaults.standard.stringArray(forKey: id) ?? [], categories = loadCategories(id)
    func addApps(_ values: [String], to menu: NSMenu) {
        for value in values { let item = NSMenuItem(title: appTitle(value), action: #selector(CategoryActions.open(_:)), keyEquivalent: ""); item.target = actions; item.representedObject = value
            if let url = URL(string: value) { let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 18, height: 18); item.image = icon }; menu.addItem(item) }
        if values.isEmpty { let empty = NSMenuItem(title: "暂无应用", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty) }
    }
    let all = NSMenuItem(title: "全部应用", action: nil, keyEquivalent: ""), allMenu = NSMenu(); addApps(apps, to: allMenu); all.submenu = allMenu; menu.addItem(all)
    for group in categories.groups { let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: ""), child = NSMenu(); addApps(apps.filter { group.apps.contains($0) }, to: child); item.submenu = child; menu.addItem(item) }
    let unassigned = apps.filter { app in !categories.groups.contains { $0.apps.contains(app) } }
    let other = NSMenuItem(title: "未分类", action: nil, keyEquivalent: ""), child = NSMenu(); addApps(unassigned, to: child); other.submenu = child; menu.addItem(other)
    menu.addItem(.separator()); let settings = NSMenuItem(title: "组件设置与分类…", action: #selector(CategoryActions.settings(_:)), keyEquivalent: ""); settings.target = actions; menu.addItem(settings)
    if let view = window.contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    withExtendedLifetime(actions) {}
}

@_cdecl("WidgetifyTestCategories") public func testCategories() {
    var state = LaunchCategories(groups: [LaunchGroup(name: "工作"), LaunchGroup(name: "开发")])
    let first = state.groups[0].id, second = state.groups[1].id
    state.assign("file:///Applications/Example.app", to: first)
    state.assign("file:///Applications/Example.app", to: second)
    precondition(state.groups[0].apps.isEmpty && state.groups[1].apps.count == 1)
    let restored = try! JSONDecoder().decode(LaunchCategories.self, from: JSONEncoder().encode(state))
    precondition(restored.groups[1].apps == state.groups[1].apps)
    state.assign("file:///Applications/Example.app", to: nil)
    precondition(state.groups.allSatisfy { $0.apps.isEmpty })
}
