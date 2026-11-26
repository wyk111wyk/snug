import Foundation
import Testing
@testable import SnugCore

@Suite("AI 客户端活动状态")
struct SessionActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("刚有活动算在干活；安静一会儿算已完成；太久就不标了；读不到算不知道")
    func states() {
        #expect(SessionActivityRule.state(lastActivity: nil, now: now) == .unknown)
        #expect(SessionActivityRule.state(lastActivity: now, now: now) == .working)
        #expect(SessionActivityRule.state(lastActivity: now.addingTimeInterval(-1), now: now) == .working)
        // 边界：正好等于窗口算在内
        #expect(SessionActivityRule.state(lastActivity: now.addingTimeInterval(-SessionActivityRule.workingWindow), now: now) == .working)
        #expect(SessionActivityRule.state(lastActivity: now.addingTimeInterval(-SessionActivityRule.workingWindow - 1), now: now) == .done)
        #expect(SessionActivityRule.state(lastActivity: now.addingTimeInterval(-SessionActivityRule.doneWindow), now: now) == .done)
        #expect(SessionActivityRule.state(lastActivity: now.addingTimeInterval(-SessionActivityRule.doneWindow - 1), now: now) == .unknown)
        // 时间戳比现在还晚（两边时钟差一点）当作刚有动静，不判成不知道
        #expect(SessionActivityRule.state(lastActivity: now.addingTimeInterval(5), now: now) == .working)
    }

    @Test("数据源表：每家一个 bundleID、不重复；路径、查询都写着")
    func sources() {
        let all = SessionSources.all
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.bundleID)).count == all.count)
        for source in all {
            switch source.kind {
            case .sqlite(let path, let query):
                #expect(path.hasPrefix("~/"))
                #expect(query.lowercased().hasPrefix("select"))
            case .newestFile(let root, let prefix, let suffix, let depth):
                #expect(root.hasPrefix("~/"))
                #expect(!prefix.isEmpty && !suffix.isEmpty && depth > 0)
            }
        }
    }
}
