// 手机、平板屏上 Snug 自己的面板，每块屏一组（ScreenPanels 跟着屏幕列表建、拆；电脑屏没有面板，资源库从菜单栏打开）：
// 盖满整块屏的 App 资源库，窗口放上来后底部的小横条；开着截图键时还有截图后浮在小横条上方的缩略图或提示，
// 以及裁剪时盖满整块屏的裁剪界面。
// 跟着这块屏的 Desk 状态走：屏在才建，列表该露就露、该收就收，屏幕一变（含换档）就重新摆位置。
// 面板不抢焦点（点它不会激活 Snug），所有桌面都在，盖在这块屏的菜单栏之上；
// 只在搜索、选型号时临时接收键盘，用完就还回去，手机上的键盘输入平时留给放上来的窗口
import AppKit
import QuartzCore
import SnugCore
import SnugSystem
import SwiftUI

/// 各块手机、平板屏的面板：屏就绪（有 Desk、是触屏）就建一组，屏没了就拆。一块屏都没有时清空资源库，下次从头读
@MainActor
final class ScreenPanels {
    private let state: AppState
    private let catalog: AppCatalog
    private let intents: (ScreenID) -> any TouchIntents
    private var panels: [ScreenID: ScreenWindows] = [:]

    init(state: AppState, catalog: AppCatalog, intents: @escaping (ScreenID) -> any TouchIntents) {
        self.state = state
        self.catalog = catalog
        self.intents = intents
        follow()
    }

    private func follow() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow() } }
        }
    }

    private func update() {
        let touch = Set(state.desks.desks.filter { $0.value.behavior.touch }.keys)
        for id in panels.keys where !touch.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }
        for id in touch where panels[id] == nil {
            panels[id] = ScreenWindows(id: id, state: state, catalog: catalog, intents: intents(id))
        }
        if state.desks.desks.isEmpty { catalog.reset() }
    }
}

@MainActor
final class ScreenWindows {
    let id: ScreenID
    private let state: AppState
    private let catalog: AppCatalog
    private let pages = TouchPages()
    private let intents: any TouchIntents
    private var display: DisplayID?
    private var list: TouchPanel?
    /// 屏底部的控件：底部横条和 / 或悬浮按钮，跟着这块屏的行为走
    private var barKind: TouchBarStyle?
    private var dockBar: TouchPanel?
    private var dockView: HomeBarView?
    private var floatBar: TouchPanel?
    private var floatView: FloatingBarView?
    /// 长按悬浮按钮跳出的收藏应用快捷切换（浮在按钮上方）+ 它背后那层「点一下就关」的背景
    private var favorites: TouchPanel?
    private var favoritesScrim: TouchPanel?
    private var favoritesTimer: Timer?
    /// 已经点了、正在切过去的 App：等这块屏忙完再收起收藏条（点完立刻转圈，不是干等）
    private var pendingFavorite: AppInfo?
    private var favoriteWasWorking = false
    /// 快捷切换里最多列几个收藏的 App；点了以后最多等多久（切换本身要几秒）。不点不会自己关
    static let favoritesLimit = 6
    static let favoritesSwitchTimeout: TimeInterval = 15
    /// 截图后浮在小横条上方的那一块（缩略图或提示），和它此刻显示的是什么
    private var overlay: TouchPanel?
    private var overlayShown: OverlayShown?
    private var cropPanel: TouchPanel?
    private var screenObserver: (any NSObjectProtocol)?
    private var closed = false
    /// 底部控件此刻露着没有：露出来的那一下让悬浮按钮重新计时（空闲变淡）
    private var barsShown = false

    init(id: ScreenID, state: AppState, catalog: AppCatalog, intents: any TouchIntents) {
        self.id = id
        self.state = state
        self.catalog = catalog
        self.intents = intents
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // 先按此刻的状态铺一遍：屏可能在面板建出来之前就绪了，不能只等下一次变化
        update()
        follow()
    }

    /// 屏没了：拆掉面板，不再跟
    func close() {
        closed = true
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        tearDown(because: "这块屏不在列表里了，或不再是手机、平板屏")
    }

    /// 截图浮层只在截图的那块屏上
    private var screenshot: ScreenshotOverlay? { state.screenshotScreen == id ? state.screenshotOverlay : nil }

