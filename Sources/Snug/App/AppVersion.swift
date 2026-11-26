// App 自己的版本号：来自 Info.plist（scripts/snug 打包时从仓库根的 VERSION 写入）。
// 开发时直接跑、没打包时读不到，返回 nil（界面显示「开发版」）。和 VERSION 一样是「多少内容升多少」，
// 看它就知道现在跑的是哪一版（关于窗口、设置「通用」页都读这里）
import Foundation
import SnugCore

enum AppVersion {
    nonisolated static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap(Version.init)

    /// 界面上显示的样子：版本号，读不到时「开发版」
    nonisolated static var text: String { current?.description ?? "开发版" }
}
