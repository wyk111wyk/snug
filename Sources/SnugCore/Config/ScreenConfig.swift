// 屏幕列表里的一项：用户自己增删，每一项是一块虚拟屏（docs/how-it-works.md「屏幕列表」）。
// 方向添加时定、之后不改；型号随时能改（在线换比例，不撤屏）；名字显示在「显示器」设置和远控的屏幕列表里。
// 身份（序列号）添加时分配、写进配置、永不复用：系统按身份记住一块屏的设置、排布和 ICC 文件
import CoreGraphics
import Foundation

/// 触屏屏底部的控件：底部横条（点一下回 App 资源库），或浮在窗口上、可拖到任意位置的按钮。
/// 被 UU远程 的工具栏压在下面时换成悬浮按钮（见 docs/how-it-works.md「App 资源库」）
public enum TouchBarStyle: String, Codable, Sendable, CaseIterable {
    case dock
    case floating

    public var title: String {
        switch self {
        case .dock: "底部横条"
        case .floating: "悬浮按钮"
        }
    }
}

public struct ScreenConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: ScreenID
    public var orientation: Orientation
    public var device: DeviceChoice
    public var enabled: Bool
    public var name: String
    /// 主序列号加两个备用的（建了不上线就依次换）
    public var serials: [UInt32]
    /// 触屏屏底部的控件，默认底部横条
    public var touchBar: TouchBarStyle
    /// 悬浮按钮的位置：控件中心，按屏的可放区域归一化（0…1，左上原点）。nil 用默认位置（右缘居中）
    public var floatingAnchor: CGPoint?

    public init(id: ScreenID, orientation: Orientation, device: DeviceChoice, enabled: Bool = true, name: String, serials: [UInt32],
                touchBar: TouchBarStyle = .dock, floatingAnchor: CGPoint? = nil) {
        self.id = id
        self.orientation = orientation
        self.device = device
        self.enabled = enabled
        self.name = name
        self.serials = serials
        self.touchBar = touchBar
        self.floatingAnchor = floatingAnchor
    }

    private enum CodingKeys: String, CodingKey {
        case id, orientation, device, enabled, name, serials, touchBar, floatingAnchor
    }

    // 逐项解：新加的字段老配置里没有，用 decodeIfPresent 给默认值，不能因为缺它们把整块屏丢掉
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ScreenID.self, forKey: .id)
        orientation = try c.decode(Orientation.self, forKey: .orientation)
        device = try c.decode(DeviceChoice.self, forKey: .device)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        name = try c.decode(String.self, forKey: .name)
        serials = try c.decode([UInt32].self, forKey: .serials)
        touchBar = try c.decodeIfPresent(TouchBarStyle.self, forKey: .touchBar) ?? .dock
        floatingAnchor = try c.decodeIfPresent(CGPoint.self, forKey: .floatingAnchor).map(ScreenFit.clampedAnchor)
    }

    /// 2.5 以前那块「Snug 手机屏」：名字、身份都不变，远控里看到的和以前一样
    public static func legacyPhone(_ device: DeviceChoice, enabled: Bool) -> ScreenConfig {
        ScreenConfig(id: .phone, orientation: .portrait, device: device, enabled: enabled, name: legacyPhoneName,
                     serials: [200_000_108, 200_000_118, 200_000_128])
    }

    public static let legacyPhoneName = "Snug 手机屏"
    /// 同时最多这么多块（V8：四块同时在没问题，现实用不到更多）
    public static let limit = 4

    /// 按型号和方向起的名字：「Snug iPad」「Snug MacBook Air」「Snug iPhone 17 Pro Max 横屏」。
    /// 名字只是给人认的，重名也不影响（身份不同）；同一台设备横竖各一块时靠「横屏」「竖屏」分开
    public static func suggestedName(for device: DeviceChoice, orientation: Orientation) -> String {
        let base: String
        if let model = device.model, !model.hasPrefix("通用 ") {
            // 去掉括号里的代际和尺寸，留下一眼认得出的那部分（「iPad（第 10 代）」→「iPad」，「MacBook Air 13 英寸（M4）」→「MacBook Air」）
            let title = device.title
            let cut = title.firstIndex { "（(".contains($0) } ?? title.endIndex
            var words = title[..<cut].split(separator: " ").map(String.init)
            if let inch = words.firstIndex(where: { $0.hasPrefix("英寸") }) {
                words.removeSubrange(max(0, inch - 1)...inch)
            }
            base = "Snug " + words.joined(separator: " ")
        } else {
            base = switch device.kind {
            case .phone: "Snug 手机"
            case .tablet: "Snug 平板"
            case .computer: "Snug 电脑"
            }
        }
        // 这类设备平常的方向不加后缀
        guard orientation != device.kind.usualOrientation else { return base }
        return base + (orientation == .portrait ? " 竖屏" : " 横屏")
    }
}
