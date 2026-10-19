import AppKit
import PDFKit

/// 让每一页都**完整**落在视口内的 PDFView。
///
/// PDFKit 的 `autoScales` 在连续模式下只保证宽度放得下，A4 这类竖长页面就会出现
/// "一整页显示不全、要上下划来划去"。这里自己算一个让**每一页**都完整可见的缩放：
/// 取所有页里最难放下的那一页所需的缩放，结果是一屏正好一页，滚一下翻一页。
///
/// 独立成文件是为了能单独编译进探针验证（`PrintOptionsSheet.swift` 依赖整个 SwiftUI 上下文）。
final class PageFittingPDFView: PDFView {

    /// 上次适配时的视口尺寸，用来避免 layout → 改 scaleFactor → 再 layout 的循环
    private var lastFittedSize: CGSize = .zero

    override func layout() {
        super.layout()
        fitPagesToViewport()
    }

    /// 换了文档后调用：视口尺寸没变也必须重新适配一次
    func resetFitting() {
        lastFittedSize = .zero
        needsLayout = true
    }

    private func fitPagesToViewport() {
        guard let document, document.pageCount > 0 else { return }

        let viewport = bounds.size
        guard viewport.width > 32, viewport.height > 32 else { return }
        guard viewport != lastFittedSize else { return }
        lastFittedSize = viewport

        let margins = pageBreakMargins
        let availableWidth = viewport.width - margins.left - margins.right
        let availableHeight = viewport.height - margins.top - margins.bottom
        guard availableWidth > 0, availableHeight > 0 else { return }

        // 取所有页里最"难放"的一页，保证拼版后的每一张都能整页显示
        var requiredScale = CGFloat.greatestFiniteMagnitude
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            guard pageBounds.width > 0, pageBounds.height > 0 else { continue }
            requiredScale = min(requiredScale,
                                availableWidth / pageBounds.width,
                                availableHeight / pageBounds.height)
        }
        guard requiredScale.isFinite, requiredScale > 0 else { return }

        autoScales = false
        let clamped = min(max(requiredScale, minScaleFactor), maxScaleFactor)
        if abs(scaleFactor - clamped) > 0.0001 {
            scaleFactor = clamped
        }
    }
}
