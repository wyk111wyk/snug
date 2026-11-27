// 连接判定（纯值类型，now 由调用方传入）：把每拍的远控观测合成连入 / 换控制端 / 断开。
// - 在场只认正面证据（RemoteObservation.present，由适配器判定，UU 见 UUSignals.isPresent）
// - 连入要快：未连接时一看到在场就连入，不做确认延迟
// - 断开要稳，同时满足两条才判：
//   1. 连续不在场超过 disconnectDebounce（UU 实测：切屏时覆盖窗口会短暂重建）
//   2. 过了自扰静默期：本工具自己加屏、撤屏后 quietWindow 内不判。屏幕组合一变，远控会停流重开、重建窗口，
//      2026-11-12 19:01 就因为改屏幕扰乱了 UU 的信号被误判为断开，屏幕改回去信号又回来，如此反复
// - 控制端记一组：UU 一次只让一台设备控制（V12），但表格有时同时列出几台（issue #3 的日志里有过，多半是没刷新）。
//   顺序是谁先连上，不代表谁在用，所以只比较有哪些人。名字只用来写日志、显示在菜单栏，不拿来做决定
// - 推流还在就算远程还在，不设「推流太久就判断开」的上限。上限得靠控制端证明「没人」，
//   可没认出控制端只说明没看到：UU 没被控时根本不显示控制端表格，主窗口关着、停在首页时也认不出（issue #1），
//   正常远程都被上限误判断开过，而它一次也没在真正该断的时候起过作用。
//   代价是停流的日志万一全漏掉，Snug 的屏会一直留着：菜单栏照样显示「远程中」，在设置里关掉那块屏就能复原
//   （退出 Snug 只是暂时撤掉：4 小时内重开，回看日志又会认成推流中）
import Foundation

public enum ConnectionEvent: Equatable, Sendable {
    /// 连入时认出的控制端（可能还没读到，为空）
    case connected(controllers: [String])
    /// 同时连着的控制端变了：有人加入、有人离开
    case controllersChanged([String])
    case disconnected
}

public struct ConnectionTracker: Sendable {
    public static let disconnectDebounce: TimeInterval = 1.5
    public static let quietWindow: TimeInterval = 5

    public private(set) var isConnected = false
    /// 此刻同时连着的控制端，按适配器给的顺序；没认出过为空
    public private(set) var controllers: [String] = []

    private var lastPresentAt: Date?
    private var quietUntil: Date?

    public init() {}

    /// 本工具即将或刚刚引起屏幕 / 窗口扰动（改显示拓扑、挪窗口……）时调用
    public mutating func noteSelfInducedChange(at date: Date) {
        let until = date.addingTimeInterval(Self.quietWindow)
        quietUntil = max(quietUntil ?? until, until)
    }

    /// remote：观测来自哪家远控（日志名），只用来写日志
    public mutating func update(_ observation: RemoteObservation, from remote: String, now: Date) -> ConnectionEvent? {
        let names = observation.controllers
        if observation.present { lastPresentAt = now }

        guard isConnected else {
            guard observation.present else { return nil }
            isConnected = true
            controllers = names
            log(.connected(controllers: names), remote, observation, now: now)
            return .connected(controllers: controllers)
        }

        if observation.present {
            // 没认出控制端时保留原来的：主窗口切走了不代表换了人
            guard !names.isEmpty, Set(names) != Set(controllers) else { return nil }
            controllers = names
            log(.controllersChanged(names), remote, observation, now: now)
            return .controllersChanged(names)
        }

        guard let last = lastPresentAt, now.timeIntervalSince(last) > Self.disconnectDebounce, quietPassed(now) else { return nil }
        log(.disconnected, remote, observation, now: now)
        isConnected = false
        controllers = []
        return .disconnected
    }

    private func quietPassed(_ now: Date) -> Bool {
        guard let until = quietUntil else { return true }
        return now > until
    }

    /// 每次连接事件都留下信号快照，排查误判时才知道是哪一路信号在变
    private func log(_ event: ConnectionEvent, _ remote: String, _ observation: RemoteObservation, now: Date) {
        let quietLeft = quietUntil.flatMap { until -> TimeInterval? in
            let remaining = until.timeIntervalSince(now)
            return remaining >= 0 ? remaining : nil
        }
        Log.info(Self.logLine(event, remote: remote, evidence: observation.evidence,
                              sincePresent: lastPresentAt.map { now.timeIntervalSince($0) }, quietLeft: quietLeft))
    }

    /// 连接事件写进日志的一行。SnugLogDigest 按「检测到 <远控> 连入（<快照> 距上次在场」解析，往返测试钉住两边
    static func logLine(_ event: ConnectionEvent, remote: String, evidence: String, sincePresent: TimeInterval?, quietLeft: TimeInterval?) -> String {
        let what = switch event {
        case .connected: "检测到 \(remote) 连入"
        case .controllersChanged(let names): "控制端变为 \(names.joined(separator: "、"))"
        case .disconnected: "检测到 \(remote) 断开"
        }
        let since = sincePresent.map { String(format: "%.2f", $0) } ?? "-"
        let quiet = quietLeft.map { String(format: " 静默期剩 %.2fs", $0) } ?? ""
        return "\(what)（\(evidence) 距上次在场 \(since)s\(quiet)）"
    }
}
