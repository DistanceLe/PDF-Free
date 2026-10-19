import PDFKit

@MainActor
struct DocumentTab: Identifiable, Equatable {

    /// 这份文档**原本**是什么（v1.3.66）。
    ///
    /// 图片是被 `ImageDocument.makeDocument(from:)` 包成单页 PDF 进来的，
    /// 所以 `document` 一律是 `PDFDocument`；这个标记是给界面和保存逻辑看的：
    /// - 「保存」对图片得变成「导出为图片」（图片的 PDF 副本写不回 `.jpg`）；
    /// - 关闭确认的文案要说"导出"而不是"保存"。
    enum Kind {
        case pdf
        case image
    }

    let id = UUID()
    let url: URL
    let document: PDFDocument
    let viewModel: PDFViewModel
    let kind: Kind

    /// 沙箱下访问用户所选文件必须持有 security scope。
    ///
    /// 由 `AppViewModel.addDocument` 在**读取文件之前**取得后传进来 ——
    /// 不能放在这里 start，那样就晚了：从「最近打开」恢复的 URL 在取得作用域之前
    /// 连 `PDFDocument(url:)` 都读不出内容。
    private let holdsSecurityScope: Bool

    init(url: URL, document: PDFDocument, kind: Kind, holdsSecurityScope: Bool) {
        self.url = url
        self.document = document
        self.kind = kind
        self.viewModel = PDFViewModel()
        self.holdsSecurityScope = holdsSecurityScope
        // 把"原本是什么"灌进 viewModel —— 保存/关闭确认那条路要用，
        // 而它拿不到 `DocumentTab`（`pdfView` 那条路只到 PDFDocument）。
        viewModel.sourceKind = kind
        // 原文件地址也留一份：图片文档的 `document.documentURL` 是 nil
        //（故意不设，见 `ImageDocument` 的底线 1），但界面显示文件名、
        // 「导出」时对齐原图分辨率都要用它。
        viewModel.sourceURL = url
        // 页面就是按"此刻的偏好"生成的（见 `ImageDocument.makePage`）——
        // 记下来，之后改底色时靠它判断"要不要重画页面"。
        viewModel.bakedPageBackgroundHex = AppPreferences.shared.pageBackgroundHex
        // 图片默认把**左侧栏收起来**（v1.3.68）：里面是缩略图 / 目录 / 书签 / 批注，
        // 而图片只有一页、没有目录、也没什么可当书签的 —— 开着纯占地方，
        // 挤得图还小一圈。用户要看随时点工具栏那个按钮，和 PDF 一模一样。
        viewModel.isLeftSidebarVisible = (kind != .image)

        // 侧边栏默认开哪个面板（v1.3.73）：**有目录就开目录，没有才开缩略图**。
        //
        // 为什么不是无脑开目录 —— 两者的成本差了两个数量级（实测）：
        //
        // | | 成本 |
        // |---|---|
        // | 目录：读 PDF 里的 outline 树 | **0~2 ms**（等于不要钱） |
        // | 缩略图：真把页面渲染出来 | 首屏 10 张 **52 / 151 / 268 / 905 ms** |
        //   （分别对应 8 页 / 2 页 / 326 页 / 84 页 246MB 那几个文件） |
        //
        // 缩略图是 `List` 懒加载的，所以只付"首屏那十来张"的钱 —— 但那笔钱
        // 每次打开文件都要付一遍，而目录几乎白拿。
        //
        // ⚠️ 但**没有目录的文档必须退回缩略图**，否则用户打开就是一片空白面板。
        // 实测 `合集2.3.pdf`（246MB）顶层就是 0 项 —— 那种文档开缩略图反而对。
        viewModel.activeSidebar =
            (document.outlineRoot?.numberOfChildren ?? 0) > 0 ? .outline : .thumbnails
    }

    /// 这是"看图"还是"读 PDF" —— 调用点读起来清楚些。
    var isImage: Bool { kind == .image }

    /// 日志 / 诊断里用的名字 = **完整文件名**（带扩展名），写清楚不歧义。
    var title: String {
        url.lastPathComponent
    }

    /// 标签页与窗口标题上显示的名字 = **去掉扩展名**（v1.3.40）。
    ///
    /// 现在标签栏是 macOS 的系统窗口标签栏，标签宽度本来就窄，而且
    /// 一个 PDF 阅读器里放的几乎都是 `.pdf` —— 后缀纯属占地方。
    /// 系统那栏本身鼠标悬停就会补全路径，同名文件也分得清。
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// 鼠标悬停时的提示：带上所在的文件夹，同名文件在不同目录也能分清。
    var titleTooltip: String {
        url.deletingLastPathComponent().path
    }

    /// 关闭标签时必须调用，否则文件访问权限持续泄漏。
    func releaseSecurityScope() {
        guard holdsSecurityScope else { return }
        url.stopAccessingSecurityScopedResource()
    }

    nonisolated static func == (lhs: DocumentTab, rhs: DocumentTab) -> Bool {
        lhs.id == rhs.id
    }
}
