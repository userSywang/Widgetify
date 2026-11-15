import AppKit
import SwiftUI

private struct LaunchGroup: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var apps: [String] = []
}
private struct LaunchCategories: Codable, Equatable {
    var groups: [LaunchGroup] = []
    mutating func assign(_ app: String, to group: String?) {
        for i in groups.indices { groups[i].apps.removeAll { $0 == app } }
        if let i = groups.firstIndex(where: { $0.id == group }) { groups[i].apps.append(app) }
    }
}
private func categoryKey(_ id: String) -> String { "custom.component.\(id).launchCategories.v1" }
private func loadCategories(_ id: String) -> LaunchCategories {
    guard let data = UserDefaults.standard.data(forKey: categoryKey(id)), let value = try? JSONDecoder().decode(LaunchCategories.self, from: data) else { return LaunchCategories(groups: [LaunchGroup(id: "default-frequent", name: "常用"), LaunchGroup(id: "default-work", name: "工作"), LaunchGroup(id: "default-development", name: "开发"), LaunchGroup(id: "default-entertainment", name: "娱乐")]) }
    return value
}
private func saveCategories(_ value: LaunchCategories, id: String) {
    if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: categoryKey(id)) }
    NotificationCenter.default.post(name: .init("WidgetifyCategoriesChanged"), object: id)
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
                Text("点击卡片顶部的分类按钮，直接切换应用").font(.system(size: 12, weight: .medium))
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
                Text(notice.isEmpty ? "自动保存。删除分类不删除应用，应用选择和排序保持不变。" : notice).font(.system(size: 11)).foregroundColor(.secondary)
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
    let ordered = ["file:///Applications/Other.app", "file:///Applications/Example.app"]
    precondition(filteredApps(ordered, categories: restored, selected: second) == [ordered[1]])
    precondition(filteredApps(ordered, categories: restored, selected: unassignedLaunchApps) == [ordered[0]])
    precondition(filteredApps(ordered, categories: restored, selected: allLaunchApps) == ordered)
    precondition(filteredApps(ordered, categories: restored, selected: "deleted-category") == ordered)
    precondition(filteredApps([ordered[0]], categories: restored, selected: second).isEmpty)
    state.assign("file:///Applications/Example.app", to: nil)
    precondition(state.groups.allSatisfy { $0.apps.isEmpty })
}

