// 字号：手机、平板屏已经是基准宽度（2 倍高清门槛内最窄的一档，见 ScreenFit），字再大只能靠 App 自己的 ⌘+ / ⌘-。
// 放上手机、平板屏时按这个 App 记住的级数放大（没记过就用设置里的默认级数），放回原位时按同样的级数缩回，
// 不用 ⌘0：那会把用户原来的字号也一起清掉。
// 浏览器不在名单里：它们按网站记缩放、一直记着，放大会连带同一网站的其它窗口，
// 换了网页再缩回又缩到别的网站上，改动收不回来。网页在 540 点宽的屏上本来就按窄屏排版。
// 名单里每个 App 都登记字号存在哪（ZoomScope）：窗口在 Snug 之外没了以后，靠它判断还有没有要缩回的、缩回给谁
import Foundation

/// 放大的字号存在哪（2026-11 读各 App 源码、实测 VS Code 确认）
public enum ZoomScope: Sendable {
    /// 只在开着的窗口里（Ghostty：每个窗格各一份）。窗口没了就没了，退出后恢复的窗口也不带；
    /// 只有关窗后几秒内「撤销关闭」恢复的窗口还带着（同一个进程里）
    case liveWindow
    /// 跟窗口存在一起（系统终端、iTerm2）：App 恢复这个窗口时连大小一起带回来，新开的窗口不带
    case restoredWindow
    /// 按工作区存（VS Code、Cursor）：重开这个工作区就带回来，大小却可能被 App 重设（屏不在了，VS Code 用默认大小）
    case workspace
    /// 整个 App 共用、只在内存里（Zed）：窗口没了还留在它别的窗口上，新开的窗口也带，App 退出才没
    case app
}

public struct ZoomBook: Codable, Equatable, Sendable {
    /// 支持 ⌘+ / ⌘- 调字号的 App，和它们的字号存在哪。不在名单里的不发按键：⌘= 在别的 App 里可能是别的意思
    public static let zoomableApps: [String: ZoomScope] = [
        "com.mitchellh.ghostty": .liveWindow,
        "com.apple.Terminal": .restoredWindow, "com.googlecode.iterm2": .restoredWindow,
        "com.microsoft.VSCode": .workspace, "com.todesktop.230313mzl4w4u92": .workspace,
        "dev.zed.Zed": .app,
        "ai.commandcode.desktop": .app,
    ]
    /// 相对原来最多缩小 / 放大几级
    public static let range = -4...8

    /// bundle ID → 这个 App 在手机、平板屏上放大几级
    public private(set) var remembered: [String: Int] = [:]

    public init() {}

    public static func isZoomable(_ bundleID: String?) -> Bool { scope(of: bundleID) != nil }

    /// 字号存在哪；不在名单里返回 nil
    public static func scope(of bundleID: String?) -> ZoomScope? { bundleID.flatMap { zoomableApps[$0] } }

    /// 放上手机、平板屏时该放大几级；不支持调字号的 App 返回 0
    public func steps(for bundleID: String?, default fallback: Int) -> Int {
        guard let bundleID, Self.isZoomable(bundleID) else { return 0 }
        return (remembered[bundleID] ?? fallback).clamped(to: Self.range)
    }

    public mutating func remember(_ steps: Int, for bundleID: String) {
        remembered[bundleID] = steps.clamped(to: Self.range)
    }

    /// 设置里改了默认级数：各 App 记住的一起清掉，以新的默认为准
    public mutating func forgetAll() { remembered = [:] }
}
