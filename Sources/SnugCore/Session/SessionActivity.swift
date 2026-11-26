// AI 客户端「在不在干活」：各客户端自己会把会话写成本地文件/库，这里只读它们「最近一次活动」的时间，
// 按「最近活动 → 现在」的距离分三态。数据源是一张表（SessionSources.all），加一家只加一条。
// 纯逻辑：读库、读文件在 SnugSystem（SessionReader），这里只定「从哪读、怎么判」
import Foundation

/// 一个 AI 客户端的状态从哪读
public struct SessionSource: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 只读查一个 SQLite 库，取最近一次活动的毫秒时间戳（Unix）
        case sqlite(path: String, query: String)
        /// 日期目录（子目录按名字排，YYYY/MM/DD 正好按时间）里最新那一层下、匹配文件的最新修改时间
        case newestFile(root: String, prefix: String, suffix: String, depth: Int)
    }

    /// 这个来源对应哪个 App（按 bundleID 认，和资源库里的 App 对上）
    public let bundleID: String
    public let kind: Kind

    public init(bundleID: String, kind: Kind) {
        self.bundleID = bundleID
        self.kind = kind
    }
}

/// 一个 AI 客户端此刻的样子
public enum SessionActivity: Equatable, Sendable {
    /// 刚有活动（在干活）
    case working
    /// 有过活动、现在安静了（多半在等你输入）
    case done
    /// 不知道（没这个客户端、读不到、太久没动静）
    case unknown
}

/// 三态的判据
public enum SessionActivityRule {
    /// 最近这么久内有活动就算在干活
    public static let workingWindow: TimeInterval = 8
    /// 安静超过这么久就不标了（早干完了，别一直挂着）
    public static let doneWindow: TimeInterval = 10 * 60

    public static func state(lastActivity: Date?, now: Date) -> SessionActivity {
        guard let last = lastActivity else { return .unknown }
        let quiet = now.timeIntervalSince(last)
        // 时间戳比现在还晚（两边时钟差一点）当作刚有动静，不判成「不知道」
        if quiet < 0 { return .working }
        if quiet <= workingWindow { return .working }
        if quiet <= doneWindow { return .done }
        return .unknown
    }
}

/// 单一数据源：每个 AI 客户端的活动状态从哪读。加一家只在这里加一条
public enum SessionSources {
    public static let all: [SessionSource] = [
        // OpenCode：会话消息表，time_updated 跟着流式实时刷新（11-26 实测：最新一条 updated 就是当前时刻）
        SessionSource(bundleID: "ai.opencode.desktop",
                      kind: .sqlite(path: "~/.local/share/opencode/opencode.db",
                                    query: "SELECT max(time_updated) FROM session_message")),
        // ZCode：同族的表结构（session_entry 与 OpenCode 的 session_message 形状一致）
        SessionSource(bundleID: "dev.zcode.app",
                      kind: .sqlite(path: "~/.zcode/cli/db/db.sqlite",
                                    query: "SELECT max(time_updated) FROM session_entry")),
        // Codex：会话是日期目录下的 rollout-*.jsonl，取最新一个的修改时间。
        // 这台机器上没装 Codex 应用（CLI 跑在别的终端里时，窗口归那个终端 App，认不出是 Codex），
        // 所以这条暂时挂不到任何一行上；真在用 Codex 应用时，把 bundleID 改成它的就行
        SessionSource(bundleID: "com.openai.codex",
                      kind: .newestFile(root: "~/.codex/sessions", prefix: "rollout-", suffix: "jsonl", depth: 3)),
    ]
}
