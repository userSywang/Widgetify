import AppKit
import SwiftUI
import ObjectiveC
import Combine

struct InspirationEntry: Codable, Identifiable, Equatable {
    struct Addition: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var text: String
        var createdAt = Date()
    }
    var id = UUID().uuidString
    var text: String
    var context: String = ""
    var tag: String = ""
    var createdAt = Date()
    var additions: [Addition] = []
    var archived = false
    var deletedAt: Date? = nil
    var status: String? = nil
    var priority: String? = nil
    var notionDetails: String? = nil
}
struct InspirationDraft: Codable, Equatable {
    var text = ""
    var tag = ""
}
private struct InspirationDocument: Codable {
    var version = 1
    var entries: [InspirationEntry]
    var draft = InspirationDraft()
    var selectedID: String?
    var supplementDrafts: [String: String]? = nil
}

final class InspirationStore: ObservableObject {
    @Published private(set) var entries: [InspirationEntry] = []
    @Published var draft = InspirationDraft() { didSet { if ready { persistDraft() } } }
    @Published var supplementDrafts: [String: String] = [:] { didSet { if ready { persistDraft() } } }
    @Published private(set) var selectedID: String?
    @Published private(set) var message = ""
    @Published private(set) var readOnly = false
    @Published private(set) var canUndoArchive = false
    private let file: URL
    private var ready = false
    private var lastArchivedID: String?
    private var undoAddedID: String?
    var current: InspirationEntry? { active.first { $0.id == selectedID } ?? active.first }
    var active: [InspirationEntry] { entries.filter { !$0.archived && $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt } }
    var archived: [InspirationEntry] { entries.filter { $0.archived && $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt } }
    init(directory: URL, seed: [InspirationEntry]) {
        file = directory.appendingPathComponent("ideas-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let document = try JSONDecoder().decode(InspirationDocument.self, from: Data(contentsOf: file))
                guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                entries = document.entries; draft = document.draft; selectedID = document.selectedID; supplementDrafts = document.supplementDrafts ?? [:]
            } catch { readOnly = true; message = "记录暂时无法读取，已保留原文件。" }
        } else {
            entries = seed; selectedID = seed.first?.id
            do { try write(entries, draft: draft, selected: selectedID) }
            catch { readOnly = true; message = "暂时无法保存记录，请检查本地存储。" }
        }
        ready = true
    }
    private func write(_ values: [InspirationEntry], draft: InspirationDraft, selected: String?, supplements: [String: String]? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        let document = InspirationDocument(entries: values, draft: draft, selectedID: selected, supplementDrafts: supplements ?? supplementDrafts)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    @discardableResult private func commit(_ values: [InspirationEntry], draft nextDraft: InspirationDraft, selected: String?, supplements: [String: String]? = nil) -> Bool {
        guard !readOnly else { return false }
        do {
            try write(values, draft: nextDraft, selected: selected, supplements: supplements)
            ready = false; entries = values; draft = nextDraft; selectedID = selected; if let supplements { supplementDrafts = supplements }; ready = true
            message = ""; return true
        } catch { message = "没有保存成功，输入仍保留，请重试。"; return false }
    }
    private func persistDraft() {
        guard !readOnly else { return }
        do { try write(entries, draft: draft, selected: selectedID) }
        catch { message = "草稿暂存失败，输入仍保留。" }
    }
    @discardableResult func add() -> Bool {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { message = "先记下一点想法。"; return false }
        let entry = InspirationEntry(text: text, tag: draft.tag.trimmingCharacters(in: .whitespacesAndNewlines))
        guard commit([entry] + entries, draft: InspirationDraft(), selected: entry.id) else { return false }
        undoAddedID = entry.id; message = "已存下"; return true
    }
    @discardableResult func append(_ text: String, to id: String, category: String? = nil) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { message = "先写下新的补充。"; return false }
        var next = entries; next[index].additions.append(.init(text: value))
        if let category { next[index].tag = category.trimmingCharacters(in: .whitespacesAndNewlines) }
        var supplements = supplementDrafts; supplements.removeValue(forKey: id)
        guard commit(next, draft: draft, selected: id, supplements: supplements) else { return false }
        message = "已补充"; return true
    }
    var deleted: [InspirationEntry] { entries.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! } }
    @discardableResult func select(_ id: String) -> Bool {
        guard entries.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        return commit(entries, draft: draft, selected: id)
    }
    @discardableResult func delete(_ id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        var next = entries; next[index].deletedAt = Date()
        let nextSelection = selectedID == id ? active.first { $0.id != id }?.id : selectedID
        guard commit(next, draft: draft, selected: nextSelection) else { return false }
        message = "已删除，恢复请到 Notion 垃圾箱"; return true
    }
    func restoreDeleted(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { return }
        var next = entries; next[index].deletedAt = nil
        if commit(next, draft: draft, selected: id) { message = "已恢复" }
    }
    func next() {
        guard !active.isEmpty else { return }
        let index = active.firstIndex { $0.id == current?.id } ?? -1
        select(active[(index + 1) % active.count].id)
    }
    @discardableResult func archive(_ id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var next = entries; next[index].archived = true; next[index].status = "归档"
        let selected = next.first { !$0.archived && $0.id != id }?.id
        guard commit(next, draft: draft, selected: selected) else { return false }
        lastArchivedID = id; canUndoArchive = true; message = "已归档"; return true
    }
    func restore(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var next = entries; next[index].archived = false; next[index].status = "未开始"
        if commit(next, draft: draft, selected: id) { lastArchivedID = nil; canUndoArchive = false; message = "已恢复" }
    }
    func undoArchive() { if let id = lastArchivedID { restore(id) } }
    func undoAdd() {
        guard let id = undoAddedID, let entry = entries.first(where: { $0.id == id }), entry.additions.isEmpty else { return }
        if commit(entries.filter { $0.id != id }, draft: .init(text: entry.text, tag: entry.tag), selected: active.first { $0.id != id }?.id) { undoAddedID = nil; message = "已撤销，内容回到草稿" }
    }
    @discardableResult func edit(_ id: String, text: String, category: String, status: String, priority: String, details: String? = nil, expected: InspirationEntry? = nil) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let expected, entries[index] != expected { message = "这条记录已在另一端更新，暂未覆盖；当前输入仍保留。"; return false }
        var next = entries; next[index].text = text; next[index].tag = category; next[index].status = status; next[index].priority = priority
        if let details { next[index].notionDetails = details }
        next[index].archived = status == "归档"
        return commit(next, draft: draft, selected: id)
    }
    @discardableResult func applyRemote(_ update: NotionIncoming) -> Bool {
        guard !readOnly else { return false }
        let current = entries.first(where: { $0.id == update.id })
        if current == update.value { return true }
        guard current == update.expected else { return false }
        do {
            let directory = file.deletingLastPathComponent().appendingPathComponent("SyncHistory")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = directory.appendingPathComponent(UUID().uuidString + ".json")
            try Data(contentsOf: file).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } catch { message = "远端更新备份失败，暂未覆盖本地记录。"; return false }
        var next = entries; next.removeAll { $0.id == update.id }; next.append(update.value)
        return commit(next, draft: draft, selected: selectedID)
    }
    var canUndoAdd: Bool { message == "已存下" && undoAddedID != nil }
    func clearMessage() { if !readOnly { message = "" } }
}

