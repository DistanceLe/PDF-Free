import AppKit
import PDFKit

/// 按住空格 + 拖动平移页面（Photoshop 的抓手工具）。
///
/// 需要拦两套事件：
/// - `.keyDown` / `.keyUp` 跟踪空格按下状态，并把空格吞掉（否则 PDFView 会用它翻页）
/// - `.leftMouseDown` / `.leftMouseDragged` / `.leftMouseUp` 在抓手模式下平移
///
/// 另外还要持续重申光标：PDFView 有自己的 cursor rect，鼠标一动就会把光标改回 I-beam，
/// 所以在抓手模式期间监听 `.mouseMoved` 把 openHand / closedHand 按回去。
///
/// ## ⚠️ 必须**按窗口**记状态（v1.3.41）
///
/// 原来这个类只存**一个** `pdfView`（`attach` 里还会先 `detach()`）—— 那是在
/// "一个窗口装所有文件"的时代写的。改成一个文件一个窗口之后，症状是：
///
/// ```
/// 打开 A → attach(A)
/// 打开 B → attach(B)（把 A 顶掉了）
/// 切回 A → 空格拖拽完全没反应
/// ```
///
/// 因为 `handleKeyEvent` / `handleMouseEvent` 里都有一句
/// `event.window === pdfView.window` —— 那个 `pdfView` 已经是 B 的了。
///
/// 现在改成一张"每个 PDFView 一份状态"的表，事件按 `event.window` 找到对应那一份。
/// 监听器仍然是**全局**的一份（local monitor 本来就是整个 app 级的），
/// 只有最后一个 PDFView 也卸掉时才移除。
@MainActor
final class SpaceDragPanMonitor {

    static let shared = SpaceDragPanMonitor()

    private init() {}

    /// 空格键的虚拟键码
    private static let spaceKeyCode: UInt16 = 49

    /// 一个 PDFView 的抓手状态。这些字段**不能**放在类上共用 ——
    /// 每个窗口各有自己的空格按下状态与拖动进度。
    private struct Session {
        weak var pdfView: PDFView?
        var isSpaceDown = false
        var isDragging = false
        var lastLocationInWindow: CGPoint?
        /// 进入抓手模式前的 `acceptsMouseMovedEvents` 原值，退出时还原
        var savedAcceptsMouseMoved: Bool?
        /// 窗口失焦时兜底复位用
        var resignObserver: NSObjectProtocol?
    }

    private var sessions: [ObjectIdentifier: Session] = [:]

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var cursorMonitor: Any?

    /// 仅供自动化验证：现在挂在哪些窗口上（多窗口时必须是**好几个**）。
    ///
    /// 这一条直接对应"切回旧文件后空格拖拽失效"那个 bug —— 修复前这里只会有一个。
    var attachedWindowTitles: [String] {
        sessions.values.compactMap { $0.pdfView?.window?.title }
    }

    // MARK: - 生命周期

    func attach(to pdfView: PDFView) {
        let key = ObjectIdentifier(pdfView)
        // 重复 attach（`updateNSView` 会反复调）只刷新引用，别把状态清掉 ——
        // 清掉的话正在按住空格拖动的过程中一切换就断了
        if sessions[key] != nil {
            sessions[key]?.pdfView = pdfView
        } else {
            sessions[key] = Session(pdfView: pdfView)
        }
        installMonitorsIfNeeded()
    }

    func detach(from pdfView: PDFView) {
        let key = ObjectIdentifier(pdfView)
        guard let session = sessions.removeValue(forKey: key) else { return }
        // 先还原窗口状态，再丢引用（顺序反了就拿不到窗口了）
        if let saved = session.savedAcceptsMouseMoved, let window = session.pdfView?.window {
            window.acceptsMouseMovedEvents = saved
        }
        if let observer = session.resignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if sessions.isEmpty {
            removeMonitors()
        }
    }

