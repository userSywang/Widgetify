import Foundation

final class FakeNotion {
    var pages: [String:[[String:Any]]] = [:]
    var creates = 0, appends = 0
    var offline = false, ambiguousCreate = false, ambiguousAppend = false
    var patches: [[String:Any]] = []
    var createdProperties: [String:Any] = [:]
    func call(_ method:String,_ path:String,_ body:[String:Any]?) throws -> [String:Any] {
        if offline { throw NotionSyncError.network }
        if path.hasPrefix("data_sources/") && method == "GET" {
            return ["properties":["创意":["type":"title"],"日期":["type":"date"],"详情":["type":"rich_text"],"优秀级":["type":"select"],"状态":["type":"status"],"Widgetify同步编号":["type":"rich_text"],"分类":["type":"select","select":["options":[["name":"职业生涯"]]]]]]
        }
        if path.hasSuffix("/query") { return ["results":pages.keys.map { ["id":$0,"properties":createdProperties] as [String:Any] },"has_more":false] }
        if path == "pages" {
            createdProperties = body?["properties"] as? [String:Any] ?? [:]
            creates += 1; pages["page"] = body?["children"] as? [[String:Any]] ?? []
            if ambiguousCreate { ambiguousCreate = false; throw NotionSyncError.network }
            return ["id":"page"]
        }
        if path.hasPrefix("pages/") {
            if method == "PATCH" { patches.append(body?["properties"] as? [String:Any] ?? [:]) }
            return ["id":"page","in_trash":false,"archived":false,"properties":createdProperties]
        }
        if path.hasPrefix("blocks/") {
            if method == "PATCH" {
                appends += 1; pages["page",default:[]] += body?["children"] as? [[String:Any]] ?? []
                if ambiguousAppend { ambiguousAppend = false; throw NotionSyncError.network }
            }
            return ["results":pages["page"] ?? [],"has_more":false]
        }
        fatalError("Unexpected request")
    }
}
@main struct InspirationNotionTests {
    static func main() throws {
        let savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: -8 * 3600)!
        let timestamp = ISO8601DateFormatter().date(from: "2026-11-17T15:15:25Z")!
        precondition(InspirationNotion.stamp(timestamp) == "2026/11/17 23:15:25")
        precondition(InspirationNotion.stamp(timestamp, day: true) == "2026-11-17")
        NSTimeZone.default = savedZone
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let fake = FakeNotion()
        var engine: InspirationNotion? = InspirationNotion(directory:dir,credential:{ "unused" },transport:fake.call,automatic:false)
        var entry = InspirationEntry(text:"不重复的新想法",tag:"产品")
        engine!.enqueue(entry); engine!.waitForPendingOperations(); precondition(fake.creates == 0)
        engine!.setEnabled(true); engine!.waitForPendingOperations()
        fake.offline = true; engine!.enqueue(entry,category:"新分类");engine!.waitForPendingOperations()
        let file = dir.appendingPathComponent("notion-sync-v1.json")
        var state = try JSONDecoder().decode(NotionSyncState.self,from:Data(contentsOf:file));precondition(state.queue.count == 1 && fake.creates == 0)
        fake.offline = false; fake.ambiguousCreate = true
        engine!.retry(); engine!.waitForPendingOperations(); precondition(fake.creates == 1)
        engine = nil
        engine = InspirationNotion(directory:dir,credential:{"unused"},transport:fake.call,automatic:false)
        engine!.retry();engine!.waitForPendingOperations();precondition(fake.creates == 1)
        state = try JSONDecoder().decode(NotionSyncState.self,from:Data(contentsOf:file));precondition(state.queue.isEmpty)
        entry.additions = [.init(text:"相同的补充"),.init(text:"相同的补充")]
        fake.ambiguousAppend = true
        engine!.enqueue(entry);engine!.waitForPendingOperations();precondition(fake.appends == 1)
        engine!.retry();engine!.waitForPendingOperations();precondition(fake.appends == 2)
        engine!.enqueue(entry);engine!.waitForPendingOperations();precondition(fake.appends == 2 && fake.creates == 1)
        entry.tag = "直接输入的新分类"
        engine!.enqueue(entry, category: entry.tag); engine!.waitForPendingOperations()
        precondition((fake.patches.last?["分类"] as? [String:Any])?["select"] is [String:String])
        entry.tag = ""; engine!.enqueue(entry, category: "");engine!.waitForPendingOperations()
        precondition((fake.patches.last?["分类"] as? [String:Any])?["select"] is NSNull)
        precondition(fake.patches.allSatisfy { $0["状态"] == nil && $0["优秀级"] == nil && $0["日期"] == nil })
        fake.offline = true;engine!.enqueue(entry);engine!.waitForPendingOperations();entry.deletedAt = Date();engine!.cancelDeleted([entry]);engine!.waitForPendingOperations()
        state = try JSONDecoder().decode(NotionSyncState.self,from:Data(contentsOf:file));precondition(state.queue.isEmpty)
        engine = nil
        try Data("broken".utf8).write(to:file)
        let protected = InspirationNotion(directory:dir,credential:{"unused"},transport:fake.call,automatic:false)
        protected.setEnabled(true);protected.enqueue(entry);protected.waitForPendingOperations();let protectedText = try String(contentsOf:file);precondition(protectedText == "broken")
        let clean = InspirationNotion.timestampBlock("2026/11/17 23:15:25", page: "page", addition: "addition-id")
        precondition(InspirationNotion.plain(clean) == "2026/11/17 23:15:25")
        precondition(InspirationNotion.markerLines([clean]).contains("Widgetify-addition: addition-id"))
        precondition(fake.pages["page"]!.allSatisfy { !InspirationNotion.plain($0).hasPrefix("Widgetify-ID:") && !InspirationNotion.plain($0).hasPrefix("Widgetify-addition:") })
        let unicode = String(repeating:"💡灵感",count:2000)
        let chunks = InspirationNotion.rich(unicode)
        let texts = chunks.map { ($0["text"] as! [String:String])["content"]! }
        precondition(texts.joined() == unicode && texts.allSatisfy { $0.utf16.count <= 900 })
        print("PASS: opt-in, persistent offline queue, ambiguous create/append recovery, restart deduplication, identical additions, remote property preservation, deletion cancellation, corrupt state protection, Unicode")
    }
}
