import AppKit
import PDFKit

extension PDFView {
    /// PDFKit 没有公开内部的滚动视图，只能递归查找。
    ///
    /// 缩放锚点补偿和空格拖拽平移都需要直接操作它。注意这个 `NSScrollView` 不在公开 API 里，
    /// 所以找到之后要按"可能找不到"来处理，不能假设一定存在。
    var internalScrollView: NSScrollView? {
        Self.firstScrollView(in: self)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView != nil {
            return scrollView
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
