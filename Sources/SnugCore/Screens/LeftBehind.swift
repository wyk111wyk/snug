// 留下的账：放在屏上的窗口在 Snug 之外没了（用户在手机上关掉、App 自己换了窗口、App 退出），
// Snug 改过的大小、字号还没还。macOS 不让别的 App 拦关窗，Snug 知道时 App 往往已经把屏上的样子存下了：
// Clash Verge 再打开还是 540 宽的竖条，VS Code 重开工作区字号还大两级（issue #14，11-16 实测）。
// 所以账不跟着窗口一起销：先挂着，等它回来再还。
// 认它回来只认看得见的证据：同一个 App 的窗口带着 Snug 铺成的大小出现，说明 App 原样存下、原样带回来了，
// 这时按账放回原位（字号存在窗口里的连字号一起缩回）。大小对不上的不碰：可能是用户自己调过，也可能是 App 重设了，
// 再动就会把用户的窗口挪错、字号缩过头
import CoreGraphics
import Foundation

public struct LeftBehind: Codable, Equatable, Sendable {
    /// 没还的那份还原记录：原位、还欠几级字号、App、标题、Snug 铺成的样子
    public var record: PlacedRecord
    /// 什么时候留下的（墙钟）：过期就不等了
    public var since: Date

    public init(record: PlacedRecord, since: Date) {
        self.record = record
        self.since = since
    }

    /// 字号存在哪；名单外的 App 没调过字号，为 nil
    var zoomScope: ZoomScope? { ZoomBook.scope(of: record.bundleID) }

    /// 窗口回来了（编号可能换了）：按回来的窗口改写还原记录，字号只算随窗口一起回来的那几级
    public func returned(as key: WindowKey) -> PlacedRecord {
        var r = record
        r.window = key
        if !carriesZoom(returnedIn: key.pid) { r.zoom = 0 }
        return r
    }

    /// 回来的窗口还带不带着放大的字号
    func carriesZoom(returnedIn pid: Int32) -> Bool {
        switch zoomScope {
        case .restoredWindow?, .workspace?: true
        // 退出后恢复的窗口不带；只有同一个进程里「撤销关闭」恢复的还带着
        case .liveWindow?: pid == record.window.pid
        // 整个 App 共用的不看是哪个窗口回来：同一个进程的窗口回来时字号还在它身上（没关过 App），
        // 带着；进程换了才是真的没了，按进程另外还（LeftBehindLedger.repayAppWideZoom）
        case .app?: pid == record.window.pid
        case nil: false
        }
    }
}

public struct LeftBehindBook: Codable, Equatable, Sendable {
    /// 等这么久还没回来就不等了（App 下次开出来的窗口多半已经不是它）
    public static let keep: TimeInterval = 14 * 24 * 3600
    public static let limit = 20

    public private(set) var entries: [LeftBehind]

    public init(entries: [LeftBehind] = []) { self.entries = entries }

    /// 没铺成过（还没挪上屏就没了）的不记：大小没被改过，也认不出它回来没有
    public mutating func add(_ entry: LeftBehind) {
        guard entry.record.filled != nil else { return }
        entries.append(entry)
    }

    public mutating func remove(at index: Int) { entries.remove(at: index) }

    public mutating func update(at index: Int, _ change: (inout LeftBehind) -> Void) { change(&entries[index]) }

    /// 丢掉过期的；多于 limit 笔时丢最旧的
    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.since) > Self.keep }
        entries.sort { $0.since < $1.since }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// 这个 App 有没有哪笔账在等这个大小的窗口回来（先用窗口服务器给的大小筛，对上了再读辅助功能）
    public func awaits(bundleID: String, size: CGSize) -> Bool {
        entries.contains { $0.record.bundleID == bundleID && Self.isFilled($0, size: size) }
    }

    /// 这个窗口是不是哪一笔账的窗口原样回来了：同一个 App、带着 Snug 铺成的大小。
    /// 同一个 App 留下好几笔时，先认同一个窗口（编号没变：App 只是藏起来又显示），再认标题，都没有就认任意一笔；
    /// 每一层都取最近的：同一个窗口、同一个工作区后来又留下的账，才是它现在实际欠的
    public func match(_ window: WindowInfo, frame: CGRect) -> Int? {
        let candidates = entries.indices.filter { entries[$0].record.bundleID == window.bundleID && Self.isFilled(entries[$0], size: frame.size) }
        let newest = { (picked: [Int]) in picked.max { entries[$0].since < entries[$1].since } }
        return newest(candidates.filter { entries[$0].record.window == window.key })
            ?? newest(candidates.filter { entries[$0].record.title == window.title })
            ?? newest(candidates)
    }

    /// 大小差一两点也算（App 会把尺寸取整）
    private static func isFilled(_ entry: LeftBehind, size: CGSize) -> Bool {
        guard let filled = entry.record.filled else { return false }
        return abs(filled.width - size.width) < 2 && abs(filled.height - size.height) < 2
    }
}
