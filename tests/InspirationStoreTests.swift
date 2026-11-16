import Foundation
@main struct InspirationStoreTests {
    static func tryResult(_ operation: () throws -> Bool) -> Bool { do { return try operation() } catch { preconditionFailure("Unexpected failure: \(error)") } }
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("inspiration-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("store")
        let seed = InspirationEntry(text: "如果把提醒变成互动？", context: "最初的缘由", tag: "产品", createdAt: Date(timeIntervalSince1970: 1000))
        let store = InspirationStore(directory: directory, seed: [seed])
        precondition(!store.readOnly && store.current?.text == seed.text)
        store.draft.text = "中文草稿\n第二行"
        store.supplementDrafts[seed.id] = "尚未提交的补充"
        let reloaded = InspirationStore(directory: directory, seed: [])
        precondition(reloaded.draft.text == store.draft.text && reloaded.supplementDrafts[seed.id] == "尚未提交的补充")
        store.draft.text = "新增的零散想法"; store.draft.tag = "#设计"
        precondition(store.add())
        let created = store.current!
        precondition(store.draft.text.isEmpty && created.tag == "设计")
        precondition(store.append("继续往下想", to: seed.id))
        precondition(store.current?.context == "最初的缘由" && store.current?.createdAt == seed.createdAt)
        precondition(store.current?.additions.count == 1 && store.supplementDrafts[seed.id] == nil)
        precondition(store.archive(seed.id) && !store.active.contains { $0.id == seed.id })
        store.undoArchive(); precondition(store.active.contains { $0.id == seed.id })
        let durable = InspirationStore(directory: directory, seed: [])
        precondition(durable.entries.count == 2 && durable.entries.first { $0.id == seed.id }?.additions.first?.text == "继续往下想")
        // Failed writes must leave the committed records and input intact.
        store.draft.text = "不能丢失的输入"
        let saved = store.entries
        try fm.moveItem(at: directory, to: fixture.appendingPathComponent("saved"))
        try Data("blocker".utf8).write(to: directory)
        precondition(!store.add() && store.entries == saved && store.draft.text == "不能丢失的输入")
        let corrupt = fixture.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let file = corrupt.appendingPathComponent("ideas-v1.json"), bytes = Data("unreadable original".utf8)
        try bytes.write(to: file)
        let protected = InspirationStore(directory: corrupt, seed: [seed])
        protected.draft.text = "不得覆盖原数据"
        let preserved = try Data(contentsOf: file)
        precondition(protected.readOnly && !protected.add() && preserved == bytes)
        let history = InspirationHistory(directory: fixture.appendingPathComponent("history"))
        precondition(tryResult { try history.save(durable.entries) })
        precondition(!tryResult { try history.save(durable.entries) })
        let privateMode = try fm.attributesOfItem(atPath: history.directory.path)[.posixPermissions] as! NSNumber
        let recordMode = try fm.attributesOfItem(atPath: history.directory.appendingPathComponent("records.json").path)[.posixPermissions] as! NSNumber
        precondition(privateMode.intValue == 0o700 && recordMode.intValue == 0o600)
        let first = try history.revisions()
        precondition(first.count == 1)
        let oldText = try history.text(at: first[0].id)
        precondition(oldText.contains("最初的缘由") && oldText.contains("继续往下想") && !oldText.contains("中文草稿"))
        var edited = durable.entries
        edited[0].additions.append(.init(text: "第二次历史补充"))
        precondition(tryResult { try history.save(edited) })
        let second = try history.revisions()
        precondition(second.count == 2)
        let historical = try history.text(at: first[0].id)
        precondition(historical == oldText && !historical.contains("第二次历史补充"))
        let config = try String(contentsOf: history.directory.appendingPathComponent(".git/config"))
        precondition(!config.contains("remote") && !config.contains("localhost"))
        let primaryDirectory = fixture.appendingPathComponent("primary")
        let primary = InspirationStore(directory: primaryDirectory, seed: edited)
        primary.draft.text = "Git失败也不能丢的草稿"
        let primaryFile = primaryDirectory.appendingPathComponent("ideas-v1.json")
        let primaryBefore = try Data(contentsOf: primaryFile)
        let lock = history.directory.appendingPathComponent(".git/index.lock")
        try Data("locked".utf8).write(to: lock)
        do { _ = try history.save([]); preconditionFailure("Locked history must fail") } catch {}
        let primaryAfter = try Data(contentsOf: primaryFile)
        precondition(primaryAfter == primaryBefore && primary.entries == edited)
        try fm.removeItem(at: lock)
        precondition(!tryResult { try history.save(edited) })
        let unrelated = fixture.appendingPathComponent("unrelated")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated.appendingPathComponent("existing"))
        do { _ = try InspirationHistory(directory: unrelated).save([]); preconditionFailure("Must not adopt unrelated data") } catch {}
        precondition(!fm.fileExists(atPath: unrelated.appendingPathComponent(".git").path))
        do { _ = try history.text(at: "HEAD:other"); preconditionFailure("Must reject revision injection") } catch {}
        let deletionDirectory = fixture.appendingPathComponent("deletions")
        let deletions = InspirationStore(directory: deletionDirectory, seed: durable.entries)
        let chosen = deletions.active.last!
        precondition(deletions.select(chosen.id) && deletions.current?.id == chosen.id)
        let other = deletions.active.first { $0.id != chosen.id }!
        precondition(deletions.delete(other.id) && deletions.current?.id == chosen.id)
        precondition(deletions.deleted.count == 1 && !deletions.active.contains { $0.id == other.id })
        let reopened = InspirationStore(directory: deletionDirectory, seed: [])
        precondition(reopened.deleted.first?.text == other.text)
        reopened.restoreDeleted(other.id)
        precondition(reopened.deleted.isEmpty && reopened.entries.first { $0.id == other.id }?.additions == other.additions)
        precondition(!reopened.select("missing-id") && reopened.current?.id == other.id)
        let preservedRecords = reopened.entries
        try fm.moveItem(at: deletionDirectory, to: fixture.appendingPathComponent("deletions-safe"))
        try Data("blocked".utf8).write(to: deletionDirectory)
        precondition(!reopened.delete(other.id) && reopened.entries == preservedRecords && reopened.deleted.isEmpty)
        print("PASS: exact row selection, deletion preserves other selection, trash survives restart, restore retains additions")
        print("PASS: local Git snapshots, no duplicate commits, old snapshots preserved, no draft leak, no remote, unrelated folder protection")
        print("PASS: draft/restart, Unicode, capture, append preserves origin, archive/undo, failed writes, corrupt data protection")
    }
}