private let inspirationPositionKey = "custom.inspiration.position.v1"

private struct InspirationRoute: Identifiable {
    enum Kind { case capture, expand(String), settings, history }
    let kind: Kind
    let id = UUID()
}
private final class InspirationModel: ObservableObject {
    let store: InspirationStore
    weak var window: NSWindow?
    @Published var ink = NSColor.white
    @Published var accent = NSColor.systemBlue
    @Published var fixed = false
    @Published var route: InspirationRoute?
    @Published var historyBusy = false
    @Published var historyMessage = ""
    @Published var revisions: [InspirationRevision] = []
    @Published var revisionText = ""
    @Published var selectedRevision: String?
    private var notionObservation: AnyCancellable?
    private var remoteObservation: AnyCancellable?
    private var applyingRemote = false
    let notion: InspirationNotion
    let history: InspirationHistory
    private let historyQueue = DispatchQueue(label: "local.inspiration.history", qos: .utility)
    func saveHistory() {
        guard !historyBusy, !store.readOnly else { return }
        historyBusy = true; historyMessage = "正在保存本地历史…"
        let entries = store.entries
        historyQueue.async { [self] in
            do {
                let changed = try history.save(entries)
                let values = try history.revisions()
                DispatchQueue.main.async { self.historyBusy = false; self.revisions = values; self.historyMessage = changed ? "已保存到本地 Git" : "已是最新，无需重复保存" }
            } catch {
                let diagnostic = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("inspiration-history-error.txt")
                try? Data(String(describing: error).utf8).write(to: diagnostic, options: .atomic)
                DispatchQueue.main.async { self.historyBusy = false; self.historyMessage = "历史保存失败，本地灵感仍保留，可重试。" } }
        }
    }
    func loadHistory() {
        guard !historyBusy else { return }
        historyBusy = true
        historyQueue.async { [self] in
            do {
                let values = try history.revisions()
                let text = try values.first.map { try history.text(at: $0.id) } ?? ""
                DispatchQueue.main.async { self.historyBusy = false; self.revisions = values; self.selectedRevision = values.first?.id; self.revisionText = text }
            } catch { DispatchQueue.main.async { self.historyBusy = false; self.historyMessage = "暂时无法读取历史，本地灵感不受影响。" } }
        }
    }
    func showRevision(_ revision: InspirationRevision) {
        guard !historyBusy else { return }; historyBusy = true
        historyQueue.async { [self] in
            do { let text = try history.text(at: revision.id)
                DispatchQueue.main.async { self.historyBusy = false; self.selectedRevision = revision.id; self.revisionText = text }
            } catch { DispatchQueue.main.async { self.historyBusy = false; self.historyMessage = "这次历史暂时无法读取。" } }
        }
    }
    init(window: NSWindow) {
        self.window = window
        let preview = Bundle.main.object(forInfoDictionaryKey: "WidgetifyStylePreview") as? Bool == true
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(preview ? "InspirationPreview" : "Inspiration", isDirectory: true)
        let seed = preview ? Bundle.main.url(forResource: "InspirationSample", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([InspirationEntry].self, from: $0) } ?? [] : []
        store = InspirationStore(directory: directory, seed: seed)
        notion = InspirationNotion(directory: directory)
        history = InspirationHistory(directory: directory.appendingPathComponent("LocalHistory", isDirectory: true))
        remoteObservation = notion.$incoming.sink { [weak self] updates in
            guard let self else { return }
            for update in updates {
                self.applyingRemote = true
                let applied = self.store.applyRemote(update)
                self.applyingRemote = false
                self.notion.acknowledge(update.id, applied: applied)
            }
        }
        notionObservation = store.$entries.dropFirst().removeDuplicates().sink { [weak self] entries in
            guard let self, !self.applyingRemote else { return }; self.notion.localChanged(entries)
        }
        notion.attach(store.entries)
    }
    func refresh(_ theme: NSDictionary) {
        if let value = theme["fixed"] as? Bool, fixed != value { fixed = value }
        if let color = theme["base"] as? NSColor, !ink.isEqual(color) { ink = color }
        if let color = theme["accent"] as? NSColor, !accent.isEqual(color) { accent = color }
    }
    var dark: Bool {
        guard let color = ink.usingColorSpace(.sRGB) else { return true }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent > 0.6
    }
}
private struct InspirationActionStyle: ButtonStyle {
    var primary = false
    var accent = Color.accentColor
    var fontSize: CGFloat = 13
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: fontSize, weight: .medium))
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .foregroundColor(primary ? .white : .primary)
            .background {
                if primary { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent) }
                else { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.ultraThinMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(primary ? 0 : 0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
private struct InspirationEditorBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 13.0, *) { content.scrollContentBackground(.hidden) } else { content }
    }
}
private struct InspirationEditor: View {
    @ObservedObject var store: InspirationStore
    @ObservedObject var model: InspirationModel
    @State private var notionCategory = ""
    @State private var editingOriginal = false
    @State private var originalText = ""
    @State private var status = "未开始"
    @State private var priority = "中优先级"
    @State private var detailsText = ""
    @State private var editingBase: InspirationEntry?
    let entry: InspirationEntry?
    private var category: Binding<String> { entry == nil ? $store.draft.tag : $notionCategory }
    private var addition: Binding<String> {
        Binding(get: { entry.map { store.supplementDrafts[$0.id] ?? "" } ?? "" }, set: { value in if let entry { store.supplementDrafts[entry.id] = value } })
    }
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry == nil ? "记一条灵感" : "展开思路").font(.system(size: 14, weight: .semibold))
                Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain).accessibilityLabel("关闭编辑")
            }
            if let entry {
                HStack {
                    Button(editingOriginal ? "继续补充" : "修改原文") {
                        if !editingOriginal, let fresh = store.entries.first(where: { $0.id == entry.id }) { editingBase = fresh; originalText = fresh.text; detailsText = fresh.notionDetails ?? ""; status = fresh.status ?? "未开始"; priority = fresh.priority ?? "中优先级"; notionCategory = fresh.tag }
                        editingOriginal.toggle()
                    }.buttonStyle(.plain).font(.system(size: 12))
                    Spacer()
                    Text("\(status) · \(priority)").font(.system(size: 10)).foregroundColor(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.text).font(.system(size: 13)).textSelection(.enabled)
                        if let details = entry.notionDetails, !details.isEmpty, details != entry.context, details != ([entry.context] + entry.additions.map { InspirationNotion.stamp($0.createdAt) + "\n" + $0.text }).filter({ !$0.isEmpty }).joined(separator: "\n\n") { Text("详情：" + details).font(.system(size: 12)).foregroundColor(.secondary) }
                        if !entry.context.isEmpty { Text("当时想到：" + entry.context).font(.system(size: 12)).foregroundColor(.secondary) }
                        ForEach(entry.additions) { item in
                            Text(item.createdAt, style: .date).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(item.text).font(.system(size: 12)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            }
            ZStack(alignment: .topLeading) {
                if (entry == nil ? store.draft.text : (editingOriginal ? originalText : addition.wrappedValue)).isEmpty {
                    Text(entry == nil ? "记下刚想到的…" : "现在想到的补充…").foregroundColor(.secondary).padding(.horizontal, 5).padding(.vertical, 7).allowsHitTesting(false)
                }
                TextEditor(text: entry == nil ? $store.draft.text : (editingOriginal ? $originalText : addition)).modifier(InspirationEditorBackground()).font(.system(size: 13)).focused($focused)
                    .accessibilityLabel(entry == nil ? "灵感内容" : "新的补充").padding(3).opacity((entry == nil ? store.draft.text : addition.wrappedValue).isEmpty ? 0.8 : 1)
            }.frame(height: 110).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            if editingOriginal {
                TextField("Notion 详情", text: $detailsText).font(.system(size: 12)).textFieldStyle(.plain)
                HStack {
                    Picker("状态", selection: $status) { ForEach(["未开始", "进行中", "归档", "已完结"], id: \.self) { Text($0).tag($0) } }
                    Picker("优先级", selection: $priority) { ForEach(["低优先级", "中优先级", "高优先级"], id: \.self) { Text($0).tag($0) } }
                }.font(.system(size: 11))
            }
            HStack {
                InspirationNotionCategory(notion: model.notion, selection: category)
                Spacer()
                Button(entry == nil ? "存下" : "保存") {
                    let selectedCategory = category.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved: Bool
                    if let entry, editingOriginal { saved = store.edit(entry.id, text: originalText, category: selectedCategory, status: status, priority: priority, details: detailsText, expected: editingBase) }
                    else { saved = entry.map { store.append(addition.wrappedValue, to: $0.id, category: selectedCategory) } ?? store.add() }
                    if saved {
                        dismiss()
                    }
                }.buttonStyle(InspirationActionStyle(primary: true, accent: Color(nsColor: model.accent)))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.readOnly || (entry == nil ? store.draft.text : (editingOriginal ? originalText : addition.wrappedValue)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !store.message.isEmpty && !["已存下", "已补充"].contains(store.message) { Text(store.message).font(.system(size: 11)).foregroundColor(.secondary) }
        }.padding(18).frame(width: 300).onAppear { focused = true; notionCategory = entry.map { model.notion.selections[$0.id] ?? $0.tag } ?? ""; originalText = entry?.text ?? ""; status = entry?.status ?? "未开始"; priority = entry?.priority ?? "中优先级"; detailsText = entry?.notionDetails ?? ""; editingBase = entry }
    }
}
private struct InspirationNotionCategory: View {
    @ObservedObject var notion: InspirationNotion
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 6) {
            TextField("分类（输入或选择）", text: $selection)
                .font(.system(size: 12)).textFieldStyle(.plain)
                .accessibilityLabel("灵感分类，可输入新分类")
            Menu {
                ForEach(notion.categories, id: \.self) { name in Button(name) { selection = name } }
            } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(notion.categories.isEmpty).accessibilityLabel("选择已有分类")
        }.frame(minWidth: 0, maxWidth: .infinity).frame(height: 22)
    }
}
private struct InspirationNotionSettings: View {
    @ObservedObject var notion: InspirationNotion
    let entries: [InspirationEntry]
    @State private var token = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Notion").font(.system(size: 13, weight: .medium)); Spacer(); Toggle("同步", isOn: Binding(get: { notion.enabled }, set: { notion.setEnabled($0) })).toggleStyle(.switch).labelsHidden().accessibilityLabel("Notion 同步") }
            Text("思考随想 · 创意收集数据库").font(.system(size: 12)).foregroundColor(.secondary)
            SecureField("连接密钥", text: $token).textFieldStyle(.roundedBorder)
            HStack {
                Button("保存连接") { notion.connect(token: token); token = "" }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notion.busy)
                Button("刷新分类") { notion.refreshCategories() }.disabled(notion.busy)
            }
            HStack {
                Button("同步已有灵感") { for entry in entries where !entry.archived && entry.deletedAt == nil { notion.enqueue(entry, manual: true) } }.disabled(!notion.enabled || notion.busy)
                Button("重试") { notion.retry() }.disabled(!notion.enabled || notion.busy)
            }
            Text(notion.busy ? "正在同步…" : notion.message).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
            if notion.pendingCount > 0 { Text("待同步 \(notion.pendingCount) 条").font(.system(size: 11)).foregroundColor(.secondary) }
            ForEach(notion.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text("两端都有修改：" + String(conflict.local.text.prefix(30))).font(.system(size: 11))
                    Text("本地：\n" + NotionConflict.summary(conflict.local)).font(.system(size: 11)).textSelection(.enabled)
                    Text("Notion：\n" + NotionConflict.summary(conflict.remote)).font(.system(size: 11)).textSelection(.enabled)
                    HStack { Button("采用 Notion") { notion.resolve(conflict.id, useRemote: true) }; Button("保留本地") { notion.resolve(conflict.id, useRemote: false) } }
                }
            }
            Text("双向同步。删除后请到 Notion 垃圾箱恢复。").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}