    private func follow() {
        withObservationTracking {
            _ = state.desks.desks[id]
            _ = state.desks.quitting
            _ = state.streamedDisplay
            _ = state.screensInUse
            _ = state.screenshotOverlay
            _ = state.screenshotScreen
            _ = state.config.screenshot
            _ = pages.active
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.update()
                    self.follow()
                }
            }
        }
    }

    private func update() {
        guard !closed else { return }
        let panel = state.panel(id)
        guard let display = panel.display else { return tearDown(because: "屏撤掉了") }
        guard let screen = Screens.screen(for: display) else { return tearDown(because: "系统里还没有 #\(display) 这块屏") }
        if display != self.display {
            tearDown(because: "换到 #\(display)")
            build(on: display)
        }
        // 底部控件换了样式（横条 ⇄ 悬浮按钮 ⇄ 两个都要）：只重建这两块，不动资源库
        if panel.behavior.bar != barKind { rebuildBars(panel.behavior.bar, on: display) }
        // 收藏快捷切换：点了以后这块屏会忙起来，等它做完再收起收藏条（这期间收藏条上的那个在转圈）
        if pendingFavorite != nil {
            if panel.work != nil { favoriteWasWorking = true }
            else if favoriteWasWorking { hideFavorites() }
        }
        guard let list else { return }
        list.setFrame(screen.frame, display: true)
        let scale = ScreenFit.scale(screen: screen.frame.size)
        dockBar?.setFrame(dockBarFrame(on: screen), display: true)
        dockView?.scale = scale
        // 有横条时它才画箭头、才放相机键；只有悬浮按钮时这一条只铺底色，不画箭头
        dockView?.showsGrabber = panel.behavior.bar.docks
        dockView?.showsCamera = state.config.screenshot && panel.behavior.bar.docks
        if let frame = floatingBarFrame(on: screen) {
            // 悬浮按钮正在被拖：别在当前这拍把它拽回记下的位置（松手时自己会记新的）
            if floatView?.isDragging != true { floatBar?.setFrame(frame, display: true) }
            floatView?.scale = scale
            // 有横条时相机键在横条上，悬浮按钮不重复放一个
            floatView?.showsCamera = state.config.screenshot && !panel.behavior.bar.docks
        }

        let showList = panel.listVisible || panel.placed == nil
        let watching = state.watching(id)
        if showList { list.orderFrontRegardless() } else { list.orderOut(nil) }
        // 手机离开了就关掉搜索、型号页，交还键盘：不然在主屏上打的字会进到看不见的输入框
        if !showList || !watching { pages.close() }
        // 手机离开了还在裁剪：取消回到缩略图，不然这块屏的手势翻译一直停着，手机上又看不到裁剪界面
        if !watching, screenshot?.isCropping == true {
            Log.info("手机离开了屏（\(id)），取消这块屏上的截图裁剪")
            intents.cancelCrop()
        }
        // 只在打开页面那一下拿键盘：之后用户点了别的窗口，不能每次状态一变就抢回来
        let entering = pages.active && !list.acceptsKeys
        list.acceptsKeys = pages.active
        if entering { list.makeKey() }
        // 列表每轮要把所有 App 的窗口读一遍，还和搬窗口共用一条队：手机没在看这块屏就不为它刷
        if showList, watching {
            catalog.want(id.rawValue, busy: panel.work != nil)
        } else {
            catalog.release(id.rawValue)
        }
        let cropping = screenshot?.isCropping == true
        let barsVisible = panel.placed != nil && !showList && !cropping
        if barsVisible {
            // 刚从收起变成露出：悬浮按钮恢复不透明、重新计时（空闲变淡）
            if !barsShown { floatView?.beginIdleCountdown() }
            dockBar?.orderFrontRegardless()
            floatBar?.orderFrontRegardless()
        } else {
            dockBar?.orderOut(nil)
            floatBar?.orderOut(nil)
            hideFavorites()
        }
        barsShown = barsVisible
        updateOverlay(on: screen, hidden: showList)
        updateCrop(on: screen)
    }

    /// 截图后的浮层：缩略图靠左、正在相机键上方（点它进裁剪），提示居中（不拦点击）。
    /// 面板只有内容那么大，不挡窗口底部别的地方；回到 App 资源库、裁剪时不显示。
    /// 不显示时连面板一起拆掉：缩略图拿着解码后的整张截图，不留着占内存
    private func updateOverlay(on screen: NSScreen, hidden: Bool) {
        guard !hidden, let shot = screenshot, !shot.isCropping else {
            overlay?.orderOut(nil)
            overlay = nil
            overlayShown = nil
            return
        }
        let scale = ScreenFit.scale(screen: screen.frame.size)
        let panel = overlay ?? TouchPanel(content: NSView(), opaque: false)
        overlay = panel
        let preview = if case .preview = shot { true } else { false }
        let shown = OverlayShown(overlay: shot, scale: scale)
        if shown != overlayShown {
            overlayShown = shown
            if case .preview(let image) = shot {
                panel.contentView = FirstMouseHostingView(rootView: ScreenshotThumbnail(
                    image: NSImage(data: image.png) ?? NSImage(), scale: scale) { [weak self] in self?.intents.openCrop() })
            } else if case .notice(let notice) = shot {
                panel.contentView = NSHostingView(rootView: ScreenshotNoticeView(notice: notice, scale: scale))
            }
            panel.ignoresMouseEvents = !preview
        }
        let size = panel.contentView?.fittingSize ?? .zero
        let barRect = overlayAnchorFrame(on: screen)
        // 横条：缩略图靠左、就在相机键上方；悬浮按钮：靠它左上方。提示都居中在它的上方
        let x = preview ? barRect.minX + 12 * scale : barRect.midX - size.width / 2
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: barRect.maxY + 8 * scale), size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// 裁剪界面：盖满这块屏。进裁剪时建（图片只解码这一次），出裁剪就拆
    private func updateCrop(on screen: NSScreen) {
        guard case .cropping(let image) = screenshot else {
            cropPanel?.orderOut(nil)
            cropPanel = nil
            return
        }
        let panel = cropPanel ?? TouchPanel(content: FirstMouseHostingView(rootView: CropView(
            image: NSImage(data: image.png) ?? NSImage(), pixelSize: image.size,
            onCancel: { [weak self] in self?.intents.cancelCrop() },
            onDone: { [weak self] selection in self?.intents.finishCrop(selection) }).screenPanel(id, state: state)))
        cropPanel = panel
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    private func build(on id: DisplayID) {
        Log.info("屏（\(self.id)）的列表、底部控件建在 #\(id) 上")
        display = id
        list = TouchPanel(content: FirstMouseHostingView(rootView: TouchHomeView(screen: self.id, state: state, catalog: catalog, pages: pages,
                                                                                 intents: intents).screenPanel(self.id, state: state)))
        buildBars(panelBehavior.bar)
    }

    /// 这块屏此刻该用哪种底部控件（按行为走）
    private var panelBehavior: ScreenBehavior { state.desks.desks[id]?.behavior ?? .touchScreen }

    /// 建底部控件：底部那一条一直在（窗口高度不随之变），没有横条时只铺底色、不画箭头；要悬浮按钮再建一个
    private func buildBars(_ kind: TouchBarStyle) {
        barKind = kind
        buildDock()
        if kind.floats { buildFloat() }
    }

    private func buildDock() {
        let view = HomeBarView()
        view.onActivate = { [weak self] in self?.intents.showList() }
        view.onCapture = { [weak self] in self?.intents.takeScreenshot() }
        dockView = view
        dockBar = TouchPanel(content: view)
    }

    private func buildFloat() {
        let view = FloatingBarView()
        // 切换条开着时点按钮：先收切换条，再回主页
        view.onActivate = { [weak self] in
            self?.hideFavorites()
            self?.intents.showList()
        }
        view.onCapture = { [weak self] in self?.intents.takeScreenshot() }
        view.onMoved = { [weak self] frame in self?.commitAnchor(frame) }
        view.onLongPress = { [weak self] in self?.showFavorites() }
        floatView = view
        // 悬浮按钮是个圆，面板透明（背景由按钮自己画）
        floatBar = TouchPanel(content: view, opaque: false)
    }

    /// 换了底部控件：拆掉旧的两块面板，按新样式重建（资源库面板不动）
    private func rebuildBars(_ kind: TouchBarStyle, on display: DisplayID) {
        Log.info("屏（\(self.id)）的底部控件换成\(kind.title)")
        hideFavorites()
        dockBar?.orderOut(nil)
        floatBar?.orderOut(nil)
        floatView?.stopIdleCountdown()
        dockBar = nil
        dockView = nil
        floatBar = nil
        floatView = nil
        buildBars(kind)
        guard let screen = Screens.screen(for: display) else { return }
        dockBar?.setFrame(dockBarFrame(on: screen), display: true)
        if let frame = floatingBarFrame(on: screen) { floatBar?.setFrame(frame, display: true) }
    }

    private func tearDown(because reason: String) {
        if let display { Log.info("屏（\(id)）在 #\(display) 上的列表、底部控件拆掉：\(reason)") }
        catalog.release(id.rawValue)
        pages.close()
        list?.orderOut(nil)
        dockBar?.orderOut(nil)
        floatBar?.orderOut(nil)
        floatView?.stopIdleCountdown()
        hideFavorites()
        overlay?.orderOut(nil)
        cropPanel?.orderOut(nil)
        list = nil
        dockBar = nil
        dockView = nil
        floatBar = nil
        floatView = nil
        barKind = nil
        overlay = nil
        overlayShown = nil
        cropPanel = nil
        display = nil
    }

    /// 底部横条在这一档屏上的外框：可见区底部那一条（放上来的窗口正好让出它，见 ScreenFit.homeBarHeight）
    private func dockBarFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(x: visible.minX, y: visible.minY, width: visible.width,
                      height: ScreenFit.homeBarHeight(screen: screen.frame.size))
    }

    /// 悬浮按钮的外框：浮在窗口上，按记下的位置摆（见 ScreenFit.floatingBarFrame）。这块屏没要悬浮按钮时 nil
    private func floatingBarFrame(on screen: NSScreen) -> NSRect? {
        guard barKind?.floats == true else { return nil }
        let area = Screens.axRect(fromAppKit: screen.visibleFrame)
        let frame = ScreenFit.floatingBarFrame(in: area, anchor: state.screen(id)?.floatingAnchor,
                                               showsCamera: state.config.screenshot)
        return Screens.appKitRect(fromAX: frame)
    }

    /// 截图浮层靠哪一块摆：有悬浮按钮就靠它，否则靠底部横条
    private func overlayAnchorFrame(on screen: NSScreen) -> NSRect {
        floatingBarFrame(on: screen) ?? dockBarFrame(on: screen)
    }

    /// 悬浮按钮拖完了：按它落下的位置记成归一化的锚点，再把面板夹回屏内（拖到屏外的部分回弹）
    private func commitAnchor(_ frame: NSRect) {
        guard let display, let area = Screens.usableArea(for: display) else { return }
        let anchor = ScreenFit.floatingAnchor(of: Screens.axRect(fromAppKit: frame), in: area)
        let clamped = ScreenFit.floatingBarFrame(in: area, anchor: anchor, showsCamera: state.config.screenshot)
        floatBar?.setFrame(Screens.appKitRect(fromAX: clamped), display: true)
        intents.setFloatingAnchor(anchor)
    }

    // MARK: 收藏的快捷切换（长按悬浮按钮）

    /// 长按悬浮按钮：把收藏的几个 App（带当前活跃窗口名）浮在按钮上方，点一个就切到它。没有收藏时什么都不弹。
    /// 不点不会自己关：右上角 ✕ 关，点列表外的背景也关
    private func showFavorites() {
        guard let display, let screen = Screens.screen(for: display) else { return }
        let rows = favoriteRows()
        guard !rows.isEmpty else { return }
        hideFavorites()
        let scale = ScreenFit.scale(screen: screen.frame.size)
        // 背后那层：点它就关
        let dismiss = DismissView()
        dismiss.onTap = { [weak self] in self?.hideFavorites() }
        let scrim = TouchPanel(content: dismiss, opaque: false)
        scrim.setFrame(screen.frame, display: true)
        scrim.orderFrontRegardless()
        // 列表卡片
        let host = FirstMouseHostingView(rootView: FavoriteSwitcher(
            rows: rows,
            icon: { [weak self] in self?.catalog.icon(for: $0) ?? NSImage() },
            pick: { [weak self] in self?.pickFavorite($0) },
            close: { [weak self] in self?.hideFavorites() }))
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let anchor = overlayAnchorFrame(on: screen)
        let margin = 8 * scale
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + margin)
        origin.x = min(max(origin.x, visible.minX + margin), max(visible.minX + margin, visible.maxX - margin - size.width))
        // 上面放不下就放到按钮下方；两边都放不下就夹回屏内
        if origin.y + size.height > visible.maxY - margin { origin.y = anchor.minY - margin - size.height }
        origin.y = min(max(origin.y, visible.minY + margin), max(visible.minY + margin, visible.maxY - margin - size.height))
        let panel = TouchPanel(content: host, opaque: false)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        favorites = panel
        favoritesScrim = scrim
        // 悬浮按钮留在最上面：切换条在时，点它仍然能回主页
        floatBar?.orderFrontRegardless()
    }

    /// 第一行是这块屏上正在前台的那个 App（不管收没收藏），其余是收藏的 App（去掉已经在前台的那个），一共最多 favoritesLimit 行
    private func favoriteRows() -> [FavoriteSwitcher.Row] {
        var rows: [FavoriteSwitcher.Row] = []
        let placed = state.panel(id).placed?.window
        if let placed {
            rows.append(FavoriteSwitcher.Row(app: catalog.app(of: placed).app, window: placed.displayTitle, active: true))
        }
        let rest = catalog.installed
            .filter { state.config.favorites.contains($0.app.bundleID) && $0.app.bundleID != placed?.bundleID }
            .prefix(Self.favoritesLimit - rows.count)
            .map { item -> FavoriteSwitcher.Row in
                let running = catalog.running(item.app)
                let window = running?.windows.first?.displayTitle
                return FavoriteSwitcher.Row(app: item.app, window: window ?? (running == nil ? "未运行" : "无窗口"), active: false)
            }
        return rows + rest
    }

    private func pickFavorite(_ app: AppInfo) {
        // 不马上收起：选中的那行转圈，等这块屏做完再收（见 update）
        pendingFavorite = app
        favoriteWasWorking = false
        armFavoritesTimeout()
        intents.open(app)
    }

    /// 点了以后留个兜底：切换的正常路径会先把收藏条收掉，这条只防止它一直挂着
    private func armFavoritesTimeout() {
        favoritesTimer?.invalidate()
        let timer = Timer(timeInterval: Self.favoritesSwitchTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideFavorites() }
        }
        RunLoop.main.add(timer, forMode: .common)
        favoritesTimer = timer
    }

    private func hideFavorites() {
        favoritesTimer?.invalidate()
        favoritesTimer = nil
        favoritesScrim?.orderOut(nil)
        favoritesScrim = nil
        favorites?.orderOut(nil)
        favorites = nil
        pendingFavorite = nil
        favoriteWasWorking = false
    }

    /// 浮层上显示的截图结果和当时的倍率：换了才重建视图
    private struct OverlayShown: Equatable {
        let overlay: ScreenshotOverlay
        let scale: CGFloat
    }
}

