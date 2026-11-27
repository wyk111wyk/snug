// AI 客户端「在不在干活」：各客户端自己会把会话写成本地文件/库，这里只读它们「最近一次活动」的时间，
// 按「最近活动 → 现在」的距离分三态。数据源是一张表（SessionSources.all），加一家只加一条。
// 纯逻辑：读库、读文件在 SnugSystem（SessionReader），这里只定「从哪读、怎么判」
import Foundation

/// 触屏屏底部那一行控件之外，App 资源库里能显示状态的应用
public enum SessionActivity: Equatable, Sendable {
    /// 刚有活动（在干活）
    case working
    /// 有过活动、现在安静了（多半在等你输入）
    case done
    /// 不知道（没这个客户端、读不到、太久没动静）
    case unknown
}

/// 一个 AI 客户端的一条会话：名字和它自己的状态
public struct SessionEntry: Equatable, Hashable, Sendable, Identifiable {
    public let title: String
    public let activity: SessionActivity

    public var id: String { title }

    public init(title: String, activity: SessionActivity) {
        self.title = title
        self.activity = activity
    }
}

/// 一个来源的查询结果：**一行一条会话**，每行 5 列（见 SessionSource.Kind.sqlite）
public struct SessionReading: Equatable, Sendable {
    /// 客户端自己说它此刻还在跑（进程在）
    public var running: Bool
    /// 这个客户端的各条会话；按最近活动排好序
    public var sessions: [SessionEntry]

    public init(running: Bool, sessions: [SessionEntry] = []) {
        self.running = running
        self.sessions = sessions
    }
}

/// 一个 AI 客户端的状态从哪读
public struct SessionSource: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 只读查一个 SQLite 库，**一行一条会话、五列**：
        /// 1 会话名　2 在跑？(0/1)　3 最近活动（毫秒）　4 最后查看（毫秒，可 NULL）　5 近 2 分钟新消息数（可 NULL）
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

/// 三态的判据。取舍（2026-11-27 定）：
/// 1. 在跑的永远显示——它正占着你的时间，藏起来会让人等错；
/// 2. 干完了、还没看过的显示（圆点提醒看一眼）；
/// 3. 看过了、或安静超过 doneWindow 的收起（会话本身不丢，App 里还在）。
public enum SessionActivityRule {
    /// 最近这么久内有活动就算在干活
    public static let workingWindow: TimeInterval = 8
    /// 安静超过这么久就收起（看过没看过都收）
    public static let doneWindow: TimeInterval = 10 * 60
    /// 说了「在跑」但这么久没有新消息、且没在流式生成：多半是生成到一半中断留下的空 finish，按结束算
    public static let staleBusyWindow: TimeInterval = 120

    /// 一条会话的状态
    /// - busy: 客户端说在不在跑；nil = 它没这么说
    /// - freshMessages: 近 2 分钟的新消息数；-1 = 查不到
    public static func state(busy: Bool?, lastActivity: Date?, lastViewed: Date?, freshMessages: Int = -1,
                             now: Date) -> SessionActivity {
        guard let last = lastActivity else { return busy == true ? .working : .unknown }
        let quiet = now.timeIntervalSince(last)
        // 时间戳比现在还晚（两边时钟差一点）当作刚有动静
        if quiet < 0 { return .working }
        // 说了在跑：再核一层「还在产出吗」，防止空 finish 的残留一直挂着
        if busy == true {
            if quiet <= staleBusyWindow || freshMessages > 0 { return .working }
            return .done
        }
        guard quiet > workingWindow else { return .working }
        // 结束了：看过了、或太久没动静，就收起
        guard isUnseen(lastActivity: last, lastViewed: lastViewed, now: now) else { return .unknown }
        return .done
    }

