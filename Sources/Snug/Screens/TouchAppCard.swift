// 「运行中」页的一张 App 卡片：头上是 App（点它同点 Dock 图标；右边新建窗口、退出），下面是它的各个窗口
// （点一下放上这块屏，右边关掉）。放在这块屏上的那个窗口排第一、写明在这块屏上，紧跟一行字号和还原。
// 退出、关窗口都要再点一下确认，同一时刻只有一处在等确认（见 TouchHomeView.Confirm）
import AppKit
import SnugCore
import SwiftUI

/// 放在这块屏上的那个窗口怎么标：图标跟着屏的类别和方向，字样竖屏手机沿用「在手机屏上」（和 2.5 一样）
struct OnScreen {
    let text: String
    let symbol: String

    init(_ screen: ScreenConfig?) {
        text = screen.map { $0.device.kind == .phone && $0.orientation == .portrait } == true ? "在手机屏上" : "在这块屏上"
        symbol = screen?.symbol ?? "iphone"
    }
}

struct AppCard: View {
    /// 窗口按要显示的顺序（放在这块屏上的排第一，见 AppCatalog.app(of:)）
    let app: RunningApp
    let panel: PanelState
    let onScreen: OnScreen
    /// 这个 App 收藏了没有（App 资源库「全部」页里置顶）
    let favorited: Bool
    /// 客户端自己记的会话名（如 ZCode 的「新闻网站优化」）：有就盖过窗口标题，
    /// 因为有些客户端（OpenCode、Antigravity）把会话名写进了窗口标题、有些（ZCode）不写
    var sessionTitle: String? = nil
    /// 这个 App 此刻的 Agent 状态（在干活 / 已结束 / 不知道）。nil = 不是支持的 Agent 应用
    var activity: SessionActivity? = nil
    @Binding var confirming: TouchHomeView.Confirm?
    let icon: NSImage
    let intents: any TouchIntents