/// 不抢焦点、所有桌面都在、盖住菜单栏的面板。截图的浮层是圆角卡片，面板透明（opaque 传 false）
final class TouchPanel: NSPanel {
    init(content: NSView, opaque: Bool = true) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 菜单栏是 24，菜单栏右边的图标是 25：再高一级才盖得住
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = opaque
        backgroundColor = opaque ? TouchTokens.Color.backgroundNSColor : .clear
        contentView = content
    }

    /// 平时点面板不让它变成键盘焦点：手机上的键盘输入要留给放上来的窗口；搜索、选型号时才打开
    var acceptsKeys = false {
        didSet {
            // 交还键盘：收起再摆回去才会让出焦点（resignKey 只是通知，调了也还是焦点）
            guard !acceptsKeys, isKeyWindow, isVisible else { return }
            orderOut(nil)
            orderFrontRegardless()
        }
    }

    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }
}

/// 面板不是键盘焦点，第一下点击也要直接生效
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 底部小横条：点一下，或者往上滑，回到 App 资源库。中间是 SF Symbols 的 chevron.compact.up；
/// 开着截图键时左边多一个相机键（camera.viewfinder），点左边这一段是截图。
/// 屏换到更宽的一档时跟着放大（scale），在手机上看着、点着、滑着都和基准宽度一样
final class HomeBarView: NSView {
    /// 基准宽度下往上滑过这么多点算数
    static let swipeDistance: CGFloat = 12

