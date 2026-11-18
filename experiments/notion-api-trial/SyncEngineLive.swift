import Foundation

// Compiled only into the isolated Notion preview, never a production build.
@_cdecl("WidgetifyRunNotionEnginePreview") public func runNotionEnginePreview() {
    guard Bundle.main.object(forInfoDictionaryKey:"WidgetifyNotionEnginePreview") as? Bool == true else { return }
    DispatchQueue.global(qos:.utility).async {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotionEngineLive")
        let report = root.appendingPathComponent("report.json")
        guard !FileManager.default.fileExists(atPath:report.path) else { return }
        var result: [String:Any] = ["status":"started","pid":ProcessInfo.processInfo.processIdentifier]
        func save() { if let data = try? JSONSerialization.data(withJSONObject:result,options:.prettyPrinted) { try? data.write(to:report,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:report.path) } }
        save()
        do {
            let file = root.appendingPathComponent("token.txt")
            let token = try String(contentsOf:file).trimmingCharacters(in:.whitespacesAndNewlines)
            try FileManager.default.removeItem(at:file)
            try NotionCredential.save(token)
            guard try NotionCredential.read() == token else { throw NotionSyncError.credential }
            result["keychainVerified"] = true; save()
            let engine = InspirationNotion(directory:root,automatic:false)
            engine.setEnabled(true); engine.waitForPendingOperations()
            var entry = InspirationEntry(text:"Widgetify 灵感组件接入验证",context:"正式同步引擎测试，保留供查看。",tag:"API 测试")
            engine.enqueue(entry,category:"职业生涯");engine.waitForPendingOperations()
            for text in ["第一条补充：组件会先保存本地，再同步到 Notion。","第二条补充：后续思路会追加到同一页面。"] {
                entry.additions.append(.init(text:text));engine.enqueue(entry);engine.waitForPendingOperations()
            }
            let state = try JSONDecoder().decode(NotionSyncState.self,from:Data(contentsOf:root.appendingPathComponent("notion-sync-v1.json")))
            guard state.queue.isEmpty, let binding = state.bindings[entry.id], let page = binding.pageID, binding.additions.count == 2 else { throw NotionSyncError.uncertain }
            result["pageID"] = page
            result["pageURL"] = "https://www.notion.so/" + page.replacingOccurrences(of:"-",with:"")
            result["twoAdditionsSynced"] = true
            result["testPageRetained"] = true
            result["status"] = "complete"
        } catch { result["status"] = "failed";result["message"] = (error as? NotionSyncError)?.message ?? "Local preview verification failed" }
        save()
    }
}
