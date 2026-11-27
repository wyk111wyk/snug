// AI 客户端「在不在干活」：各客户端自己会把会话写成本地文件/库，这里只读它们「最近一次活动」的时间，
// 按「最近活动 → 现在」的距离分三态。数据源是一张表（SessionSources.all），加一家只加一条。
// 纯逻辑：读库、读文件在 SnugSystem（SessionReader），这里只定「从哪读、怎么判」
import Foundation

/// 一个 AI 客户端的状态从哪读
public struct SessionSource: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 只读查一个 SQLite 库，返回**一行三列**：busy（0/1，NULL 表示它没这么说）、最近一次活动的毫秒时间戳、最后查看的毫秒时间戳
        case sqlite(path: String, query: String)
        /// 日期目录（子目录按名字排，YYYY/MM/DD 正好按时间）里最新那一层下、匹配文件的最新修改时间
        case newestFile(root: String, prefix: String, suffix: String, depth: Int)
    }

    /// 这个来源对应哪个 App（按 bundleID 认，和资源库里的 App 对上）
    public let bundleID: String
    public let kind: Kind
    /// 客户端进程名里带这些词之一（小写、包含匹配）就说明它还活着。**进程不在就一律不标**：
    /// 客户端崩了、被强退时库里会留着最后那条「还没结束」的消息，只看库就会一直显示在干活。
    /// Token Monitor 对 Claude Code 也是这么做的（用它写的 pid 核对进程启动时间）——从不只信文件
    public let processKeywords: [String]

    public init(bundleID: String, kind: Kind, processKeywords: [String]) {
        self.bundleID = bundleID
        self.kind = kind
        self.processKeywords = processKeywords
    }
}

/// 从一个来源读到的原始读数
public struct SessionReading: Equatable, Sendable {
    /// 客户端自己说它此刻还在跑（进程在）
    public var running: Bool
    /// 客户端有没有说自己在忙；nil = 它没这么说（按时间戳判）
    public var busy: Bool?
    /// 最近一次活动
    public var lastActivity: Date?
    /// 客户端记的「最后查看时刻」：比最近一次活动还晚，就说明这一轮的结果已经看过了
    public var lastViewed: Date?
    /// 最近这一轮所在会话的名字（客户端自己有存的话）
    public var sessionTitle: String?

