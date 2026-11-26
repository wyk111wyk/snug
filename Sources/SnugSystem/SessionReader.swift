// 读各 AI 客户端自己留下的会话数据，取「最近一次活动」的时间。只读，不写；读不到就交回 nil。
// 从哪读、怎么判在 SnugCore（SessionSources / SessionActivityRule），这里只管把文件、库读出来
import Foundation
import SnugCore
import SQLite3

public struct SessionReader: Sendable {
    public init() {}

    /// 一个来源最近一次活动的时间；没装、没这个表、文件没有，都返回 nil
    public func lastActivity(_ source: SessionSource) -> Date? {
        switch source.kind {
        case .sqlite(let path, let query): sqliteLastActivity(path: path, query: query)
        case .newestFile(let root, let prefix, let suffix, let depth): newestFile(root: root, prefix: prefix, suffix: suffix, depth: depth)
        }
    }

    /// 只读打开库、跑一句取时间的查询。库不在、表不在、时间戳为 0 都返回 nil
    private func sqliteLastActivity(path: String, query: String) -> Date? {
        let file = (path as NSString).expandingTildeInPath
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        // 客户端正在写的时候等一小会儿，别把它锁住
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let milliseconds = sqlite3_column_int64(statement, 0)
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
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