    var onActivate: (() -> Void)?
    var onCapture: (() -> Void)?
    /// 这一档比基准宽度宽几倍（ScreenFit.scale）
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { updateIcons() } }
    }
    /// 设置里开着「截图」
    var showsCamera = false {
        didSet { camera.isHidden = !showsCamera }
    }
    /// 画不画返回箭头：是底部横条时画；只有悬浮按钮时这一条只铺底色、不画箭头
    var showsGrabber = true {
        didSet { grabber.isHidden = !showsGrabber }
    }
    private let grabber = NSImageView()
    private let camera = NSImageView()
    private var swipe: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        updateIcons()
        grabber.contentTintColor = .secondaryLabelColor
        camera.contentTintColor = .secondaryLabelColor
        camera.imageScaling = .scaleNone
        camera.isHidden = true
        addSubview(camera)
        grabber.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grabber)
        NSLayoutConstraint.activate([
            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 加载") }

    private func updateIcons() {
        grabber.image = NSImage(systemSymbolName: "chevron.compact.up", accessibilityDescription: "App 资源库")?
            .withSymbolConfiguration(.init(pointSize: 22 * scale, weight: .semibold))
        camera.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")?
            .withSymbolConfiguration(.init(pointSize: 20 * scale, weight: .semibold))
        needsLayout = true
    }

    /// 相机键的点击范围：左边整条高、一个手指宽（图标只有二十几点）。图标摆在它正中
    private var cameraArea: NSRect { NSRect(x: 0, y: 0, width: TouchTokens.Size.touchTarget * scale, height: bounds.height) }

    override func layout() {
        super.layout()
        camera.frame = cameraArea
    }

    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 图标只是装饰，点哪儿都由横条自己接：子视图不接面板的第一下点击（acceptsFirstMouse 默认 false）
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        TouchTokens.Color.backgroundNSColor.setFill()
        bounds.fill()
    }

    /// 接住按下，抬起才会送到这里
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if showsCamera, cameraArea.contains(point) { onCapture?() } else { onActivate?() }
    }

    /// 手势翻译把单指上滑变成滚动：手指往上走，滚动量是负的
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { swipe = 0 }
        swipe += event.scrollingDeltaY
        if swipe <= -Self.swipeDistance * scale {
            swipe = 0
            onActivate?()
        }
    }
}

