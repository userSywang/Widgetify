import Foundation
import Combine
import Security

struct NotionBinding: Codable {
    var pageID: String? = nil
    var legacy = false
    var creating = false
    var additions: Set<String> = []
    var pending: Set<String> = []
    var category = ""
    var baseline: InspirationEntry? = nil
    var originalBlock: String? = nil
    var lastTitle: String? = nil
    var lastOriginalBody: String? = nil
    var lastEdited: String? = nil
}
struct NotionIncoming: Codable, Identifiable {
    var id: String
    var expected: InspirationEntry?
    var value: InspirationEntry
}
struct NotionConflict: Codable, Identifiable {
    var id: String
    var local: InspirationEntry
    var remote: InspirationEntry
    static func summary(_ e: InspirationEntry) -> String {
        ([e.text,e.context,e.notionDetails ?? ""] + e.additions.map { InspirationNotion.stamp($0.createdAt) + "\n" + $0.text } + ["分类：" + e.tag,"状态：" + (e.status ?? "未开始"),"优先级：" + (e.priority ?? "中优先级")]).filter { !$0.isEmpty }.joined(separator:"\n\n")
    }
}
struct NotionSyncState: Codable {
    var local: [String: InspirationEntry]? = nil
    var inbox: [String: NotionIncoming]? = nil
    var conflicts: [String: NotionConflict]? = nil
    var enabled = false
    var sourceID = "1d9bc4ff-b77a-82d8-9add-87ced13f644a"
    var categories: [String] = []
    var categoryByEntry: [String: String] = [:]
    var bindings: [String: NotionBinding] = [:]
    var queue: [String: InspirationEntry] = [:]
}
enum NotionSyncError: Error {
    case credential, storage, response(Int), network, schema, uncertain, conflict, oversized
    var message: String {
        switch self {
        case .credential: return "请导入 Notion 连接密钥。"
        case .storage: return "同步记录无法保存，已暂停发送。"
        case .response(let code): return code == 401 ? "连接密钥无效，请重新导入。" : code == 404 || code == 403 ? "无法访问目标，请检查 Notion 页面授权。" : code == 429 ? "Notion 请求较多，稍后自动重试。" : "Notion 暂未接受请求（\(code)），本地记录已保留。"
        case .schema: return "目标属性与思考随想不一致，已暂停发送。"
        case .uncertain: return "上次发送结果待确认，请稍后重试；不会重复创建。"
        case .conflict: return "发现重复的对应页面，请先在 Notion 核对。"
        case .oversized: return "内容超出单次同步范围，本地记录已保留。"
        case .network: return "连接暂时失败，本地记录已保留，稍后重试。"
        }
    }
}

/// No credential is stored in the document, local Git history or request logs.
enum NotionCredential {
    static var service: String {
        let bundle = Bundle.main.bundleIdentifier ?? "local.widgetify.custom"
        let base = bundle + ".inspiration.notion"
        if bundle.hasPrefix("local.widgetify.stylepreview."), let scope = Bundle.main.object(forInfoDictionaryKey:"WidgetifyNotionCredentialScope") as? String { return base + "." + scope }
        if bundle == "local.widgetify.custom", Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String != "0.2.14" { return base + ".bidirectional-v2" }
        return base
    }
    static func read() throws -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"internal-connection", kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let token = String(data:data,encoding:.utf8), !token.isEmpty else { throw NotionSyncError.credential }
        return token
    }
    static func save(_ token: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"internal-connection"]
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw NotionSyncError.credential }
        } else if status != errSecSuccess { throw NotionSyncError.credential }
    }
}

