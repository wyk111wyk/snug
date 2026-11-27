// Snug 自己的日志（Snug.log）里和远程有关的几样：远程开始与结束、连入时的信号快照、认出的控制端、Snug 的屏的编号。
// 远控的兼容自检（UU 见 UUCheck）拿它和远控自己的日志对照：Snug 记到了远程、远控日志里却没有对应的痕迹，才说得上是远控变了。
// 只认这几句的固定写法：会话和连入的写法由 RemoteSession、ConnectionTracker 的 logLine 产出，往返测试钉住两边；
// 屏的写法是 ScreenSet、Desk 打的，那边改措辞时这里和测试一起改。
// 只摘一家远控的：会话行不带远控名（日志措辞不变），归到它前面最近一行「检测到 <远控> 连入」的那家。
// 会话的开始、重连都紧跟在这一行后面（RemoteSession 同一拍里先记连入、再记会话），归属只在连入时变，所以就近归属不会错。
// 前面一行连入都找不到的（日志轮转后的开头一段）照旧算进来：连入的写法万一改了、一行都认不出，自检还能从会话数看出来
import Foundation

public struct SnugLogDigest: Equatable, Sendable {
    /// 「检测到 <远控> 连入」那一刻的信号快照（写法由适配器定，UU 见 UUSignals.description）
    public struct Detection: Equatable, Sendable {
        public var date: Date
        public var evidence: String
    }

    /// 远程开始（「会话：开始」）
    public var sessionStarts: [Date] = []
    /// 远程结束（「会话：结束」「会话：立即结束」）
    public var sessionEnds: [Date] = []
    public var detections: [Detection] = []
    /// 认出过的控制端，按首次出现的顺序、去重
    public var controllers: [String] = []
    /// Snug 建过、放过窗口、撤过的屏的编号
    public var snugDisplays: Set<DisplayID> = []

    /// 只摘 remote（远控的日志名）的，只看 since 之后的行；since 之前的行只用来认归属。认不出的行跳过
    public init(lines: some Sequence<some StringProtocol>, since: Date, remote: String) {
        let reader = LineReader()
        var owner: String?
        for line in lines {
            guard let (date, message) = reader.split(line) else { continue }
            let detection = Self.detection(in: message)
            if let detection { owner = detection.remote }
            guard date.timeIntervalSince(since) >= 0 else { continue }
            if let detection {
                if detection.remote == remote { detections.append(Detection(date: date, evidence: detection.evidence)) }
            } else if owner == nil || owner == remote {
                take(message, at: date)
            }
            noteDisplays(in: message)
        }
    }

    /// since 之后的行（取证材料里只放这一段）；认不出时间的行跟着上一行走（多行的报错）
    public static func recent<S: StringProtocol>(_ lines: [S], since: Date) -> [S] {
        let reader = LineReader()
        var keep = false
        return lines.filter { line in
            if let date = reader.split(line)?.date { keep = date.timeIntervalSince(since) >= 0 }
            return keep
        }
    }

    private mutating func take(_ message: String, at date: Date) {
        if message.hasPrefix("会话：开始") {
            sessionStarts.append(date)
            note(Self.controllerList(in: message, after: "（控制端 "))
        } else if message.hasPrefix("会话：重连上") {
            note(Self.controllerList(in: message, after: "（控制端 "))
        } else if message.hasPrefix("会话：控制端变为 ") {
            note(Self.controllerList(in: message, after: "会话：控制端变为 "))
        } else if message.hasPrefix("会话：结束") || message.hasPrefix("会话：立即结束") {
            sessionEnds.append(date)
        }
    }

    /// Snug 的屏不分是哪家远控在用
    private mutating func noteDisplays(in message: String) {
        for marker in ["放上屏 #", "已撤掉屏 #"] {
            if let id = Self.number(after: marker, in: message) { snugDisplays.insert(id) }
        }
        // 「「Snug 手机屏」#367 已建好（540 宽）」：编号在「已建好」前面
        if let built = message.range(of: " 已建好"), let hash = message[..<built.lowerBound].lastIndex(of: "#"),
           let id = DisplayID(message[message.index(after: hash)..<built.lowerBound]) {
            snugDisplays.insert(id)
        }
    }

    private mutating func note(_ names: [String]) {
        for name in names where !controllers.contains(name) { controllers.append(name) }
    }

    /// marker 之后到「）」或行尾的名字，按「、」分开；读不到名字的不算
    private static func controllerList(in message: String, after marker: String) -> [String] {
        guard let start = message.range(of: marker)?.upperBound else { return [] }
        let tail = message[start...]
        let list = tail.prefix { $0 != "）" }
        return list.split(separator: "、").map(String.init).filter { !$0.isEmpty && $0 != SessionTransition.unnamed }
    }

    /// 「检测到 <远控> 连入（<快照> 距上次在场 …）」（ConnectionTracker.logLine）
    private static func detection(in message: String) -> (remote: String, evidence: String)? {
        let prefix = "检测到 "
        guard message.hasPrefix(prefix), let joined = message.range(of: " 连入（"),
              let tail = message.range(of: " 距上次在场", range: joined.upperBound..<message.endIndex) else { return nil }
        let remote = message[message.index(message.startIndex, offsetBy: prefix.count)..<joined.lowerBound]
        return (String(remote), String(message[joined.upperBound..<tail.lowerBound]))
    }

    private static func number(after marker: String, in message: String) -> DisplayID? {
        guard let start = message.range(of: marker)?.upperBound else { return nil }
        return DisplayID(message[start...].prefix(while: \.isNumber))
    }

}

/// 「[时间] [级别] 正文」，帮手进程多一段「[帮手]」（见 FileLogSink）
private struct LineReader {
    private let formatter: DateFormatter

    init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func split(_ line: some StringProtocol) -> (date: Date, message: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let date = formatter.date(from: String(line[line.index(after: line.startIndex)..<close])) else { return nil }
        var rest = line[line.index(after: close)...]
        while rest.hasPrefix(" ["), let end = rest.firstIndex(of: "]") { rest = rest[rest.index(after: end)...] }
        return (date, String(rest.drop { $0 == " " }))
    }
}