    private var quitting: Bool { panel.quitting.contains(app.pid) }
    private var askingQuit: Bool { confirming == .quit(app.pid) }
    /// 这个 App 放在这块屏上的窗口
    private var placed: Desk.Placed? { panel.placed.flatMap { $0.window.key.pid == app.pid ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(app.windows) { window in
                let isPlaced = window.key == placed?.window.key
                Divider().padding(.leading, AppRowLabel.textInset)
                WindowRow(window: window, isPlaced: isPlaced, onScreen: onScreen, closing: panel.closing.contains(window.key),
                          confirming: $confirming, intents: intents)
                if isPlaced, let placed {
                    PlacedControls(placed: placed, work: panel.work, intents: intents)
                }
            }
            .disabled(quitting)
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: TouchTokens.Space.s) {
            Button { intents.open(app.app) } label: {
                HStack(spacing: TouchTokens.Space.l) {
                    AppIcon(image: icon, size: TouchTokens.Size.listIcon)
                    VStack(alignment: .leading, spacing: TouchTokens.Space.xs) {
                        HStack(spacing: TouchTokens.Space.s) {
                            Text(app.app.name).font(TouchTokens.Font.headline.font).lineLimit(1)
                            // 支持的 Agent 应用：名字后面挂状态（在干活转圈 / 已结束圆点）
                            if let activity { AgentStatusMark(activity: activity) }
                        }
                        Text(subtitle)
                            .font(TouchTokens.Font.body.font)
                            .foregroundStyle(askingQuit ? .red : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: TouchTokens.Space.s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(quitting)
            actions
        }
        .padding(.leading, TouchTokens.Space.l)
        .padding(.trailing, TouchTokens.Space.m)
        .padding(.vertical, TouchTokens.Space.m)
    }

    private var subtitle: String {
        if askingQuit { return "退出 \(app.app.name)？" }
        if quitting { return "正在退出" }
        // 客户端自己有会话名就用它（ZCode 不往窗口标题写）；否则照旧显示窗口摘要
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        return app.windowSummary
    }

    @ViewBuilder private var actions: some View {
        if quitting {
            ProgressView().controlSize(.small).frame(width: TouchTokens.Size.touchTarget)
        } else if askingQuit {
            ConfirmButtons(title: "退出", confirming: $confirming) { intents.quit(app) }
        } else {
            HStack(spacing: TouchTokens.Space.s) {
                RoundButton(symbol: favorited ? "star.fill" : "star",
                            label: favorited ? "取消收藏" : "收藏",
                            tint: favorited ? TouchTokens.Color.tint : nil) {
                    intents.setFavorite(app.app.bundleID, !favorited)
                }
                RoundButton(symbol: "macwindow.badge.plus", label: "新建窗口") { intents.newWindow(app) }
                if AppList.canQuit(app.app) {
                    RoundButton(symbol: "xmark.app", label: "退出") { confirming = .quit(app.pid) }
                }
            }
        }
    }
}

/// App 卡片里的一个窗口：点一下放上这块屏，已经在这块屏上的就回到它；右边关掉它
private struct WindowRow: View {
    let window: WindowInfo
    let isPlaced: Bool
    let onScreen: OnScreen
    let closing: Bool
    @Binding var confirming: TouchHomeView.Confirm?
    let intents: any TouchIntents

    private var askingClose: Bool { confirming == .close(window.key) }

    var body: some View {
        HStack(spacing: TouchTokens.Space.s) {
            Button { isPlaced ? intents.returnToPlaced() : intents.pull(window) } label: {
                HStack(spacing: TouchTokens.Space.l) {
                    Image(systemName: isPlaced ? onScreen.symbol : "macwindow")
                        .font(TouchTokens.Font.headline.font.weight(.regular))
                        .foregroundStyle(isPlaced ? TouchTokens.Color.tint : .secondary)
                        .frame(width: TouchTokens.Size.listIcon)
                    Text(askingClose ? "关闭此窗口？" : window.displayTitle)
                        .font(TouchTokens.Font.body.font)
                        .foregroundStyle(askingClose ? Color.red : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !askingClose {
                        if isPlaced { Tag(text: onScreen.text, color: TouchTokens.Color.tint) }
                        if window.minimized { Tag(text: "已最小化", color: .secondary) }
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            trailing
        }
        .padding(.leading, TouchTokens.Space.l)
        .padding(.trailing, TouchTokens.Space.m)
        .frame(height: TouchTokens.Size.touchTarget)
        .disabled(closing)
    }

    @ViewBuilder private var trailing: some View {
        if closing {
            HStack(spacing: TouchTokens.Space.s) {
                ProgressView().controlSize(.small)
                Text("正在关闭").font(TouchTokens.Font.label.font).foregroundStyle(.secondary)
            }
        } else if askingClose {
            ConfirmButtons(title: "关闭", confirming: $confirming) { intents.close(window) }
        } else {
            Button { confirming = .close(window.key) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(TouchTokens.Font.headline.font.weight(.regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: TouchTokens.Size.touchTarget, height: TouchTokens.Size.touchTarget)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("关闭窗口")
        }
    }
}

/// 窗口行右边的小标签：在这块屏上、已最小化
private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(TouchTokens.Font.label.font)
            .foregroundStyle(color)
            .padding(.horizontal, TouchTokens.Space.s)
            .padding(.vertical, TouchTokens.Space.xxs)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 放在这块屏上那个窗口的字号和还原，排在它下面一行、和标题对齐。这个 App 调不了字号时只有还原
private struct PlacedControls: View {
    let placed: Desk.Placed
    let work: Desk.Work?
    let intents: any TouchIntents

    var body: some View {
        HStack(spacing: TouchTokens.Space.m) {
            if placed.zoomable {
                RoundButton(symbol: "textformat.size.smaller", label: "缩小字号") { intents.zoom(by: -1) }
                    .disabled(placed.zoom <= ZoomBook.range.lowerBound)
                Text(zoomText)
                    .font(TouchTokens.Font.body.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72)
                    .contentTransition(.numericText())
                RoundButton(symbol: "textformat.size.larger", label: "放大字号") { intents.zoom(by: 1) }
                    .disabled(placed.zoom >= ZoomBook.range.upperBound)
            }
            Spacer(minLength: TouchTokens.Space.s)
            Button { intents.putBack() } label: {
                HStack(spacing: TouchTokens.Space.s) {
                    if work == .puttingBack {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    Text("还原")
                }
                .font(TouchTokens.Font.body.font.weight(.medium))
                .padding(.horizontal, TouchTokens.Space.margin)
                .frame(height: TouchTokens.Size.touchTarget)
                .background(TouchTokens.Color.background, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.leading, AppRowLabel.textInset)
        .padding(.trailing, TouchTokens.Space.m)
        .padding(.bottom, TouchTokens.Space.m)
    }

    private var zoomText: String {
        placed.zoom == 0 ? "默认字号" : "字号 \(placed.zoom > 0 ? "+" : "")\(placed.zoom)"
    }
}