// The compiled host keeps ownership of its controller and settings callbacks.
// A sibling presentation reads its ordered URL list; filtering never edits it.
private let allLaunchApps = "__all__"
private let unassignedLaunchApps = "__unassigned__"
private func filteredApps(_ apps: [String], categories: LaunchCategories, selected: String) -> [String] {
    if selected == allLaunchApps { return apps }
    if selected == unassignedLaunchApps { return apps.filter { app in !categories.groups.contains { $0.apps.contains(app) } } }
    guard let group = categories.groups.first(where: { $0.id == selected }) else { return apps }
    return apps.filter { group.apps.contains($0) }
}
private final class InlineLaunchModel: ObservableObject {
    let id: String
    weak var window: NSWindow?
    @Published var categories: LaunchCategories
    @Published var apps: [String] = []
    @Published var compact = true
    @Published var selected: String
    @Published var ink = NSColor.white
    @Published var fixed = false
    private var observer: NSObjectProtocol?
    init(id: String, window: NSWindow) {
        self.id = id; self.window = window; categories = loadCategories(id)
        selected = UserDefaults.standard.string(forKey: "custom.component.\(id).launchSelection.v1") ?? allLaunchApps
        observer = NotificationCenter.default.addObserver(forName: .init("WidgetifyCategoriesChanged"), object: nil, queue: .main) { [weak self] _ in self?.refresh(nil) }
        refresh(nil)
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    var visibleApps: [String] { filteredApps(apps, categories: categories, selected: selected) }
    var title: String { selected == allLaunchApps ? "全部应用" : selected == unassignedLaunchApps ? "未分类" : categories.groups.first { $0.id == selected }?.name ?? "全部应用" }
    func select(_ value: String) {
        selected = value
        UserDefaults.standard.set(value, forKey: "custom.component.\(id).launchSelection.v1")
    }
    func refresh(_ theme: NSDictionary?) {
        let next = loadCategories(id)
        if next != categories { categories = next }
        let ordered = UserDefaults.standard.stringArray(forKey: id) ?? []
        if apps != ordered { apps = ordered }
        let isCompact = UserDefaults.standard.object(forKey: id + "_compactIconsEnabled") as? Bool ?? false
        if compact != isCompact { compact = isCompact }
        if selected != allLaunchApps && selected != unassignedLaunchApps && !categories.groups.contains(where: { $0.id == selected }) { select(allLaunchApps) }
        if let color = theme?["base"] as? NSColor, !ink.isEqual(color) { ink = color }
        if let value = theme?["fixed"] as? Bool, fixed != value { fixed = value }
    }
    func open(_ value: String) {
        guard apps.contains(value), let url = URL(string: value), url.isFileURL, url.pathExtension == "app" else { return }
        NSWorkspace.shared.open(url)
    }
    func settings() { if let window { _ = invokeOriginalSettings(window.contentView) } }
}
private final class LaunchDragView: NSView {
    var fixed = false
    override func mouseDown(with event: NSEvent) { if !fixed { window?.performDrag(with: event) } }
}
private struct LaunchDragHandle: NSViewRepresentable {
    let fixed: Bool
    func makeNSView(context: Context) -> LaunchDragView { LaunchDragView() }
    func updateNSView(_ view: LaunchDragView, context: Context) { view.fixed = fixed }
}
private struct LaunchIcon: View {
    let url: String
    let compact: Bool
    @State private var hovered = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: URL(string: url)?.path ?? ""))
                    .resizable().interpolation(.high).frame(width: compact ? 32 : 42, height: compact ? 32 : 42)
                    .scaleEffect(hovered ? 1.08 : 1)
                if !compact { Text(appTitle(url)).font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity) }
            }.frame(maxWidth: .infinity).frame(height: compact ? 38 : 64).contentShape(Rectangle())
        }.buttonStyle(.plain).help(appTitle(url)).accessibilityLabel("启动\(appTitle(url))")
            .onHover { hovered = $0 }.animation(.easeOut(duration: 0.15), value: hovered)
    }
}
private struct InlineLaunchCard: View {
    @ObservedObject var model: InlineLaunchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var ink: Color { Color(nsColor: model.ink) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    categoryButton("全部应用", allLaunchApps)
                    Divider()
                    ForEach(model.categories.groups) { group in categoryButton(group.name, group.id) }
                    categoryButton("未分类", unassignedLaunchApps)
                    Divider()
                    Button("管理分类…") { model.settings() }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "square.grid.2x2"); Text(model.title).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).frame(height: 26)
                        .background(ink.opacity(0.09), in: Capsule())
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("切换应用分类：\(model.title)")
                LaunchDragHandle(fixed: model.fixed).frame(maxWidth: .infinity).frame(height: 26).accessibilityHidden(true)
                Text("\(model.visibleApps.count)").font(.system(size: 10)).monospacedDigit().foregroundColor(ink.opacity(0.5)).accessibilityLabel("\(model.visibleApps.count) 个应用")
                Button { model.settings() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 12)).frame(width: 26, height: 26).background(ink.opacity(0.07), in: Circle()) }
                    .buttonStyle(.plain).help("组件设置与分类").accessibilityLabel("组件设置与分类")
            }
            if model.visibleApps.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 21, weight: .light)).foregroundColor(ink.opacity(0.32))
                    Text(model.apps.isEmpty ? "添加常用应用" : "这个分类还没有应用").font(.system(size: 11)).foregroundColor(ink.opacity(0.65))
                    Button("设置分类") { model.settings() }.font(.system(size: 10)).buttonStyle(.plain).foregroundColor(ink.opacity(0.85))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.compact ? 32 : 58), spacing: model.compact ? 14 : 9)], spacing: 8) {
                        ForEach(model.visibleApps, id: \.self) { value in LaunchIcon(url: value, compact: model.compact) { model.open(value) } }
                    }.padding(.top, 1).padding(.bottom, 3)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundColor(ink).frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.selected)
    }
    func categoryButton(_ title: String, _ id: String) -> some View {
        Button { model.select(id) } label: { if model.selected == id { Label(title, systemImage: "checkmark") } else { Text(title) } }
    }
}
// Hide only the native app grid. The host still draws its own background,
// including its shared color, opacity, image and blur implementation.
private func hideOriginalGrid(_ view: NSView) {
    if view is NSScrollView { view.alphaValue = 0; return }
    for child in view.subviews { hideOriginalGrid(child) }
}
private final class InlineLaunchContainer: NSView {
    let source: NSView
    let model: InlineLaunchModel
    let presentation: NSHostingView<InlineLaunchCard>
    init(source: NSView, id: String, window: NSWindow, theme: NSDictionary) {
        self.source = source; model = InlineLaunchModel(id: id, window: window)
        model.refresh(theme); presentation = NSHostingView(rootView: InlineLaunchCard(model: model))
        super.init(frame: source.frame)
        // Keep the native hosting view and controller alive, at the same bounds,
        // for native settings, app picking, size/lock/pin and persistence.
        source.alphaValue = 1
        hideOriginalGrid(source)
        addSubview(source); addSubview(presentation)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); source.frame = bounds; presentation.frame = bounds }
    func refresh(_ theme: NSDictionary) { model.refresh(theme); hideOriginalGrid(source) }
}
@_cdecl("WidgetifyUpdateInlineShortcuts")
public func updateInlineShortcuts(_ windowPointer: UnsafeMutableRawPointer, _ contextPointer: UnsafeMutableRawPointer) {
    let window = Unmanaged<NSWindow>.fromOpaque(windowPointer).takeUnretainedValue()
    let theme = Unmanaged<NSDictionary>.fromOpaque(contextPointer).takeUnretainedValue()
    guard let id = theme["id"] as? String, let source = window.contentView else { return }
    if let container = source as? InlineLaunchContainer { container.refresh(theme); return }
    let container = InlineLaunchContainer(source: source, id: id, window: window, theme: theme)
    window.contentView = container
    container.needsLayout = true; container.layoutSubtreeIfNeeded()
}
