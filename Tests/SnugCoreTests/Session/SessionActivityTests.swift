import Foundation
import Testing
@testable import SnugCore

@Suite("AI 客户端活动状态")
struct SessionActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 只有时间的简写（busy 不说、没查看记录、查不到新消息数）
    private func state(_ last: Date?) -> SessionActivity {
        SessionActivityRule.state(busy: nil, lastActivity: last, lastViewed: nil, now: now)
    }

    @Test("只说时间的时候：刚有活动算在干活；安静一会儿算已结束；太久就不标了；读不到算不知道")
    func states() {
        #expect(state(nil) == .unknown)
        #expect(state(now) == .working)
        #expect(state(now.addingTimeInterval(-1)) == .working)
        // 边界：正好等于窗口算在内
        #expect(state(now.addingTimeInterval(-SessionActivityRule.workingWindow)) == .working)
        #expect(state(now.addingTimeInterval(-SessionActivityRule.workingWindow - 1)) == .done)
        #expect(state(now.addingTimeInterval(-SessionActivityRule.doneWindow)) == .done)
        #expect(state(now.addingTimeInterval(-SessionActivityRule.doneWindow - 1)) == .unknown)
        // 时间戳比现在还晚（两边时钟差一点）当作刚有动静，不判成不知道
        #expect(state(now.addingTimeInterval(5)) == .working)
    }

    @Test("客户端说在忙就以它为准，但要再核一层「还在产出吗」：久无新消息又没在流式生成，按结束算（排除空 finish 残留）")
    func busyNeedsFreshOutput() {
        let quiet = now.addingTimeInterval(-300)
        // 说在忙、但 5 分钟没有新消息、近 2 分钟也没产出：多半是生成到一半中断的残留
        #expect(SessionActivityRule.state(busy: true, lastActivity: quiet, lastViewed: nil, freshMessages: 0, now: now) == .done)
        // 说在忙、还在产出：在干活
        #expect(SessionActivityRule.state(busy: true, lastActivity: quiet, lastViewed: nil, freshMessages: 3, now: now) == .working)
        // 说在忙、安静不到 2 分钟：再等等，别急着判结束
        #expect(SessionActivityRule.state(busy: true, lastActivity: now.addingTimeInterval(-30), lastViewed: nil,
                                          freshMessages: 0, now: now) == .working)
        // 空 finish 残留但进程还在、刚动过：在干活
        #expect(SessionActivityRule.state(busy: true, lastActivity: now, lastViewed: nil, now: now) == .working)
    }

    @Test("看过了就收起：最后查看时刻不早于这一轮活动，就不再显示（会话本身不丢，App 里还在）")
    func viewedClearsMark() {
        let last = now.addingTimeInterval(-60)
        #expect(SessionActivityRule.state(busy: false, lastActivity: last, lastViewed: nil, now: now) == .done)
        // 查看发生在上一轮：还没看这一轮 → 仍算已结束
        #expect(SessionActivityRule.state(busy: false, lastActivity: last, lastViewed: last.addingTimeInterval(-10), now: now) == .done)
        // 看过这一轮了 → 收起
        #expect(SessionActivityRule.state(busy: false, lastActivity: last, lastViewed: last, now: now) == .unknown)
        #expect(SessionActivityRule.state(busy: false, lastActivity: last, lastViewed: now, now: now) == .unknown)
        // 客户端没有查看记录（ZCode）：当作没看过，照常标，等 doneWindow 收
        #expect(SessionActivityRule.state(busy: nil, lastActivity: last, lastViewed: nil, now: now) == .done)
    }

    @Test("进程不在就一律不标：客户端崩了、被强退时库里会留着「还没结束」，只看库会一直显示在干活")
    func processGoneNeverMarks() {
        let working = SessionEntry(title: "a", activity: .working)
        let done = SessionEntry(title: "b", activity: .done)
        #expect(SessionActivityRule.state(reading: SessionReading(running: false, sessions: [working, done]), now: now) == .unknown)
        #expect(SessionActivityRule.state(reading: SessionReading(running: true, sessions: [working, done]), now: now) == .working)
        #expect(SessionActivityRule.state(reading: SessionReading(running: true, sessions: [done]), now: now) == .done)
        #expect(SessionActivityRule.state(reading: SessionReading(running: true, sessions: []), now: now) == .unknown)
    }

    @Test("数据源表：每家一个 bundleID、不重复；路径、查询都写着；每家都有进程关键词")
    func sources() {
        let all = SessionSources.all
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.bundleID)).count == all.count)
        for source in all {
            #expect(!source.processKeywords.isEmpty, "\(source.bundleID) 缺 processKeywords")
            #expect(source.processKeywords.allSatisfy { $0 == $0.lowercased() }, "\(source.bundleID) 的关键词要小写")
            switch source.kind {
            case .sqlite(let path, let query):
                #expect(path.hasPrefix("~/"))
                #expect(query.lowercased().hasPrefix("select") || query.lowercased().hasPrefix("with"))
            case .newestFile(let root, let prefix, let suffix, let depth):
                #expect(root.hasPrefix("~/"))
                #expect(!prefix.isEmpty && !suffix.isEmpty && depth > 0)
            }
        }
    }
}
