import Foundation
import Combine

private final class BidirectionalLiveHarness {
    let root: URL
    let token: String
    let engine: InspirationNotion
    let store: InspirationStore
    var subscriptions: [AnyCancellable] = []
    var applying = false
    var result: [String:Any] = ["status":"started"]
    init(root: URL, token: String) {
        self.root = root; self.token = token
        store = InspirationStore(directory:root,seed:[])
        engine = InspirationNotion(directory:root,credential:{ token },automatic:false)
        subscriptions.append(engine.$incoming.sink { [weak self] values in
            guard let self else { return }
            for value in values { self.applying = true;let ok = self.store.applyRemote(value);self.applying = false;self.engine.acknowledge(value.id,applied:ok) }
        })
        subscriptions.append(store.$entries.dropFirst().removeDuplicates().sink { [weak self] values in
            guard let self, !self.applying else { return };self.engine.localChanged(values)
        })
        engine.attach(store.entries)
    }
    func save() { if let data = try? JSONSerialization.data(withJSONObject:result,options:.prettyPrinted) { try? data.write(to:root.appendingPathComponent("report.json"),options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("report.json").path) } }
    func api(_ method: String,_ path: String,_ body: [String:Any]? = nil) throws -> [String:Any] {
        var request = URLRequest(url:URL(string:"https://api.notion.com/v1/"+path)!);request.httpMethod = method;request.timeoutInterval = 25
        request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization");request.setValue("2026-03-11",forHTTPHeaderField:"Notion-Version");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject:body) }
        var object: [String:Any]?;var status = 0;let wait = DispatchSemaphore(value:0)
        let task = URLSession.shared.dataTask(with:request) { data,response,_ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data { object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] };wait.signal()
        };task.resume();guard wait.wait(timeout:.now()+30) == .success, (200..<300).contains(status), let object else { task.cancel();throw NotionSyncError.network };return object
    }
    func settle() {
        for _ in 0..<5 { engine.waitForPendingOperations(); DispatchQueue.main.sync {}; engine.waitForPendingOperations() }
    }
    func check(_ value: Bool,_ name: String) throws { result[name] = value;save();if !value { throw NotionSyncError.conflict } }
    func run() {
        do {
            let config = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("config.json"))) as! [String:String]
            let previous = config["resumePageID"]!
            let old = try api("GET","pages/" + previous)
            let oldProps = old["properties"] as! [String:[String:Any]]
            let title = (oldProps["创意"]!["title"] as! [[String:Any]]).map { $0["plain_text"] as? String ?? "" }.joined()
            guard title == "双向验证：Notion 修改" || title == "Widgetify 双向同步验证" else { throw NotionSyncError.conflict }
            let children = try api("GET","blocks/" + previous + "/children?page_size=100")["results"] as! [[String:Any]]
            guard let first = children.first, let block = first["id"] as? String else { throw NotionSyncError.conflict }
            _ = try api("PATCH","blocks/" + block,["paragraph":["rich_text":InspirationNotion.rich("Widgetify 双向同步验证")]])
            let p = try api("PATCH","pages/" + previous,["properties":["创意":["title":InspirationNotion.rich("Widgetify 双向同步验证")],"日期":["date":["start":InspirationNotion.stamp(Date(),day:true)]],"状态":["status":["name":"未开始"]],"优秀级":["select":["name":"中优先级"]]]])
            let page = p["id"] as! String;result["pageID"] = page;save()
            engine.setEnabled(true);settle()
            let id = "notion-" + page
            try check(DispatchQueue.main.sync { store.entries.contains { $0.id == id } },"notionCreationImported")
            _ = try api("PATCH","pages/" + page,["properties":["创意":["title":InspirationNotion.rich("双向验证：Notion 修改")],"分类":["select":["name":"ai"]]]])
            engine.retry();settle()
            try check(DispatchQueue.main.sync { store.entries.first { $0.id == id }?.text == "双向验证：Notion 修改" && store.entries.first { $0.id == id }?.tag == "ai" },"notionEditImported")
            DispatchQueue.main.sync { _ = store.edit(id,text:"双向验证：组件修改",category:"职业生涯",status:"进行中",priority:"高优先级") };settle()
            let updated = try api("GET","pages/"+page);let props = updated["properties"] as! [String:[String:Any]]
            try check((props["状态"]?["status"] as? [String:Any])?["name"] as? String == "进行中","componentEditUploaded")
            _ = try api("PATCH","pages/"+page,["in_trash":true]);engine.retry();settle()
            try check(DispatchQueue.main.sync { store.entries.first { $0.id == id }?.deletedAt != nil },"notionDeleteImported")
            _ = try api("PATCH","pages/"+page,["in_trash":false]);engine.retry();settle()
            try check(DispatchQueue.main.sync { store.entries.first { $0.id == id }?.deletedAt == nil },"notionRestoreImported")
            DispatchQueue.main.sync { _ = store.delete(id) };settle()
            try check(try api("GET","pages/"+page)["in_trash"] as? Bool == true,"componentDeleteUploaded")
            _ = try api("PATCH","pages/"+page,["in_trash":false]);engine.retry();settle()
            try check(DispatchQueue.main.sync { store.entries.first { $0.id == id }?.deletedAt == nil },"secondNotionRestoreImported")
            result["status"] = "complete";result["testPageRetained"] = true
        } catch { result["status"] = "failed";result["message"] = (error as? NotionSyncError)?.message ?? "Live verification failed" }
        save()
    }
}
private var liveHarness: BidirectionalLiveHarness?
@_cdecl("WidgetifyRunNotionEnginePreview") public func runBidirectionalPreview() {
    guard Bundle.main.object(forInfoDictionaryKey:"WidgetifyNotionEnginePreview") as? Bool == true else { return }
    let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotionBidirectionalLiveV3")
    guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("report.json").path) else { return }
    do {
        let tokenFile = root.appendingPathComponent("token.txt")
        let token = try String(contentsOf:tokenFile).trimmingCharacters(in:.whitespacesAndNewlines);try FileManager.default.removeItem(at:tokenFile)
        let harness = BidirectionalLiveHarness(root:root,token:token);liveHarness = harness
        harness.result["pid"] = ProcessInfo.processInfo.processIdentifier;harness.save()
        DispatchQueue.global(qos:.utility).async { harness.run() }
    } catch {}
}
