// App 资源库的统一数据源：在跑的 App 和各自的窗口、本机装着的 App、App 图标，各块屏上的资源库和电脑屏的资源库窗口
// 都只从这里读，控制器决定「点一个 App 做什么」也看这里。系统读取在 SnugSystem（AppService、WindowService）。
// 谁露着资源库谁就要它（want），露着的有一个就每 1.5 秒刷新在跑的 App：每次从没人要到有人要，第一次按最近用过重排，
// 之后只增删、不换位置（见 AppList.keepingOrder）；装着的 App 每次有人要时读一次。都收起就停；
// 要它的都在放窗口时暂停（列表被盖住，刷了也看不见，还和搬窗口排同一条队）；
// 电脑屏的资源库窗口还要每个窗口在哪块屏（spots）：有它要时在同一轮里紧跟着列表读，一次拷全系统的窗口表；
// 一次远程结束就清空，下次从头读。退掉的 App、关掉的窗口，DeskSet 一确认就从这里去掉，不等下一轮
import AppKit
import Observation
import SnugCore
import SnugSystem

@MainActor
@Observable
final class AppCatalog {
    static let refreshInterval: TimeInterval = 1.5

    private(set) var running: [RunningApp]
    /// 字典序
    private(set) var installed: [InstalledApp]
    /// 第一次刷新完成前显示「正在读取」，不显示「没有」
    private(set) var loaded: Bool
    /// 每个窗口在哪块屏、露没露着（电脑屏的资源库标在每个窗口后面）。只在有人要时跟着刷新读
    private(set) var spots: [WindowKey: WindowSpot]

    /// 不出现在资源库里的 App：各家远控自己（见 AppList.sorted）
    @ObservationIgnored private let excluded: Set<String>
    @ObservationIgnored private let apps: AppService?
    @ObservationIgnored private let windows: WindowService?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var scanning: Task<Void, Never>?
    /// 谁在要（屏号或资源库窗口）：在不在忙（忙着就不用为它刷）、要不要窗口在哪块屏
    @ObservationIgnored private var demand: [String: Demand] = [:]
    private var paused: Bool { demand.values.allSatisfy(\.busy) }
    /// 不忙的里面有要窗口在哪块屏的：没有就不拷全系统的窗口表
    private var locating: Bool { demand.values.contains { $0.spots && !$0.busy } }
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    /// forget/reset 过几次：刷新读到一半时有东西没了，读出来的那份可能还带着它，丢掉重读
    @ObservationIgnored private var forgotten = 0
    /// 第一次刷新按最近用过重排，之后只增删、不换位置；跨重启循环保留
    @ObservationIgnored private var reorder = true
    /// 重启的循环先发布一次窗口位置，不等整轮 AX 扫描
    @ObservationIgnored private var spotsFirst = false
    /// 诊断用：上一次标题变动的时刻（按 pid），限流用
    @ObservationIgnored private var titleLogAt: [Int32: TimeInterval] = [:]

    init(apps: AppService, windows: WindowService, excluding excluded: Set<String>) {
        self.excluded = excluded
        self.apps = apps
        self.windows = windows
        running = []
        installed = []
        loaded = false
        spots = [:]
    }

    /// 渲染样例用：固定的内容，不刷新
    init(sample running: [RunningApp], installed: [InstalledApp], spots: [WindowKey: WindowSpot] = [:], loaded: Bool = true) {
        excluded = []
        apps = nil
        windows = nil
        self.running = running
        self.installed = AppList.sorted(installed, excluding: [])
        self.loaded = loaded
        self.spots = spots
    }

