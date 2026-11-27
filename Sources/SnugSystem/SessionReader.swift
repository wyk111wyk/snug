// 读各 AI 客户端自己留下的会话数据：每条会话在不在跑、最近一次活动、看没看过。只读，不写；读不到就交回空的。
// 从哪读、怎么判在 SnugCore（SessionSources / SessionActivityRule），这里只管把进程、文件、库读出来
import Darwin
import Foundation
import SnugCore
import SQLite3

public struct SessionReader: Sendable {
    public init() {}

    /// 一个来源的读数。先查「客户端进程在不在」：不在就直接交回 running=false，
    /// 库里留着的「还没结束」不再信（客户端崩了、被强退时最容易残留）
    public func reading(_ source: SessionSource) -> SessionReading {
        guard ProcessList.isRunning(matchingAny: source.processKeywords) else { return SessionReading(running: false) }
        switch source.kind {
        case .sqlite(let path, let query):
            return SessionReading(running: true, sessions: sqliteSessions(path: path, query: query))
        case .newestFile(let root, let prefix, let suffix, let depth):
            // 只有修改时间可读：当作一条无名会话，按时间判
            guard let last = newestFile(root: root, prefix: prefix, suffix: suffix, depth: depth) else {
                return SessionReading(running: true)
            }
            let state = SessionActivityRule.state(busy: nil, lastActivity: last, lastViewed: nil, now: Date())
            return SessionReading(running: true, sessions: [SessionEntry(title: "", activity: state)])
        }
    }

    /// 只读打开库、跑一句查询：一行一条会话，列依次是
    /// 会话名 / 在跑？(0-1) / 最近活动（毫秒） / 最后查看（毫秒，可 NULL） / 近 2 分钟新消息数（可 NULL）
    private func sqliteSessions(path: String, query: String) -> [SessionEntry] {
        let file = (path as NSString).expandingTildeInPath
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        // 客户端正在写的时候等一小会儿，别把它锁住
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        let now = Date()
        var entries: [SessionEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let title = text(statement, 0) ?? ""
            let busy: Bool? = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1) != 0
            let last = milliseconds(statement, 2).map { Date(timeIntervalSince1970: $0 / 1000) }
            let viewed = milliseconds(statement, 3).map { Date(timeIntervalSince1970: $0 / 1000) }
            let fresh: Int = {
                let value = sqlite3_column_type(statement, 4) == SQLITE_NULL ? -1 : sqlite3_column_int64(statement, 4)
                return Int(value)
            }()
            let state = SessionActivityRule.state(busy: busy, lastActivity: last, lastViewed: viewed,
                                                  freshMessages: fresh, now: now)
            guard state != .unknown else { continue }        // 看过了、或太久没动静：不在列表里占位置
            entries.append(SessionEntry(title: title, activity: state))
        }
        return entries
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_count(statement) > column, let raw = sqlite3_column_text(statement, column) else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func milliseconds(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_count(statement) > column, sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, column)
        return value > 0 ? Double(value) : nil
    }

    /// 沿着名字最大的子目录往下走（日期目录 YYYY/MM/DD 正好按时间排），最后一层里取匹配文件的最新修改时间
    private func newestFile(root: String, prefix: String, suffix: String, depth: Int) -> Date? {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        for _ in 0..<depth {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? []
            let subdirectories = entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let last = subdirectories.last else { break }
            directory = last
        }
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == suffix }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}

/// 进程在不在：按名字里的关键词匹配（客户端的主程序、Helper、CLI 名字各不相同，用一组词一起认）。
/// 只读 proc_listallpids + proc_name，不需要辅助功能权限
public enum ProcessList {
    /// 有任何一个进程的名字包含 keywords 里的某个词（都按小写比）就交回 true
    public static func isRunning(matchingAny keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        let wanted = keywords.map { $0.lowercased() }
        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        guard count > 0 else { return false }
        for index in 0..<count where pids[index] > 0 {
            var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            guard proc_name(pids[index], &buffer, UInt32(buffer.count)) > 0 else { continue }
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
            if wanted.contains(where: name.contains) { return true }
        }
        return false
    }
}
