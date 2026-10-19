import SwiftUI
import PDFKit

@MainActor
struct PDFKitRepresentedView: NSViewRepresentable {

    let tab: DocumentTab

    /// 盯住偏好：**页面底色**改一下要立刻反映到已经开着的窗口上（v1.3.67），
    /// 不能等下次重开文档才生效。
    @ObservedObject private var preferences = AppPreferences.shared

    func makeNSView(context: Context) -> PDFView {
        let pdfView = EditablePDFView()
        pdfView.document = tab.document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageBreakMargins = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        // **页面外**那块留白的颜色（v1.3.67）。
        // ⚠️ 页面**内**那一层它管不着 —— PDFKit 会自己把页面擦成白，只能靠
        //    `ImageDocument.makePage` 把底色**画进页面内容**（见那里的说明）。
        // 默认 `.textBackgroundColor`（跟随系统，深浅模式自己会变）。
        pdfView.backgroundColor = preferences.pageBackgroundNSColor

        // 标注交互的入口：视图直接拿 viewModel（画/选/删都在它那儿）
        pdfView.viewModel = tab.viewModel
        pdfView.onAnnotationsChanged = { [weak viewModel = tab.viewModel] in
            viewModel?.reloadAnnotations()
        }

        // 绑定 viewModel
        tab.viewModel.bind(to: pdfView)

        // ⌥ + 滚轮缩放，缩放后立刻回写 scaleFactor 让工具栏百分比同步。
        // ⚠️ 回调必须**跟着这个 PDFView 一起交上去**（不是设成单例的属性）——
        // 多窗口时每个窗口的数字要各回各家，否则 A 的缩放会写到 B 的工具栏上。
        ScrollZoomMonitor.shared.attach(to: pdfView) { [weak viewModel = tab.viewModel] scale in
            viewModel?.scaleFactor = scale
        }

        // 按住空格 + 拖动平移（抓手工具）
        SpaceDragPanMonitor.shared.attach(to: pdfView)

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // ⚠️ 这句必须在换文档那道 `guard` **之前**：用户刚在设置里改完底色、
        // 而这时文档没变，放 guard 后面就永远刷不到了。
        // 每次无条件设一遍 —— 设成同一个颜色本来就无害，比"记个上次的值再比"
        // 少一个可能出错的地方（也能顺带跟上深浅模式切换）。
        pdfView.backgroundColor = preferences.pageBackgroundNSColor
        // 图片文档：底色是**画进页面内容**的，改一次就得重画一次那一页（v1.3.67）。
        // 内部会先比一下"烘焙时用的值"和"现在的偏好"，一样就直接返回。
        tab.viewModel.syncImagePageBackground()

        guard pdfView.document !== tab.document else { return }

        // ⚠️ **必须在换 document 之前**把"旧标签"的视图状态（位置 + 缩放）记下来。
        //
        // SwiftUI 会**复用**这个 NSView 实例（类型和位置都没变），所以切标签走的是
        // 这条路、不是 `makeNSView` —— 而换 document 会让 PDFView 回到第一页、
        // 缩放也重置。等切回来时，靠这份**内存里**的状态还给它。
        //
        // 不这么做就只能去读 `BookmarksStore`（＝上次**关闭**该文件时的位置），
        // 用户看到的就是"切回来位置和缩放全变了"。
        (pdfView as? EditablePDFView)?.viewModel?.captureViewState(from: pdfView)

        pdfView.document = tab.document

        // ⚠️ viewModel 必须跟着换。SwiftUI 会复用同一个 NSView 实例（类型和位置都没变），
        // 只换 document 不换 viewModel 的话，新标签上的"编辑模式/标注操作"仍然打在
        // 旧标签的 viewModel 上 —— 表现就是切到另一个文件后，点「编辑」工具条出现了
        // 却画不出任何东西（旧 viewModel 的 isEditable 还是 false）。
        if let editable = pdfView as? EditablePDFView {
            editable.viewModel = tab.viewModel
            editable.onAnnotationsChanged = { [weak viewModel = tab.viewModel] in
                viewModel?.reloadAnnotations()
            }
        }

        tab.viewModel.bind(to: pdfView)
        // 这两个监听都按 PDFView 各记一份状态，重复调只是刷新引用（见各自类里的说明）
        ScrollZoomMonitor.shared.attach(to: pdfView) { [weak viewModel = tab.viewModel] scale in
            viewModel?.scaleFactor = scale
        }
        SpaceDragPanMonitor.shared.attach(to: pdfView)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: ()) {
        // ⚠️ 必须**指名**卸掉这一个 —— 原来是全局 `detach()`，多窗口时会把
        // 别的窗口那份也一起摘掉（症状：切回旧文件后空格拖拽、⌥滚轮全失效）
        ScrollZoomMonitor.shared.detach(from: pdfView)
        SpaceDragPanMonitor.shared.detach(from: pdfView)
        let editable = pdfView as? EditablePDFView

        // ⚠️ 先 capture：切标签时这个 PDFView 有可能是被**销毁**的（而不是复用），
        // 那 `updateNSView` 里那次 capture 就轮不到 —— 这是唯一的机会。
        // 两条路都补上，才不至于"切回来位置变了"。
        editable?.viewModel?.captureViewState(from: pdfView)

        // 撤掉键盘监听（Delete / Esc）
        editable?.detach()

        // 保存阅读进度：交给 viewModel 那份实现。
        //
        // ⚠️ 别再用 `pdfView.currentPage` 自己算 —— 它**不跟 `clipView` 的滚动更新**
        // （这个坑在 `syncState` 的注释里记着），直接用会存下一个过期的页号。
        // `saveProgress()` 用的是"视口中心页"，和界面上的页码判据一致。
        editable?.viewModel?.saveProgress()
    }
}