final class InspirationNotion: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var message = "尚未开启 Notion 同步"
    @Published private(set) var categories: [String] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var selections: [String:String] = [:]
    @Published private(set) var incoming: [NotionIncoming] = []
    @Published private(set) var conflicts: [NotionConflict] = []
    private var attached = false
    private let retryLock = NSLock()
    private var retryScheduled = false
    private var state = NotionSyncState()
    private let file: URL
    private let worker = DispatchQueue(label:"local.inspiration.notion",qos:.utility)
    private var writable = true
    private let credential: () throws -> String
    private let transport: ((String,String,[String:Any]?) throws -> [String:Any])?
    private var timer: Timer?
    init(directory: URL, credential: @escaping () throws -> String = NotionCredential.read, transport: ((String,String,[String:Any]?) throws -> [String:Any])? = nil, automatic: Bool = true) {
        file = directory.appendingPathComponent("notion-sync-v1.json"); self.credential = credential; self.transport = transport
        if FileManager.default.fileExists(atPath:file.path) {
            do { state = try JSONDecoder().decode(NotionSyncState.self,from:Data(contentsOf:file)) }
            catch { writable = false; message = "同步配置无法读取，已保留原文件。" }
        }
        let pendingCredential = directory.appendingPathComponent("notion-connection-import-once")
        if FileManager.default.fileExists(atPath:pendingCredential.path) {
            do {
                let token = try String(contentsOf:pendingCredential,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
                try NotionCredential.save(token)
                try FileManager.default.removeItem(at:pendingCredential)
            } catch { message = "连接密钥导入失败，请在设置中重新保存连接。" }
        }
        enabled = state.enabled; categories = state.categories; pendingCount = state.queue.count; selections = state.categoryByEntry
        if writable && enabled { message = state.queue.isEmpty ? "Notion 已连接" : "等待同步 \(state.queue.count) 条" }
        if automatic {
            timer = Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in self?.retry() }
            retry()
        }
    }
    deinit { timer?.invalidate() }
    private func persist() throws {
        guard writable else { throw NotionSyncError.storage }
        do {
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(state).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        } catch { throw NotionSyncError.storage }
    }
    private func publish(_ text: String? = nil) {
        let deliveries = Array((state.inbox ?? [:]).values), clashes = Array((state.conflicts ?? [:]).values)
        let active = state.enabled, options = state.categories, count = state.queue.count, selected = state.categoryByEntry
        DispatchQueue.main.async { self.enabled = active; self.categories = options; self.pendingCount = count; self.selections = selected; self.incoming = deliveries; self.conflicts = clashes; if let text { self.message = text } }
    }
    func setEnabled(_ value: Bool) {
        worker.async { do { self.state.enabled = value; try self.persist(); self.publish(value ? "Notion 同步已开启" : "Notion 同步已暂停"); if value { self.drain() } } catch { self.publish(NotionSyncError.storage.message) } }
    }
    func connect(token: String) {
        worker.async {
            do { try NotionCredential.save(token.trimmingCharacters(in:.whitespacesAndNewlines)); try self.loadCategories(); self.publish("连接成功，可开启同步") }
            catch { self.publish((error as? NotionSyncError)?.message ?? NotionSyncError.network.message) }
        }
    }
    func refreshCategories() {
        worker.async { do { try self.loadCategories(); self.publish("分类已更新") } catch { self.publish((error as? NotionSyncError)?.message ?? NotionSyncError.network.message) } }
    }
    func enqueue(_ entry: InspirationEntry, category: String? = nil, manual: Bool = false) {
        worker.async {
            guard self.writable, (self.state.enabled || manual), self.attached || entry.deletedAt == nil else { return }
            if let category { self.state.categoryByEntry[entry.id] = category.trimmingCharacters(in:.whitespacesAndNewlines) }
            self.state.queue[entry.id] = entry
            do { try self.persist(); self.publish(); self.drain() } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    func waitForPendingOperations() { worker.sync {} }
    func retry() {
        retryLock.lock(); if retryScheduled { retryLock.unlock(); return }; retryScheduled = true; retryLock.unlock()
        worker.async { defer { self.retryLock.lock(); self.retryScheduled = false; self.retryLock.unlock() }; self.drain() }
    }
    func cancelDeleted(_ entries: [InspirationEntry]) {
        worker.async {
            let active = Set(entries.filter { $0.deletedAt == nil }.map(\.id))
            self.state.queue = self.state.queue.filter { active.contains($0.key) }
            do { try self.persist(); self.publish() } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    func reconcile(_ entries: [InspirationEntry]) {
        worker.async {
            guard self.state.enabled else { return }
            // Only resume known records at startup; existing local records require explicit import.
            for e in entries where e.deletedAt == nil && (self.state.bindings[e.id] != nil || self.state.queue[e.id] != nil) { self.state.queue[e.id] = e }
            do { try self.persist(); self.drain() } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    private func request(_ method: String,_ path: String,_ body: [String:Any]? = nil) throws -> [String:Any] {
        if let transport { return try transport(method,path,body) }
        let token = try credential()
        var req = URLRequest(url:URL(string:"https://api.notion.com/v1/" + path)!); req.httpMethod = method; req.timeoutInterval = 25
        req.setValue("Bearer " + token,forHTTPHeaderField:"Authorization"); req.setValue("2026-03-11",forHTTPHeaderField:"Notion-Version"); req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject:body) }
        let semaphore = DispatchSemaphore(value:0)
        var output: [String:Any]?; var code = 0
        let session = URLSession(configuration:.ephemeral)
        let task = session.dataTask(with:req) { data,response,_ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data { output = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] }
            semaphore.signal()
        }; task.resume()
        guard semaphore.wait(timeout:.now()+30) == .success else { task.cancel(); session.invalidateAndCancel(); throw NotionSyncError.network }
        session.finishTasksAndInvalidate()
        guard code >= 200 && code < 300 else { if code == 0 { throw NotionSyncError.network }; throw NotionSyncError.response(code) }
        guard let output else { throw NotionSyncError.network }
        Thread.sleep(forTimeInterval:0.4)
        return output
    }
    private func loadCategories() throws {
        let schema = try request("GET","data_sources/" + state.sourceID)
        guard let props = schema["properties"] as? [String:[String:Any]], props["创意"]?["type"] as? String == "title", props["日期"]?["type"] as? String == "date", props["详情"]?["type"] as? String == "rich_text", props["优秀级"]?["type"] as? String == "select", props["状态"]?["type"] as? String == "status", let select = props["分类"]?["select"] as? [String:Any], let options = select["options"] as? [[String:Any]] else { throw NotionSyncError.schema }
        if props["Widgetify同步编号"] == nil {
            _ = try request("PATCH","data_sources/" + state.sourceID,["properties":["Widgetify同步编号":["rich_text":[:]]]])
        } else if props["Widgetify同步编号"]?["type"] as? String != "rich_text" { throw NotionSyncError.schema }
        state.categories = options.compactMap { $0["name"] as? String }; try persist(); publish()
    }
    static func rich(_ text: String) -> [[String:Any]] {
        var chunks: [String] = []; var chunk = ""
        for c in text { if chunk.utf16.count + String(c).utf16.count > 900 { chunks.append(chunk); chunk = "" }; chunk.append(c) }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.map { ["type":"text","text":["content":$0]] }
    }
    static func paragraph(_ text:String) -> [String:Any] { ["object":"block","type":"paragraph","paragraph":["rich_text":rich(text)]] }
    static func title(_ entry:InspirationEntry) -> String { String((entry.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "灵感").prefix(100)) }
    static func stamp(_ date:Date, day:Bool = false) -> String { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(identifier:"Asia/Shanghai"); f.dateFormat = day ? "yyyy-MM-dd" : "yyyy/MM/dd HH:mm:ss"; return f.string(from:date) }
    private func blocks(_ page:String) throws -> [[String:Any]] {
        var all: [[String:Any]] = []; var cursor: String?
        repeat {
            let r = try request("GET","blocks/\(page)/children?page_size=100" + (cursor.map { "&start_cursor=" + $0 } ?? ""))
            all += r["results"] as? [[String:Any]] ?? []; cursor = (r["has_more"] as? Bool == true) ? r["next_cursor"] as? String : nil
        } while cursor != nil
        return all
    }
    static func plain(_ block:[String:Any]) -> String {
        let kind = block["type"] as? String ?? ""; let v = block[kind] as? [String:Any] ?? [:]
        return (v["rich_text"] as? [[String:Any]] ?? []).map { $0["plain_text"] as? String ?? (($0["text"] as? [String:Any])?["content"] as? String ?? "") }.joined()
    }
    static func identity(_ page: [String:Any]) -> String {
        let p = (page["properties"] as? [String:[String:Any]])?["Widgetify同步编号"] ?? [:]
        return (p["rich_text"] as? [[String:Any]] ?? []).map { $0["plain_text"] as? String ?? (($0["text"] as? [String:Any])?["content"] as? String ?? "") }.joined()
    }
    static func markerLines(_ blocks: [[String:Any]]) -> [String] {
        var lines = blocks.map(Self.plain)
        for block in blocks {
            let value = block[block["type"] as? String ?? ""] as? [String:Any] ?? [:]
            for part in value["rich_text"] as? [[String:Any]] ?? [] {
                let text = part["text"] as? [String:Any] ?? [:]
                let link = text["link"] as? [String:Any] ?? [:]
                if let url = link["url"] as? String, let fragment = URL(string:url)?.fragment, fragment.hasPrefix("widgetify-addition=") {
                    lines.append("Widgetify-addition: " + String(fragment.dropFirst("widgetify-addition=".count)))
                }
            }
        }
        return lines
    }
    static func timestampBlock(_ text: String, page: String, addition: String) -> [String:Any] {
        var rich = Self.rich(text)
        if !rich.isEmpty { rich[0]["text"] = ["content":text,"link":["url":"https://www.notion.so/" + page.replacingOccurrences(of:"-",with:"") + "#widgetify-addition=" + addition]] }
        return ["object":"block","type":"heading_3","heading_3":["rich_text":rich]]
    }
    private func locate(_ entry:InspirationEntry) throws -> String? {
        for filter in [["property":"Widgetify同步编号","rich_text":["equals":entry.id]], ["property":"创意","title":["equals":Self.title(entry)]]] as [[String:Any]] {
            var cursor: String?; var matches: [String] = []
            repeat {
                var body: [String:Any] = ["filter":filter,"page_size":100]; if let cursor { body["start_cursor"] = cursor }
                let r = try request("POST","data_sources/\(state.sourceID)/query",body)
                for page in r["results"] as? [[String:Any]] ?? [] {
                    guard let id = page["id"] as? String else { continue }
                    let identity = Self.identity(page)
                    if identity == entry.id { matches.append(id); continue }
                    guard identity.isEmpty else { continue }
                    let lines = try blocks(id).map(Self.plain)
                    if lines.contains("Widgetify-ID: " + entry.id) || (!lines.contains(where: { $0.hasPrefix("Widgetify-ID: ") }) && lines.contains(entry.text)) { matches.append(id) }
                }
                cursor = (r["has_more"] as? Bool == true) ? r["next_cursor"] as? String : nil
            } while cursor != nil
            guard matches.count < 2 else { throw NotionSyncError.conflict }
            if let found = matches.first { return found }
        }
        return nil
    }
    private func sync(_ entry:InspirationEntry) throws {
        var binding = state.bindings[entry.id] ?? NotionBinding()
        func checkpoint() throws { state.bindings[entry.id] = binding; try persist() }
        let category = state.categoryByEntry[entry.id] ?? entry.tag
        if binding.pageID == nil {
            if let found = try locate(entry) { binding.pageID = found; binding.legacy = true; try checkpoint() }
            else {
                guard !binding.creating else { throw NotionSyncError.uncertain }
                guard Self.rich(entry.text).count <= 100 else { throw NotionSyncError.oversized }
                binding.creating = true; try checkpoint()
                var props: [String:Any] = ["Widgetify同步编号":["rich_text":Self.rich(entry.id)],"创意":["title":Self.rich(Self.title(entry))],"日期":["date":["start":Self.stamp(entry.createdAt,day:true)]],"优秀级":["select":["name":entry.priority ?? "中优先级"]],"状态":["status":["name":entry.status ?? "未开始"]]]
                if !category.isEmpty { props["分类"] = ["select":["name":category]] }
                var children = [Self.paragraph(entry.text)]
                if !entry.context.isEmpty { children.append(Self.paragraph(entry.context)) }
                guard Self.rich(entry.text).count <= 100 else { throw NotionSyncError.oversized }
                do {
                    let page = try request("POST","pages",["parent":["type":"data_source_id","data_source_id":state.sourceID],"properties":props,"children":children])
                    guard let id = page["id"] as? String else { throw NotionSyncError.network }; binding.pageID = id; binding.category = category; try checkpoint()
                } catch {
                    if case NotionSyncError.response(let code) = error, (400..<500).contains(code), code != 408 { binding.creating = false; try checkpoint() }
                    throw error
                }
            }
        }
        guard let page = binding.pageID else { throw NotionSyncError.uncertain }
        let remote = try request("GET","pages/" + page)
        guard remote["in_trash"] as? Bool != true, remote["archived"] as? Bool != true else { throw NotionSyncError.conflict }
        let identity = Self.identity(remote)
        guard identity.isEmpty || identity == entry.id else { throw NotionSyncError.conflict }
        if identity.isEmpty {
            _ = try request("PATCH","pages/" + page,["properties":["Widgetify同步编号":["rich_text":Self.rich(entry.id)]]])
        }
        let remoteBlocks = try blocks(page)
        if attached, let base = binding.baseline {
            if entry.text != base.text, let id = binding.originalBlock {
                _ = try request("PATCH","blocks/" + id,["paragraph":["rich_text":Self.rich(entry.text)]])
            }
            for addition in entry.additions {
                guard let before = base.additions.first(where: { $0.id == addition.id }), before.text != addition.text else { continue }
                if let index = remoteBlocks.firstIndex(where: { Self.markerLines([$0]).contains("Widgetify-addition: " + addition.id) }), index + 1 < remoteBlocks.count,
                   remoteBlocks[index+1]["type"] as? String == "paragraph", let id = remoteBlocks[index+1]["id"] as? String {
                    _ = try request("PATCH","blocks/" + id,["paragraph":["rich_text":Self.rich(addition.text)]])
                } else { throw NotionSyncError.conflict }
            }
        }
        if attached, let base = binding.baseline {
            let latest = try Self.decodePage(remote,blocks:remoteBlocks,id:entry.id,previous:base,primaryBlock:binding.originalBlock,previousTitle:binding.lastTitle,previousBody:binding.lastOriginalBody)
            if !Self.same(base,latest) && !Self.same(entry,latest) {
                if state.conflicts == nil { state.conflicts = [:] }
                state.conflicts?[entry.id] = .init(id:entry.id,local:entry,remote:latest)
                try persist(); publish("发送前发现 Notion 又有修改，请选择保留版本")
                throw NotionSyncError.conflict
            }
        }
        // Retire only our own legacy marker blocks after their replacement is saved.
        for (index, block) in remoteBlocks.enumerated() {
            let value = Self.plain(block)
            guard let id = block["id"] as? String else { continue }
            if value == "Widgetify-ID: " + entry.id {
                _ = try request("PATCH","blocks/" + id,["in_trash":true])
            } else if value.hasPrefix("Widgetify-addition: "), index >= 2 {
                let additionID = String(value.dropFirst("Widgetify-addition: ".count))
                let heading = remoteBlocks[index-2]
                guard heading["type"] as? String == "heading_3", let headingID = heading["id"] as? String,
                      let addition = entry.additions.first(where: { $0.id == additionID }) else { continue }
                let updated = Self.timestampBlock(Self.stamp(addition.createdAt),page:page,addition:additionID)
                _ = try request("PATCH","blocks/" + headingID,["heading_3":updated["heading_3"]!])
                _ = try request("PATCH","blocks/" + id,["in_trash":true])
            }
        }
        var lines = Self.markerLines(remoteBlocks)
        if binding.legacy {
            var legacyLines = lines
            for addition in entry.additions.sorted(by: { $0.createdAt < $1.createdAt }) {
                if let i = legacyLines.firstIndex(of: addition.text) { binding.additions.insert(addition.id); legacyLines.remove(at: i) }
            }
            binding.legacy = false; try checkpoint()
        }
        for addition in entry.additions.sorted(by:{ $0.createdAt < $1.createdAt }) where !binding.additions.contains(addition.id) {
            let marker = "Widgetify-addition: " + addition.id
            if !lines.contains(marker) {
                guard !binding.pending.contains(addition.id) else { throw NotionSyncError.uncertain }
                guard Self.rich(addition.text).count <= 100 else { throw NotionSyncError.oversized }
                binding.pending.insert(addition.id); try checkpoint()
                do { _ = try request("PATCH","blocks/\(page)/children",["children":[Self.timestampBlock(Self.stamp(addition.createdAt),page:page,addition:addition.id),Self.paragraph(addition.text)]]) }
                catch { if case NotionSyncError.response(let code) = error, (400..<500).contains(code), code != 408 { binding.pending.remove(addition.id); try checkpoint() }; throw error }
                lines.append(marker)
            }
            binding.pending.remove(addition.id); binding.additions.insert(addition.id); try checkpoint()
        }
        var properties: [String:Any] = [:]
        if attached, let base = binding.baseline {
            if entry.text != base.text { properties["创意"] = ["title":Self.rich(Self.title(entry))] }
            if entry.status != base.status, let status = entry.status { properties["状态"] = ["status":["name":status]] }
            if entry.priority != base.priority, let priority = entry.priority { properties["优秀级"] = ["select":["name":priority]] }
        }
        if binding.category != category { properties["分类"] = ["select":category.isEmpty ? NSNull() : ["name":category] as Any] }
        // Append-only body is authoritative; details is a summary and remote status/date stay untouched.
        let details = ([entry.context] + entry.additions.sorted(by:{$0.createdAt < $1.createdAt}).map { Self.stamp($0.createdAt) + "\n" + $0.text }).filter{ !$0.isEmpty }.joined(separator:"\n\n")
        if !attached || binding.baseline == nil {
            properties["详情"] = ["rich_text":Self.rich(String((entry.notionDetails ?? details).prefix(18000)))]
        } else if let value = entry.notionDetails, value != binding.baseline?.notionDetails {
            properties["详情"] = ["rich_text":Self.rich(String(value.prefix(18000)))]
        }
        _ = try request("PATCH","pages/" + page,["properties":properties]); binding.category = category
        if !category.isEmpty && !state.categories.contains(category) { state.categories.append(category) }
        try checkpoint()
    }
    private func drain() {
        if attached { bidirectionalCycle(); return }
        guard writable, state.enabled, !state.queue.isEmpty else { return }
        DispatchQueue.main.async { self.busy = true }; defer { DispatchQueue.main.async { self.busy = false } }
        do {
            try loadCategories()
            for entry in state.queue.values.sorted(by:{$0.createdAt < $1.createdAt}) {
                try sync(entry); state.queue.removeValue(forKey:entry.id); try persist(); publish()
            }
            publish("已同步到 Notion")
        } catch { publish((error as? NotionSyncError)?.message ?? NotionSyncError.network.message) }
    }
}

extension InspirationNotion {
    static func same(_ a: InspirationEntry, _ b: InspirationEntry) -> Bool {
        a.text == b.text && a.context == b.context && (a.notionDetails ?? "") == (b.notionDetails ?? "") && a.tag == b.tag && a.archived == b.archived &&
        (a.deletedAt == nil) == (b.deletedAt == nil) && stamp(a.createdAt,day:true) == stamp(b.createdAt,day:true) &&
        (a.status ?? "未开始") == (b.status ?? "未开始") && (a.priority ?? "中优先级") == (b.priority ?? "中优先级") &&
        a.additions.map { [$0.id,$0.text,stamp($0.createdAt)] } == b.additions.map { [$0.id,$0.text,stamp($0.createdAt)] }
    }
    /// Merge independent append operations, but never guess between edits of the same text.
    static func merged(base: InspirationEntry, local: InspirationEntry, remote: InspirationEntry) -> InspirationEntry? {
        var l = local, r = remote, b = base
        l.additions = []; r.additions = []; b.additions = []
        guard same(l,b), same(r,b) else { return nil }
        var result = remote
        for addition in local.additions {
            if let other = remote.additions.first(where: { $0.id == addition.id }) { if other.text != addition.text { return nil } }
            else if base.additions.contains(where: { $0.id == addition.id }) { return nil }
            else { result.additions.append(addition) }
        }
        // Deleting an existing addition concurrently with an edit is a conflict.
        for before in base.additions where !local.additions.contains(where: { $0.id == before.id }) { return nil }
        result.additions.sort { $0.createdAt < $1.createdAt }; return result
    }
    func attach(_ entries: [InspirationEntry]) {
        worker.async {
            self.attached = true
            let previous = self.state.local ?? [:]
            for entry in entries where self.state.inbox?[entry.id] == nil && self.state.conflicts?[entry.id] == nil {
                let changedSinceWrite = previous[entry.id].map { !Self.same($0,entry) } ?? false
                let unsent = self.state.bindings[entry.id]?.baseline.map { !Self.same($0,entry) } ?? false
                if changedSinceWrite || unsent { self.state.queue[entry.id] = entry; self.state.categoryByEntry[entry.id] = entry.tag }
            }
            self.state.local = Dictionary(uniqueKeysWithValues:entries.map { ($0.id,$0) })
            do { try self.persist(); self.publish(); self.drain() } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    func localChanged(_ entries: [InspirationEntry]) {
        worker.async {
            let previous = self.state.local ?? [:]
            let next = Dictionary(uniqueKeysWithValues:entries.map { ($0.id,$0) })
            for entry in entries where previous[entry.id].map({ !Self.same($0,entry) }) ?? true {
                self.state.queue[entry.id] = entry; self.state.categoryByEntry[entry.id] = entry.tag
            }
            for (id,entry) in previous where next[id] == nil {
                var removed = entry; removed.deletedAt = Date(); self.state.queue[id] = removed
            }
            self.state.local = next
            do { try self.persist(); self.publish(); self.drain() } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    func acknowledge(_ id: String, applied: Bool) {
        worker.async {
            guard let update = self.state.inbox?[id] else { return }
            if applied {
                self.state.local?[id] = update.value
                self.state.bindings[id]?.baseline = update.value
                self.state.categoryByEntry[id] = update.value.tag
                self.state.queue.removeValue(forKey:id)
                self.state.conflicts?.removeValue(forKey:id)
            } else if let local = self.state.local?[id] {
                if self.state.conflicts == nil { self.state.conflicts = [:] }
                self.state.conflicts?[id] = .init(id:id,local:local,remote:update.value)
            }
            self.state.inbox?.removeValue(forKey:id)
            do { try self.persist(); self.publish() } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    func resolve(_ id: String, useRemote: Bool) {
        worker.async {
            guard let conflict = self.state.conflicts?[id] else { return }
            do {
                let dir = self.file.deletingLastPathComponent().appendingPathComponent("SyncConflicts")
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let backup = dir.appendingPathComponent(UUID().uuidString + ".json")
                try JSONEncoder().encode(conflict).write(to:backup,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
                if useRemote { try self.deliver(conflict.remote, expected:self.state.local?[id]) }
                else {
                    self.state.bindings[id]?.baseline = conflict.remote
                    self.state.queue[id] = self.state.local?[id] ?? conflict.local
                    self.state.conflicts?.removeValue(forKey:id); try self.persist(); self.drain()
                }
            } catch { self.publish(NotionSyncError.storage.message) }
        }
    }
    private func deliver(_ remote: InspirationEntry, expected: InspirationEntry?) throws {
        if state.inbox == nil { state.inbox = [:] }
        state.inbox?[remote.id] = .init(id:remote.id,expected:expected,value:remote)
        try persist(); publish()
    }
    private func allPages() throws -> [[String:Any]] {
        var pages: [[String:Any]] = []; var cursor: String?
        repeat {
            var body: [String:Any] = ["page_size":100]; if let cursor { body["start_cursor"] = cursor }
            let response = try request("POST","data_sources/" + state.sourceID + "/query",body)
            guard let values = response["results"] as? [[String:Any]] else { throw NotionSyncError.schema }
            pages += values
            if response["has_more"] as? Bool == true && response["next_cursor"] as? String == nil { throw NotionSyncError.schema }
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil
        return pages
    }
    private func documentBlocks(_ page: String, depth: Int = 0) throws -> [[String:Any]] {
        guard depth < 10 else { throw NotionSyncError.oversized }
        var result: [[String:Any]] = []
        for block in try blocks(page) {
            result.append(block)
            if block["has_children"] as? Bool == true, let id = block["id"] as? String { result += try documentBlocks(id,depth:depth+1) }
            guard result.count < 2000 else { throw NotionSyncError.oversized }
        }
        return result
    }
    static func decodePage(_ page: [String:Any], blocks: [[String:Any]], id: String, previous: InspirationEntry?, primaryBlock: String? = nil, acceptLegacyAdditions: Bool = false, previousTitle: String? = nil, previousBody: String? = nil) throws -> InspirationEntry {
        guard let props = page["properties"] as? [String:[String:Any]], let titleParts = props["创意"]?["title"] as? [[String:Any]] else { throw NotionSyncError.schema }
        func text(_ rich: [[String:Any]]) -> String { rich.map { $0["plain_text"] as? String ?? (($0["text"] as? [String:Any])?["content"] as? String ?? "") }.joined() }
        let title = text(titleParts)
        var entry = previous ?? InspirationEntry(id:id,text:title)
        entry.id = id
        if page["in_trash"] as? Bool == true || page["archived"] as? Bool == true { entry.deletedAt = previous?.deletedAt ?? Date(); return entry }
        entry.deletedAt = nil
        let titleWasChanged = previousTitle.map { $0 != title } ?? (previous.map { Self.title($0) != title && !$0.text.hasPrefix(title) } ?? false)
        let first = blocks.first.map(Self.plain) ?? ""
        let firstIsOriginal = (primaryBlock != nil && blocks.first?["id"] as? String == primaryBlock) || (previous.map { first == $0.text } ?? (!title.isEmpty && first.hasPrefix(title)))
        if titleWasChanged || !firstIsOriginal { entry.text = title }
        else if let previous, let previousBody, previousBody == first { entry.text = previous.text }
        else { entry.text = first }
        var context: [String] = []; var additions: [InspirationEntry.Addition] = []
        var currentID: String?; var currentDate: Date?; var content: [String] = []
        func finishAddition() {
            guard let currentID else { return }
            let before = previous?.additions.first { $0.id == currentID }
            additions.append(.init(id:currentID,text:content.joined(separator:"\n"),createdAt:before?.createdAt ?? currentDate ?? Date()))
        }
        for (index, block) in blocks.enumerated() {
            let plain = Self.plain(block)
            if plain.hasPrefix("Widgetify-ID:") || plain.hasPrefix("Widgetify-addition:") { continue }
            if let marker = Self.markerLines([block]).first(where: { $0.hasPrefix("Widgetify-addition: ") }) {
                finishAddition(); currentID = String(marker.dropFirst("Widgetify-addition: ".count)); content = []
                let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.timeZone = TimeZone(identifier:"Asia/Shanghai");f.dateFormat = "yyyy/MM/dd HH:mm:ss"
                currentDate = f.date(from:String(plain.prefix(19))); continue
            }
            if index == 0 && firstIsOriginal { continue }
            if currentID != nil { content.append(plain) }
            else if acceptLegacyAdditions, let legacy = previous?.additions.first(where: { $0.text == plain }), !additions.contains(where: { $0.id == legacy.id }) { additions.append(legacy) }
            else if !plain.isEmpty { context.append(plain) }
        }
        finishAddition()
        entry.notionDetails = text(props["详情"]?["rich_text"] as? [[String:Any]] ?? [])
        entry.context = context.joined(separator:"\n\n")
        if blocks.isEmpty { entry.context = text(props["详情"]?["rich_text"] as? [[String:Any]] ?? []) }
        entry.additions = additions
        entry.tag = (props["分类"]?["select"] as? [String:Any])?["name"] as? String ?? ""
        entry.status = (props["状态"]?["status"] as? [String:Any])?["name"] as? String ?? "未开始"
        entry.priority = (props["优秀级"]?["select"] as? [String:Any])?["name"] as? String ?? "中优先级"
        entry.archived = entry.status == "归档"
        if let day = (props["日期"]?["date"] as? [String:Any])?["start"] as? String {
            if previous.map({ Self.stamp($0.createdAt,day:true) != String(day.prefix(10)) }) ?? true {
                let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.timeZone = TimeZone(identifier:"Asia/Shanghai");f.dateFormat = "yyyy-MM-dd"
                entry.createdAt = f.date(from:String(day.prefix(10))) ?? entry.createdAt
            }
        }
        return entry
    }
    private func bidirectionalCycle() {
        guard writable, state.enabled else { return }
        DispatchQueue.main.async { self.busy = true }; defer { DispatchQueue.main.async { self.busy = false } }
        do {
            try loadCategories()
            let pages = try allPages()
            var identities = Set<String>()
            for page in pages { let identity = Self.identity(page); if !identity.isEmpty && !identities.insert(identity).inserted { throw NotionSyncError.conflict } }
            var byID: [String:[String:Any]] = [:]
            for page in pages { if let id = page["id"] as? String { byID[id] = page } }
            var unavailable = Set<String>()
            // A missing query result is not a deletion. Fetch that page explicitly.
            for binding in state.bindings.values {
                if let id = binding.pageID, byID[id] == nil { do { byID[id] = try request("GET","pages/" + id) } catch { unavailable.insert(id) } }
            }
            for (pageID,page) in byID {
                var id = state.bindings.first(where: { $0.value.pageID == pageID })?.key
                let remoteID = Self.identity(page)
                let trashed = page["in_trash"] as? Bool == true || page["archived"] as? Bool == true
                let content = trashed ? [] : try documentBlocks(pageID)
                if id == nil && !remoteID.isEmpty && state.local?[remoteID] != nil { id = remoteID }
                if id == nil {
                    let candidates = (state.local ?? [:]).values.filter { e in content.contains(where: { Self.plain($0) == e.text }) && state.bindings[e.id] == nil }
                    if candidates.count == 1 { id = candidates[0].id }
                    else if candidates.count > 1 { throw NotionSyncError.conflict }
                }
                let key = id ?? (remoteID.isEmpty ? "notion-" + pageID : remoteID)
                guard state.inbox?[key] == nil, state.conflicts?[key] == nil else { continue }
                let local = state.local?[key]
                var binding = state.bindings[key] ?? NotionBinding()
                binding.pageID = pageID
                if binding.originalBlock == nil, let first = content.first, first["type"] as? String == "paragraph", (binding.baseline ?? local).map({ Self.plain(first) == $0.text }) ?? false { binding.originalBlock = first["id"] as? String }
                state.bindings[key] = binding
                let remote = try Self.decodePage(page,blocks:content,id:key,previous:binding.baseline ?? local,primaryBlock:binding.originalBlock,acceptLegacyAdditions:binding.baseline == nil,previousTitle:binding.lastTitle,previousBody:binding.lastOriginalBody)
                let propertyValues = page["properties"] as? [String:[String:Any]] ?? [:]
                state.bindings[key]?.lastTitle = (propertyValues["创意"]?["title"] as? [[String:Any]] ?? []).map { $0["plain_text"] as? String ?? (($0["text"] as? [String:Any])?["content"] as? String ?? "") }.joined()
                state.bindings[key]?.lastEdited = page["last_edited_time"] as? String
                state.bindings[key]?.lastOriginalBody = content.first.map(Self.plain)
                if state.bindings[key]?.originalBlock == nil, let first = content.first, first["type"] as? String == "paragraph", Self.plain(first) == remote.text { state.bindings[key]?.originalBlock = first["id"] as? String }
                if let pending = state.queue[key] {
                    // An explicit local deletion wins over remote edits, but remains recoverable in Notion.
                    if pending.deletedAt != nil {
                        if remote.deletedAt == nil { _ = try request("PATCH","pages/" + pageID,["in_trash":true]) }
                        var deleted = pending; deleted.deletedAt = remote.deletedAt ?? pending.deletedAt
                        state.bindings[key]?.baseline = deleted; state.queue.removeValue(forKey:key); try persist(); continue
                    }
                    if remote.deletedAt != nil { try deliver(remote,expected:local); continue }
                    if let base = binding.baseline, !Self.same(base,remote), !Self.same(pending,remote) {
                        if let merged = Self.merged(base:base,local:pending,remote:remote) {
                            state.queue[key] = merged; state.bindings[key]?.baseline = remote
                        } else {
                            if state.conflicts == nil { state.conflicts = [:] }
                            state.conflicts?[key] = .init(id:key,local:pending,remote:remote); try persist(); continue
                        }
                    } else if binding.baseline == nil { state.bindings[key]?.baseline = remote }
                } else if local.map({ !Self.same($0,remote) }) ?? true {
                    try deliver(remote,expected:local)
                } else { state.bindings[key]?.baseline = remote }
            }
            // Only enqueue unmatched local records after a complete successful remote scan.
            for (id,entry) in state.local ?? [:] where entry.deletedAt == nil && !entry.archived && state.bindings[id] == nil && state.inbox?[id] == nil && state.conflicts?[id] == nil { state.queue[id] = entry }
            try persist()
            for (id,entry) in state.queue where state.inbox?[id] == nil && state.conflicts?[id] == nil && !unavailable.contains(state.bindings[id]?.pageID ?? "") {
                if entry.deletedAt != nil && state.bindings[id]?.pageID == nil {
                    var active = entry; active.deletedAt = nil; try sync(active)
                    guard let page = state.bindings[id]?.pageID else { throw NotionSyncError.uncertain }
                    _ = try request("PATCH","pages/" + page,["in_trash":true])
                } else { try sync(entry) }
                state.bindings[id]?.baseline = entry; state.queue.removeValue(forKey:id); try persist()
                if let local = state.local?[id], !Self.same(local,entry) { try deliver(entry,expected:local) }
            }
            publish(!(state.conflicts ?? [:]).isEmpty ? "两端都有修改，请在灵感设置中选择保留版本" : (!unavailable.isEmpty ? "部分 Notion 页面暂不可访问，本地记录保留；其他记录已同步" : "Notion 双向同步已更新"))
        } catch { publish((error as? NotionSyncError)?.message ?? NotionSyncError.network.message) }
    }
}