/// 悬浮按钮：浮在铺满的窗口之上，点一下回 App 资源库，按住可拖到屏内任意位置；开着截图时左边多一个相机键。
/// 面板只有控件那么大，背景是圆的（面板透明）。和底部横条不同，它不在屏上占一条：按下时手势翻译让开它那一块
/// （TouchRegion 的洞），事件原样到这儿，拖动移动面板本身，松手把落点交回 ScreenWindows 记进配置。
/// 屏换到更宽的一档时跟着放大（scale），在手机上看着、点着、拖着都和基准宽度一样
final class FloatingBarView: NSView {
    /// 基准宽度下挪过这么多点才算拖动（比手势翻译的 10 点宽容些：手指搭在按钮上会轻微漂，别把长按误判成拖动）
    static let dragThreshold: CGFloat = 16
    /// 按住不动这么久算长按（跳出收藏的快捷切换）
    static let holdDelay: TimeInterval = 0.5
    /// 一段时间没碰就淡到这个透明度，好看清下面的内容；一碰就恢复
    static let idleAlpha: CGFloat = 0.3
    static let idleDelay: TimeInterval = 4

    var onActivate: (() -> Void)?
    var onCapture: (() -> Void)?
    /// 长按：跳出收藏的应用快捷切换
    var onLongPress: (() -> Void)?
    /// 拖完了：交回控件所在的窗口外框（AppKit 坐标），由 ScreenWindows 换算成归一化位置存起来
    var onMoved: ((NSRect) -> Void)?
    /// 这一档比基准宽度宽几倍（ScreenFit.scale）
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { updateIcons(); needsLayout = true } }
    }
    /// 设置里开着「截图」
    var showsCamera = false {
        didSet {
            guard showsCamera != oldValue else { return }
            camera.isHidden = !showsCamera
            needsLayout = true
            needsDisplay = true
        }
    }
    private let grabber = NSImageView()
    private let camera = NSImageView()
    /// 长按的进度环：按住时从 0 画满到 1（时长 = holdDelay），让人知道正在长按
    private let holdRing = CAShapeLayer()
    /// 按下那一刻在屏幕坐标里的指针位置和窗口原点
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var moved = false
    /// 正在拖着（按下到抬起之间）：ScreenWindows 别在这一刻把它摆回记下的位置
    private(set) var isDragging = false
    /// 空闲变淡的计时器
    private var fadeTimer: Timer?
    /// 长按计时器；longPressed 记着这次按下已经当长按处理过了
    private var holdTimer: Timer?
    private var longPressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateIcons()
        grabber.contentTintColor = .secondaryLabelColor
        camera.contentTintColor = .secondaryLabelColor
        camera.imageScaling = .scaleNone
        camera.isHidden = true
        addSubview(camera)
        addSubview(grabber)
        holdRing.fillColor = nil
        holdRing.strokeColor = NSColor.systemBlue.cgColor
        holdRing.lineCap = .round
        holdRing.strokeEnd = 0
        holdRing.isHidden = true
        layer?.addSublayer(holdRing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 加载") }

    private func updateIcons() {
        grabber.image = NSImage(systemSymbolName: "chevron.compact.up", accessibilityDescription: "App 资源库")?
            .withSymbolConfiguration(.init(pointSize: 30 * scale, weight: .semibold))
        camera.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")?
            .withSymbolConfiguration(.init(pointSize: 26 * scale, weight: .semibold))
        needsLayout = true
    }

    private var diameter: CGFloat { bounds.height }
    /// 相机键那个圆：左边一整个圆的直径见方
    private var cameraArea: NSRect { NSRect(x: 0, y: 0, width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        let d = diameter
        camera.frame = cameraArea
        grabber.frame = NSRect(x: bounds.width - d, y: 0, width: d, height: d)
        // 进度环套在主按钮那个圆的外沿
        let ringRect = NSRect(x: bounds.width - d, y: 0, width: d, height: d).insetBy(dx: 2.5 * scale, dy: 2.5 * scale)
        holdRing.frame = bounds
        holdRing.lineWidth = 3 * scale
        holdRing.path = CGPath(ellipseIn: ringRect, transform: nil)
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 图标只是装饰，点哪儿都由控件自己接
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = diameter
        drawKnob(NSRect(x: bounds.width - d, y: 0, width: d, height: d))
        if showsCamera { drawKnob(cameraArea) }
    }

    /// 一个圆：卡片色底 + 细描边。不画阴影——面板正好是控件那么大，阴影会被裁掉，留着不画
    private func drawKnob(_ rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        TouchTokens.Color.cardNSColor.setFill()
        circle.fill()
        TouchTokens.Color.separatorNSColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    /// 露出来时调：恢复不透明，重新计时
    func beginIdleCountdown() {
        setDimmed(false)
        restFade()
    }

    /// 拆掉时调：停掉计时器，免得它留着
    func stopIdleCountdown() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func restFade() {
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDimmed(true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func setDimmed(_ dimmed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionTokens.fast
            animator().alphaValue = dimmed ? Self.idleAlpha : 1
        }
    }

    /// 按住时进度环从 0 画满到 1（时长 = holdDelay），让人知道正在长按
    private func startHoldRing() {
        holdRing.removeAllAnimations()
        holdRing.isHidden = false
        holdRing.strokeEnd = 0
        let grow = CABasicAnimation(keyPath: "strokeEnd")
        grow.fromValue = 0
        grow.toValue = 1
        grow.duration = Self.holdDelay
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        holdRing.strokeEnd = 1
        holdRing.add(grow, forKey: "hold")
    }

    private func stopHoldRing() {
        holdRing.removeAllAnimations()
        holdRing.strokeEnd = 0
        holdRing.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        moved = false
        longPressed = false
        isDragging = true
        // 一碰就恢复不透明，并在松手后再重新计时
        setDimmed(false)
        fadeTimer?.invalidate()
        startHoldRing()
        Log.info("悬浮按钮：按下")
        // 按住不动一会儿：跳出收藏的快捷切换
        let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDragging, !self.moved else { return }
                self.longPressed = true
                Log.info("悬浮按钮：长按，弹出收藏切换")
                self.onLongPress?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        if !moved, hypot(dx, dy) >= Self.dragThreshold * scale {
            moved = true
            holdTimer?.invalidate()
            holdTimer = nil
            stopHoldRing()   // 是在拖，不是在长按
            Log.info("悬浮按钮：当作拖动（已挪 \(Int(hypot(dx, dy))) 点），不认长按")
        }
        guard moved else { return }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        stopHoldRing()
        isDragging = false
        restFade()
        guard let window else { return }
        if moved {
            onMoved?(window.frame)
            return
        }
        // 已经当过长按了：这次抬起不再当点一下
        if longPressed {
            longPressed = false
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if showsCamera, cameraArea.contains(point) {
            Log.info("悬浮按钮：点相机键")
            onCapture?()
        } else {
            Log.info("悬浮按钮：点一下，回 App 资源库")
            onActivate?()
        }
    }
}
