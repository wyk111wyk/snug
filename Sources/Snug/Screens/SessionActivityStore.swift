// 各 AI 客户端的会话与状态：只在资源库露着（或长按弹出列表）时轮询，收起就停——不给后台添负担。
// 读库 / 读文件是阻塞的，放后台线程做；算好的结果回主线程发布，界面读它画会话名和状态标记
import Foundation
import Observation
import SnugCore
import SnugSystem

@MainActor
@Observable
final class SessionActivityStore {
    /// 露着时多久读一次
    static let interval: TimeInterval = 2

    /// 按 bundleID 的各条会话（已滤掉看过、太久的；在干活的排前面）
    private(set) var sessions: [String: [SessionEntry]] = [:]

    @ObservationIgnored private let reader = SessionReader()
    @ObservationIgnored private let sources: [SessionSource]
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(sources: [SessionSource] = SessionSources.all) {
        self.sources = sources
    }

    /// 这个 App 最「活跃」那条会话的状态（在干活 > 已结束 > 不知道）
    func activity(_ bundleID: String) -> SessionActivity {
        let list = sessions[bundleID] ?? []
        if list.contains(where: { $0.activity == .working }) { return .working }
        if list.contains(where: { $0.activity == .done }) { return .done }
        return .unknown
    }

    /// 这个 App 的会话名：在干活的那条优先，否则最近那条
    func sessionTitle(_ bundleID: String) -> String? {
        let list = sessions[bundleID] ?? []
        let picked = list.first { $0.activity == .working } ?? list.first
        guard let title = picked?.title, !title.isEmpty else { return nil }
        return title
    }

    /// 这个 App 是不是支持的 Agent 应用（有会话源）
    func supports(_ bundleID: String) -> Bool { sources.contains { $0.bundleID == bundleID } }

    /// 露出来：开始轮询。先立刻读一次，读不到的先按上次的值显示（不清空，免得第一眼闪成「不知道」）
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

    /// 收起：停掉轮询。结果留着（下次露出来先用它显示第一帧，读回来再改），
    /// 只有远程结束、屏幕拆掉时才随着 store 一起没了
    func stop() {
        poller?.cancel()
        poller = nil
    }

    private func read() {
        let sources = self.sources
        let reader = self.reader
        Task.detached { [weak self] in
            var next: [String: [SessionEntry]] = [:]
            for source in sources {
                let reading = reader.reading(source)
                // 进程不在、或这一次什么都没读到（库被锁）：保留上一次的结果，不要冲成空白
                if !reading.running || reading.sessions.isEmpty,
                   let previous = await self?.sessions[source.bundleID] {
                    next[source.bundleID] = previous
                    continue
                }
                next[source.bundleID] = reading.sessions
            }
            await MainActor.run { self?.sessions = next }
        }
    }
}
