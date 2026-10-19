import AppKit
import PDFKit

/// 像素级平滑自动滚动。
///
/// PDFKit 没有公开"滚动到位置"的接口，这里直接操作 `PDFView` 内部的
/// `NSScrollView` 的 clip view，以 60fps 逐帧推进滚动位置，比定时翻页平滑得多。
/// 找不到内部 scroll view 时会退化为定时翻页。
@MainActor
final class AutoScroller: ObservableObject {

    @Published private(set) var isRunning = false

    /// 滚动速度（点/秒）
    @Published var speed: Double = 40

    /// 滚动到文档末尾时触发（用于提示用户）
    var onReachEnd: (() -> Void)?

    private weak var pdfView: PDFView?
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    /// 退化模式：找不到 scroll view 时的翻页计时累加器
    private var fallbackAccumulator: Double = 0

    private let frameInterval: Double = 1.0 / 60.0

    // MARK: - 控制

    func start(in pdfView: PDFView) {
        guard !isRunning else { return }
        self.pdfView = pdfView
        self.scrollView = Self.findScrollView(in: pdfView)
        self.fallbackAccumulator = 0

        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.step()
            }
        }
        // 放进 common 模式，拖动滚动条/菜单弹出时不会被挂起
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scrollView = nil
        pdfView = nil
        isRunning = false
    }

    func toggle(in pdfView: PDFView) {
        if isRunning {
            stop()
        } else {
            start(in: pdfView)
        }
    }

    // MARK: - 逐帧推进

    private func step() {
        guard let pdfView else {
            stop()
            return
        }

        if let scrollView, let documentView = scrollView.documentView {
            let clipView = scrollView.contentView
            let maxOffset = max(0, documentView.bounds.height - clipView.bounds.height)
            var origin = clipView.bounds.origin
            origin.y = min(origin.y + speed * frameInterval, maxOffset)

            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)

            if origin.y >= maxOffset - 0.5 {
                stop()
                onReachEnd?()
            }
        } else {
            // 退化路径：累积到间隔时间后翻一页
            fallbackAccumulator += frameInterval
            let pageInterval = max(1.0, 400.0 / max(speed, 1))
            if fallbackAccumulator >= pageInterval {
                fallbackAccumulator = 0
                if pdfView.canGoToNextPage {
                    pdfView.goToNextPage(nil)
                } else {
                    stop()
                    onReachEnd?()
                }
            }
        }
    }

    // MARK: - 定位内部滚动视图

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView != nil {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
