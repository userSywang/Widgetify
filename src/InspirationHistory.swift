import Foundation

struct InspirationRevision: Identifiable {
    let id: String
    let date: Date
    let title: String
}

/// A dedicated local repository. Never operates on the software checkout or a user-selected repository.
final class InspirationHistory {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "InspirationGit") ?? URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=灵感本地记录", "-c", "user.email=inspiration@localhost"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HistoryError.commandFailed(String(decoding: data.prefix(2000), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }
    enum HistoryError: Error { case commandFailed(String), invalidRevision, invalidRepository }
    private func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(".inspiration-local-history")
        if !fm.fileExists(atPath: marker.path) {
            // Never adopt an unrelated repository or overwrite an existing directory.
            guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { throw HistoryError.invalidRepository }
            try Data("Inspiration local history v1\n".utf8).write(to: marker, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for name in ["records.json", "灵感.md", ".inspiration-local-history"] {
            let path = directory.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        }
        if !fm.fileExists(atPath: directory.appendingPathComponent(".git").path) { _ = try git(["init", "--quiet", "--template="]) }
        let root = try git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw HistoryError.invalidRepository }
    }
    /// Returns false when the committed notes are unchanged; drafts and selection are intentionally excluded.
    @discardableResult func save(_ entries: [InspirationEntry]) throws -> Bool {
        try prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries.sorted { $0.id < $1.id }).write(to: directory.appendingPathComponent("records.json"), options: .atomic)
        try Data(Self.markdown(entries).utf8).write(to: directory.appendingPathComponent("灵感.md"), options: .atomic)
        for name in ["records.json", "灵感.md", ".inspiration-local-history"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        _ = try git(["add", "--", ".inspiration-local-history", "records.json", "灵感.md"])
        let changes = try git(["diff", "--cached", "--name-only", "--", "records.json", "灵感.md"])
        guard !changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        _ = try git(["commit", "--quiet", "-m", "保存灵感 · \(entries.filter { !$0.archived && $0.deletedAt == nil }.count) 条记录"])
        return true
    }
    func revisions() throws -> [InspirationRevision] {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) else { return [] }
        try prepare()
        if try git(["rev-parse", "--verify", "--quiet", "HEAD"]).isEmpty { return [] }
        return try git(["log", "-30", "--format=%H%x09%ct%x09%s"]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3, let seconds = Double(fields[1]) else { return nil }
            return .init(id: String(fields[0]), date: Date(timeIntervalSince1970: seconds), title: String(fields[2]))
        }
    }
    func text(at revision: String) throws -> String {
        guard revision.count == 40, revision.allSatisfy({ $0.isHexDigit }) else { throw HistoryError.invalidRevision }
        try prepare()
        return try git(["show", "\(revision):灵感.md"])
    }
    static func markdown(_ entries: [InspirationEntry]) -> String {
        let date = ISO8601DateFormatter()
        return "# 灵感记录\n\n" + entries.sorted { $0.createdAt > $1.createdAt }.map { entry in
            var result = "## " + String(entry.text.split(whereSeparator: \.isNewline).first ?? "灵感" ).prefix(70) + "\n\n"
            result += "记录时间：\(date.string(from: entry.createdAt))\n\n"
            if !entry.tag.isEmpty { result += "标签：#\(entry.tag)\n\n" }
            result += "状态：\(entry.deletedAt != nil ? "已删除（在 Notion 恢复）" : (entry.archived ? "已归档" : "未归档"))\n\n\(entry.text)\n\n"
            if !entry.context.isEmpty { result += "当时想到：\(entry.context)\n\n" }
            for addition in entry.additions { result += "### 补充 · \(date.string(from: addition.createdAt))\n\n\(addition.text)\n\n" }
            return result + "---\n\n"
        }.joined()
    }
}