private struct InspirationNotionStatus: View {
    @ObservedObject var notion: InspirationNotion
    var body: some View {
        if notion.enabled { Label(notion.busy ? "正在同步…" : notion.message, systemImage: "icloud").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).help(notion.message).padding(.top, 5) }
    }
}
private struct InspirationSettings: View {
    @ObservedObject var model: InspirationModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("灵感设置").font(.system(size: 14, weight: .semibold))
            HStack { Text("背景与模糊"); Spacer(); Text("跟随全局").foregroundColor(.secondary) }
            Text("沿用原组件的经典、液态玻璃和单色风格。").font(.system(size: 12)).foregroundColor(.secondary)
            Divider()
            Button("全局外观设置…") {
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let item = menu.items.first(where: { ($0.title.contains("Preferences") || $0.title.contains("偏好设置")) && $0.action != nil }), let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }
            Divider()
            if Bundle.main.object(forInfoDictionaryKey: "WidgetifyInspirationEnabled") as? Bool == true {
                Button("隐藏灵感组件") {
                    model.route = nil; UserDefaults.standard.set(true, forKey: "custom.inspiration.hidden")
                    DispatchQueue.main.async { model.window?.orderOut(nil) }
                }
                Text("可从应用菜单的“灵感组件”重新显示。").font(.system(size: 11)).foregroundColor(.secondary)
            }
            InspirationNotionSettings(notion: model.notion, entries: model.store.entries)
            Divider()
            Text("本地保存").font(.system(size: 13, weight: .medium))
            Text("输入自动暂存。点击保存到 Git，保留当前全部灵感和补充的历史版本。").font(.system(size: 12)).foregroundColor(.secondary)
            HStack {
                Button("保存到 Git") { model.saveHistory() }.disabled(model.historyBusy || model.store.readOnly)
                Button("查看历史") { model.route = .init(kind: .history) }.disabled(model.historyBusy)
            }
            if !model.historyMessage.isEmpty { Text(model.historyMessage).font(.system(size: 11)).foregroundColor(.secondary) }
            Text("独立私人仓库，仅保存在这台电脑。与软件源码分开，不连接远端仓库。").font(.system(size: 11)).foregroundColor(.secondary)
        }.font(.system(size: 13)).padding(18) }.frame(width: 326, height: 530)
    }
}
private struct InspirationHistoryView: View {
    @ObservedObject var model: InspirationModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("私人 Git 历史").font(.system(size: 14, weight: .semibold)); Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭历史")
            }
            if model.historyBusy { ProgressView().controlSize(.small) }
            if model.revisions.isEmpty {
                Text("还没有历史版本。先在组件菜单中选择“保存到 Git”。").font(.system(size: 12)).foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.revisions) { revision in
                            Button { model.showRevision(revision) } label: {
                                HStack {
                                    Image(systemName: model.selectedRevision == revision.id ? "checkmark.circle.fill" : "circle")
                                    Text(revision.date, style: .date); Text(revision.date, style: .time); Spacer(); Text(String(revision.id.prefix(7)))
                                }.font(.system(size: 12)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.historyBusy)
                        }
                    }
                }.frame(maxHeight: 100)
                Divider()
                ScrollView { Text(model.revisionText).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 190)
            }
            if !model.historyMessage.isEmpty { Text(model.historyMessage).font(.system(size: 11)).foregroundColor(.secondary) }
            HStack {
                Text("独立私人仓库 · 仅此电脑").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                Button("打开保存目录") { NSWorkspace.shared.open(model.history.directory) }.disabled(model.revisions.isEmpty)
            }
        }.padding(18).frame(width: 390).onAppear { model.loadHistory() }
    }
}
private struct InspirationCard: View {
    @ObservedObject var model: InspirationModel
    @ObservedObject var store: InspirationStore
    @State private var mode = "回顾"
    var ink: Color { Color(nsColor: model.ink) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("灵感").font(.system(size: 17, weight: .semibold)).background(WidgetDragHandle(fixed: model.fixed, positionKey: inspirationPositionKey).accessibilityHidden(true)).help("拖动以移动组件")
                Menu { ForEach(["回顾", "全部灵感", "已归档"], id: \.self) { value in Button(value) { mode = value } } } label: { Text(mode).font(.system(size: 14)) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("灵感视图")
                WidgetDragHandle(fixed: model.fixed, positionKey: inspirationPositionKey).frame(maxWidth: .infinity).frame(height: 28).accessibilityHidden(true).help("拖动以移动组件")
                Button("记一条") { model.route = .init(kind: .capture) }.buttonStyle(InspirationActionStyle()).fixedSize().disabled(store.readOnly)
                Menu {
                    if mode == "回顾", let entry = store.current { Button("归档这条灵感") { _ = store.archive(entry.id) }; Button("删除这条灵感") { _ = store.delete(entry.id) } }
                    if store.canUndoArchive { Button("撤销上次归档") { store.undoArchive() } }
                    Button("查看已归档") { mode = "已归档" }
                    Divider()
                    Button(model.historyBusy ? "正在保存历史…" : "保存到 Git") { model.saveHistory() }.disabled(model.historyBusy || store.readOnly)
                    Button("查看本地历史…") { model.route = .init(kind: .history) }.disabled(model.historyBusy)
                    Divider(); Button("灵感设置…") { model.route = .init(kind: .settings) }
                } label: { Image(systemName: "ellipsis").frame(width: 16) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("灵感更多操作")
            }.frame(height: 28)
            Divider().overlay(ink.opacity(0.1)).padding(.top, 10).padding(.bottom, 12)
            if mode == "回顾", let entry = store.current {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(metadata(entry)).font(.system(size: 13)).foregroundColor(ink.opacity(0.7)).padding(.bottom, 14)
                        Text(entry.text).font(.system(size: 24, weight: .semibold)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        if let latest = entry.additions.last {
                            Text("新的补充：" + latest.text).font(.system(size: 14)).lineSpacing(3).foregroundColor(ink.opacity(0.66)).padding(.top, 14)
                        } else if !entry.context.isEmpty {
                            Text("当时想到：" + entry.context).font(.system(size: 14)).lineSpacing(3).foregroundColor(ink.opacity(0.66)).padding(.top, 14)
                        } else if let details = entry.notionDetails, !details.isEmpty {
                            Text(details).font(.system(size: 14)).lineSpacing(3).foregroundColor(ink.opacity(0.66)).padding(.top, 14)
                        }
                        Divider().overlay(ink.opacity(0.1)).padding(.top, 16).padding(.bottom, 12)
                        Button { model.route = .init(kind: .expand(entry.id)) } label: { Text("这一条，现在有了新想法吗…").font(.system(size: 13)).foregroundColor(ink.opacity(0.4)).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading) }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button("下一条") { store.next() }.buttonStyle(InspirationActionStyle(fontSize: 16, horizontalPadding: 16, verticalPadding: 7))
                    Button("展开思路") { model.route = .init(kind: .expand(entry.id)) }.buttonStyle(InspirationActionStyle(primary: true, accent: Color(nsColor: model.accent), fontSize: 16, horizontalPadding: 16, verticalPadding: 7))
                }.padding(.top, 12)
            } else if mode != "回顾" {
                list(mode == "已归档" ? store.archived : store.active, archived: mode == "已归档")
            } else {
                VStack(spacing: 10) { Image(systemName: "lightbulb").font(.system(size: 25, weight: .light)); Text("先记下一条灵感").font(.system(size: 16, weight: .medium)); Text("一句没想完整的话也可以。").font(.system(size: 12)).foregroundColor(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            InspirationNotionStatus(notion: model.notion)
            if !model.historyMessage.isEmpty { Text(model.historyMessage).font(.system(size: 10)).foregroundColor(ink.opacity(0.75)).lineLimit(2).padding(.top, 5) }
            if !store.message.isEmpty {
                HStack(spacing: 6) {
                    Text(store.message)
                    if store.canUndoAdd { Button("撤销") { store.undoAdd() }.buttonStyle(.plain) }
                    if store.canUndoArchive { Button("撤销") { store.undoArchive() }.buttonStyle(.plain) }
                }.font(.system(size: 10)).foregroundColor(ink.opacity(0.75)).padding(.top, 5)
            }
        }.padding(22).foregroundColor(ink).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { dragMargin.frame(height: 16) }
            .overlay(alignment: .bottom) { dragMargin.frame(height: 16) }
            .overlay(alignment: .leading) { dragMargin.frame(width: 14) }
            .overlay(alignment: .trailing) { dragMargin.frame(width: 14) }
            .environment(\.colorScheme, model.dark ? .dark : .light)
            .onChange(of: store.message) { value in
                if ["已存下", "已补充", "已归档", "已恢复"].contains(value) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if store.message == value { store.clearMessage() } }
                }
            }
            .popover(item: $model.route, arrowEdge: .trailing) { route in
                Group {
                    switch route.kind {
                    case .capture: InspirationEditor(store: store, model: model, entry: nil)
                    case .expand(let id):
                        if let entry = store.entries.first(where: { $0.id == id }) { InspirationEditor(store: store, model: model, entry: entry) }
                    case .settings: InspirationSettings(model: model)
                    case .history: InspirationHistoryView(model: model)
                    }
                }.environment(\.colorScheme, model.dark ? .dark : .light)
            }
    }
    var dragMargin: some View {
        WidgetDragHandle(fixed: model.fixed, positionKey: inspirationPositionKey).accessibilityHidden(true).help("拖动标题或空白边缘移动组件")
    }
    func metadata(_ entry: InspirationEntry) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日"
        return formatter.string(from: entry.createdAt) + (entry.tag.isEmpty ? "" : " · #" + entry.tag)
    }
    func list(_ entries: [InspirationEntry], archived: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty { Text(archived ? "还没有归档灵感" : "还没有灵感").font(.system(size: 13)).foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            _ = store.select(entry.id); model.route = .init(kind: .expand(entry.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.text).font(.system(size: 13)).lineLimit(2)
                                Text(metadata(entry)).font(.system(size: 11)).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("展开灵感：" + entry.text)
                        if archived { Button("取消归档") { store.restore(entry.id) }.buttonStyle(.borderless).font(.system(size: 11)) }
                        Button { _ = store.delete(entry.id) } label: { Image(systemName: "trash").font(.system(size: 12)).frame(width: 24, height: 24) }.buttonStyle(.plain).help("删除这条灵感，恢复请到 Notion 垃圾箱").accessibilityLabel("删除灵感：" + entry.text)
                    }
                    Divider()
                }
            }
        }
    }

}
private final class InspirationHostingView: NSHostingView<InspirationCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) ?? (frame.contains(point) ? self : nil) }
}
private final class InspirationAttachment: NSObject {
    weak var source: NSView?
    weak var surface: NSView?
    let model: InspirationModel
    let presentation: InspirationHostingView
    init(source: NSView, surface: NSView, window: NSWindow, theme: NSDictionary) {
        self.source = source; self.surface = surface; model = InspirationModel(window: window); model.refresh(theme)
        presentation = InspirationHostingView(rootView: InspirationCard(model: model, store: model.store))
        super.init(); restoreWidgetPosition(window, key: inspirationPositionKey); presentation.frame = surface.bounds; presentation.autoresizingMask = [.width, .height]
        surface.addSubview(presentation, positioned: .above, relativeTo: nil); hideNativeWidgetScrolls(source, excluding: presentation)
    }
    func refresh(_ theme: NSDictionary) {
        guard let source, let surface else { return }; model.refresh(theme); presentation.frame = surface.bounds
        if presentation.superview !== surface { surface.addSubview(presentation, positioned: .above, relativeTo: nil) }
        hideNativeWidgetScrolls(source, excluding: presentation)
    }
}
private var inspirationAttachmentKey: UInt8 = 0
@_cdecl("WidgetifyUpdateInspirationPreview") public func updateInspirationPreview(_ windowPointer: UnsafeMutableRawPointer, _ contextPointer: UnsafeMutableRawPointer) {
    let preview = Bundle.main.object(forInfoDictionaryKey: "WidgetifyStylePreview") as? Bool == true
    let enabled = Bundle.main.object(forInfoDictionaryKey: "WidgetifyInspirationEnabled") as? Bool == true
    guard enabled || (preview && Bundle.main.bundleIdentifier?.hasPrefix("local.widgetify.stylepreview.inspiration.") == true) else { return }
    let window = Unmanaged<NSWindow>.fromOpaque(windowPointer).takeUnretainedValue()
    let theme = Unmanaged<NSDictionary>.fromOpaque(contextPointer).takeUnretainedValue()
    guard let source = window.contentView else { return }
    if let existing = objc_getAssociatedObject(source, &inspirationAttachmentKey) as? InspirationAttachment { existing.refresh(theme); return }
    guard let surface = nativeWidgetSurface(source) else { return }
    objc_setAssociatedObject(source, &inspirationAttachmentKey, InspirationAttachment(source: source, surface: surface, window: window, theme: theme), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}
@_cdecl("WidgetifyShowInspirationSettings") public func showInspirationSettings(_ pointer: UnsafeMutableRawPointer) {
    let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
    guard let source = window.contentView, let attachment = objc_getAssociatedObject(source, &inspirationAttachmentKey) as? InspirationAttachment else { return }
    attachment.model.route = .init(kind: .settings)
}
@_cdecl("WidgetifyExportInspirationPreview") public func exportInspirationPreview(_ pointer: UnsafeMutableRawPointer) -> Bool {
    let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
    guard let source = window.contentView, let attachment = objc_getAssociatedObject(source, &inspirationAttachmentKey) as? InspirationAttachment,
          let surface = attachment.surface, let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return false }
    surface.cacheDisplay(in: surface.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("inspiration-preview.png")
    do { try png.write(to: file, options: .atomic); return true } catch { return false }
}