    public init(running: Bool, busy: Bool? = nil, lastActivity: Date? = nil, lastViewed: Date? = nil,
                sessionTitle: String? = nil) {
        self.running = running
        self.busy = busy
        self.lastActivity = lastActivity
        self.lastViewed = lastViewed
        self.sessionTitle = sessionTitle
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

    /// 客户端进程不在：一律不标（库里可能留着「还没结束」的残留，只看库会一直显示在干活）
    public static func state(reading: SessionReading, now: Date) -> SessionActivity {
        guard reading.running else { return .unknown }
        return state(busy: reading.busy, lastActivity: reading.lastActivity, lastViewed: reading.lastViewed, now: now)
    }

    /// 客户端自己说了在忙 / 空闲时以它为准：忙 = 在干活；闲且这一轮确实完了、还没看过 = 已完成；否则不标
    public static func state(busy: Bool?, lastActivity: Date?, lastViewed: Date?, now: Date) -> SessionActivity {
        guard let busy else { return state(lastActivity: lastActivity, lastViewed: lastViewed, now: now) }
        if busy { return .working }
        guard isUnseen(lastActivity: lastActivity, lastViewed: lastViewed, now: now) else { return .unknown }
        return .done
    }

    /// 没有 busy 时按时间戳判
    public static func state(lastActivity: Date?, lastViewed: Date? = nil, now: Date) -> SessionActivity {
        guard let last = lastActivity else { return .unknown }
        let quiet = now.timeIntervalSince(last)
        // 时间戳比现在还晚（两边时钟差一点）当作刚有动静，不判成「不知道」
        if quiet < 0 { return .working }
        if quiet <= workingWindow { return .working }
        guard isUnseen(lastActivity: last, lastViewed: lastViewed, now: now) else { return .unknown }
        return .done
    }

    /// 这一轮的结果还没看过：有「最后查看」时刻时，它得早于最近一次活动；读不到查看时刻就当没看过
    private static func isUnseen(lastActivity: Date?, lastViewed: Date?, now: Date) -> Bool {
        guard let last = lastActivity, now.timeIntervalSince(last) <= doneWindow else { return false }
        guard let viewed = lastViewed else { return true }
        return viewed < last
    }
}

/// 单一数据源：每个 AI 客户端的活动状态从哪读。加一家只在这里加一条
public enum SessionSources {
    public static let all: [SessionSource] = [
        // OpenCode：会话里带「在忙 / 空闲」和「最后查看」三个时刻，客户端自己写的（实测：正在跑时 busy=1）
        // time_busy 比 time_idle 晚就是还在忙；time_viewed 不早于 time_idle 就是这一轮已经看过了
        SessionSource(bundleID: "ai.opencode.desktop", kind: .sqlite(
            path: "~/.local/share/opencode/opencode.db",
            query: """
                SELECT CASE WHEN coalesce(time_busy, 0) > coalesce(time_idle, 0) THEN 1 ELSE 0 END,
                       max(coalesce(time_busy, 0), coalesce(time_idle, 0), coalesce(time_updated, 0)),
                       time_viewed
                FROM session_v2 WHERE time_archived IS NULL
                ORDER BY 2 DESC LIMIT 1
                """), processKeywords: ["opencode"]),
        // ZCode：和 OpenCode 同一套表（Token Monitor 也用同一份代码处理这两家）。判「这一轮还在跑」靠三件事：
        //   最新一条 user 消息（用户发了新指令 → 在跑）、最新一条 assistant 消息的 finish、
        //   有没有更新的 user 消息把结束状态重新打开。
        // finish：NULL=还在流式生成、tool-calls=暂停去跑工具（都算在跑）；stop/completed/length=这一轮结束
        SessionSource(bundleID: "dev.zcode.app", kind: .sqlite(
            path: "~/.zcode/cli/db/db.sqlite",
            query: """
                WITH m AS (
                    SELECT json_extract(data, '$.role') AS role,
                           lower(coalesce(json_extract(data, '$.finish'), '')) AS finish,
                           time_updated, session_id
                    FROM message
                    WHERE json_valid(data) AND json_extract(data, '$.role') IN ('assistant', 'user')
                    ORDER BY time_updated DESC LIMIT 40
                ),
                -- 最新一条 assistant 的 finish 决定这一轮是否结束
                a AS (SELECT finish, time_updated, session_id FROM m WHERE role = 'assistant' ORDER BY time_updated DESC LIMIT 1),
                -- 它之后又有一条 user 消息，说明用户已经发了新指令、新一轮开始
                u AS (SELECT count(*) AS newer FROM m, a WHERE m.role = 'user' AND m.time_updated > a.time_updated)
                SELECT CASE
                         WHEN a.finish IN ('stop', 'completed', 'length') AND u.newer = 0 THEN 0
                         ELSE 1
                       END,
                       coalesce((SELECT time_updated FROM m WHERE role = 'user' ORDER BY time_updated DESC LIMIT 1), a.time_updated),
                       NULL,
                       (SELECT s.title FROM session s WHERE s.id = a.session_id)
                FROM a, u
                """), processKeywords: ["zcode"]),
        // Codex：会话是日期目录下的 rollout-*.jsonl，取最新一个的修改时间。
        // 这台机器上没装 Codex 应用（CLI 跑在别的终端里时，窗口归那个终端 App，认不出是 Codex），
        // 所以这条暂时挂不到任何一行上；真在用 Codex 应用时，把 bundleID 改成它的就行
        SessionSource(bundleID: "com.openai.codex",
                      kind: .newestFile(root: "~/.codex/sessions", prefix: "rollout-", suffix: "jsonl", depth: 3),
                      processKeywords: ["codex"]),
    ]
}
