import AppKit
import PDFKit

/// 按住 ⌥ 滚动滚轮即可缩放页面，锚点跟随鼠标位置。
///
/// 为什么用 local event monitor 而不是子类化 PDFView：
/// PDFView 的滚动由它内部的 `NSScrollView` 处理，滚轮事件会先被内层 scroll view 消费，
/// 子类 override `scrollWheel(with:)` 收不到。事件监听能在事件分发前拦下并吞掉。
///
/// ## ⚠️ 必须**按窗口**记（v1.3.41）
///
/// 原来这里只存**一个** `pdfView` + 一个 `onZoom` 回调（`attach` 里还会先 `detach()`）——
/// 那是"一个窗口装所有文件"时代的写法。改成一个文件一个窗口之后症状是：
///
/// ```
/// 打开 A → attach(A)
/// 打开 B → attach(B)（把 A 顶掉了）
/// 切回 A → ⌥+滚轮缩放完全没反应
/// ```
///
/// 因为 `handle` 里有一句 `event.window === pdfView.window` —— 那个 `pdfView` 已经是 B 的。
/// 现在改成"每个 PDFView 一份"，事件按 `event.window` 找对应那一份；
/// 缩放回调（回写工具栏百分比）也跟着一份走，否则两个窗口会互相改对方的数字。
@MainActor
final class ScrollZoomMonitor {

    static let shared = ScrollZoomMonitor()

    private init() {}

    /// 缩放灵敏度：非精确设备（普通鼠标滚轮）每格 delta 约 1~3，
    /// 精确设备（触控板）是像素级的几十，所以分开归一化。
    private let preciseSensitivity: CGFloat = 0.0025
    private let wheelSensitivity: CGFloat = 0.012

    /// 弱引用包一层：字典不能把 PDFView 强留下（它归视图层级所有）
    private final class Entry {
        weak var view: PDFView?
        var onZoom: ((CGFloat) -> Void)?
        init(view: PDFView, onZoom: ((CGFloat) -> Void)?) {
            self.view = view
            self.onZoom = onZoom
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?

    /// 仅供自动化验证：现在挂在哪些窗口上（多窗口时必须是**好几个**）。
    ///
    /// 这一条直接对应"切回旧文件后 ⌥+滚轮缩放失效"那个 bug —— 修复前这里只会有一个。
    var attachedWindowTitles: [String] {
        entries.values.compactMap { $0.view?.window?.title }
    }

    // MARK: - 生命周期

    /// 挂上（可重复调：`updateNSView` 会反复来，顺便把回调刷成最新的 viewModel）
    func attach(to pdfView: PDFView, onZoom: ((CGFloat) -> Void)? = nil) {
        let key = ObjectIdentifier(pdfView)
        if let existing = entries[key] {
            existing.view = pdfView
            if let onZoom { existing.onZoom = onZoom }
        } else {
            entries[key] = Entry(view: pdfView, onZoom: onZoom)
        }
        installMonitorIfNeeded()
    }

    func detach(from pdfView: PDFView) {
        entries.removeValue(forKey: ObjectIdentifier(pdfView))
        if entries.isEmpty { removeMonitor() }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // 返回 nil 表示吞掉事件，避免 ⌥+滚轮 同时触发普通滚动
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 事件发生在哪个 PDFView 所在的窗口上；顺手扔掉已经销毁的那些
    private func entry(matching window: NSWindow?) -> Entry? {
        guard let window else { return nil }
        var found: Entry?
        for (key, entry) in entries {
            guard let view = entry.view else {
                entries.removeValue(forKey: key)
                continue
            }
            if view.window === window, found == nil { found = entry }
        }
        return found
    }

    // MARK: - 事件处理

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option),
              let entry = entry(matching: event.window),
              let pdfView = entry.view else { return false }

        // 「页面管理」浮层盖着时让位：⌥+滚轮不去缩底下那份 PDF
        //（它是同窗口的一层视图，`event.window` 那道判断拦不住）。
        // **不吞事件** —— 浮层自己的滚动照常。
        guard !AppModelBridge.isPageManagerVisible(for: event.window) else { return false }

        // 鼠标要落在 PDFView 范围内（工具栏、侧边栏上滚不应该缩放）
        let anchor = pdfView.convert(event.locationInWindow, from: nil)
        guard pdfView.bounds.contains(anchor) else { return false }

        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * preciseSensitivity
            : event.scrollingDeltaY * wheelSensitivity

        // ⌥ 按住期间一律吞掉事件，即使这一格没有位移，否则页面会跟着滚
        guard delta != 0 else { return true }

        zoom(pdfView: pdfView, factor: 1 + delta, anchor: anchor, onZoom: entry.onZoom)
        return true
    }

    private func zoom(pdfView: PDFView, factor: CGFloat, anchor: CGPoint,
                      onZoom: ((CGFloat) -> Void)?) {
        let current = pdfView.scaleFactor
        let lower = max(pdfView.minScaleFactor, 0.05)
        let upper = max(pdfView.maxScaleFactor, lower + 0.1)
        let target = min(max(current * factor, lower), upper)
        guard abs(target - current) > 0.0001 else { return }

        // 页坐标不随缩放变化，用它当桥梁把锚点固定住
        let page = pdfView.page(for: anchor, nearest: true)
        let pagePoint = page.map { pdfView.convert(anchor, to: $0) }

        pdfView.autoScales = false
        pdfView.scaleFactor = target
        // 实测 layoutDocumentView() 已足够让 convert 反映新布局，无需额外的 layoutSubtreeIfNeeded
        pdfView.layoutDocumentView()

        if let page, let pagePoint {
            keepAnchorFixed(pdfView: pdfView, anchor: anchor, pagePoint: pagePoint, page: page)
        }

        onZoom?(pdfView.scaleFactor)
    }

    /// 缩放后把锚点对应的 PDF 内容滚回鼠标下方。
    private func keepAnchorFixed(pdfView: PDFView, anchor: CGPoint, pagePoint: CGPoint, page: PDFPage) {
        guard let scrollView = pdfView.internalScrollView else { return }

        let scale = pdfView.scaleFactor
        guard scale > 0 else { return }

        let moved = pdfView.convert(pagePoint, from: page)
        guard moved.x.isFinite, moved.y.isFinite else { return }

        let clipView = scrollView.contentView

        // 两个坑，都靠实测确认过：
        //
        // 1. clipView.bounds 用的是 documentView 坐标系，**1 个单位 = scaleFactor 个屏幕点**
        //    （缩放是靠改 clip.bounds 的尺寸实现的，documentView.frame 始终不变）。
        //    所以补偿量必须先除以 scaleFactor，否则会过头 scale 倍、越滚越飘。
        // 2. PDFView 的 y 轴向上（isFlipped == false），而 documentView 的 y 轴向下，
        //    两个坐标系方向相反，所以 y 分量的符号与 x 相反。
        var proposed = clipView.bounds
        proposed.origin.x += (moved.x - anchor.x) / scale
        proposed.origin.y += (anchor.y - moved.y) / scale

        // 边界交给 NSClipView 自己判断，不要手写 clamp：
        // 内容比视口小时它会返回**居中**值，比视口大时才限制在可滚动范围内。
        // （之前手写 min(max(origin, 0), upper) 会在缩小时把 origin 钳成 0，
        //   导致页面贴左边不居中。）
        let constrained = clipView.constrainBoundsRect(proposed)
        let deltaX = constrained.origin.x - clipView.bounds.origin.x
        let deltaY = constrained.origin.y - clipView.bounds.origin.y
        guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return }

        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
