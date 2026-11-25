// 屏幕查找与坐标换算。AppKit（NSScreen、窗口）用左下原点，辅助功能和 CGEvent 用主屏左上原点
import AppKit
import SnugCore

@MainActor
public enum Screens {
    public static func screen(for id: DisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// 在线的屏，按系统列出的顺序（含镜像中的从属屏）。读不到记 warn、返回 nil，调用方按「没有屏」处理还是另说
    public nonisolated static func online() -> [DisplayID]? {
        var count: UInt32 = 0
        var error = CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if error == .success, count > 0 { error = CGGetOnlineDisplayList(count, &ids, &count) }
        guard error == .success else {
            Log.warn("读不到在线的屏（CGError=\(error.rawValue)）")
            return nil
        }
        return Array(ids.prefix(Int(count)))
    }

    /// 能单独管模式和位置的在线屏：去掉镜像组里的从属屏。从属屏显示的是主控屏的画面，模式、位置都跟着主控屏走，
    /// 单独设模式报「没有这个模式」（实测），单独设原点会把它踢出镜像组（CGDisplayConfiguration.h）。管住主控屏就管住了整组
    public nonisolated static func standalone() -> [DisplayID]? {
        online()?.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// 在「显示器」设置里的名字；找不到就用编号
    public static func name(of id: DisplayID) -> String {
        screen(for: id)?.localizedName ?? "显示器 #\(id)"
    }

    /// 主屏：菜单栏所在、原点为 0,0 的那块
    public static var primary: NSScreen? { NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first }

    /// AppKit 坐标 → 辅助功能坐标
    public static func axRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (primary?.frame.height ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 辅助功能坐标 → AppKit 坐标（和上面同一个换算，两个方向对称）
    public static func appKitRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (primary?.frame.height ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 这块屏上能放悬浮按钮的范围（辅助功能坐标）：去掉菜单栏那一块
    public static func usableArea(for id: DisplayID) -> CGRect? {
        screen(for: id).map { axRect(fromAppKit: $0.visibleFrame) }
    }
}

extension NSScreen {
    /// 这块屏的显示器编号（和 CGDirectDisplayID 同一个数）
    public var displayID: DisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