    private func installMonitorsIfNeeded() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event) ? nil : event
        }

        cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.refreshCursorIfNeeded(for: event)
            return event
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, mouseMonitor, cursorMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        mouseMonitor = nil
        cursorMonitor = nil
    }

    /// 事件发生在哪个 PDFView 所在的窗口上。
    ///
    /// 顺手做两件清理：`pdfView` 已经没了（视图被销毁但没走 detach）的直接扔掉。
    private func sessionKey(matching window: NSWindow?) -> ObjectIdentifier? {
        guard let window else { return nil }
        var found: ObjectIdentifier?
        for (key, session) in sessions {
            if session.pdfView == nil {
                sessions.removeValue(forKey: key)
                continue
            }
            if session.pdfView?.window === window, found == nil {
                found = key
            }
        }
        return found
    }

    // MARK: - 空格键

    /// 这一份 PDFView 是不是被「页面管理」浮层盖住了。
    ///
    /// 盖着的时候空格拖拽不该去动底下那份 PDF —— 用户看不见它，
    /// 但滚动位置却真的被改了（关掉浮层才发现"页面跑偏了"）。
    private func isCoveredByPageManager(_ pdfView: PDFView) -> Bool {
        AppModelBridge.isPageManagerVisible(for: pdfView.window)
    }

    /// 返回 true 表示吞掉该事件
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let key = sessionKey(matching: event.window),
              let pdfView = sessions[key]?.pdfView, pdfView.window != nil else { return false }
        guard !isCoveredByPageManager(pdfView) else { return false }
        // 只在 PDFView 所在窗口生效，别把 sheet（签名、批注输入）里的空格也吞了
        guard event.keyCode == Self.spaceKeyCode else { return false }
        // 正在文本框里输入（搜索框）时不能抢空格，否则打不出空格
        guard !isEditingText(in: event.window) else { return false }

        switch event.type {
        case .keyDown:
            if sessions[key]?.isSpaceDown == false && !event.isARepeat {
                sessions[key]?.isSpaceDown = true
                beginHandMode(key: key, window: event.window)
                updateCursor(key: key)
            }
            // 按住期间的所有 keyDown（含自动重复）都吞掉，避免 PDFView 空格翻页
            return true

        case .keyUp:
            sessions[key]?.isSpaceDown = false
            sessions[key]?.isDragging = false
            sessions[key]?.lastLocationInWindow = nil
            restoreMouseMovedTracking(key: key)
            updateCursor(key: key)
            return true

        default:
            return false
        }
    }

    private func isEditingText(in window: NSWindow?) -> Bool {
        // NSTextField 进入编辑态时 firstResponder 是 field editor（NSTextView 子类）
        window?.firstResponder is NSTextView
    }

    // MARK: - 鼠标拖动

    /// 返回 true 表示吞掉该事件
    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard let key = sessionKey(matching: event.window),
              sessions[key]?.isSpaceDown == true,
              let pdfView = sessions[key]?.pdfView else { return false }
        guard !isCoveredByPageManager(pdfView) else { return false }

        switch event.type {
        case .leftMouseDown:
            let point = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(point) else { return false }
            // 吞掉 mouseDown，PDFView 就不会开始文本选择
            sessions[key]?.isDragging = true
            sessions[key]?.lastLocationInWindow = event.locationInWindow
            updateCursor(key: key)
            return true

        case .leftMouseDragged:
            guard sessions[key]?.isDragging == true,
                  let previous = sessions[key]?.lastLocationInWindow else { return false }
            pan(pdfView: pdfView, from: previous, to: event.locationInWindow)
            sessions[key]?.lastLocationInWindow = event.locationInWindow
            return true

        case .leftMouseUp:
            guard sessions[key]?.isDragging == true else { return false }
            sessions[key]?.isDragging = false
            sessions[key]?.lastLocationInWindow = nil
            updateCursor(key: key)
            return true

        default:
            return false
        }
    }

    private func pan(pdfView: PDFView, from previous: CGPoint, to current: CGPoint) {
        // locationInWindow 是 window 基础坐标系：原点左下、y 向上
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        guard dx != 0 || dy != 0 else { return }

        guard let scrollView = pdfView.internalScrollView else { return }
        let clipView = scrollView.contentView
        let scale = pdfView.scaleFactor
        guard scale > 0 else { return }

        // 内容要跟着鼠标走。clip.bounds 处于 documentView 坐标系：
        // 1 个单位 = scaleFactor 个屏幕点，且 y 轴方向与 window 坐标相反。
        // 想清楚方向：鼠标右移 → 内容右移 → 视口左移 → origin.x 减小。
        var proposed = clipView.bounds
        proposed.origin.x -= dx / scale
        proposed.origin.y += dy / scale

        // 越界交给 NSClipView 判断；拖到边界就停住，不做橡皮筋回弹
        let constrained = clipView.constrainBoundsRect(proposed)
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - 光标

    private func updateCursor(key: ObjectIdentifier) {
        if sessions[key]?.isDragging == true {
            NSCursor.closedHand.set()
        } else if sessions[key]?.isSpaceDown == true {
            NSCursor.openHand.set()
        } else if let pdfView = sessions[key]?.pdfView {
            // 让 PDFView 自己把光标恢复成它认为合适的样子（文本选择是 I-beam）
            pdfView.window?.invalidateCursorRects(for: pdfView)
        }
    }

    /// PDFView 的 cursor rect 会在鼠标移动时覆盖我们的光标，所以要在抓手模式期间重申
    private func refreshCursorIfNeeded(for event: NSEvent) {
        guard let key = sessionKey(matching: event.window),
              sessions[key]?.isSpaceDown == true,
              let pdfView = sessions[key]?.pdfView else { return }

        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard pdfView.bounds.contains(point) else { return }
        updateCursor(key: key)
    }

    // MARK: - 抓手模式开关

    private func beginHandMode(key: ObjectIdentifier, window: NSWindow?) {
        guard let window else { return }
        if sessions[key]?.savedAcceptsMouseMoved == nil {
            sessions[key]?.savedAcceptsMouseMoved = window.acceptsMouseMovedEvents
            // 只有开了这个才会派发 .mouseMoved，光标重申才有效
            window.acceptsMouseMovedEvents = true
        }
        registerWindowResignObserver(key: key, window: window)
    }

    private func restoreMouseMovedTracking(key: ObjectIdentifier) {
        guard let saved = sessions[key]?.savedAcceptsMouseMoved else { return }
        sessions[key]?.savedAcceptsMouseMoved = nil
        guard let window = sessions[key]?.pdfView?.window ?? NSApp.keyWindow else { return }
        window.acceptsMouseMovedEvents = saved
    }

    /// 按住空格时切到别的 app，keyUp 收不到，状态会卡在抓手模式 —— 用失焦通知兜住
    private func registerWindowResignObserver(key: ObjectIdentifier, window: NSWindow) {
        guard sessions[key]?.resignObserver == nil else { return }
        sessions[key]?.resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reset(key: key)
            }
        }
    }

    private func reset(key: ObjectIdentifier) {
        sessions[key]?.isSpaceDown = false
        sessions[key]?.isDragging = false
        sessions[key]?.lastLocationInWindow = nil
        restoreMouseMovedTracking(key: key)
    }
}