    /// 诊断用（2026-11-26 起，摸 AI 客户端能不能从窗口标题看出「在干活 / 干完了」）：
    /// 标题一变就记一行，同一个 App 每 2 秒最多一条。看一阵子日志就能定标题这条路可不可用，定完删掉
    private func logTitleChanges(from previous: [RunningApp], to next: [RunningApp]) {
        let now = ProcessInfo.processInfo.systemUptime
        let before = Dictionary(previous.map { ($0.pid, $0.windows) }, uniquingKeysWith: { first, _ in first })
        for app in next {
            guard let old = before[app.pid] else { continue }
            let titles = Dictionary(old.map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first })
            for window in app.windows {
                guard let was = titles[window.key], was != window.title else { continue }
                if let last = titleLogAt[app.pid], now - last < 2 { continue }
                titleLogAt[app.pid] = now
                Log.info("标题变了：\(app.app.name)「\(was)」→「\(window.title)」")
            }
        }
        if next.isEmpty { titleLogAt = [:] }
    }

    /// 露着资源库：busy 是这块屏正在放窗口、打开 App（列表被盖住）；spots 是还要每个窗口在哪块屏（电脑屏的资源库窗口）
    func want(_ owner: String, busy: Bool = false, spots: Bool = false) {
        let hadSpots = locating
        demand[owner] = Demand(busy: busy, spots: spots)
        // 新出现的窗口位置需求（切回「运行中」、从忙恢复）立刻开一轮，不等当前 1.5 秒的等待
        if locating, !hadSpots {
            restartRefreshing()
        } else {
            startRefreshing()
        }
    }

    /// 收起了：都收起就停
    func release(_ owner: String) {
        guard demand.removeValue(forKey: owner) != nil, demand.isEmpty else { return }
        stopRefreshing()
    }

    private func startRefreshing() {
        guard let apps, let windows else { return }
        if scanning == nil {
            scanning = Task { [weak self, excluded] in
                let list = AppList.sorted(await apps.installed(), excluding: excluded)
                guard let self, !Task.isCancelled, list != installed else { return }
                installed = list
            }
        }
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !paused {
                    let before = forgotten
                    var located: [WindowKey: WindowSpot]?
                    if locating, spotsFirst {
                        located = await windows.spots()
                        guard !Task.isCancelled, forgotten == before else { continue }
                        // 先发布一次，切回「运行中」时不等整轮 AX 扫描
                        if let located, locating, located != spots { spots = located }
                        spotsFirst = false
                    }
                    let fresh = await windows.withWindows(apps.running())
                    guard !Task.isCancelled else { return }
                    // 紧跟着列表读，两边对得上；重启轮前面预读过一遍，这里补上列表扫描期间的变化
                    if locating {
                        located = await windows.spots()
                        guard !Task.isCancelled else { return }
                    }
                    spotsFirst = false
                    guard forgotten == before else { continue }
                    let next = AppList.refreshed(fresh, shown: running, reorder: reorder, excluding: excluded)
                    logTitleChanges(from: running, to: next)
                    if next != running { running = next }
                    if let located, locating, located != spots { spots = located }
                    loaded = true
                    reorder = false
                }
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    private func restartRefreshing() {
        spotsFirst = true
        refreshing?.cancel()
        refreshing = nil
        startRefreshing()
    }

    private func stopRefreshing() {
        reorder = true
        spotsFirst = false
        refreshing?.cancel()
        refreshing = nil
        scanning?.cancel()
        scanning = nil
    }

    /// 一次远程结束：清空，在途的刷新结果作废，下次露出时显示「正在读取」，不拿上次的旧列表。需求不在这里清：各块屏的面板撤掉时各自 release，
    /// 电脑屏的资源库窗口跟着它的屏关掉时 release（这一刻它可能还没关完，需求还在就接着刷新，等它 release 再停）
    func reset() {
        forgotten += 1
        reorder = true
        running = []
        spots = [:]
        loaded = false
        if demand.isEmpty { stopRefreshing() }
    }

    /// 退完了的 App、关上了的窗口：马上去掉，顺序不动（见 DeskSet.onGone）
    func forget(_ gone: DeskSet.Gone) {
        forgotten += 1
        switch gone {
        case .app(let pid):
            running.removeAll { $0.pid == pid }
        case .window(let key):
            guard let index = running.firstIndex(where: { $0.pid == key.pid }) else { return }
            running[index].windows.removeAll { $0.key == key }
        }
    }

    /// 在跑的这个 App（搜索结果里写它开着几个窗口）
    func running(_ app: AppInfo) -> RunningApp? { running.first { $0.app.bundleID == app.bundleID } }

    /// 窗口所属的在跑 App，这个窗口排第一个、用列表里最新的样子（终端的标题跟着命令变）。
    /// 列表还没刷到它（刚打开的 App，正在放窗口时列表暂停）就用窗口自己带的补上
    func app(of window: WindowInfo) -> RunningApp {
        let found = running.first { $0.pid == window.key.pid }
        let windows = found?.windows ?? []
        let latest = windows.first { $0.key == window.key } ?? window
        return RunningApp(pid: window.key.pid,
                          app: found?.app ?? AppInfo(bundleID: window.bundleID ?? "", name: window.app, path: nil),
                          windows: [latest] + windows.filter { $0.key != window.key })
    }

    func icon(for app: AppInfo) -> NSImage {
        if let cached = icons[app.bundleID] { return cached }
        let icon = AppService.icon(for: app)
        icons[app.bundleID] = icon
        return icon
    }

    /// 窗口所属 App 的图标
    func icon(for window: WindowInfo) -> NSImage { icon(for: app(of: window).app) }

    private struct Demand {
        var busy: Bool
        var spots: Bool
    }
}
