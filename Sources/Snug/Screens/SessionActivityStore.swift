// 各 AI 客户端「在不在干活」：只在收藏切换条露着时轮询（每 2 秒），收起就停——不给后台添负担。
// 读库 / 读文件是阻塞的，放后台线程做；算好的状态回主线程发布，界面读它画状态点
import Foundation
import Observation
import SnugCore
import SnugSystem

@MainActor
@Observable
final class SessionActivityStore {
    /// 切换条露着时多久读一次
    static let interval: TimeInterval = 2

    /// 按 bundleID 的状态；没读到的按「不知道」
    private(set) var states: [String: SessionActivity] = [:]

    @ObservationIgnored private let reader = SessionReader()
    @ObservationIgnored private let sources: [SessionSource]
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(sources: [SessionSource] = SessionSources.all) {
        self.sources = sources
    }

    func activity(_ bundleID: String) -> SessionActivity { states[bundleID] ?? .unknown }

    /// 切换条露出来：开始轮询。先立刻读一次，读不到的先按上次的值显示（不清空，免得第一眼闪成「不知道」）
    func start() {
        guard poller == nil else { return }
        read()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard !Task.isCancelled, let self else { return }
                self.read()
            }
        }
    }

    /// 收起：停掉轮询。状态留着（下次露出来先用它显示第一帧，读回来再改），
    /// 只有远程结束、屏幕拆掉时才随着 store 一起没了
    func stop() {
        poller?.cancel()
        poller = nil
    }

    private func read() {
        let sources = self.sources
        let reader = self.reader
        Task.detached { [weak self] in
            let now = Date()
            var next: [String: SessionActivity] = [:]
            for source in sources {
                let reading = reader.reading(source)
                // 这一次什么都没读到（库被锁、文件没在写）：保留上一次的结果，不要冲成「不知道」
                if reading.busy == nil, reading.lastActivity == nil,
                   let previous = await self?.states[source.bundleID] {
                    next[source.bundleID] = previous
                    continue
                }
                next[source.bundleID] = SessionActivityRule.state(reading: reading, idleIsUnfinished: source.idleIsUnfinished, now: now)
            }
            await MainActor.run { self?.states = next }
        }
    }
}
