import Foundation
import Combine

final class NotionServer {
    var pages: [String:[String:Any]] = [:]
    var contents: [String:[[String:Any]]] = [:]
    var offline = false
    var denied = false
    var omitted: Set<String> = []
    func create(_ title: String) -> String {
        let id = UUID().uuidString
        pages[id] = ["id":id,"in_trash":false,"properties":["创意":["title":InspirationNotion.rich(title)],"分类":["select":["name":"职业生涯"]],"状态":["status":["name":"未开始"]],"优秀级":["select":["name":"中优先级"]],"日期":["date":["start":"2026-11-18"]],"详情":["rich_text":[]]]]
        var block = InspirationNotion.paragraph(title); block["id"] = UUID().uuidString; contents[id] = [block]
        return id
    }
    func property(_ page: String, _ name: String, _ value: Any) {
        var p = pages[page]!["properties"] as! [String:Any];p[name] = value;pages[page]!["properties"] = p
    }
    func title(_ page:String) -> String { InspirationNotion.plain(["type":"paragraph","paragraph":["rich_text":(pages[page]!["properties"] as! [String:[String:Any]])["创意"]!["title"]!]]) }
    func call(_ method:String, _ path:String, _ body:[String:Any]?) throws -> [String:Any] {
        if offline { throw NotionSyncError.network }; if denied { throw NotionSyncError.response(403) }
        if path.hasPrefix("data_sources/") && method == "GET" {
            return ["properties":["创意":["type":"title"],"日期":["type":"date"],"详情":["type":"rich_text"],"优秀级":["type":"select"],"状态":["type":"status"],"Widgetify同步编号":["type":"rich_text"],"分类":["select":["options":[["name":"职业生涯"]]]]]]
        }
        if path.hasSuffix("/query") {
            let filter = body?["filter"] as? [String:Any]
            let values = pages.values.filter { p in
                let id = p["id"] as! String
                if p["in_trash"] as? Bool == true || omitted.contains(id) { return false }
                guard let filter else { return true }
                if filter["property"] as? String == "Widgetify同步编号" { return InspirationNotion.identity(p) == (filter["rich_text"] as? [String:String])?["equals"] }
                return title(id) == (filter["title"] as? [String:String])?["equals"]
            }
            return ["results":Array(values),"has_more":false]
        }
        if path == "pages" {
            let id = create("placeholder"); pages[id]!["properties"] = body!["properties"]
            contents[id] = (body!["children"] as! [[String:Any]]).map { var b=$0;b["id"]=UUID().uuidString;return b };return pages[id]!
        }
        if path.hasPrefix("pages/") {
            let id = String(path.dropFirst(6));guard pages[id] != nil else { throw NotionSyncError.response(404) }
            if let props = body?["properties"] as? [String:Any] { for (key,value) in props { property(id,key,value) } }
            if let trash = body?["in_trash"] as? Bool { pages[id]!["in_trash"] = trash }
            return pages[id]!
        }
        if path.hasPrefix("blocks/") {
            let id = String(path.dropFirst(7)).components(separatedBy:"/")[0]
            if path.contains("/children") {
                if let blocks = body?["children"] as? [[String:Any]] { contents[id,default:[]] += blocks.map { var b=$0;b["id"]=UUID().uuidString;return b } }
                return ["results":(contents[id] ?? []).filter { $0["in_trash"] as? Bool != true },"has_more":false]
            }
            for page in contents.keys {
                if let index = contents[page]!.firstIndex(where: { $0["id"] as? String == id }) {
                    for (key,value) in body ?? [:] { contents[page]![index][key] = value };return contents[page]![index]
                }
            }
            throw NotionSyncError.response(404)
        }
        fatalError("Unexpected request")
    }
}
@main struct NotionBidirectionalTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let server = NotionServer();let remoteID = server.create("Notion 新建")
        let store = InspirationStore(directory:directory,seed:[])
        let engine = InspirationNotion(directory:directory,transport:server.call,automatic:false)
        var applying = false
        let remoteObservation = engine.$incoming.sink { changes in
            for change in changes { applying = true; let ok = store.applyRemote(change); applying = false; engine.acknowledge(change.id,applied:ok) }
        }
        let localObservation = store.$entries.dropFirst().removeDuplicates().sink { entries in if !applying { engine.localChanged(entries) } }
        func settle() {
            for _ in 0..<12 { engine.waitForPendingOperations(); RunLoop.main.run(until:Date().addingTimeInterval(0.005)) }
        }
        engine.attach(store.entries);engine.setEnabled(true);settle()
        precondition(store.active.count == 1 && store.active[0].text == "Notion 新建")
        let id = store.active[0].id
        server.property(remoteID,"创意",["title":InspirationNotion.rich("Notion 修改标题")]);engine.retry();settle()
        precondition(store.active[0].text == "Notion 修改标题")
        engine.retry();settle();precondition(store.active[0].text == "Notion 修改标题")
        let blockID = server.contents[remoteID]![0]["id"] as! String
        _ = try server.call("PATCH","blocks/"+blockID,["paragraph":["rich_text":InspirationNotion.rich("Notion 修改正文")]])
        engine.retry();settle();precondition(store.active[0].text == "Notion 修改正文")
        precondition(store.edit(id,text:"组件修改原文",category:"新分类",status:"进行中",priority:"高优先级"));settle()
        precondition(server.title(remoteID) == "组件修改原文")
        precondition(InspirationNotion.plain(server.contents[remoteID]![0]) == "组件修改原文")
        precondition(store.append("组件追加",to:id));settle()
        let addition = store.active[0].additions[0]
        let appendedBlock = server.contents[remoteID]!.last!["id"] as! String
        _ = try server.call("PATCH","blocks/"+appendedBlock,["paragraph":["rich_text":InspirationNotion.rich("Notion 修改补充")]])
        engine.retry();settle();precondition(store.active[0].additions.first(where: { $0.id == addition.id })?.text == "Notion 修改补充")
        server.property(remoteID,"详情",["rich_text":InspirationNotion.rich("Notion 修改详情")]);engine.retry();settle()
        precondition(store.active[0].notionDetails == "Notion 修改详情")
        server.pages[remoteID]!["in_trash"] = true;engine.retry();settle();precondition(store.active.isEmpty)
        server.pages[remoteID]!["in_trash"] = false;engine.retry();settle();precondition(store.active.count == 1)
        precondition(store.delete(id));settle();precondition(server.pages[remoteID]!["in_trash"] as? Bool == true)
        server.pages[remoteID]!["in_trash"] = false;engine.retry();settle();precondition(store.active.count == 1)
        server.omitted.insert(remoteID);engine.retry();settle();precondition(store.active.count == 1);server.omitted.removeAll()
        server.offline = true;engine.retry();settle();precondition(store.active.count == 1)
        server.offline = false;server.denied = true;engine.retry();settle();precondition(store.active.count == 1);server.denied = false
        server.offline = true;precondition(store.edit(id,text:"本地离线修改",category:"新分类",status:"进行中",priority:"高优先级"));settle()
        server.property(remoteID,"创意",["title":InspirationNotion.rich("远端同时修改")]);server.offline = false
        engine.retry();settle();precondition(engine.conflicts.count == 1 && store.active[0].text == "本地离线修改")
        engine.resolve(id,useRemote:true);settle();precondition(store.active[0].text == "远端同时修改" && engine.conflicts.isEmpty)
        let before = store.entries[0]
        precondition(!store.edit(id,text:"stale editor",category:"",status:"未开始",priority:"中优先级",expected:InspirationEntry(text:"old version")))
        var staleValue = before; staleValue.text = "stale remote"
        precondition(!store.applyRemote(.init(id:id,expected:InspirationEntry(text:"stale"),value:staleValue)))
        precondition(store.applyRemote(.init(id:id,expected:InspirationEntry(text:"already applied"),value:before)))
        precondition(FileManager.default.fileExists(atPath:directory.appendingPathComponent("SyncConflicts").path))
        store.draft.text = "组件新建验证"; store.draft.tag = "新分类"; precondition(store.add());settle()
        let newID = store.current!.id
        let newState = try JSONDecoder().decode(NotionSyncState.self,from:Data(contentsOf:directory.appendingPathComponent("notion-sync-v1.json")))
        let newPage = newState.bindings[newID]!.pageID!
        precondition(server.title(newPage) == "组件新建验证")
        precondition(InspirationNotion.identity(server.pages[newPage]!) == newID)
        engine.retry();settle();precondition(store.entries.filter { $0.id == newID }.count == 1)
        let archiveServer = NotionServer()
        var legacy = InspirationEntry(text:"旧归档示例");legacy.archived = true
        let archiveEngine = InspirationNotion(directory:directory.appendingPathComponent("legacy-archive"),transport:archiveServer.call,automatic:false)
        archiveEngine.attach([legacy]);archiveEngine.setEnabled(true);archiveEngine.waitForPendingOperations()
        precondition(archiveServer.pages.isEmpty)
        localObservation.cancel()
        precondition(store.edit(newID,text:"退出前本地已保存但尚未入队",category:"新分类",status:"未开始",priority:"中优先级"))
        let restarted = InspirationNotion(directory:directory,transport:server.call,automatic:false)
        let replay = restarted.$incoming.sink { updates in for update in updates { let ok = store.applyRemote(update); restarted.acknowledge(update.id,applied:ok) } }
        restarted.attach(store.entries)
        for _ in 0..<12 { restarted.waitForPendingOperations();RunLoop.main.run(until:Date().addingTimeInterval(0.005)) }
        precondition(server.title(newPage) == "退出前本地已保存但尚未入队")
        _ = replay
        _ = [remoteObservation,localObservation]
        print("PASS: Notion import, title/body edits, local edit/category/status/priority, remote deletion, local deletion, Notion-only restore, missing-query safety, offline/403 safety, conflict preservation/resolution, stale-inbox protection")
    }
}