    /// 从读数（进程 + 各条会话）算出每个 App 的状态：取最「活跃」的那条会话
    public static func state(reading: SessionReading, now: Date) -> SessionActivity {
        guard reading.running else { return .unknown }
        if reading.sessions.contains(where: { $0.activity == .working }) { return .working }
        if reading.sessions.contains(where: { $0.activity == .done }) { return .done }
        return .unknown
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
        // OpenCode：会话自带「在忙 / 空闲 / 查看」三个时刻，客户端自己写的（实测：正在跑时 busy=1）。
        // 每条会话一行；只取近 30 分钟内动过的，按最近活动排
        SessionSource(bundleID: "ai.opencode.desktop", kind: .sqlite(
            path: "~/.local/share/opencode/opencode.db",
            query: """
                SELECT coalesce(nullif(trim(title), ''), ''),
                       CASE WHEN coalesce(time_busy, 0) > coalesce(time_idle, 0) THEN 1 ELSE 0 END,
                       max(coalesce(time_busy, 0), coalesce(time_idle, 0), coalesce(time_updated, 0)),
                       time_viewed,
                       NULL
                FROM session_v2
                WHERE time_archived IS NULL
                  AND coalesce(time_updated, 0) > (strftime('%s', 'now') - 1800) * 1000
                GROUP BY id
                ORDER BY 3 DESC
                LIMIT 8
                """), processKeywords: ["opencode"]),
        // ZCode：和 OpenCode 同一套表（Token Monitor 也用同一份代码处理这两家）。
        // 每个 session 各自判：最新一条 assistant 的 finish，若其后又来了 user 消息（用户发了新指令）就是新一轮。
        // finish：NULL=还在流式生成、tool-calls=暂停去跑工具（都算在跑）；stop/completed/length=这一轮结束
        SessionSource(bundleID: "dev.zcode.app", kind: .sqlite(
            path: "~/.zcode/cli/db/db.sqlite",
            query: """
                WITH recent AS (
                    SELECT json_extract(data, '$.role') AS role,
                           lower(coalesce(json_extract(data, '$.finish'), '')) AS finish,
                           time_updated, session_id
                    FROM message
                    WHERE json_valid(data)
                      AND json_extract(data, '$.role') IN ('assistant', 'user')
                      AND time_updated > (strftime('%s', 'now') - 1800) * 1000
                ),
                latest AS (
                    SELECT session_id, finish, time_updated,
                           ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY time_updated DESC) AS rn
                    FROM recent WHERE role = 'assistant'
                ),
                newer AS (
                    SELECT l.session_id, count(r.time_updated) AS newer_users
                    FROM latest l JOIN recent r
                      ON r.session_id = l.session_id AND r.role = 'user' AND r.time_updated > l.time_updated
                    WHERE l.rn = 1 GROUP BY l.session_id
                ),
                lastmsg AS (
                    SELECT session_id, max(time_updated) AS at FROM recent GROUP BY session_id
                )
                SELECT coalesce(s.title, ''),
                       CASE WHEN l.finish IN ('stop', 'completed', 'length') AND coalesce(n.newer_users, 0) = 0
                            THEN 0 ELSE 1 END,
                       coalesce(lm.at, l.time_updated),
                       NULL,
                       (SELECT count(*) FROM recent r2 WHERE r2.session_id = l.session_id
                          AND r2.time_updated > (strftime('%s','now') - 120) * 1000)
                FROM latest l
                LEFT JOIN session s ON s.id = l.session_id
                LEFT JOIN newer n ON n.session_id = l.session_id
                LEFT JOIN lastmsg lm ON lm.session_id = l.session_id
                WHERE l.rn = 1
                ORDER BY coalesce(lm.at, l.time_updated) DESC
                LIMIT 8
                """), processKeywords: ["zcode"]),
        // Codex：会话是日期目录下的 rollout-*.jsonl，取最新一个的修改时间。
        // 这台机器上没装 Codex 应用（CLI 跑在别的终端里时，窗口归那个终端 App，认不出是 Codex），
        // 所以这条暂时挂不到任何一行上；真在用 Codex 应用时，把 bundleID 改成它的就行
        SessionSource(bundleID: "com.openai.codex",
                      kind: .newestFile(root: "~/.codex/sessions", prefix: "rollout-", suffix: "jsonl", depth: 3),
                      processKeywords: ["codex"]),
    ]
}
