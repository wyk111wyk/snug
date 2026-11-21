import CoreGraphics
import Foundation
import Testing
@testable import SnugCore

// 在手机屏上被 Snug 之外关掉、换掉的窗口留下的账：怎么认出它回来了、记多久、字号存在哪

private let vscode = "com.microsoft.VSCode"
private let filled = CGRect(x: -757, y: 30, width: 540, height: 892)

private func record(_ title: String = "README.md — snug", key: WindowKey = WindowKey(pid: 20, id: 300),
                    bundleID: String? = vscode, zoom: Int = 2) -> PlacedRecord {
    PlacedRecord(window: key, app: "Visual Studio Code", label: "Visual Studio Code「\(title)」",
                original: CGRect(x: 100, y: 80, width: 1200, height: 800), zoom: zoom,
                bundleID: bundleID, title: title, filled: filled)
}

private func window(_ title: String = "README.md — snug", key: WindowKey = WindowKey(pid: 21, id: 400),
                    bundleID: String? = vscode) -> WindowInfo {
    WindowInfo(key: key, app: "Visual Studio Code", bundleID: bundleID, title: title)
}

@Suite("留下的账 LeftBehind")
struct LeftBehindTests {
    @Test("字号存在哪：按 App 认，名单外的 App 不调字号")
    func zoomScopes() {
        #expect(ZoomBook.scope(of: "com.mitchellh.ghostty") == .liveWindow)
        #expect(ZoomBook.scope(of: "com.apple.Terminal") == .restoredWindow)
        #expect(ZoomBook.scope(of: "com.googlecode.iterm2") == .restoredWindow)
        #expect(ZoomBook.scope(of: vscode) == .workspace)
        #expect(ZoomBook.scope(of: "com.todesktop.230313mzl4w4u92") == .workspace)
        #expect(ZoomBook.scope(of: "dev.zed.Zed") == .app)
        #expect(ZoomBook.scope(of: "ai.commandcode.desktop") == .app)
        #expect(ZoomBook.scope(of: "com.apple.Safari") == nil)
        #expect(ZoomBook.scope(of: nil) == nil)
        #expect(ZoomBook.isZoomable(vscode))
        #expect(!ZoomBook.isZoomable("com.apple.Safari"))
    }

    @Test("整个 App 共用字号的（.app）窗口回来了：同一个进程还带着，换了进程才算没了")
    func appWideZoomCarried() {
        // Command Code 这种：uiScale 存整个 App 里，窗口回来时（进程没换）字号还在身上
        let cc = "ai.commandcode.desktop"
        let key = WindowKey(pid: 20, id: 300)
        let left = LeftBehind(record: record("Command Code", key: key, bundleID: cc, zoom: 3), since: Date())

        // 同一个进程里窗口回来了：字号还在，别清零（清零会少缩一次，留在 App 上）
        let back = left.returned(as: WindowKey(pid: 20, id: 999))
        #expect(back.zoom == 3)

        // App 重启了：字号真的没了，清零，交给 repayAppWideZoom 另外还
        let rebooted = left.returned(as: WindowKey(pid: 77, id: 999))
        #expect(rebooted.zoom == 0)
    }

    @Test("旧版的还原记录（没有 App、标题、铺成的样子）照样读得出来")
    func oldRecordDecodes() throws {
        let old = #"{"window":{"pid":10,"id":7},"app":"Ghostty","label":"Ghostty","original":[[100,100],[1200,800]],"wasFullScreen":false,"wasMinimized":false,"zoom":2}"#
        let r = try JSONDecoder().decode(PlacedRecord.self, from: Data(old.utf8))
        #expect(r.zoom == 2)
        #expect(r.bundleID == nil && r.title == nil && r.filled == nil)
    }

    @Test("带着手机屏上的大小回来的同一个 App 的窗口才算它：编号变了也认（App 重开、重启后编号都会换）")
    func matchesBySizeAndApp() {
        let book = LeftBehindBook(entries: [LeftBehind(record: record(), since: Date())])
        #expect(book.match(window(), frame: CGRect(x: 0, y: 33, width: 540, height: 892)) == 0)
        #expect(book.match(window(), frame: CGRect(x: 0, y: 33, width: 541, height: 893)) == 0)   // 取整差一两点
        #expect(book.match(window(), frame: CGRect(x: 156, y: 33, width: 1200, height: 800)) == nil)   // App 重设了大小：不是原样回来的
        #expect(book.match(window(bundleID: "com.apple.Safari"), frame: filled) == nil)
        #expect(book.match(window(bundleID: nil), frame: filled) == nil)
    }

    @Test("同一个 App 留下好几笔：先认同一个窗口，再认标题，都没有就认最近的一笔")
    func prefersSameWindowThenTitle() {
        let now = Date()
        let book = LeftBehindBook(entries: [
            LeftBehind(record: record("a — x", key: WindowKey(pid: 20, id: 1)), since: now.addingTimeInterval(-30)),
            LeftBehind(record: record("b — y", key: WindowKey(pid: 20, id: 2)), since: now.addingTimeInterval(-20)),
            LeftBehind(record: record("c — z", key: WindowKey(pid: 20, id: 3)), since: now.addingTimeInterval(-10)),
        ])
        #expect(book.match(window("c — z", key: WindowKey(pid: 20, id: 1)), frame: filled) == 0)
        #expect(book.match(window("b — y"), frame: filled) == 1)
        #expect(book.match(window("别的标题"), frame: filled) == 2)
    }

    @Test("同一个窗口、同一个工作区留下好几笔：认最近的一笔（它才是现在实际欠的）")
    func prefersNewestAmongSame() {
        let now = Date()
        let book = LeftBehindBook(entries: [
            LeftBehind(record: record("README.md — snug", zoom: 2), since: now.addingTimeInterval(-3 * 24 * 3600)),
            LeftBehind(record: record("README.md — snug", zoom: 3), since: now.addingTimeInterval(-60)),
        ])
        #expect(book.match(window(), frame: filled) == 1)
        #expect(book.match(window(key: WindowKey(pid: 20, id: 300)), frame: filled) == 1)
        #expect(book.awaits(bundleID: vscode, size: filled.size))
        #expect(!book.awaits(bundleID: vscode, size: CGSize(width: 1200, height: 800)))
        #expect(!book.awaits(bundleID: "com.apple.Safari", size: filled.size))
    }

    @Test("没铺成过的（窗口还没挪上手机屏就没了）不记：认不出它回来没有")
    func unfilledIsNotKept() {
        var book = LeftBehindBook()
        var r = record()
        r.filled = nil
        book.add(LeftBehind(record: r, since: Date()))
        #expect(book.entries.isEmpty)
    }

    @Test("记两周、最多 20 笔：过期的和最旧的先丢")
    func pruneByAgeAndCount() {
        let now = Date()
        var book = LeftBehindBook()
        book.add(LeftBehind(record: record("旧的"), since: now.addingTimeInterval(-15 * 24 * 3600)))
        for i in 0..<21 { book.add(LeftBehind(record: record("第 \(i) 个"), since: now.addingTimeInterval(Double(i)))) }
        book.prune(now: now)
        #expect(book.entries.count == 20)
        #expect(book.entries.first?.record.title == "第 1 个")
        #expect(!book.entries.contains { $0.record.title == "旧的" })
    }
}
