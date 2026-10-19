import SwiftUI
@preconcurrency import PDFKit
import Combine

/// 用于把 PDFKit 的非 Sendable 对象显式传递到后台队列（仅做只读查询）。
struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

@MainActor
class PDFViewModel: ObservableObject {
    weak var pdfView: PDFView?

    /// 强持有当前文档。
    ///
    /// `pdfView` 是 weak（避免视图与 viewModel 互相强引用），但**窗口关闭时视图树会先销毁**
    /// —— 那一刻 `pdfView` 已经是 nil，而"关闭确认框里选保存"还要用文档。
    /// 不记住它的话：用户点「保存」会失败（拿不到 document）→ 关不掉文档 →
    /// 留下一个"app 还活着但没有窗口"的死角。
    ///
    /// （v1.3.31 实测：点红叉关闭时，`applicationShouldTerminate` 比视图销毁晚 22ms。）
    private(set) var boundDocument: PDFDocument?

    /// 取当前文档：优先走 `pdfView`；视图已销毁时回退到绑定时留住的那份。
    var currentDocument: PDFDocument? { pdfView?.document ?? boundDocument }

    // MARK: - 这份文档原本是什么（v1.3.66）

    /// PDF 还是「图片包装出来的单页 PDF」。由 `DocumentTab` 在创建时灌进来。
    ///
    /// 影响两件事：「保存」按钮最后到底存成什么格式，以及关闭确认的文案。
    var sourceKind: DocumentTab.Kind = .pdf

    /// **原文件**地址。
    ///
    /// ⚠️ PDF 文档它等于 `document.documentURL`；**图片文档则不然** ——
    /// 图片那份 `PDFDocument` 是内存里造的、`documentURL` 是 `nil`
    ///（故意的，见 `ImageDocument` 的底线 1：指回 `.jpg` 就会把照片覆盖成 PDF）。
    /// 所以"原始文件是谁"这件事只能靠这个字段，界面显示文件名、
    /// 「导出」时对齐原图分辨率都要用它。
    var sourceURL: URL?

    /// 存进度 / 存缩放该用的「文件身份」。
    ///
    /// ⚠️ **不能直接用 `pdfView.document?.documentURL`**（v1.3.72 修的 bug）：
    /// 图片是被包成**内存里**的单页 PDF 进来的，那个 `documentURL` 永远是 nil
    ///（故意的，见 `ImageDocument` 的底线 1：指回 `.jpg` 就会把照片覆盖成 PDF）。
    /// 拿它当 guard 的话会**直接 return** —— 后果是图片的缩放和阅读位置
    /// 一个都没存，用户看到的就是"**每次打开图片都回到默认大小**"。
    ///
    /// `sourceURL` 是 `DocumentTab` 建的时候灌进来的原始文件地址，PDF 和图片都有；
    /// 万一它也空（不该发生），再退回 `documentURL` 兜一下。
    ///
    /// ⚠️ 注意**别拿它当写回文件的落点** —— 那是另一回事，见 `saveAnnotationsToDisk`：
    /// 图片必须写不回去（指回 `.jpg` 就等于把照片覆盖成 PDF），所以那里
    /// **仍然要死守 `documentURL`**，不能换成这个。
    private var storageURL: URL? {
        sourceURL ?? pdfView?.document?.documentURL
    }

    /// 界面/提示里要显示的文件名（**带扩展名**，说全不歧义）。
    /// 图片文档取不到 `documentURL`，只能走 `sourceURL`。
    var sourceFileName: String? { sourceURL?.lastPathComponent }

    /// 这份文档是不是"看图"。
    var isImageDocument: Bool { sourceKind == .image }

    /// 图片文档**当前页面上已经画进去**的底色（`#RRGGBB`；空串 = 跟随系统）。
    ///
    /// 由 `DocumentTab` 创建时置入 —— 那一刻页面就是按这个值生成的。
    /// 用来判断"用户有没有改过底色、要不要重画页面"，见 `syncImagePageBackground`。
    var bakedPageBackgroundHex: String?

    /// 图片文档：底色被改过就**重画这一页**（v1.3.67）。
    ///
    /// ## 为什么必须重画页面，而不是"刷一下颜色"
    ///
    /// 因为底色不是视图属性 —— 它是**画进页面内容**里的。
    /// `PDFView` 画每一页之前会把页面**擦成白色**（头文件 `PDFView.h:263` 原话），
    /// 只有画在页面内容里的东西盖得住那层白（见 `ImageDocument.makePage`）。
    /// 所以改一次底色，就得重新生成一次这一页。
    ///
    /// ## 批注**必须搬过去**
    ///
    /// 它们在 `page.annotations` 里，页面一换就跟着没了。
    /// 逐个 `copy()` 到新页 —— ⚠️ **要 copy 不能直接把原对象 add 过去**：
    /// 一个 `PDFAnnotation` 只属于一页。
    ///
    /// 由 `PDFKitRepresentedView.updateNSView` 每次更新时调；绝大多数时候
    /// 只是比一串字符串就返回（空转，开销可以忽略）。
    func syncImagePageBackground() {
        guard isImageDocument else { return }
        let wanted = AppPreferences.shared.pageBackgroundHex
        guard let baked = bakedPageBackgroundHex else {
            // 第一次进来：页面本来就是这个值生成的，记下即可
            bakedPageBackgroundHex = wanted
            return
        }
        guard baked != wanted else { return }
        bakedPageBackgroundHex = wanted
        rebuildImagePage()
    }

    private func rebuildImagePage() {
        guard let document = pdfView?.document, document.pageCount == 1,
              let sourceURL, let old = document.page(at: 0) else { return }
        let carried = old.annotations
        guard let fresh = ImageDocument.makePage(from: sourceURL,
                                                 background: AppPreferences.shared.pageBackgroundNSColor) else { return }
        for annotation in carried {
            guard let copy = annotation.copy() as? PDFAnnotation else { continue }
            fresh.addAnnotation(copy)
        }

        // 换页会让 PDFView 重新布局 —— 记下缩放，换完还回去，
        // 不然用户就看着页面"啪"地跳一下比例（尤其是开过"适合宽度"之后）
        let scale = pdfView?.scaleFactor
        document.insert(fresh, at: 1)
        document.removePage(at: 0)
        pdfView?.layoutDocumentView()
        if let scale { pdfView?.scaleFactor = scale }

        reloadAnnotations()
        Diagnostics.shared.record("图片文档：页面底色变了 → 重画页面（搬了 \(carried.count) 条批注）")
    }

    @Published var currentPageIndex: Int = 0
    @Published var pageCount: Int = 0
    /// 真实缩放：**1 个 PDF 点占几个界面点**（PDFKit 的原始语义）。
    /// 界面上**不要直接拿它显示百分比** —— 用 `zoomPercent`（见那里的说明）。
    @Published var scaleFactor: CGFloat = 1.0

    /// 工具栏上那个百分比：**相对「实际大小」**（v1.3.64）。
    ///
    /// ⚠️ 不能是 `scaleFactor * 100`。`scaleFactor = 1.0` 只代表"1 PDF 点 = 1 界面点"，
    /// 而 1 界面点在物理上不等于 1/72 英寸（这台 27" 4K 屏上是 1/108.5 英寸）——
    /// 所以真正的"实际大小"是 `1.507`。原来按名义值显示 100% 时，页面其实只有
    /// 真实尺寸的 66%，跟预览.app / Adobe 的 100% 一比就"小了一截"。
    ///
    /// 现在统一按 `实际大小` 折算：显示 100% ⇒ 页面上拿尺子量就是纸的尺寸。
    @Published var zoomPercent: CGFloat = 100

    /// 这个文档所在的窗口是不是**用户正在操作的那个**。
    ///
    /// ⚠️ 为什么必须有这个：菜单命令走的是 `NotificationCenter` **广播**，
    /// 而 v1.3.40 起一个文件一个窗口 —— 每个窗口都会收到一遍。
    /// 不加过滤的话，**⌘Z 会在所有打开的文件上各撤销一步**，
    /// ⌘S 把每个文件都存一遍，⌘P 弹一摞打印面板。
    ///
    /// 判据用"key 或 main 窗口"：我们的 sheet（页面管理、打印选项…）打开时
    /// key/main 会变成那个 sheet 子窗口，所以还得认一下 `sheetParent`。
    var isInActiveWindow: Bool {
        guard let window = pdfView?.window else { return false }
        if window.isKeyWindow || window.isMainWindow { return true }
        if let key = NSApp.keyWindow, key.sheetParent === window { return true }
        if let main = NSApp.mainWindow, main.sheetParent === window { return true }
        // 一个 key/main 都没有（app 不在最前 —— 自动化跑就是这种）：
        // 只有一个文档窗口时才认它，单窗口下的行为一字不变。
        if NSApp.keyWindow == nil, NSApp.mainWindow == nil {
            return AppModelBridge.allEntries.count <= 1
        }
        return false
    }

    // MARK: - 搜索
    @Published var searchQuery: String = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var isSearching: Bool = false
    @Published var selectedSearchResult: Int = -1

    // MARK: - 标注工具与样式（v1.3）
    //
    // 只读 / 编辑：打开文件默认只读，点了「编辑」才出标注工具、才允许改动。
    @Published var isEditable: Bool = false {
        didSet {
            guard isEditable != oldValue else { return }
            // ⚠️ 这里的副作用**必须挪到下一轮主队列**。
            //
            // `didSet` 是在 **SwiftUI 写入绑定的同一轮更新里**执行的。
            // 在这里接着改别的 `@Published`（右栏显隐、选中项…），
            // 就落到"视图更新过程中改状态"那条禁忌上 —— SwiftUI 会把这一次更新**丢掉**。
            // 用户实测的症状正是："点「编辑」按钮已经变色了，但没切过去，要再点一次"。
            //
            // 延后一轮之后：状态切换立刻生效（按钮、工具条马上响应），
            // 右栏这些副作用紧随其后 —— 反正它们本来就是为了"提前占位"，
            // 早一轮晚一轮对手感没影响。
            let enteringEditMode = isEditable
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if enteringEditMode {
                    // 进编辑模式顺手把右侧属性栏带出来。
                    //
                    // 不这么做的话：第一次画完才 `select` → 那时才弹栏 → PDFView 变窄 →
                    // `autoScales` 重新适配页面（实测 168% → 125%）→ **页面当着你面跳一下**。
                    // 提前在切编辑模式时把栏位占好，宽度就稳定了。
                    self.revealRightPanel()
                } else {
                    // 切回只读：属性栏没有意义了，顺手收起来（用户要求）。
                    // 但如果正在搜索，右侧栏是搜索结果 —— 那个不能收。
                    self.selectedAnnotation = nil
                    self.pdfView?.needsDisplay = true      // 把选中框擦掉
                    if self.searchQuery.isEmpty {
                        self.beginPreservingZoom()         // 栏位要消失，PDFView 会变宽，先记下缩放
                        self.isRightSidebarVisible = false
                    }
                }
            }
        }
    }

    /// 当前选中的工具。工具条由它驱动（见 `AnnotationTool`）。
    @Published var activeTool: AnnotationTool = .select

    /// 颜色 / 线宽 / 字号，跨会话记忆
    let style = AnnotationStyle()

    /// 当前选中的标注 —— 右侧属性栏据此显示
    @Published var selectedAnnotation: AnnotationItem?

    /// 点击放置类工具（文本 / 便签 / 签名）在页面上点的那一下
    struct Placement {
        let pageIndex: Int
        /// 页坐标下的落点
        let point: CGPoint
    }
    @Published private(set) var pendingPlacement: Placement?

    // MARK: - 书签
    @Published var isCurrentPageBookmarked: Bool = false

    // MARK: - 批注（v1.0）
    @Published private(set) var annotations: [AnnotationItem] = []

    /// 批注列表里当前选中的条数（由列表同步过来）。
    ///
    /// 用途：让 `EditablePDFView` 的**全局键盘监听**判断 Delete 键该走哪条路 ——
    /// 列表里选中了（尤其多条）就交给列表处理，它能弹确认框、一次删掉一批。
    ///
    /// ⚠️ **故意不是 `@Published`。** 它由列表 `Binding` 的 `set` 在**视图更新过程中**写入，
    /// 而 `@Published` 在那一刻赋值会触发 SwiftUI 的
    /// "Publishing changes from within view updates" 警告，更新本身还有被合并/丢弃的风险。
    /// 它也只被键盘监听（非渲染路径）读取，本来就不需要触发重绘。
    var annotationListSelectionCount: Int = 0

    /// 列表里按下 Delete 的请求计数。
    ///
    /// 键盘监听 +1，批注列表 `onChange` 到就弹自己的确认框、然后删掉选中那些。
    ///
    /// 为什么不直接用列表的 `.onDeleteCommand`：那个 command 要**列表拿到焦点**才触发，
    /// 而焦点通常在 PDF 视图那边 —— 实测在列表里选中后按 Delete 毫无反应。
    /// 走"监听 → 计数器"这条路完全不依赖焦点。
    /// （用计数器而不是注册闭包：闭包跨 SwiftUI 重绘去持有 `@State` 很脆弱。）
    @Published private(set) var listDeleteRequestTick = 0

    /// 键盘监听在"列表里有选中项"时按下 Delete 会调它（见 `EditablePDFView.handleKeyEvent`）。
    func requestDeleteOfListSelection() {
        listDeleteRequestTick &+= 1
    }

    /// 需要以弹窗呈现的辅助面板。放在 viewModel 上，工具栏和菜单都能触发。
    enum ActiveSheet: String, Identifiable {
        case note
        case freeText
        /// 编辑**已有**文本注释的内容（双击打开，v1.3.73）
        case editFreeText
        case signature
        case ocr
        case print
        // 注：「页面管理」不在这个枚举里 —— 它不是 sheet，而是**盖在主窗口上的浮层**
        //（见 `isPageManagerVisible`）。放在 `PDFContentView` 里用 `.sheet` 弹会被
        // 窗口尺寸卡住，盖不满；而且 sheet 是模态的，开着的时候窗口都关不掉。

        var id: String { rawValue }
    }
    @Published var activeSheet: ActiveSheet?

    /// 双击打开编辑框的那个文本注释（配合 `activeSheet == .editFreeText` 用）。
    ///
    /// 为什么不塞进 `ActiveSheet`：那是 `String` 枚举、带不了数据 ——
    /// 而编辑必须知道"改的是哪一条、在哪一页、原来是什么"。
    struct FreeTextTarget {
        let annotation: PDFAnnotation
        let pageIndex: Int
        /// 打开编辑框那一刻的内容。提交时一模一样就不入撤销栈。
        let originalText: String
    }
    @Published var editingFreeText: FreeTextTarget?

    /// 只读模式下试图添加/修改标注时的提示文案（nil 表示不弹）。
    ///
    /// 存在的理由：只读时这些操作会被 guard 挡掉，如果什么都不做，用户看到的就是
    /// 「点了没反应」—— 那种失败最难排查。给一句话说明该先做什么。
    @Published var readOnlyNotice: String?

    /// 打开某个「添加标注」的弹窗。只读模式下弹提示而不是静默失败。
    func requestAnnotationSheet(_ sheet: ActiveSheet) {
        guard isEditable else {
            readOnlyNotice = "当前是「只读」模式。点顶栏左侧的「编辑」后就能添加标注了。"
            return
        }
        activeSheet = sheet
    }

    // MARK: - 侧边栏
    /// 当前侧边栏面板。提到 viewModel 上是为了让菜单快捷键也能切换面板。
    @Published var activeSidebar: SidebarItem = .thumbnails
    /// 每次 ⌘F 自增一次，顶栏搜索框据此重新取得焦点
    @Published private(set) var searchFocusToken: Int = 0

    /// ⌘F：把焦点送到顶栏右上角的搜索框
    func revealSearch() {
        searchFocusToken += 1
    }

    // MARK: - 侧边栏显示控制（v1.3.4）

    @Published var isLeftSidebarVisible = true
    @Published var isRightSidebarVisible = false

    /// 需要右侧栏时把它唤出来。
    ///
    /// **只负责显示，不负责隐藏** —— 隐藏只由用户点关闭按钮触发。
    /// 这样删掉一条标注后，右侧栏会留成空白而不是整个消失，页面宽度不会跟着抖一下
    /// （之前 `hasSelection || 有搜索词` 一变就增删整栏，删除时页面会横跳）。
    func revealRightPanel() {
        if !isRightSidebarVisible {
            // 栏位一出现，PDFView 就变窄 —— 先记下缩放，别让页面跟着缩放
            beginPreservingZoom()
            isRightSidebarVisible = true
        }
    }

    // MARK: - 缩放：跨布局变化保持（v1.3.9）
    //
    // 需求：显示/隐藏左右侧边栏、拖分隔条、弹属性栏的时候，**页面不要跟着缩放**。
    //
    // ⚠️ 必须在**宽度变化之前**调 `beginPreservingZoom()`。实测 PDFKit 在宽度变化的
    // 过程中就已经按"适合宽度"把 `scaleFactor` 重算好了 —— 等 `layout()` 被调到，
    // 读到的已经是新值，那会儿再想"还原"已经无从还原。
    // 详见 `EditablePDFView.zoomToPreserve`。

    /// 记下当前缩放，接下来的宽度变化不要让它跟着变。
    func beginPreservingZoom() {
        guard let pdfView, pdfView.document != nil else { return }
        (pdfView as? EditablePDFView)?.zoomToPreserve = pdfView.scaleFactor
    }

    /// 用户自己改了缩放之后同步基准，否则下次宽度变化会把用户的缩放还回旧值。
    private func syncPreservedZoom() {
        guard let pdfView, let editable = pdfView as? EditablePDFView,
              editable.zoomToPreserve != nil else { return }
        editable.zoomToPreserve = pdfView.scaleFactor
    }

    /// 用户明确要求"适合宽度"（或换文档）时，别再钉住缩放
    private func resetPreservedZoom() {
        (pdfView as? EditablePDFView)?.resetPreservedZoom()
    }

    // MARK: - 朗读（v1.0）
    let speech = SpeechReader.shared

    // MARK: - 自动滚动（v1.0）
    let autoScroller = AutoScroller()

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// 书签 store 的订阅（只挂一次，见 `bind`）
    private var bookmarksObservation: AnyCancellable?

    // MARK: - 绑定

    /// 一个标签的"视图状态"：看到哪一页的哪个位置 + 缩放。
    ///
    /// 切标签时**存进内存**（见 `captureViewState`）。为什么不能只靠
    /// `BookmarksStore` 那一份 —— 那是"上次**关闭这个文件**时"的状态。
    struct ViewState {
        let pageIndex: Int
        let offsetRatio: Double
        let scaleFactor: CGFloat
    }

    /// 切走这个标签时暂存的视图状态；切回来时优先用它恢复。
    private var pendingViewState: ViewState?

    /// 上一次 `bind` 的是哪份文档 —— 用来区分"**新打开的文档**"和"**切标签回来的**"。
    ///
    /// ⚠️ 这两种情况在 `bind` 里必须分开处理，曾经混在一起，导致：
    /// - 切回来时 `unsavedChanges.clear()` 把编辑过的脏标记抹了 → **关闭不提示保存**；
    /// - 切回来时 `restoreProgress()` 用**存储里（上次关闭时）**的位置覆盖当前视图
    ///   → **位置和缩放全变了**。
    ///
    /// 用 `ObjectIdentifier(document)` 而不是 URL：同一个文件重新打开会是新实例，
    /// 那种情况本来就该按"新文档"走。
    private var boundDocumentIdentity: ObjectIdentifier?

    /// 切走这个标签时调：把"现在看到哪儿了 + 缩放"记进内存。
    ///
    /// ⚠️ 必须在**换 document 之前**调 —— `updateNSView` 里换完 document，
    /// PDFView 已经回到第一页、缩放也重置了，那时什么都capture 不到。
    func captureViewState(from pdfView: PDFView) {
        guard let document = pdfView.document else { return }
        let bounds = pdfView.bounds
        guard !bounds.isEmpty else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let page = pdfView.page(for: center, nearest: true) else { return }
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.height > 0 else { return }
        let pagePoint = pdfView.convert(center, to: page)
        pendingViewState = ViewState(
            pageIndex: document.index(for: page),
            offsetRatio: min(max(pagePoint.y / pageRect.height, 0), 1),
            scaleFactor: pdfView.scaleFactor
        )
        Diagnostics.shared.record("切走标签：记下视图状态 页=\(pendingViewState!.pageIndex)"
                                  + " 比例=\(String(format: "%.3f", pendingViewState!.offsetRatio))"
                                  + " 缩放=\(String(format: "%.3f", pendingViewState!.scaleFactor))")
    }

    func bind(to pdfView: PDFView) {
        self.pdfView = pdfView
        // 记住文档：`pdfView` 是 weak，窗口关闭时视图树会先销毁、它就成了 nil，
        // 而"关闭确认框里选保存"还要用文档（见 `boundDocument` 的说明）。
        // 这里取得安全 —— `PDFKitRepresentedView.makeNSView` 是先设 document 再 bind。
        boundDocument = pdfView.document

        // 这次 bind 是"换了新文档"还是"切标签切回来"？
        let identity = pdfView.document.map { ObjectIdentifier($0) }
        let isNewDocument = identity != boundDocumentIdentity
        boundDocumentIdentity = identity

        if isNewDocument {
            // ── 只有真的换了文档，才做这些"重新开始"的事 ──
            //
            // ⚠️ 这里**没有** `unsavedChanges.clear()`：新标签的 viewModel 本来就是
            // 新建的（脏标记初始为 false），不需要清；而切标签回来时清掉它，
            // 就等于把用户刚做过、还没保存的编辑"标记成干净"了 ——
            // 表现正是"编辑的没保存，再关闭也不提示"。
            // 撤销历史同理：它拍的是**这份文档**的页副本，换文档了才作废。
            clearUndoHistory()
            // 换文档了，之前钉住的缩放不作数（新文档要重新"适合宽度"）
            (pdfView as? EditablePDFView)?.resetPreservedZoom()
            // "点一下切实际大小"的那个临时态也不跨文档
            zoomBeforeActualSize = nil
        }

        self.pageCount = pdfView.document?.pageCount ?? 0
        self.scaleFactor = pdfView.scaleFactor
        self.zoomPercent = pdfView.scaleFactor
            / ScreenMetrics.actualSizeScale(for: pdfView.window?.screen) * 100

        // 使用 Timer 轮询更新当前页（PDFKit 无原生页面变化通知）
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncState()
            }
        }

        // 恢复视图状态：**切标签回来用内存那份，新文档才去读存储**。
        //
        // 用存储那份去恢复"切回来的标签"是错的：存储里是"上次关闭这个文件时"的位置，
        // 拿它盖掉用户切走前的视图，看起来就是"位置和缩放全变了"。
        if let pending = pendingViewState {
            pendingViewState = nil
            whenViewIsReady { [weak self] in
                guard let self, let pdfView = self.pdfView else { return }
                // 先缩放、后定位：缩放一变布局和视口尺寸都跟着变，
                // 反过来先定位的话刚对好的位置会被挤走
                pdfView.autoScales = false
                pdfView.scaleFactor = pending.scaleFactor
                self.syncPreservedZoom()
                Diagnostics.shared.record("切回标签：恢复视图状态 页=\(pending.pageIndex)"
                                          + " 缩放=\(String(format: "%.3f", pending.scaleFactor))")
                self.applyReadingPosition(pageIndex: pending.pageIndex,
                                          offsetRatio: pending.offsetRatio)
            }
        } else if isNewDocument {
            restoreProgress()
        }
        updateBookmarkStatus()
        reloadTOC()

        // 盯住"书签已经改完"的广播：书签是**应用自己的数据**（存 UserDefaults），
        // 从哪儿被改都可能有（书签栏、工具栏、以后别的地方），
        // 与其在每个调用点手动刷新，不如统一在这里重算一次。
        //
        // ⚠️ 用 `pdfBookmarksDidChange` 而不是 `BookmarksStore.shared.$bookmarks`：
        // `@Published` 是 willSet，收到时数组还是旧的，算出来是改动前的状态。
        // 只挂一次 —— `bind` 有可能被调多次，重复订阅会白跑 N 遍。
        if bookmarksObservation == nil {
            bookmarksObservation = NotificationCenter.default
                .publisher(for: .pdfBookmarksDidChange)
                .sink { [weak self] _ in
                    self?.updateBookmarkStatus()
                }
        }
        reloadAnnotations()
        // 把批注的显示切到自绘（清晰 + 拖拽期间可实时刷新）。
        // 必须在绑定之后做 —— 这时才拿得到页面上已有的批注。
        applyDisplayPolicyToDocument()
    }

    func unbind() {
        // ⚠️ 必须在 `pdfView = nil` **之前**：关标签 / 关窗口时把"看到哪儿了"记下来
        //（页号 + 页内比例 + 缩放），下次打开才能接着看。见 `saveProgress`。
        saveProgress()
        clearUndoHistory()
        timer?.invalidate()
        timer = nil
        autoScroller.stop()
        speech.stop()
        speech.onFinish = nil
        pdfView = nil
    }

    /// 目录列表正在拖动 / 拖放交互期间，暂停 `syncState` 的页码校准（见它开头的说明）。
    ///
    /// **故意不是 `@Published`** —— 它只被读来决定"跳不跳过一次轮询"，不该引起任何重绘。
    /// 存"截止时刻"而不是布尔量：标记万一没被清掉（拖拽被取消）也会自己失效。
    var tocInteractionUntil: Date = .distantPast

    private func syncState() {
        // ⚠️ 拖动目录期间**先不校准页码**。
        //
        // 这个轮询每 0.3 秒一次，一旦发现页码变了就会写 `currentPageIndex` ——
        // 那是个 `@Published`，写一次就让**所有**观察者重算一轮（含目录列表那 40 多行）。
        // 拖动时主线程本来就在满负荷处理拖放回调，再插一次全界面重算就是雪上加霜。
        guard Date() >= tocInteractionUntil else { return }
        guard let pdfView = pdfView, let document = pdfView.document else { return }
        // ⚠️ 用**视口中心**所在的页，而不是 PDFKit 的 `currentPage`。
        //
        // 实测（`/tmp/pageprobe`，真 PDFView + 8 页文档 + `.singlePageContinuous`，也就是本
        // app 的显示模式）：**`currentPage` 只跟着 PDFKit 自己的滚动路径更新**。直接操作内部
        // `clipView` 之后它一点不变 —— 强制 `layout`/`display` 不变、窗口可见且是 key 窗口
        // 也不变、等 2 秒仍是旧页；而同一时刻"视口中心页"已经是正确的目标页。
        // （走 `go(to:)` 时它倒是会更新 —— 所以早先用 `go(to:)` 做的探针没能发现这一点。）
        //
        // 而 `centerOn` 用的正是"直接滚 clipView"这条路（`PDFView.go(to:)` 定位不到视图正中）。
        // 于是跳转后：我们刚把 `currentPageIndex` 设成目标页（列表里竖条亮起），0.3 秒后
        // 这个轮询用**没更新的** `currentPage` 把它冲回旧页 —— 竖条随即消失不再回来，
        // 就是「竖条出现后又消失，闪一下」的根因。
        //
        // 改成和 `centerOn` 同一套判据后两边永远一致：`centerOn` 把目标点摆到视口正中，
        // 目标页必然包含视口中心 —— 实测批注在页中央 / 页顶 / 页底，"视口中心页"都是目标页。
        let bounds = pdfView.bounds
        let centerPage = bounds.isEmpty
            ? nil
            : pdfView.page(for: CGPoint(x: bounds.midX, y: bounds.midY), nearest: true)
        if let page = centerPage ?? pdfView.currentPage {
            let index = document.index(for: page)
            if index != currentPageIndex {
                Diagnostics.shared.activity = "页码变了 → 刷新界面"
                currentPageIndex = index
                updateBookmarkStatus()
                addToHistory(pageIndex: index)
            }
        }
        if pdfView.scaleFactor != scaleFactor {
            scaleFactor = pdfView.scaleFactor
        }
        // 工具栏那个百分比按「实际大小」折算（见 `zoomPercent` 的说明）。
        // 这个轮询 0.3 秒一次，差 0.5% 以内不刷新 —— `zoomPercent` 是 `@Published`，
        // 写一次就让整个工具栏重算，没必要为那点观察不到的小数点白刷。
        let percent = pdfView.scaleFactor / ScreenMetrics.actualSizeScale(for: pdfView.window?.screen) * 100
        if abs(percent - zoomPercent) > 0.5 {
            zoomPercent = percent
        }
    }

    private func addToHistory(pageIndex: Int) {
        guard !isNavigatingHistory else { return }
        // 如果当前不在历史末尾，截断后面的历史
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        // 避免连续添加相同的页面
        if let last = history.last, last == pageIndex { return }
        history.append(pageIndex)
        if history.count > maxHistorySize {
            history.removeFirst()
        }
        historyIndex = history.count - 1
    }

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < history.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        isNavigatingHistory = true
        goToPage(at: history[historyIndex])
        isNavigatingHistory = false
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        isNavigatingHistory = true
        goToPage(at: history[historyIndex])
        isNavigatingHistory = false
    }

    private func updateBookmarkStatus() {
        guard let documentURL = pdfView?.document?.documentURL else { return }
        // 值没变就不赋值 —— `isCurrentPageBookmarked` 是 @Published，
        // 而这个方法现在会被书签 store 的**每次**变动调起（含别的文档的书签），
        // 不判等就会让工具栏白重绘一轮
        let value = BookmarksStore.shared.isBookmarked(
            documentURL: documentURL,
            pageIndex: currentPageIndex
        )
        if isCurrentPageBookmarked != value {
            isCurrentPageBookmarked = value
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 页面导航

    func goToPage(at index: Int) {
        guard let pdfView = pdfView,
              let document = pdfView.document,
              let page = document.page(at: index) else { return }

        let dest = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).height))
        pdfView.go(to: dest)
        currentPageIndex = index
        // ⚠️ 必须显式刷一次：`syncState` 只在"页码变了"时才更新书签状态，
        // 而这里已经把 `currentPageIndex` 写成了新值 —— 等 0.3 秒后的轮询跑到时
        // `index == currentPageIndex`，那一支根本不会进来。
        // 漏掉它的表现：从缩略图跳到某页后，工具栏的书签图标显示的还是**上一页**的状态。
        updateBookmarkStatus()
    }

    func goToPreviousPage() {
        pdfView?.goToPreviousPage(nil)
    }

    func goToNextPage() {
        pdfView?.goToNextPage(nil)
    }

    // MARK: - 缩放

    func zoomIn() {
        pdfView?.zoomIn(nil)
        syncPreservedZoom()
    }

    func zoomOut() {
        pdfView?.zoomOut(nil)
        syncPreservedZoom()
    }

    func zoomToActualSize() {
        // ⚠️ **不是 `1.0`**（v1.3.64）：`1.0` 只等于"1 PDF 点 = 1 界面点"，
        // 而"实际大小"要求页面上量出来就是纸的物理尺寸 —— 见 `ScreenMetrics`。
        pdfView?.autoScales = false
        pdfView?.scaleFactor = ScreenMetrics.actualSizeScale(for: pdfView?.window?.screen)
        syncPreservedZoom()
    }

    func zoomToFitWidth() {
        // 用户明确要"适合宽度" —— 解除钉住，并让 autoScales 重新接管
        resetPreservedZoom()
        pdfView?.autoScales = true
    }

    func zoomToFitPage() {
        guard let pdfView = pdfView, let page = pdfView.currentPage else { return }
        pdfView.autoScales = false
        let pageBounds = page.bounds(for: .cropBox)
        let visibleBounds = pdfView.convert(pdfView.bounds, from: pdfView)
        let scaleX = visibleBounds.width / pageBounds.width
        let scaleY = visibleBounds.height / pageBounds.height
        pdfView.scaleFactor = min(scaleX, scaleY)
        syncPreservedZoom()
    }

    // MARK: - 显示模式

    func setDisplayMode(_ mode: PDFDisplayMode) {
        pdfView?.displayMode = mode
    }

    func setDisplayDirection(_ direction: PDFDisplayDirection) {
        pdfView?.displayDirection = direction
    }

    // MARK: - 页面旋转

    func rotateCurrentPageClockwise() {
        rotateCurrentPage(by: 90)
    }

    func rotateCurrentPageCounterClockwise() {
        rotateCurrentPage(by: -90)
    }

    private func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfView?.currentPage else { return }
        let newRotation = (page.rotation + degrees + 360) % 360
        page.rotation = newRotation
    }

    // MARK: - 文档信息
    @Published var showDocumentInfo: Bool = false

    // MARK: - 历史导航
    private var history: [Int] = []
    private var historyIndex: Int = -1
    private var isNavigatingHistory = false
    private let maxHistorySize = 50

    struct DocumentInfo {
        let title: String?
        let author: String?
        let subject: String?
        let creator: String?
        let pageCount: Int
        let fileSize: String?
        let creationDate: Date?
        let modificationDate: Date?
    }

    var documentInfo: DocumentInfo? {
        guard let document = pdfView?.document else { return nil }
        let attrs = document.documentAttributes
        // 图片文档的 `documentURL` 是 nil（见 `ImageDocument` 的底线 1），
        // 文件大小要从原图那个 URL 取 —— 否则"文档信息"里图片永远没有大小。
        let url = document.documentURL ?? sourceURL
        let fileSize: String? = {
            guard let url = url else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(size))
        }()
        return DocumentInfo(
            title: attrs?[PDFDocumentAttribute.titleAttribute] as? String,
            author: attrs?[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attrs?[PDFDocumentAttribute.subjectAttribute] as? String,
            creator: attrs?[PDFDocumentAttribute.creatorAttribute] as? String,
            pageCount: document.pageCount,
            fileSize: fileSize,
            creationDate: attrs?[PDFDocumentAttribute.creationDateAttribute] as? Date,
            modificationDate: attrs?[PDFDocumentAttribute.modificationDateAttribute] as? Date
        )
    }

    // MARK: - 搜索

    /// 最多给 PDFView 塞多少条高亮。
    ///
    /// 每个高亮都要建绘图对象，搜「的」这种单字能出几千条，全画上去会把主线程拖住。
    /// 2000 已经远超正常搜索（右侧栏列表仍然显示**全部**结果）。
    private static let maxHighlightedResults = 2000

    func performSearch() {
        guard let document = pdfView?.document,
              !searchQuery.isEmpty else {
            searchResults.removeAll()
            pdfView?.highlightedSelections = nil
            return
        }

        isSearching = true
        searchResults.removeAll()
        // 开始新一轮搜索 → 先把上一轮的高亮撤掉，否则旧结果会一直留在页面上
        pdfView?.highlightedSelections = nil
        revealRightPanel()          // 搜索结果要放在右侧栏，先把它唤出来

        // 先把查询串取出，避免在后台闭包里跨 actor 读取 @Published 属性
        let query = searchQuery
        // PDFDocument 不是 Sendable，包一层以显式声明"只读查询可跨线程"
        let box = UnsafeSendableBox(value: document)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = box.value.findString(query, withOptions: .caseInsensitive)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.searchResults = results
                self.isSearching = false
                // **把所有结果都标记出来**（v1.3.74）。
                //
                // PDFKit 的 `highlightedSelections` 就是干这个的：接一组 `PDFSelection`，
                // 统一画成高亮。之前只用 `setCurrentSelection` 标了"当前那一条"，
                // 所以不点结果、页面上什么标记都看不到。
                //
                // ⚠️ 它和 `setCurrentSelection` **可以共存**：高亮是底色，
                // 当前选中那一条还会按系统选中色再描一层，一眼能分出"跳到哪了"。
                self.pdfView?.highlightedSelections =
                    results.isEmpty ? nil : Array(results.prefix(Self.maxHighlightedResults))
            }
        }
    }

    func goToSearchResult(at index: Int) {
        guard index >= 0, index < searchResults.count else { return }
        selectedSearchResult = index
        let selection = searchResults[index]
        pdfView?.setCurrentSelection(selection, animate: true)
        if let page = selection.pages.first {
            // 滚到**视图正中**（`scrollSelectionToVisible` 只保证可见，结果常贴在边上）
            centerOn(selection.bounds(for: page), page: page)
            if let document = pdfView?.document {
                let index = document.index(for: page)
                if index != currentPageIndex { currentPageIndex = index }
            }
        }
    }

    /// 把页面上的一块区域滚到视图正中。
    ///
    /// 换算关系与 `ScrollZoomMonitor` 的锚点补偿同源：
    /// `clipView.bounds` 处于 documentView 坐标系，**1 个单位 = scaleFactor 个屏幕点**，
    /// 且 y 方向与视图坐标相反。
    func centerOn(_ rect: CGRect, page: PDFPage) {
        guard let pdfView,
              let scrollView = pdfView.internalScrollView else { return }
        let clipView = scrollView.contentView
        let scale = pdfView.scaleFactor
        guard scale > 0 else { return }

        let rectInView = pdfView.convert(rect, from: page)
        let origin = AnnotationGeometry.scrollOriginToCenter(
            current: clipView.bounds,
            targetInView: rectInView,
            viewportCenter: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY),
            scale: scale
        )

        let constrained = clipView.constrainBoundsRect(
            CGRect(origin: origin, size: clipView.bounds.size)
        )
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    func clearSearch() {
        searchQuery = ""
        searchResults.removeAll()
        selectedSearchResult = -1
        // 两个都得清：`highlightedSelections` 是那一片高亮底色，
        // `currentSelection` 是"当前跳到哪一条"
        pdfView?.highlightedSelections = nil
        pdfView?.setCurrentSelection(nil, animate: false)
    }

    /// ⌘G：跳到下一个结果，到末尾回到开头
    func goToNextSearchResult() {
        guard !searchResults.isEmpty else { return }
        let index = selectedSearchResult < 0
            ? 0
            : (selectedSearchResult + 1) % searchResults.count
        goToSearchResult(at: index)
    }

    /// ⇧⌘G：跳到上一个结果，到开头回到末尾
    func goToPreviousSearchResult() {
        let count = searchResults.count
        guard count > 0 else { return }
        let index = selectedSearchResult < 0
            ? count - 1
            : (selectedSearchResult - 1 + count) % count
        goToSearchResult(at: index)
    }

    // MARK: - 书签

    func toggleBookmark() {
        guard let documentURL = pdfView?.document?.documentURL else { return }
        if isCurrentPageBookmarked {
            BookmarksStore.shared.remove(documentURL: documentURL, pageIndex: currentPageIndex)
        } else {
            BookmarksStore.shared.add(
                documentURL: documentURL,
                pageIndex: currentPageIndex,
                title: "第 \(currentPageIndex + 1) 页"
            )
        }
        updateBookmarkStatus()
    }

    /// 从书签栏删掉若干条。
    ///
    /// 书签栏**必须走这里**，不能直接 `BookmarksStore.shared.remove(...)` ——
    /// 那样只改了 UserDefaults，`isCurrentPageBookmarked` 不会重算，
    /// 表现就是"删掉书签后，工具栏那个书签图标还亮着不刷新"。
    /// （另外还挂了 store 的订阅兜底，见 `bind`，两条改动路径任一条都不会漏刷新。）
    func removeBookmarks(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        BookmarksStore.shared.remove(ids: ids)
        updateBookmarkStatus()
    }

    // MARK: - 书签栏的列表选择（供键盘监听判断 Delete 键该删什么）

    /// 书签栏当前选中的书签 id。
    ///
    /// 和 `annotationListSelectionCount` 一样**故意不是 `@Published`** ——
    /// 它在列表 `Binding` 的 `set`（视图更新过程中）被写入，而且只被键盘监听读取。
    var bookmarkListSelectionIDs: Set<UUID> = []

    /// 书签栏按下 Delete 的请求计数（键盘监听 +1，列表 `onChange` 到就弹确认框）。
    ///
    /// 和批注列表同一套路数：`.onDeleteCommand` 要列表拿到焦点才触发，
    /// 而焦点一般不在侧边栏，所以由键盘监听主动转发。
    @Published private(set) var bookmarkDeleteRequestTick = 0

    func requestDeleteOfBookmarkSelection() {
        bookmarkDeleteRequestTick &+= 1
    }

    /// 回到上次看到的地方（v1.3.37：位置精确到页内，缩放也一起回来）。
    ///
    /// ⚠️ **顺序是"先缩放、再定位"**。缩放一变，页面布局和视口尺寸就跟着变 ——
    /// 反过来先定位的话，刚对好的位置会被随后的缩放挤走。
    func restoreProgress() {
        // 用 `storageURL` 而不是 `document.documentURL` —— 图片的后者是 nil，
        // 那样这里会直接返回，缩放和位置都恢复不了（见 `storageURL` 的说明）。
        guard let documentURL = storageURL else { return }

        // ① 缩放
        if let zoom = BookmarksStore.shared.loadZoom(documentURL: documentURL),
           zoom > 0.05, zoom < 50 {
            pdfView?.autoScales = false
            pdfView?.scaleFactor = CGFloat(zoom)
            // 钉住：窗口宽度变化时 `layout()` 会把它还回来（见 `EditablePDFView` 的说明）
            syncPreservedZoom()
        }

        // ② 位置：**延后**到 PDFView 真正上屏、布局好之后再滚
        guard BookmarksStore.shared.loadReadingPosition(documentURL: documentURL) != nil
                || BookmarksStore.shared.loadProgress(documentURL: documentURL) != nil else { return }
        restoreSavedPositionWhenReady(documentURL: documentURL)
    }

    /// 等 PDFView 真正上屏、布局好之后再执行一段操作（最多约 2 秒）。
    ///
    /// ⚠️ 为什么必须等：`bind()` 是在 `makeNSView` / `updateNSView` 里调的，
    /// 那一刻视图**还没上屏**、`pdfView.bounds` 是零 —— 滚不动也定不了位。
    /// 更坏的是紧接着 0.3 秒的页码轮询会用**真实的视口中心**（第一页）把
    /// `currentPageIndex` 写回去，看着就像"位置压根没恢复"（v1.3.37 实测踩过）。
    ///
    /// 判据用"有窗口 + 有高度 + 有文档"而不是固定延迟：文档大小不同、
    /// 首次渲染耗时不同，固定延迟在慢机器上照样踩空。
    private func whenViewIsReady(_ attempt: Int = 0, _ body: @escaping () -> Void) {
        let limit = 14                       // ≈ 2.1 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let pdfView = self.pdfView,
                      pdfView.window != nil,
                      pdfView.bounds.height > 1,
                      pdfView.document != nil else {
                    if attempt < limit {
                        self.whenViewIsReady(attempt + 1, body)
                    } else {
                        Diagnostics.shared.record("等视图上屏：试了 \(limit) 轮还没好，放弃")
                    }
                    return
                }
                body()
            }
        }
    }

    /// **新文档**：把存储里的阅读位置滚回去（延后到视图上屏再执行）。
    ///
    /// ⚠️ 只在"真的换了文档"时用。切标签回来要走 `bind` 里那份**内存**里的
    /// `pendingViewState` —— 用存储这份（＝上次关闭该文件时的位置）去盖，
    /// 用户看到的就是"切回来位置和缩放全变了"。
    private func restoreSavedPositionWhenReady(documentURL: URL) {
        whenViewIsReady { [weak self] in
            guard let self else { return }
            if let saved = BookmarksStore.shared.loadReadingPosition(documentURL: documentURL) {
                Diagnostics.shared.record("恢复阅读位置：页 \(saved.pageIndex)"
                                          + " 页内比例 \(String(format: "%.3f", saved.offsetRatio))")
                self.applyReadingPosition(pageIndex: saved.pageIndex,
                                          offsetRatio: saved.offsetRatio)
            } else if let page = BookmarksStore.shared.loadProgress(documentURL: documentURL) {
                Diagnostics.shared.record("恢复阅读位置（老数据，只有页号）：页 \(page)")
                self.goToPage(at: page)
            }
        }
    }

    /// 把"现在看到哪儿了"记下来：缩放 + 页号 + **视口中心在页面里的纵向比例**。
    ///
    /// 关标签（`unbind`）和退出应用（`applicationShouldTerminate`）之前各调一次。
    func saveProgress() {
        // ⚠️ 同上：`storageURL` 而不是 `documentURL` —— 图片的后者是 nil，
        // 那样这里会直接返回，**缩放和阅读位置一个都不会被记住**
        //（v1.3.72 修的 bug：杰哥报"图片每次打开都没记住之前的缩放比例"）。
        guard let pdfView, let document = pdfView.document,
              let documentURL = storageURL else { return }
        BookmarksStore.shared.saveZoom(documentURL: documentURL,
                                       scaleFactor: Double(pdfView.scaleFactor))

        let bounds = pdfView.bounds
        guard !bounds.isEmpty else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // ⚠️ 用"**视口中心**所在的页"，和 `syncState` 的页码判据保持一致 ——
        // `currentPage` 不跟 `clipView` 的滚动更新，这个坑踩过好几次（见 syncState 的注释）
        guard let page = pdfView.page(for: center, nearest: true) else { return }
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.height > 0 else { return }
        let pagePoint = pdfView.convert(center, to: page)
        let ratio = min(max(pagePoint.y / pageRect.height, 0), 1)
        BookmarksStore.shared.saveReadingPosition(documentURL: documentURL,
                                                  pageIndex: document.index(for: page),
                                                  offsetRatio: Double(ratio))
    }

    /// 把"页号 + 页内纵向比例"摆到视口正中（比例 0 = 页底、1 = 页顶）。
    private func applyReadingPosition(pageIndex: Int, offsetRatio: Double) {
        guard let pdfView, let document = pdfView.document,
              let page = document.page(at: pageIndex) else { return }
        let pageRect = page.bounds(for: .cropBox)
        let target = CGPoint(x: pageRect.midX, y: pageRect.height * min(max(offsetRatio, 0), 1))
        scrollPointToCenter(target, page: page)
        currentPageIndex = pageIndex
        // 页码是直接写的，`syncState` 那一支不会进来 → 这里补一次书签图标状态
        updateBookmarkStatus()
    }

    /// 把页面上的一点滚到**视口正中**。
    /// `scrollPointToTop` 的兄弟，只是落点不同（那个摆到靠上 1/4 处，目录跳转用）。
    private func scrollPointToCenter(_ point: CGPoint, page: PDFPage) {
        guard let pdfView, let scrollView = pdfView.internalScrollView else { return }
        let clipView = scrollView.contentView
        let scale = pdfView.scaleFactor
        guard scale > 0, pdfView.bounds.height > 1 else { return }
        let rectInView = pdfView.convert(CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                        from: page)
        let origin = AnnotationGeometry.scrollOriginToCenter(
            current: clipView.bounds,
            targetInView: rectInView,
            viewportCenter: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY),
            scale: scale
        )
        let constrained = clipView.constrainBoundsRect(CGRect(origin: origin, size: clipView.bounds.size))
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - 点一下切「实际大小」（v1.3.37）

    /// 「切到实际大小之前」的缩放。nil = 当前不在那个临时态里。
    ///
    /// 存的是**点击那一刻**的比例，而不是某个"默认比例" ——
    /// 这样"实际大小 ↔ 我刚才的视图"之间来回切，无论之前是什么状态都对得上。
    ///
    /// ⚠️ v1.3.64 起"实际大小"是**屏幕相关**的值（见 `ScreenMetrics`），不再是 1.0。
    private var zoomBeforeActualSize: CGFloat?

    /// 点一下缩放到「实际大小」，再点一下回到原来的比例（工具栏那个百分比数字）。
    @discardableResult
    func toggleActualSizeAndBack() -> Bool {
        guard let pdfView else { return false }
        // "实际大小"是屏幕相关的（见 `ScreenMetrics`），不是写死的 1.0
        let actual = ScreenMetrics.actualSizeScale(for: pdfView.window?.screen)
        if let previous = zoomBeforeActualSize {
            zoomBeforeActualSize = nil
            pdfView.autoScales = false
            pdfView.scaleFactor = previous
            syncPreservedZoom()
            return false        // 现在不在实际大小了
        }
        let current = pdfView.scaleFactor
        // 本来就是实际大小 → 没什么可切的（也避免把那个值记成"要还原到的值"）
        guard abs(current - actual) > 0.001 else { return true }
        zoomBeforeActualSize = current
        pdfView.autoScales = false
        pdfView.scaleFactor = actual
        syncPreservedZoom()
        return true             // 现在在实际大小
    }

    /// 工具栏的百分比是不是正处在"临时切到实际大小"的状态
    var isShowingTemporaryActualSize: Bool { zoomBeforeActualSize != nil }

    // MARK: - 打印

    /// 打开打印设置面板。真正的打印由 `PDFPrintService` 执行。
    func presentPrintOptions() {
        activeSheet = .print
    }

    // MARK: - 标注：工具动作

    /// 对当前文字选区套用高亮 / 下划线 / 删除线
    func applyToolToSelection(_ tool: AnnotationTool) {
        guard isEditable,
              let pdfView = pdfView,
              let selection = pdfView.currentSelection,
              !selection.pages.isEmpty,
              let subtype = tool.subtype else { return }

        for page in selection.pages {
            let box = selection.bounds(for: page)
            guard box.width > 0, box.height > 0 else { continue }

            let annotation = PDFAnnotation(bounds: box, forType: subtype, withProperties: nil)
            applyStyle(to: annotation)
            // ⚠️ **必须按行切成多个 quad。**
            // 只给 `selection.bounds(for:)` 一个框的话，跨行选择会画成一大块实心矩形 ——
            // 行间空隙、以及每行没选到的横向范围全被涂上，和实际选中的文字对不上。
            // 用户的原话：「选择多行的时候，松开鼠标会与实际的选择不一致」。
            annotation.quadrilateralPoints = Self.lineQuads(of: selection, page: page, bounds: box)
            annotation.modificationDate = Date()
            attach(annotation, to: page)
            notifyAnnotationsChanged(on: page)
        }

        pdfView.setCurrentSelection(nil, animate: false)
        reloadAnnotations()
    }

    /// 把文字选区按**行**切成 quad 点。
    ///
    /// 坐标换算与顺序要求都写在 `AnnotationGeometry.quadPoints(forLines:bounds:)` 里
    /// （那两个坑是实测出来的，注释也在那边）。
    static func lineQuads(of selection: PDFSelection, page: PDFPage, bounds: CGRect) -> [NSValue]? {
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }
        let points = AnnotationGeometry.quadPoints(forLines: rects, bounds: bounds)
        return points.isEmpty ? nil : points.map { NSValue(point: $0) }
    }

    // MARK: - 标注：拖拽绘制（涂鸦 / 矩形 / 圆 / 箭头）

    /// 一次进行中的绘制。
    ///
    /// **注意：草稿批注不会加进页面。** 它只存在于内存里，由 `EditablePDFView.drawPagePost`
    /// 直接画出来 —— 这是实测后的选择：
    ///
    /// 早先的实现是"按下时就把批注挂到页上、拖动中不断改它，靠 PDFKit 重绘"。
    /// 实测（用真实 PDF + 真实事件循环）**完全不显示**：拖动 3 次屏幕纹丝不动
    /// （红色像素恒为 32），松手重建 document 才出现（52334）。
    /// 原因是 PDFKit 的页面层在鼠标拖拽期间不刷新，而重建 document 代价太大。
    ///
    /// 改成草稿不进页后：预览由 `drawPagePost` 画（属于 PDFView 自己的层，拖拽期间实时重绘），
    /// 松手时才真正创建批注 —— 既实时又轻量。
    private struct Draft {
        let tool: AnnotationTool
        let page: PDFPage
        let anchor: CGPoint
        let annotation: PDFAnnotation
        var inkPoints: [CGPoint]
    }

    private var draft: Draft?

    /// 草稿的预览几何 + 外观（页坐标），交给视图直接画。
    ///
    /// 涂鸦走「按点直接构建」（拖动期间**不更新** `PDFAnnotation`，见 `continueDrawing`），
    /// 形状走草稿批注 —— 两边最终落下的批注几何是一致的。
    func draftPreview(for page: PDFPage)
        -> (shape: AnnotationRenderer.Shape, color: NSColor, lineWidth: CGFloat)? {
        guard let draft, draft.page === page else { return nil }
        let annotation = draft.annotation
        let lineWidth = AnnotationRenderer.strokeWidth(of: annotation)

        let shape: AnnotationRenderer.Shape?
        if draft.tool == .ink {
            shape = AnnotationRenderer.inkPaths(points: draft.inkPoints, lineWidth: lineWidth)
        } else {
            shape = AnnotationRenderer.paths(for: annotation)
        }
        guard let shape else { return nil }
        return (shape, annotation.color, lineWidth)
    }

    @discardableResult
    func beginDrawing(tool: AnnotationTool, pageIndex: Int, at point: CGPoint) -> Bool {
        guard isEditable,
              tool.isDragDraw,
              let document = pdfView?.document,
              let page = document.page(at: pageIndex) else { return false }

        let subtype = tool.subtype ?? .ink
        let annotation = PDFAnnotation(bounds: CGRect(origin: point, size: .zero),
                                       forType: subtype,
                                       withProperties: nil)
        applyStyle(to: annotation)
        // 线类工具的端点样式（直线两头都不带三角，箭头只在末端带）
        if tool == .arrow || tool == .line {
            annotation.startLineStyle = .none
            annotation.endLineStyle = tool.hasArrowHead ? .closedArrow : .none
        }
        annotation.modificationDate = Date()

        // 刻意**不**调用 page.addAnnotation —— 草稿只用于预览
        draft = Draft(tool: tool, page: page, anchor: point, annotation: annotation,
                      inkPoints: tool == .ink ? [point] : [])
        return true
    }

    func continueDrawing(to point: CGPoint) {
        guard var current = draft else { return }
        let annotation = current.annotation

        switch current.tool {
        case .rectangle, .ellipse:
            annotation.bounds = atLeastVisibleThickness(AnnotationGeometry.rectBetween(current.anchor, point))

        case .arrow, .line:
            // ⚠️ Line 的 start/end 是**批注空间**（相对 bounds 原点），用页坐标会画不出来。
            // 框再外扩半个线宽：水平/垂直线的包围盒有一边是 0，
            // 退化的 Rect 写进 PDF 后别的阅读器可能不画（描边本身也有一半在框外）。
            let pad = AnnotationRenderer.strokeWidth(of: annotation) / 2
            let box = AnnotationGeometry.rectBetween(current.anchor, point).insetBy(dx: -pad, dy: -pad)
            annotation.bounds = box
            let ends = AnnotationGeometry.linePointsInAnnotationSpace(anchor: current.anchor,
                                                                     current: point,
                                                                     bounds: box)
            annotation.startPoint = ends.start
            annotation.endPoint = ends.end
            annotation.startLineStyle = .none
            // 只有箭头带三角；「直线」工具两端都是光秃秃的
            annotation.endLineStyle = current.tool.hasArrowHead ? .closedArrow : .none

        case .ink:
            // ⚠️ 这里**只追加点**，一个字都不写进 `PDFAnnotation`。
            //
            // 原因（探针实测，真实窗口 + 125Hz 合成事件）：涂鸦若每来一个点就重建
            // 整条笔迹（`remove` 掉每一段 + 重新 `add` + 改 `bounds`），成本随点数线性增长，
            // 而它发生在**每一次鼠标事件**里 —— 900 点时事件滞后 P90 就到了 40 ms、
            // 峰值 80 ms（矩形/箭头只有 6~7 ms）。表现就是"越画越跟手不上"。
            //
            // 落成批注推迟到 `finishDrawing` 做一次（见 `buildInkPath`）。
            current.inkPoints.append(point)
            draft = current

        default:
            return
        }

        annotation.modificationDate = Date()
    }

    /// 拖动已有 ink 批注时调用：让墨迹**真的跟着框走**。
    ///
    /// ⚠️ PDFKit 改 `bounds` 时不动 ink 的墨迹（墨迹在文件里是绝对坐标），
    /// 于是 `/Rect` 和墨迹脱节，别的阅读器按 `/Rect` 裁剪就把涂鸦切掉一块。
    /// 详见 `AnnotationRenderer` 的「涂鸦（ink）的几何一致性」那一节。
    ///
    /// 超长笔迹的降级：重建是 O(点数)（实测 1000 点 1.4 ms、4000 点 5 ms），
    /// 每帧做一次对拖动来说仍可接受。但笔迹大到 `reanchorPointLimit` 以上时
    /// 改成**松手时补一次**（拖动中先只看框，见 `finishMovingAnnotation`）——
    /// 宁可那一下墨迹晚点到位，也不要把拖动拖成一卡一卡的。
    func reanchorInkIfNeeded(_ annotation: PDFAnnotation) {
        guard AnnotationItem.Kind(subtype: annotation.type) == .ink else { return }
        let points = (annotation.paths ?? []).reduce(0) { $0 + $1.elementCount }
        guard points <= Self.reanchorPointLimit else { return }
        AnnotationRenderer.reanchorInkStrokes(of: annotation)
    }

    /// 笔迹点数超过它就不再"每帧重建"（见 `reanchorInkIfNeeded`）
    static let reanchorPointLimit = 2000

    /// 拖动结束时的收尾：把降级跳过的那次重建补上。
    func finishMovingAnnotation(_ annotation: PDFAnnotation) {
        guard AnnotationItem.Kind(subtype: annotation.type) == .ink else { return }
        AnnotationRenderer.reanchorInkStrokes(of: annotation)
    }

    /// 给框补一点点厚度，只为了不让 `Rect` 退化成"零厚度矩形"
    /// （水平/垂直拖出来的一边是 0，写进 PDF 后别的阅读器可能干脆不画）。
    ///
    /// ⚠️ **只能补很小一点点（0.5 点）。** 曾经按"补到一个线宽"来保证厚度，
    /// 结果拖出来的前几个点里框被撑到线宽大小 —— 形状看着不动，
    /// 用户的原话是「最开始的几个移动点还是没有真正画出来」。
    /// 厚度只要非零就够，别去改形状本身。
    private func atLeastVisibleThickness(_ box: CGRect) -> CGRect {
        let minimum: CGFloat = 0.5
        var result = box
        if result.width < minimum {
            result = result.insetBy(dx: -(minimum - result.width) / 2, dy: 0)
        }
        if result.height < minimum {
            result = result.insetBy(dx: 0, dy: -(minimum - result.height) / 2)
        }
        return result
    }

    /// 只请求重绘（`needsDisplay`）。
    ///
    /// ⚠️ **不要在拖拽绘制的每帧里调它。** 拖动预览是独立 `CAShapeLayer`
    /// （见 `EditablePDFView.syncDraftPreview`），一次 `layer.path` 赋值就够；
    /// 走 `needsDisplay` 会让 PDFKit 把整页重新合成一遍，白白多一份开销。
    /// 只有「把可能画在页面画布上的草稿清掉」才需要它（取消绘制、尺寸太小丢弃）。
    private func requestRedraw() {
        pdfView?.needsDisplay = true
    }

    /// 涂鸦：把累积的点一次性落成 ink 笔迹。
    ///
    /// 笔迹坐标是**相对 bounds 原点**的（见 `PDFAnnotationInk.h`），
    /// 所以要先按全部点算出 bounds，再把点换算到批注空间。
    ///
    /// ⚠️ **只在松手时调用一次**。拖动期间每来一个点就重建一遍的话，
    /// 成本是 O(点数)，而它落在每一次鼠标事件里 —— 实测 900 点时事件滞后
    /// P90 40 ms、峰值 80 ms，画长笔画会明显"跟不上手"（见 `continueDrawing`）。
    private func buildInkPath(of annotation: PDFAnnotation, points: [CGPoint]) {
        guard !points.isEmpty else { return }

        var bounds = AnnotationGeometry.boundingRect(of: points)
        // 点集只是"笔迹中心线"的包围盒，而描边还会向外扩半个线宽 ——
        // 外扩后既更贴合实际墨迹，也顺手把「原地戳一下」的 0×0 框变成有厚度的小方块，
        // 免得写进 PDF 的是个零厚度 Rect。
        let pad = max(style.lineWidth / 2, 0.5)
        bounds = bounds.insetBy(dx: -pad, dy: -pad)
        annotation.bounds = bounds

        // 清掉旧笔迹：PDFKit 的 ink 只支持 add/removeBezierPath
        for path in annotation.paths ?? [] {
            annotation.remove(path)
        }

        let locals = AnnotationGeometry.inkPointsInAnnotationSpace(points, bounds: bounds)

        let path = NSBezierPath()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, local) in locals.enumerated() {
            if index == 0 {
                path.move(to: local)
            } else {
                path.line(to: local)
            }
        }
        if let only = locals.first, locals.count == 1 {
            // 单点也要留下痕迹，否则"点一下"什么都没有
            let radius = max(style.lineWidth / 2, 1)
            path.appendOval(in: CGRect(x: only.x - radius, y: only.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        annotation.add(path)
    }

    func finishDrawing() {
        guard let current = draft else { return }
        draft = nil

        // 尺寸太小的当作误触：拖了一下但没拉开，直接丢弃（草稿还没进 PDF，丢了就行）
        //
        // ⚠️ **不能拿包围盒当判据。** 箭头和细长的矩形包围盒总有一边接近 0 ——
        // 用 `bounds.height < 3` 判断的话，一条画得好好的水平箭头会被整条丢掉，
        // 表现就是"箭头距离短/画得平的时候就消失了"。
        let bounds = current.annotation.bounds
        let tooSmall: Bool
        switch current.tool {
        case .ink:
            tooSmall = current.inkPoints.count < 2
        case .arrow, .line:
            // 用线的实际长度（起终点是批注空间坐标，差值就是长度）
            let start = current.annotation.startPoint
            let end = current.annotation.endPoint
            tooSmall = hypot(end.x - start.x, end.y - start.y) < 3
        case .rectangle, .ellipse:
            // 两边都太小才算误触 —— 细长的矩形是合法图形
            tooSmall = bounds.width < 2 && bounds.height < 2
        default:
            tooSmall = false
        }
        if tooSmall {
            requestRedraw()
            return
        }

        // 涂鸦的笔迹一路没写进批注，到这里一次性落上
        if current.tool == .ink {
            buildInkPath(of: current.annotation, points: current.inkPoints)
        }
        current.annotation.modificationDate = Date()

        // 到这一步才真正入页 —— 拖动全程都没碰过 PDF
        // （拖拽绘制的批注**不走 `attach`**，所以撤销快照要在这里单独拍）
        if let index = pdfView?.document?.index(for: current.page) {
            let kind = AnnotationItem.Kind(subtype: current.annotation.type).rawValue
            recordUndo(pages: [index], name: "添加\(kind)")
        }
        current.page.addAnnotation(current.annotation)
        // 显示交给我们自绘（清晰 + 可控），PDFKit 那份不再画
        current.annotation.shouldDisplay = false

        notifyAnnotationsChanged(on: current.page)
        reloadAnnotations()
        select(current.annotation, pageIndex: pdfView?.document?.index(for: current.page) ?? 0)
    }

    /// 取消进行中的绘制（按 Esc 或切换文档）。
    /// 草稿从没进过 PDF，丢掉即可 —— 不需要从页面上移除什么。
    func cancelDrawing() {
        guard draft != nil else { return }
        draft = nil
        requestRedraw()
    }

    var isDrawing: Bool { draft != nil }

    // MARK: - 标注：点击放置（文本 / 便签 / 签名）

    /// 点击放置类工具在页面上点了一下 —— 记下落点并弹窗，确认后落在点上
    func requestPlacement(tool: AnnotationTool, pageIndex: Int, at point: CGPoint) {
        guard isEditable, tool.isClickToPlace else { return }
        pendingPlacement = Placement(pageIndex: pageIndex, point: point)
        switch tool {
        case .text: activeSheet = .freeText
        case .note: activeSheet = .note
        case .signature: activeSheet = .signature
        default: break
        }
    }

    /// 取放置点所在的页；没点过就退回当前页
    private func placementPage() -> (page: PDFPage, point: CGPoint?)? {
        guard let document = pdfView?.document else { return nil }
        if let placement = pendingPlacement,
           let page = document.page(at: placement.pageIndex) {
            return (page, placement.point)
        }
        guard let page = pdfView?.currentPage else { return nil }
        return (page, nil)
    }

    private func consumePlacement() {
        pendingPlacement = nil
        // 放置完回到选择工具，符合"放一个就结束"的直觉
        if activeTool.isClickToPlace { activeTool = .select }
    }

    // MARK: - 标注：几何辅助

    /// 两个点构成的正规矩形（拖拽可能往任意方向）
    static func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        AnnotationGeometry.rectBetween(a, b)
    }

    /// 一组点的包围盒
    static func boundingRect(of points: [CGPoint]) -> CGRect {
        AnnotationGeometry.boundingRect(of: points)
    }

    /// 把当前样式套到批注上
    func applyStyle(to annotation: PDFAnnotation) {
        let kind = AnnotationItem.Kind(subtype: annotation.type)

        // 「透明」= 不上色。描边类的标注没有颜色就是**看不见**，那不是用户要的结果 ——
        // 所以这个状态只在"带背景/填充"的种类上有意义，别的种类一律纠正回有色。
        // 放这里是因为 `applyStyle` 是所有"新建/改样式"的唯一入口。
        if style.isTransparent && !AnnotationStyle.supportsTransparent(kind) {
            style.isTransparent = false
        }

        switch kind {
        case .highlight, .underline, .strikeOut:
            // border 对这三种无效，靠 color 的透明度
            annotation.color = style.paint(for: kind)

        case .ink, .square, .circle, .line:
            annotation.color = style.paint(for: kind)
            let border = PDFBorder()
            border.lineWidth = style.lineWidth
            annotation.border = border
            if style.isFilled && kind != .ink {
                annotation.interiorColor = style.paint(for: kind).withAlphaComponent(0.2)
            }

        case .freeText:
            // 背景色和**文字**颜色分开：背景是 `annotation.color`，
            // 文字是 `annotation.fontColor`（渲染时读它，见 AnnotationRenderer.drawFreeText）
            annotation.color = style.paint(for: kind)
            annotation.fontColor = style.textPaint
            annotation.font = style.font

        case .note:
            annotation.color = style.paint(for: kind)

        default:
            // `.other` / 图章 / 结构性噪音：不改它的颜色和描边，
            // 原样留着（别人加的东西，别乱动）
            break
        }

        // 透明度 / 文字色 / 字体 PDFKit 写盘会丢，用自己的键存一份（见 AnnotationAppearance）
        AnnotationAppearance.save(style.snapshot(for: kind), to: annotation)
    }

    // MARK: - 批注：便签 / 文本注释

    func addStickyNote(text: String) {
        guard isEditable, let (page, placedAt) = placementPage() else { return }
        let size: CGFloat = 26

        // 点过就以点为**中心**（图标类居中更符合直觉），没点过就放到可见区右上角
        let origin: CGPoint
        if let placedAt {
            origin = CGPoint(x: placedAt.x - size / 2, y: placedAt.y - size / 2)
        } else {
            let visible = visibleRect(on: page)
            origin = CGPoint(x: visible.maxX - size - 12, y: visible.maxY - size - 12)
        }

        let annotation = PDFAnnotation(
            bounds: FreeTextLayout.clampToPage(
                CGRect(origin: origin, size: CGSize(width: size, height: size)),
                pageBounds: page.bounds(for: .cropBox)
            ),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = text
        applyStyle(to: annotation)
        annotation.modificationDate = Date()

        attach(annotation, to: page)
        consumePlacement()
        notifyAnnotationsChanged(on: page)
        reloadAnnotations()
        select(annotation, pageIndex: pdfView?.document?.index(for: page) ?? 0)
    }

    func addFreeText(text: String) {
        guard isEditable, let (page, placedAt) = placementPage() else { return }
        let visible = visibleRect(on: page)

        // 字体（族名 / 字号 / 粗斜体）跟着工具条和弹窗里那份 `style` 走
        let font = style.font

        // 尺寸按内容自适应，不再写死高度（见 FreeTextLayout 里的标定表）
        let maxWidth = max(
            FreeTextLayout.minimumWidth,
            min(visible.width * 0.9, FreeTextLayout.maximumWidth)
        )
        let size = FreeTextLayout.fittedSize(for: text, font: font, maxWidth: maxWidth)

        // 点过就以点为**左上角**（"文字从这里开始"），没点过就放到可见区中央
        let origin = placedAt
            ?? CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let rect = FreeTextLayout.clampToPage(
            CGRect(origin: origin, size: size),
            pageBounds: page.bounds(for: .cropBox)
        )

        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        // 记下这条批注的换行宽度上限 —— 以后改字号重排要用它，
        // 不能用"现有宽度"，否则改小一次就再也长不回去
        FreeTextLayout.setMaxWidth(maxWidth, on: annotation)
        applyStyle(to: annotation)
        annotation.modificationDate = Date()

        attach(annotation, to: page)
        consumePlacement()
        notifyAnnotationsChanged(on: page)
        reloadAnnotations()
        select(annotation, pageIndex: pdfView?.document?.index(for: page) ?? 0)
    }

    // MARK: - 批注：编辑已有的文本注释（v1.3.73）

    /// 双击一条文本注释 → 打开编辑框改里面的文字。
    func beginEditingFreeText(_ annotation: PDFAnnotation, pageIndex: Int) {
        guard isEditable else { return }
        editingFreeText = FreeTextTarget(annotation: annotation,
                                         pageIndex: pageIndex,
                                         originalText: annotation.contents ?? "")
        activeSheet = .editFreeText
    }

    /// 编辑框点了「保存」：换掉内容，并按新内容重算**高度**。
    ///
    /// 两条约束和拖边框保持一致，让用户的心智模型是同一个：
    /// - **宽度不动** —— 用户可能刚拖过边框，那是他定的宽度，不该被内容改掉；
    /// - **顶部固定** —— 内容变多就往下长。
    func updateFreeText(to newText: String) {
        guard isEditable, let target = editingFreeText else { return }
        defer { editingFreeText = nil }

        let annotation = target.annotation
        guard let document = pdfView?.document,
              let page = document.page(at: target.pageIndex) else { return }
        // 内容没变就别入撤销栈 —— 否则列表里凭空多一步"改了但什么都没改"
        guard newText != target.originalText else { return }

        beginMoveUndo(pageIndex: target.pageIndex)

        annotation.contents = newText
        // 字体读**批注自己的**（`FreeTextLayout.font(of:)`），不是工具栏那份 ——
        // 这条注释当初建的时候用的什么字体，改文字不该把它换掉。
        let font = FreeTextLayout.font(of: annotation)
        let width = annotation.bounds.width
        let height = FreeTextLayout.requiredHeight(for: newText, font: font, width: width)
        let origin = CGPoint(x: annotation.bounds.minX,
                             y: annotation.bounds.maxY - height)      // 顶部固定
        annotation.bounds = FreeTextLayout.clampToPage(
            CGRect(origin: origin, size: CGSize(width: width, height: height)),
            pageBounds: page.bounds(for: .cropBox)
        )
        annotation.modificationDate = Date()

        endMoveUndo(committed: true, name: "修改文本内容")
        notifyAnnotationsChanged(on: page)
        reloadAnnotations()
        select(annotation, pageIndex: target.pageIndex)
    }

    // MARK: - 批注：手写签名

    func insertSignature(_ payload: SignaturePayload) {
        guard isEditable, let (page, placedAt) = placementPage() else { return }
        let visible = visibleRect(on: page)
        let pageBounds = page.bounds(for: .cropBox)

        // 目标宽度取页宽的 35%，但不超过可见区域宽的 70%
        let inkAspect = payload.inkBounds.height / max(payload.inkBounds.width, 1)
        let targetWidth = min(pageBounds.width * 0.35, visible.width * 0.7)
        let targetHeight = targetWidth * inkAspect

        // 点过就以点为**中心**（签名像盖章，盖在点上），没点过就放到可见区偏下
        let target: CGRect
        if let placedAt {
            target = CGRect(x: placedAt.x - targetWidth / 2,
                            y: placedAt.y - targetHeight / 2,
                            width: targetWidth,
                            height: targetHeight)
        } else {
            target = CGRect(x: visible.midX - targetWidth / 2,
                            y: visible.minY + visible.height * 0.12,
                            width: targetWidth,
                            height: targetHeight)
        }

        let annotation = PDFAnnotation(bounds: FreeTextLayout.clampToPage(target, pageBounds: pageBounds),
                                       forType: .ink,
                                       withProperties: nil)
        // 签名默认用当前颜色，但不用"形状线宽"（签名有自己更自然的粗细）
        annotation.color = payload.color
        let border = PDFBorder()
        border.lineWidth = max(1, style.lineWidth * 0.8)
        annotation.border = border
        annotation.modificationDate = Date()

        // 画布坐标（原点左上、y 向下）→ 批注局部坐标（原点左下、y 向上）
        let scaleX = target.width / max(payload.inkBounds.width, 1)
        let scaleY = target.height / max(payload.inkBounds.height, 1)

        func localPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - payload.inkBounds.minX) * scaleX,
                y: target.height - (point.y - payload.inkBounds.minY) * scaleY
            )
        }

        for stroke in payload.strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            if stroke.count == 1 {
                // 单点笔画画一个圆点，保证"点一下"也能留下痕迹
                let point = localPoint(stroke[0])
                path.appendOval(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
            } else {
                for (index, point) in stroke.enumerated() {
                    let local = localPoint(point)
                    if index == 0 {
                        path.move(to: local)
                    } else {
                        path.line(to: local)
                    }
                }
            }

            annotation.add(path)
        }

        attach(annotation, to: page)
        consumePlacement()
        notifyAnnotationsChanged(on: page)
        reloadAnnotations()
        select(annotation, pageIndex: pdfView?.document?.index(for: page) ?? 0)
    }

    // MARK: - 批注：列表与持久化（v1.0）

    // MARK: - 批注显示策略

    /// 把批注加进页面，并关掉 PDFKit 的显示 —— 改由 `AnnotationRenderer` 自绘。
    ///
    /// 为什么自绘（两条实测结论，详见 `AnnotationRenderer` 顶部注释）：
    /// - **清晰度**：PDFKit 的页面层 `contentsScale` 是 1.0 而屏幕是 2.0，
    ///   批注是 1x 栅格化后放大显示，边缘发虚；自绘走原生分辨率。
    /// - **实时性**：PDFKit 的批注层在鼠标拖拽期间不刷新（实测拖动全程屏幕不动，
    ///   松手重建 document 才出现）；`drawPagePost` 属于 PDFView 自己的层，是实时的。
    ///
    /// ⚠️ `shouldDisplay = false` **会被持久化到文件里**（实测重载后仍是 false），
    /// 所以写回 PDF 之前必须恢复成 `true`，否则别的阅读器打开看不到批注。
    /// 见 `saveAnnotationsToDisk`。
    private func attach(_ annotation: PDFAnnotation, to page: PDFPage) {
        // ── 给批注署名（v1.3.61）──
        //
        // 写的是 PDF 标准的 `/T` 字段（`PDFAnnotation.userName`），
        // Adobe / 预览 / Foxit 都读它 —— 别人打开文件能看到"这条是谁标的"。
        // 以前没填，等于所有标注都是匿名的。
        //
        // 名字来自设置（默认取系统里当前用户的全名，可以自己改）。
        // ⚠️ 必须在 `addAnnotation` **之前**设：PDFKit 是在挂上页面那一刻
        //    把属性带进注释字典的，挂完再改不一定同步得过去。
        let author = AppPreferences.shared.annotationAuthor
        if !author.isEmpty {
            annotation.userName = author
        }

        // ⚠️ 撤销快照必须在这里拍 —— 这是**所有"新增批注"路径唯一的漏斗**
        // （文字选区套高亮/下划线/删除线、便签、文本注释、签名都走它）。
        // 拍的是"加上这一条之前"的页面。
        if let index = pdfView?.document?.index(for: page) {
            let kind = AnnotationItem.Kind(subtype: annotation.type).rawValue
            recordUndo(pages: [index], name: "添加\(kind)")
        }
        page.addAnnotation(annotation)
        applyDisplayPolicy(to: annotation)
    }

    /// 单个批注的显示策略：能自绘的交给自绘，不认识的留给 PDFKit。
    private func applyDisplayPolicy(to annotation: PDFAnnotation) {
        annotation.shouldDisplay = !AnnotationRenderer.isSelfRendered(annotation)
    }

    /// 整份文档应用一次显示策略。**文档加载后调用** ——
    /// 这样连别的应用创建的批注也能以清晰的方式显示（只要类型是我们能正确渲染的）。
    func applyDisplayPolicyToDocument() {
        guard let document = pdfView?.document else { return }

        // 先把已经被写坏的 ink 修回来：`/Rect` 没包住墨迹的话，别的阅读器
        // 会把露在外面的那部分裁掉（见 `AnnotationRenderer` 里那一节的实测）。
        // 改的是框，不动墨迹 —— 只影响"别的阅读器怎么裁"，屏幕上的观感一点不变。
        AnnotationRenderer.reconcileInkBounds(in: document)

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                // 先把我们自己的键里存的外观还原回原生属性 ——
                // PDFKit 写盘会丢掉透明度和字体（见 AnnotationAppearance 的实测表），
                // 不还原的话"存盘再打开"高亮会变实心、文字会变黑、字体回 Helvetica 12。
                AnnotationAppearance.restore(on: annotation)
                applyDisplayPolicy(to: annotation)
            }
        }
        // 要让 PDFKit 重画一遍，把"它之前画过的那一份"擦掉；
        // 页面内容在内部的 PDFPageView 上，所以必须递归标脏，不能只标 PDFView
        if let pdfView {
            Self.markNeedsDisplayRecursively(pdfView)
        }
    }

    func reloadAnnotations() {
        guard let document = pdfView?.document else {
            annotations = []
            selectedAnnotation = nil
            return
        }
        var items: [AnnotationItem] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let item = AnnotationItem(pageIndex: pageIndex, annotation: annotation)
                // 过滤 PDFKit 自动派生出来的 Popup / Link / Widget 等非用户批注
                guard item.isUserAnnotation else { continue }
                items.append(item)
            }
        }
        annotations = items.sorted { $0.pageIndex < $1.pageIndex }
        // 记一条：列表到底收了几条、都是什么类型（"别人加的批注列不出来"这类问题
        // 靠它一眼定位，见 `isUserAnnotation`）
        Diagnostics.shared.record("批注列表：\(annotations.count) 条 → "
            + annotations.map { "\($0.kind.rawValue)(第\($0.pageIndex + 1)页)" }.joined(separator: "、"))

        // 重新解析一遍选中项：列表里的 AnnotationItem 是值类型，
        // 重建后必须换成新数组里的那一个，否则属性栏会拿着旧的
        if let selected = selectedAnnotation {
            selectedAnnotation = annotations.first { $0.annotation === selected.annotation }
        }
    }

    func goToAnnotation(_ item: AnnotationItem) {
        guard let document = pdfView?.document,
              let page = document.page(at: item.pageIndex) else { return }
        // 同样滚到视图正中，而不是只保证可见
        centerOn(item.annotation.bounds, page: page)
        // 值没变就别赋值 —— `currentPageIndex` 是 @Published，每赋一次都会牵动
        // 工具栏、缩略图列表、批注列表的"当前页"标记跟着重绘一轮
        if currentPageIndex != item.pageIndex {
            currentPageIndex = item.pageIndex
        }
        select(item.annotation, pageIndex: item.pageIndex)
    }

    func removeAnnotation(_ item: AnnotationItem) {
        guard isEditable,
              let document = pdfView?.document,
              let page = document.page(at: item.pageIndex) else { return }
        // 快照要在移除之前拍
        recordUndo(pages: [item.pageIndex], name: "删除批注")
        if selectedAnnotation?.annotation === item.annotation {
            selectedAnnotation = nil
        }
        page.removeAnnotation(item.annotation)
        notifyAnnotationsChanged(on: page)
        reloadAnnotations()
    }

    /// 批量删除（列表多选后用）。
    ///
    /// 与逐条调用 `removeAnnotation` 的区别：**只重新解析一次批注列表**。
    /// 逐条删会触发 N 次 `reloadAnnotations()`，而它每次都遍历整份文档的每一页 ——
    /// 删几十条时是肉眼可见的卡顿。
    func removeAnnotations(_ items: [AnnotationItem]) {
        guard isEditable, !items.isEmpty, let document = pdfView?.document else { return }

        // 一次删一批算**一步**撤销（不然按一次 ⌘Z 只回来一条，得按几十次）
        recordUndo(pages: items.map(\.pageIndex),
                   name: items.count > 1 ? "删除 \(items.count) 条批注" : "删除批注")

        // 选中项如果落在被删的集合里，一并清掉（否则属性栏会拿着一条已经不存在的批注）
        let doomed = Set(items.map { ObjectIdentifier($0.annotation) })
        if let selected = selectedAnnotation,
           doomed.contains(ObjectIdentifier(selected.annotation)) {
            selectedAnnotation = nil
        }

        var touchedPages = Set<Int>()
        for item in items {
            guard let page = document.page(at: item.pageIndex) else { continue }
            page.removeAnnotation(item.annotation)
            touchedPages.insert(item.pageIndex)
        }
        // 同一页删多条只标脏一次
        for index in touchedPages {
            guard let page = document.page(at: index) else { continue }
            notifyAnnotationsChanged(on: page)
        }
        reloadAnnotations()
    }

    // MARK: - 选中与属性（v1.3）

    /// 选中一条标注（右侧属性栏据此显示）
    func select(_ annotation: PDFAnnotation?, pageIndex: Int) {
        if let annotation {
            // 选中时把它的外观读进设置，属性栏里的"当前值"就是它的值
            let item = AnnotationItem(pageIndex: pageIndex, annotation: annotation)
            // 已经是这一条就不重复赋值：`selectedAnnotation` 是 @Published，
            // 赋一次值会让列表、属性栏、调色板所有观察者各重绘一轮。
            // 点已经选中的那一行不该引起任何刷新。
            // ⚠️ 必须按**引用**比较 —— `AnnotationItem` 是值类型，
            //    这里刚构造出来的新实例和数组里那个永远不相等。
            if selectedAnnotation?.annotation !== annotation {
                selectedAnnotation = item
            }
            // 把右侧栏唤出来（只显示不隐藏，见 revealRightPanel 的说明）
            revealRightPanel()
            style.adopt(from: annotation, kind: item.kind)
            pdfView?.needsDisplay = true
        } else {
            clearSelection()
        }
    }

    func clearSelection() {
        guard selectedAnnotation != nil else { return }
        selectedAnnotation = nil
        pdfView?.needsDisplay = true
    }

    /// 删除当前选中的标注（Delete 键 / 属性栏的删除按钮）
    func deleteSelectedAnnotation() {
        guard let item = selectedAnnotation else { return }
        removeAnnotation(item)
    }

    /// 把当前样式（颜色 / 透明度 / 线宽 / 字体）套到选中的标注上
    func applyStyleToSelection() {
        guard isEditable, let item = selectedAnnotation else { return }
        let annotation = item.annotation
        recordUndo(pages: [item.pageIndex], name: "修改样式")

        switch item.kind {
        case .highlight, .underline, .strikeOut:
            annotation.color = style.paint(for: item.kind)
        default:
            applyStyle(to: annotation)
        }
        annotation.modificationDate = Date()

        if item.kind == .freeText {
            // 改字号 / 字体要顺带把框调整到放得下（换了字族行高会变）
            if let fitted = FreeTextLayout.fittedBounds(
                forExisting: annotation.bounds,
                text: item.content,
                font: style.font,
                maxWidth: FreeTextLayout.maxWidth(of: annotation)
            ), let document = pdfView?.document, let page = document.page(at: item.pageIndex) {
                annotation.bounds = FreeTextLayout.clampToPage(fitted, pageBounds: page.bounds(for: .cropBox))
            }
        }

        if let document = pdfView?.document, let page = document.page(at: item.pageIndex) {
            notifyAnnotationsChanged(on: page)
        }
        reloadAnnotations()
    }

    var hasSelection: Bool { selectedAnnotation != nil }

    /// 命中测试：返回该页上可以点选的标注。
    ///
    /// `tolerance` 是额外扩边 —— 线/箭头只有几磅宽、涂鸦也可能很细，
    /// 不给点容差根本点不中。反向遍历是因为后加入的画在上层。
    func annotation(at pageIndex: Int, point: CGPoint, tolerance: CGFloat = 4) -> PDFAnnotation? {
        guard let page = pdfView?.document?.page(at: pageIndex) else { return nil }
        for annotation in page.annotations.reversed() {
            let kind = AnnotationItem.Kind(subtype: annotation.type)
            guard kind.isSelectableOnPage else { continue }
            if annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return annotation
            }
        }
        return nil
    }

    /// 批量把"内容被裁掉"的文本注释加高到放得下，返回调整了几条。
    ///
    /// **只加高、不放矮，也不改宽度** —— 这是批量操作，可能碰到别的应用创建的批注，
    /// 保守一点只处理确实有问题的；要贴合内容（含收掉多余空白）请用单条的
    /// `fitFreeTextToContent`。
    @discardableResult
    func expandClippedFreeText() -> Int {
        guard isEditable, let document = pdfView?.document else { return 0 }

        // 先**只找出要改的那些、不动手**，这样能把涉及的所有页一起拍进同一步撤销 ——
        // 批量操作在用户眼里是"一次操作"，撤销当然也该一次全回来。
        // （另一条路是边改边 `recordUndo`，那会变成"改了几条就有几步撤销"。）
        var targets: [(annotation: PDFAnnotation, page: PDFPage, pageIndex: Int, rect: CGRect)] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .cropBox)

            for annotation in page.annotations where AnnotationItem.Kind(subtype: annotation.type) == .freeText {
                let text = annotation.contents ?? ""
                guard !text.isEmpty else { continue }

                let needed = FreeTextLayout.requiredHeight(
                    for: text,
                    font: FreeTextLayout.font(of: annotation),
                    width: annotation.bounds.width
                )
                guard needed > annotation.bounds.height + 0.5 else { continue }

                // 顶边固定，向下加高 —— 与文本编辑器里多打几行的直觉一致
                var rect = annotation.bounds
                rect.origin.y = rect.maxY - needed
                rect.size.height = needed

                targets.append((annotation, page, pageIndex,
                                FreeTextLayout.clampToPage(rect, pageBounds: pageBounds)))
            }
        }

        guard !targets.isEmpty else { return 0 }

        recordUndo(pages: targets.map(\.pageIndex), name: "修复被裁切的文本注释")

        var touchedPages = Set<Int>()
        for target in targets {
            target.annotation.bounds = target.rect
            target.annotation.modificationDate = Date()
            touchedPages.insert(target.pageIndex)
        }
        // 同一页改多条只标脏一次
        for pageIndex in touchedPages {
            guard let page = document.page(at: pageIndex) else { continue }
            notifyAnnotationsChanged(on: page)
        }

        pdfView?.needsDisplay = true
        reloadAnnotations()
        return targets.count
    }

    /// 把文本注释的框调整到刚好容纳内容 —— 消除裁切，也去掉单行时多余的空白。
    ///
    /// 只对文本注释有效；高亮/下划线锚定正文，便签/签名是图形，都不适用。
    /// 返回是否真的改动了。
    @discardableResult
    func fitFreeTextToContent(_ item: AnnotationItem) -> Bool {
        guard isEditable,
              item.kind == .freeText,
              let document = pdfView?.document,
              let page = document.page(at: item.pageIndex) else { return false }

        let annotation = item.annotation
        // 字号要从 /DA 或框高反推 —— 存盘重载后 annotation.font 恒为 Helvetica 12
        let font = FreeTextLayout.font(of: annotation)
        guard let fitted = FreeTextLayout.fittedBounds(
            forExisting: annotation.bounds,
            text: item.content,
            font: font,
            maxWidth: FreeTextLayout.maxWidth(of: annotation)
        ) else { return false }

        // 快照在这一步之后拍 —— 前面任何一个 guard 返回 false 都代表"没改"，不该入栈
        recordUndo(pages: [item.pageIndex], name: "框适应内容")
        annotation.bounds = FreeTextLayout.clampToPage(fitted, pageBounds: page.bounds(for: .cropBox))
        annotation.modificationDate = Date()

        notifyAnnotationsChanged(on: page)
        reloadAnnotations()
        return true
    }

    /// 批注改动后请求重绘。
    ///
    /// **现在所有批注都由我们自绘**（见 `AnnotationRenderer` 与 `attach(_:to:)`），
    /// PDFKit 不再画批注，所以刷新只需要让视图重绘 —— `drawPagePost` 会被调用，
    /// 在那里画出最新内容。
    ///
    /// 两件事：
    /// - `annotationsChanged(on:)` 让 PDFKit 丢掉该页的渲染缓存 ——
    ///   主要用于"擦掉 PDFKit 之前画过的那一份"（例如加载文档时把已有批注切到自绘）。
    /// - 递归标脏：页面内容画在内部的 `PDFPageView` 上，而 **`needsDisplay` 不会传导给子视图**，
    ///   只标 PDFView 自己那一层，`PDFPageView` 会继续用旧内容。
    ///
    /// ## 为什么不再需要那些"重手段"
    ///
    /// 历史上这里试过一长串组合（`layoutDocumentView()`、`go(to: 当前页)`、
    /// 甚至重建整个 `document`），前提都是**指望 PDFKit 重画批注**。
    /// 根因有两条：PDFKit 的页面层在鼠标拖拽期间不刷新（实测拖 3 次屏幕纹丝不动、
    /// 松手重建 document 才出现），且它的批注渲染是 1x 栅格化后放大（边缘发虚）。
    ///
    /// 改成自绘后这两个问题一并消失 —— `drawPagePost` 属于 PDFView 自己的层，
    /// 拖拽期间被持续调用（实测拖动时红色像素随拖动增长 251 → 20922 → 38467 → 51410），
    /// 且走原生屏幕分辨率。所以重建 document 那种做法已删除。
    func notifyAnnotationsChanged(on page: PDFPage) {
        guard let pdfView else { return }
        pdfView.annotationsChanged(on: page)
        Self.markNeedsDisplayRecursively(pdfView)
    }

    /// 递归把整条视图链标脏。
    ///
    /// PDFView 的层级不深（约十几个视图），全标一遍的开销可以忽略；
    /// 但漏掉任何一层，那一层就永远画的是旧内容。
    private static func markNeedsDisplayRecursively(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markNeedsDisplayRecursively(subview)
        }
    }

    // MARK: - 目录（outline）编辑（v1.3.23）

    /// 目录树里的一行（给界面用）。
    ///
    /// `PDFOutline` 不是可观察对象，界面得靠这个扁平化快照重建列表；
    /// `id` 用对象标识，所以重建之后选中项还能对得上。
    struct TOCRow: Identifiable, Equatable {
        let id: ObjectIdentifier
        let outline: PDFOutline
        let depth: Int
        let title: String
        let pageIndex: Int
        let hasChildren: Bool

        nonisolated static func == (lhs: TOCRow, rhs: TOCRow) -> Bool {
            lhs.id == rhs.id && lhs.depth == rhs.depth && lhs.title == rhs.title
                && lhs.pageIndex == rhs.pageIndex && lhs.hasChildren == rhs.hasChildren
        }
    }

    @Published private(set) var tocRows: [TOCRow] = []

    /// 目录写进文件失败时的说明（nil = 没问题）。
    /// **不能因为目录写失败就让"保存批注"整个报错** —— 批注是存进去了的，得分开说。
    @Published var outlineWriteNotice: String?

    var hasOutline: Bool { pdfView?.document?.outlineRoot != nil }

    /// 把文档现有目录读成扁平列表（层级 + 标题 + 目标页）
    ///
    /// 用 `measure` 包着：这一步会碰 `document.index(for:)`（每一条都要回查页号），
    /// 41 条目录的文档上实测能到 70~240ms。日志里出现"耗时 · 重载目录列表"就说明是它。
    func reloadTOC() {
        Diagnostics.shared.activity = "重载目录列表"
        guard let document = pdfView?.document else {
            tocRows = []
            return
        }
        let rows: [TOCRow] = Diagnostics.shared.measure("重载目录列表") {
            var rows: [TOCRow] = []
            func walk(_ outline: PDFOutline?, depth: Int) {
                guard let outline else { return }
                for index in 0..<outline.numberOfChildren {
                    guard let child = outline.child(at: index) else { continue }
                    // ⚠️ `index(for:)` 对"不在这份文档里的页"返回 `NSNotFound`
                    // （一个巨大的数），直接当页号用会显示成第 1899999999 页。
                    // 什么情况下会出现：删掉了某一页，而目录条目正好指向它
                    //（目录目标存的是**页对象**，页被删了它就悬空了）。
                    // 这种条目留着不动（用户可能还要改），只是页号退回 0。
                    //（这里不能调实例方法 `indexOf` —— `measure` 的闭包是非隔离的，
                    //  调 @MainActor 方法会报 ActorIsolatedCall，所以就地判一下。）
                    let pageIndex = child.destination?.page.flatMap { page -> Int? in
                        let index = document.index(for: page)
                        return (index >= 0 && index < document.pageCount) ? index : nil
                    } ?? 0
                    rows.append(TOCRow(id: ObjectIdentifier(child),
                                       outline: child,
                                       depth: depth,
                                       title: child.label ?? "",
                                       pageIndex: pageIndex,
                                       hasChildren: child.numberOfChildren > 0))
                    walk(child, depth: depth + 1)
                }
            }
            walk(document.outlineRoot, depth: 0)
            return rows
        }
        tocRows = rows
        // 规模也记一条 —— 用户那份"合集2.3.pdf"上出现过 **2497ms** 的重载目录列表，
        // 光看总耗时看不出是什么量级的文档，得知道"几条目录 / 几页"才能判断
        // 是"条目太多"还是"每条太贵"（v1.3.49）。
        Diagnostics.shared.record("重载目录列表：\(rows.count) 条 / 文档 \(document.pageCount) 页")
    }

    /// 取（必要时创建）可写的目录根。
    ///
    /// ⚠️ 内存里 `outlineRoot` 是**可写**的，但 PDFKit 的 `write` 不会把它写进文件 ——
    /// 落盘靠 `PDFOutlineWriter`（见它的类型注释）。这里只管内存里的编辑。
    private func mutableOutlineRoot() -> PDFOutline? {
        guard let document = pdfView?.document else { return nil }
        if let root = document.outlineRoot { return root }
        let root = PDFOutline()
        document.outlineRoot = root
        return root
    }

    /// 新增一条目录项。
    ///
    /// - Parameters:
    ///   - row: 插在它**后面**（同一层）；nil 表示追加到末尾
    ///   - point: 页面坐标（左下原点）；nil 表示跳转时整页适配
    @discardableResult
    func addTOCEntry(title: String, pageIndex: Int, point: CGPoint?, after row: TOCRow?) -> Bool {
        guard isEditable, let document = pdfView?.document,
              let page = document.page(at: pageIndex),
              let root = mutableOutlineRoot() else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = PDFOutline()
        node.label = trimmed.isEmpty ? "第 \(pageIndex + 1) 页" : trimmed
        node.destination = PDFDestination(page: page,
                                          at: point ?? CGPoint(x: 0, y: page.bounds(for: .cropBox).height))
        if let row, let parent = row.outline.parent {
            parent.insertChild(node, at: min(row.outline.index + 1, parent.numberOfChildren))
        } else {
            root.insertChild(node, at: root.numberOfChildren)
        }
        reloadTOC()
        outlineDidChange()
        return true
    }

    /// 把当前**选中的文字**加成一条目录项：标题取选中文字，目标点是选区左上角
    /// （这样点目录会正好落在那行字上，而不是只到那一页）。
    @discardableResult
    func addTOCEntryFromSelection(after row: TOCRow?) -> Bool {
        guard isEditable, let pdfView,
              let selection = pdfView.currentSelection,
              let page = selection.pages.first,
              let document = pdfView.document else { return false }
        let raw = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let title = raw.split(separator: "\n").first.map(String.init) ?? raw
        let bounds = selection.bounds(for: page)
        let ok = addTOCEntry(title: title,
                             pageIndex: document.index(for: page),
                             point: CGPoint(x: bounds.minX, y: bounds.maxY),
                             after: row)
        if ok { pdfView.setCurrentSelection(nil, animate: false) }
        return ok
    }

    /// 当前有没有可用来建目录项的文字选区（决定按钮是否可点）
    var canAddTOCEntryFromSelection: Bool {
        guard isEditable, let selection = pdfView?.currentSelection else { return false }
        return !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func renameTOCEntry(_ row: TOCRow, to title: String) {
        guard isEditable else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        row.outline.label = trimmed
        reloadTOC()
        outlineDidChange()
    }

    /// 删除（连同它的子项一起）
    func removeTOCEntry(_ row: TOCRow) {
        guard isEditable else { return }
        let children = row.outline.numberOfChildren
        let parent = row.outline.parent
        let siblingsBefore = parent?.numberOfChildren ?? 0
        Diagnostics.shared.record("目录删除：「\(row.title.prefix(12))」子项=\(children)"
                                   + " 父节点原有子项=\(siblingsBefore)")

        row.outline.removeFromParent()
        let remaining = parent?.numberOfChildren ?? 0
        Diagnostics.shared.record("  摘除后父节点子项=\(remaining)"
                                   + "（document.outlineRoot 顶层=\(pdfView?.document?.outlineRoot?.numberOfChildren ?? -1)）")

        // ⚠️⚠️ **这里绝对不能写 `document.outlineRoot = nil`。**
        //
        // 原来那段的本意是"整棵被删空时把根也收掉"。实测（`/tmp/tocdeleteprobe`）：
        // 把 `outlineRoot` 设成 nil 之后，PDFKit **会重新从文件里解析 `/Outlines`** ——
        // 而我们的目录恰恰是被 `PDFOutlineWriter` 注入到**文件**里的，
        // 于是刚删掉的东西**整棵又回来了**。症状正是杰哥报的
        // 「删掉顶层目录，里面的子目录又冒出来、顶层目录删不掉」
        // （他的文件只有一个顶层项，删它就必然把树删空、必然触发这一段）。
        //
        // 空目录不需要在这里做任何事：写盘走 `writeableOutlineItems()`，
        // 它读的是当前内存树、返回空数组 → `PDFOutlineWriter` 不注入 →
        // 而 PDFKit 的 `write` 本来就不写目录（它每次都会丢掉上一次注入的），
        // 所以文件里自然干干净净。
        reloadTOC()
        outlineDidChange()
    }

    /// 把目标改成某一页（点"用当前页更新目标"时用）
    func retargetTOCEntry(_ row: TOCRow, pageIndex: Int) {
        guard isEditable, let document = pdfView?.document,
              let page = document.page(at: pageIndex) else { return }
        row.outline.destination = PDFDestination(page: page,
                                                at: CGPoint(x: 0, y: page.bounds(for: .cropBox).height))
        reloadTOC()
        outlineDidChange()
    }

    /// 降级：成为**前一个兄弟**的最后一个子项（没有前一个兄弟就什么都不做）
    @discardableResult
    func indentTOCEntry(_ row: TOCRow) -> Bool {
        guard isEditable, let parent = row.outline.parent, row.outline.index > 0,
              let previous = parent.child(at: row.outline.index - 1) else { return false }
        let target = previous.numberOfChildren
        row.outline.removeFromParent()
        previous.insertChild(row.outline, at: target)
        reloadTOC()
        outlineDidChange()
        return true
    }

    /// 升级：成为**父项的下一个兄弟**（顶层项没有父项，不能升级）
    @discardableResult
    func outdentTOCEntry(_ row: TOCRow) -> Bool {
        guard isEditable, let parent = row.outline.parent,
              let grandparent = parent.parent else { return false }
        let insertion = parent.index + 1
        row.outline.removeFromParent()
        grandparent.insertChild(row.outline, at: min(insertion, grandparent.numberOfChildren))
        reloadTOC()
        outlineDidChange()
        return true
    }

    /// 能不能降级 / 升级（决定按钮是否可点）
    func canIndent(_ row: TOCRow) -> Bool {
        row.outline.parent != nil && row.outline.index > 0
    }
    func canOutdent(_ row: TOCRow) -> Bool {
        row.outline.parent?.parent != nil
    }

    // MARK: 拖拽移动（v1.3.25）

    /// 拖拽的落点
    enum TOCDropPosition {
        /// 放到目标**之前**（成为同一层的前一项）
        case before
        /// 放到目标**之后**（成为同一层的后一项）
        case after
        /// 放进目标**里面**（成为它的最后一个子项）
        case inside
    }

    /// 把一个目录项移到别处（拖拽用）。
    ///
    /// - Parameters:
    ///   - target: 落点所在的行；`nil` = 追加到顶层末尾
    ///   - position: 落在目标的哪个位置（前 / 后 / 里面）
    /// - Returns: 真的移动了才返回 true
    @discardableResult
    func moveTOCEntry(_ row: TOCRow,
                      relativeTo target: TOCRow?,
                      as position: TOCDropPosition) -> Bool {
        Diagnostics.shared.activity = "移动目录项"
        guard isEditable, row.outline.parent != nil else { return false }

        // ⚠️ 先挡掉两种会**把树弄坏**的落点：
        //   ① 拖到自己身上 ② 拖进自己的子孙里
        // 两种都会让节点成为自己的后代（自成环），之后任何一次遍历都会无限递归 ——
        // 界面上看不出来是什么原因，表现是"整个目录消失 / 界面卡死"。
        // 所以这里宁可什么都不做。
        if let target {
            if target.outline === row.outline { return false }
            if isDescendant(target.outline, of: row.outline) { return false }
        }

        // 先摘下来再插 —— 顺序关键：摘掉之后同级节点的 `index` 会自动重算，
        // 这时取 target 的下标才是"摘掉之后"的正确位置。
        // 反过来（先算下标再摘）会让"往后同级移动"多挪一位。
        row.outline.removeFromParent()

        if let target, let destination = target.outline.parent {
            switch position {
            case .inside:
                target.outline.insertChild(row.outline, at: target.outline.numberOfChildren)
            case .before:
                destination.insertChild(row.outline, at: target.outline.index)
            case .after:
                destination.insertChild(row.outline,
                                        at: min(target.outline.index + 1, destination.numberOfChildren))
            }
        } else {
            // 没有落点行（拖到列表空白处）→ 追加到顶层末尾
            guard let root = mutableOutlineRoot() else { return false }
            root.insertChild(row.outline, at: root.numberOfChildren)
        }

        reloadTOC()
        outlineDidChange()
        return true
    }

    /// `candidate` 是不是 `ancestor` 自己、或它的子孙（拖拽环检测用）
    private func isDescendant(_ candidate: PDFOutline, of ancestor: PDFOutline) -> Bool {
        var node: PDFOutline? = candidate
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// 把内存里的目录树读成"可写进文件"的形式
    func writeableOutlineItems() -> [PDFOutlineWriter.Item] {
        guard let document = pdfView?.document else { return [] }
        return PDFOutlineWriter.items(from: document.outlineRoot, in: document)
    }

    /// 撤销换页之后，把目录里指向"被换掉那几页"的目标重新指到新页对象上。
    ///
    /// `PDFDestination` 存的是 `PDFPage` **对象**引用，而撤销是整页替换 ——
    /// 不重指的话，点目录会跳到一个已经不在文档里的旧页对象（等于跳不动）。
    private func rebindOutlineDestinations(from oldPages: [Int: PDFPage], in document: PDFDocument) {
        guard let root = document.outlineRoot, !oldPages.isEmpty else { return }
        func walk(_ outline: PDFOutline) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                if let destination = child.destination, let target = destination.page {
                    for (pageIndex, old) in oldPages where old === target {
                        if let replacement = document.page(at: pageIndex) {
                            child.destination = PDFDestination(page: replacement, at: destination.point)
                        }
                    }
                }
                walk(child)
            }
        }
        walk(root)
    }

    /// 目录栏按下 Delete 的请求计数（键盘监听 +1，列表 `onChange` 到就删）
    @Published private(set) var tocDeleteRequestTick = 0

    /// 目录栏当前选中的那一条（键盘监听据此决定 Delete 键删什么）。
    /// 和另外两个列表一样**故意不是 `@Published`**（它在视图更新过程中被写入）。
    var tocSelectedID: ObjectIdentifier?

    func requestDeleteOfTOCSelection() {
        tocDeleteRequestTick &+= 1
    }

    /// 跳到某个目录项的目标位置。
    ///
    /// 有精确点位（"从选中文字添加"存的就是选区左上角）就把它滚到视口靠上处 ——
    /// 目录跳转的直觉是**标题出现在顶部附近**，而不是像 `centerOn` 那样摆到正中。
    func goToTOCEntry(_ row: TOCRow) {
        Diagnostics.shared.activity = "点击目录跳转（要滚动页面）"
        guard let pdfView, let document = pdfView.document,
              let page = row.outline.destination?.page else {
            // 点得下去但跳不动 —— 只有这条记录能把它和"事件没到达"区分开
            Diagnostics.shared.record("  目录跳转失败：「\(row.title.prefix(12))」没有可用的目标页")
            return
        }
        // ⚠️ 目标页可能已经被"页面管理"删掉了（目录目标存的是页对象，页没了它就悬空）。
        // 不做这一步的话，`document.index(for:)` 会返回 `NSNotFound`，
        // 后面拿它当页号用会滚到一个荒唐的位置。
        guard indexOf(page, in: document) != nil else {
            Diagnostics.shared.record("  目录跳转失败：「\(row.title.prefix(12))」的目标页已不在文档里")
            return
        }
        Diagnostics.shared.measure("目录跳转（滚动页面）") {
            jump(row, to: page, in: document)
        }
    }

    /// 真正执行跳转（拆出来只为能套 `measure`，逻辑与原来完全一致）
    private func jump(_ row: TOCRow, to page: PDFPage, in document: PDFDocument) {
        let index = document.index(for: page)
        if let point = row.outline.destination?.point,
           point.y.isFinite, point.y > 0, point.y < page.bounds(for: .cropBox).height {
            scrollPointToTop(point, page: page)
            currentPageIndex = index
            // 页码是直接写的，`syncState` 那一支不会进来（它只在"变了"时才刷新）——
            // 这里显式补一次，否则工具栏的书签图标显示的还是上一页的状态
            updateBookmarkStatus()
        } else {
            goToPage(at: index)
        }
    }

    /// 把页面上的一点滚到视口靠上（约 1/4 高）的位置
    private func scrollPointToTop(_ point: CGPoint, page: PDFPage) {
        guard let pdfView, let scrollView = pdfView.internalScrollView else { return }
        let clipView = scrollView.contentView
        let scale = pdfView.scaleFactor
        guard scale > 0, pdfView.bounds.height > 1 else { return }
        let rectInView = pdfView.convert(CGRect(origin: point, size: CGSize(width: 1, height: 1)), from: page)
        // ⚠️ PDFView 不是 flipped：视图坐标 y 向上，"顶部"是 bounds.maxY
        let anchor = CGPoint(x: pdfView.bounds.midX,
                             y: pdfView.bounds.maxY - pdfView.bounds.height * 0.25)
        let origin = AnnotationGeometry.scrollOriginToCenter(
            current: clipView.bounds,
            targetInView: rectInView,
            viewportCenter: anchor,
            scale: scale
        )
        let constrained = clipView.constrainBoundsRect(CGRect(origin: origin, size: clipView.bounds.size))
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - 目录自动保存（v1.3.25）

    /// 自动保存的结果提示（"已自动保存" / 失败原因）；nil = 没有要说的。
    ///
    /// 自动保存是**静默**发生的，但静默不等于不吭声 —— 失败必须让人知道，
    /// 否则用户以为存好了，关掉才发现没有。
    @Published private(set) var autoSaveNotice: String?

    /// 正在等防抖的那次自动保存
    private var autoSaveWorkItem: DispatchWorkItem?
    /// 自动把提示语清掉
    private var autoSaveNoticeWorkItem: DispatchWorkItem?

    /// 目录改动之后调一次：登记"有未保存的改动"，并在**开着自动保存**时排一次写盘。
    ///
    /// ⚠️ 注意顺序：**先标脏，再看自动保存开不开。** 自动保存关掉了不代表"没有改动" ——
    /// 那份改动只是留在内存里等 ⌘S 或关闭时的提示（这正是默认行为）。
    func outlineDidChange() {
        Diagnostics.shared.activity = "目录改动"
        markDirty()
        guard isEditable, AppPreferences.shared.autoSaveOutline else { return }
        scheduleOutlineAutoSaveWrite(after: 0.8)
    }

    /// 排一次自动保存写盘。
    ///
    /// 防抖 0.8 秒：拖动、连续改名、批量升降级会在很短时间里改好几次，
    /// 每次都写盘既慢（整份文档重写一遍）又让磁盘白转。
    private func scheduleOutlineAutoSaveWrite(after delay: TimeInterval) {
        autoSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // 主队列上执行，用 assumeIsolated 告诉编译器"这里确实在 MainActor 上"，
            // 不用 Task（`Task` 要等一次异步跳转，探针那种 RunLoop 环境里跑不到）
            MainActor.assumeIsolated { self?.performOutlineAutoSave() }
        }
        autoSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 立刻把还挂着的自动保存写掉（不等防抖）。
    /// 关标签页 / 关窗口时调 —— 否则"编辑完马上关闭"正好丢掉最后一笔改动。
    func flushOutlineAutoSave() {
        guard autoSaveWorkItem != nil else { return }
        autoSaveWorkItem?.cancel()
        autoSaveWorkItem = nil
        performOutlineAutoSave()
    }

    private func performOutlineAutoSave() {
        autoSaveWorkItem = nil
        guard isEditable, let document = pdfView?.document,
              let fileURL = document.documentURL, fileURL.isFileURL else { return }
        // ⚠️ 鼠标还按着（多半正在拖东西或连续操作）→ 这时候别写盘。
        // 写盘是同步的整份重写，插在用户手头这一下中间就是明显的卡顿 ——
        // 用户实测到的"拖动目录之后会卡几秒才能继续拖"就是它。等松手再写。
        if NSEvent.pressedMouseButtons != 0 {
            scheduleOutlineAutoSaveWrite(after: 1.0)
            return
        }
        do {
            // 自动保存**不做用户可见的备份**：安全性由
            // "写临时文件 + 自检 + 原子替换"保证（见 `writeDocument`），
            // 不必每次编辑都往目录里堆一个副本。
            try writeDocument(document, to: fileURL)
            showAutoSaveNotice("目录已自动保存")
        } catch {
            showAutoSaveNotice("自动保存失败：\(message(of: error))")
        }
    }

    private func showAutoSaveNotice(_ text: String) {
        autoSaveNotice = text
        autoSaveNoticeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.autoSaveNotice = nil }
        }
        autoSaveNoticeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - 撤销 / 重做（v1.3.21）

    /// 一次可撤销的改动：把**改动前**被碰到的那几页整页留一份副本。
    ///
    /// ## 为什么是"整页快照"而不是"记下每条改动的反操作"
    ///
    /// 改批注的路径有十来处（文字选区套高亮、拖拽绘制、便签、文本注释、签名、改样式、
    /// 拖动、删除、框自适应、批量加高…）。手写十来个反操作，**漏一处就是"撤销之后状态不对"**，
    /// 而且以后每加一个改动路径都要记得补一个反操作。
    /// 整页快照对所有这些改动**一视同仁**，新加的路径也自动被覆盖。
    ///
    /// ## 代价（已经实测排除，见 `/tmp/undoprobe`）
    ///
    /// - `PDFPage.copy()` 是**深拷贝**：副本里的批注是独立对象，两边增删互不影响；
    /// - 成本近乎为零 —— 页面内容惰性共享，50 次 copy 耗时 <1ms、常驻内存 +0.0MB；
    /// - `removePage(at:) + insert(_:at:)` 换回之后，页序 / 页数 / 写盘结果都正确；
    /// - PDFView 不受影响：不崩，而且 `clipView.origin` 与"视口中心页"**一点都不跳**
    ///   （实测偏移 0.0）—— 所以撤销时不需要自己记/还滚动位置。
    struct UndoStep {
        /// 动作名，会出现在菜单标题里（如"添加高亮"）
        let name: String

        /// 这一步改动"改动前后"分别长什么样。
        ///
        /// 分两种，因为**整页替换表达不了"页数变了"**（v1.3.42 加页面管理时才补的）：
        /// - `.pages`：页号 → 整页副本，只含这次碰到的页。批注类改动用它，
        ///   页序、页数都不变；
        /// - `.order`：**完整页序**（同一批 `PDFPage` 对象，只是顺序/数量变了）。
        ///   删除页 / 调整页序用它 —— 这里存的是**对象引用不是副本**，
        ///   因为"把页搬回来"必须搬回同一个对象，批注和目录跳转目标才不会断。
        enum Payload {
            case pages([Int: PDFPage])
            case order([PDFPage])
        }

        var before: Payload
        /// 撤销时补上的"撤销前状态"，给重做用。只有撤销过的步骤才有
        var after: Payload?
    }

    /// 撤销栈上限。每步只存"被碰到的那几页"的副本，而副本本身几乎不占内存，
    /// 所以这个上限主要是防止极端情况下的手滑堆积。
    private static let undoDepthLimit = 40

    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []

    /// 拖动开始时的"页快照暂存"。
    ///
    /// 拖动要记的是**拖动前**的状态，而收尾时（`mouseUp`）已经晚了 ——
    /// 所以在按下时就先留一份，抬起来再决定入不入栈：
    /// 只是点一下选中（没移动）不该凭空多出一个撤销步骤。
    private var pendingMoveUndo: (pageIndex: Int, snapshot: PDFPage)?

    var canUndo: Bool { isEditable && !undoStack.isEmpty }
    var canRedo: Bool { isEditable && !redoStack.isEmpty }
    /// 最近一次可撤销动作的名字（没有则为空串）
    var undoActionName: String { undoStack.last?.name ?? "" }
    var redoActionName: String { redoStack.last?.name ?? "" }

    /// 记一步可撤销改动。**必须在真正改动之前调用** —— 它拍的是"改动前"的页面。
    ///
    /// - Parameters:
    ///   - pages: 这次改动会碰到的页号（会自动去重）
    ///   - name: 动作名，如"添加高亮"
    func recordUndo(pages: [Int], name: String) {
        guard isEditable, let document = pdfView?.document else { return }
        // 标脏不在这里做 —— 统一放在 `pushUndo`（连拖动批注那条路一起覆盖）
        var snapshot: [Int: PDFPage] = [:]
        for index in Set(pages) {
            guard index >= 0, index < document.pageCount,
                  let page = document.page(at: index),
                  let copy = page.copy() as? PDFPage else { continue }
            snapshot[index] = copy
        }
        guard !snapshot.isEmpty else { return }
        pushUndo(UndoStep(name: name, before: .pages(snapshot), after: nil))
    }

    /// 把一步改动压进撤销栈。
    ///
    /// ⚠️ **"有未保存改动"就是在这里登记的。** —— 这是所有"改动文档"的必经之路：
    /// `recordUndo`（十来条批注改动路径都经过它）**和拖动收尾**都走这里。
    ///
    /// 早先这句 `markDirty()` 挂在 `recordUndo` 上，而**拖动批注是直接入栈的**
    /// （见 `finishMovingAnnotation`）—— 那条路漏了，症状是"拖完批注关掉不提示保存"。
    /// 挂到这个共同的入栈点之后就不会再漏。
    private func pushUndo(_ step: UndoStep) {
        markDirty()
        undoStack.append(step)
        if undoStack.count > Self.undoDepthLimit {
            undoStack.removeFirst()
        }
        // 有了新改动，原来的"重做"链就断了（和所有编辑器一致）
        redoStack.removeAll()
    }

    /// 拖动开始（在**改动之前**拍页快照，见 `pendingMoveUndo`）
    func beginMoveUndo(pageIndex: Int) {
        pendingMoveUndo = nil
        guard isEditable, let document = pdfView?.document,
              let page = document.page(at: pageIndex),
              let copy = page.copy() as? PDFPage else { return }
        pendingMoveUndo = (pageIndex, copy)
    }

    /// 拖动结束。`committed` 为 true（真的动过）才把暂存的快照入栈。
    ///
    /// - Parameter name: 撤销步骤上显示的名字。拖位置是「移动批注」；
    ///   拖文本注释的边框改宽度是「调整文本宽度」（v1.3.73）。
    func endMoveUndo(committed: Bool, name: String = "移动批注") {
        guard let pending = pendingMoveUndo else { return }
        pendingMoveUndo = nil
        guard committed else { return }
        pushUndo(UndoStep(name: name,
                          before: .pages([pending.pageIndex: pending.snapshot]),
                          after: nil))
    }

    /// 撤销一步。没有可撤销的改动时什么都不做。
    func undo() {
        guard isEditable, let step = undoStack.popLast(), let document = pdfView?.document else { return }
        // 撤销本身也是"改文档"—— 撤销完同样需要保存
        markDirty()
        // 把"现在"的样子留一份给重做
        var entry = step
        entry.after = currentPayload(matching: step.before, in: document)
        redoStack.append(entry)
        apply(step.before)
    }

    /// 重做一步。
    func redo() {
        guard isEditable, let step = redoStack.popLast(), let after = step.after else { return }
        markDirty()
        undoStack.append(step)
        apply(after)
    }

    /// 按"改动前的形状"去现在这份文档里取一份对应的"撤销前快照"（给重做用）。
    ///
    /// 两种 paylaod 的取法不一样，但这一层把它们统一起来，
    /// `undo()` / `redo()` 就不用各自判断了。
    private func currentPayload(matching payload: UndoStep.Payload,
                                in document: PDFDocument) -> UndoStep.Payload {
        switch payload {
        case .pages(let pages):
            var result: [Int: PDFPage] = [:]
            for index in pages.keys {
                guard let page = document.page(at: index),
                      let copy = page.copy() as? PDFPage else { continue }
                result[index] = copy
            }
            return .pages(result)
        case .order:
            // 撤销"页序类"改动之前，把当前的完整页序拍下来（同一批对象引用）
            return .order(allPages(of: document))
        }
    }

    /// 把一步改动落到文档上。
    private func apply(_ payload: UndoStep.Payload) {
        switch payload {
        case .pages(let pages):
            applyPageSnapshots(pages)
        case .order(let order):
            applyPageOrder(order)
        }
    }

    /// 文档当前的完整页序（存的是**对象引用**，不是副本）
    private func allPages(of document: PDFDocument) -> [PDFPage] {
        (0..<document.pageCount).compactMap { document.page(at: $0) }
    }

    /// 这一页在文档里的下标；不在文档里（比如已经被删掉）返回 nil。
    ///
    /// ⚠️ `PDFDocument.index(for:)` 对"不在这份文档里的页"返回 `NSNotFound`
    /// （一个巨大的数），直接拿来当数组下标会炸 —— 必须判。
    private func indexOf(_ page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount else { return nil }
        return index
    }

    /// 换文档 / 关标签时清空历史（两个栈 + 拖动暂存）
    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        pendingMoveUndo = nil
    }

    /// 用整页副本替换当前页 —— 撤销/重做唯一的落地动作。
    ///
    /// ⚠️ 换页会**换掉整页的 `PDFAnnotation` 对象**，所以：
    /// - 先把 `selectedAnnotation` 清掉（它持有的是旧对象，留着就是悬空引用）；
    /// - 换完必须重跑 `applyDisplayPolicyToDocument()`（新页上的批注要重新套"自绘"），
    ///   并 `reloadAnnotations()` 让侧边栏拿到新对象 —— 侧边栏的 id 是
    ///   `ObjectIdentifier(annotation)`，不重解析就会指向已经不在文档里的对象。
    private func applyPageSnapshots(_ pages: [Int: PDFPage]) {
        guard let document = pdfView?.document else { return }
        // 选中态、待删列表都可能指着旧对象，一律清掉
        selectedAnnotation = nil
        // 换页会把页面对象换掉，而目录里的跳转目标存的是**页对象引用** ——
        // 先把被换掉的那几页记下来，换完再把目录目标重新指过去（否则点目录跳不动）
        var replacedPages: [Int: PDFPage] = [:]
        for index in pages.keys where index >= 0 && index < document.pageCount {
            if let page = document.page(at: index) { replacedPages[index] = page }
        }
        for (index, page) in pages.sorted(by: { $0.key < $1.key }) {
            guard index >= 0, index < document.pageCount else { continue }
            // ⚠️ 顺序是**先插新页、再删旧页**，不要反过来（`removePage` 再 `insert`）。
            //
            // `removePage + insert` 中间会有一小段"那一页被摘下来了"的窗口，PDFView
            // 可能正好在这时去画它，日志里就刷
            // "Drawing a PDFPage when its PDFDocument is nil is unsupported."（探针实测到）。
            // 先把新页插进去：新页一落地就是挂着的，旧页被挤到 index+1 也还挂着 ——
            // 中间态里**没有任何一页是游离的**，那个警告就不会出现。
            document.insert(page, at: index)
            document.removePage(at: index + 1)
        }
        applyDisplayPolicyToDocument()
        rebindOutlineDestinations(from: replacedPages, in: document)
        reloadAnnotations()
        pdfView?.needsDisplay = true
    }

    /// 用一份**完整页序**去替换文档的页序 —— 删除页 / 调整顺序的撤销与重做走这里。
    ///
    /// ## 为什么不能复用 `applyPageSnapshots`
    ///
    /// 那个函数是"按下标一对一换页"，**表达不了页数变化**（删页之后索引全错位）。
    /// 页序类改动只能整份重排。
    ///
    /// ## 为什么存的是对象引用而不是 `copy()`
    ///
    /// 页对象的身份必须保持 —— 目录（`PDFOutline` 的 destination）和书签都指着**页对象**。
    /// 换成副本的话，撤回来之后目录就跳不动了。
    private func applyPageOrder(_ target: [PDFPage]) {
        guard let document = pdfView?.document else { return }
        selectedAnnotation = nil

        let keepingPage = document.page(at: min(max(currentPageIndex, 0),
                                                 max(document.pageCount - 1, 0)))
        let targetIDs = Set(target.map(ObjectIdentifier.init))

        // ① 先把"目标里没有的页"删掉。**从后往前**删，下标才不漂。
        for index in stride(from: document.pageCount - 1, through: 0, by: -1) {
            guard let page = document.page(at: index) else { continue }
            if !targetIDs.contains(ObjectIdentifier(page)) {
                document.removePage(at: index)
            }
        }

        // ② 再按目标顺序逐个就位。
        //    走到第 index 步时，0..<index 已经是对的了 —— 所以目标页此刻**必然在
        //    index 或它后面**（不可能在前面），先删后插的下标是稳的。
        //
        // ⚠️ 两种情况要分开，**少了第二种"撤销删除"就永远回不来**（实测过）：
        //   - 目标页还在文档里（顺序不对）→ 先删旧位置、再插新位置。
        //     顺序只能是"先删后插"：`insert` 要求这一页**不在**文档里。
        //   - 目标页**已经不在**文档里了（它正是被删掉的那一页）→ 直接插回去，
        //     这种情况下没有"游离窗口"的问题（它本来就不在文档里）。
        for (index, page) in target.enumerated() {
            let position = min(index, document.pageCount)
            if let current = document.page(at: position), current === page { continue }
            if let from = indexOf(page, in: document) {
                document.removePage(at: from)
            }
            document.insert(page, at: position)
        }

        refreshAfterPageStructureChange(keeping: keepingPage)
    }

    // MARK: - 页面管理（v1.3.42）

    /// 页序 / 页数一变就 +1 —— 用来驱动"缩略图栏"和「页面管理」面板重绘。
    ///
    /// ⚠️ 为什么需要它：`PDFDocument` **不是** `ObservableObject`，它自己的
    /// `pageCount` 变了不会通知任何 SwiftUI 视图。而 `pageCount` 这个 `@Published`
    /// 只反映页数，**顺序变了它不变**，所以两种情况都得有一个统一信号。
    @Published private(set) var pageRevision: Int = 0

    /// 页面管理里的提示（比如"不能把所有页都删掉"）。nil 表示不弹。
    @Published var pageEditNotice: String?

    /// 「页面管理」面板是不是正开着（v1.3.43 改成**覆盖在主窗口上**的浮层）。
    ///
    /// 它同时是"**改页面时先别刷新**"的开关：面板挡着，底下的 PDF 视图、目录栏、
    /// 批注栏用户都看不见，没必要每改一下就重算一遍
    ///（`reloadTOC` 在 41 条目录的文档上实测 70~240ms，改一次就卡一下）。
    /// 重活攒到关面板时一次做完 —— 见 `performDeferredPageRefresh()`。
    @Published var isPageManagerVisible = false

    /// 有攒着的"页面结构收尾"没做（关面板时补）
    private var pendingPageRefresh = false
    /// 面板开着期间攒了几次（只用于日志 —— 用来证明"改的时候真的没刷新"）
    private var deferredRefreshCount = 0
    /// 正看着的那一页在改动中被删了 → 记下"回来后要跳到的页号"
    private var deferredJumpTarget: Int?

    /// 打开页面管理面板
    func beginPageEditing() {
        isPageManagerVisible = true
    }

    /// 关掉页面管理面板 —— 攒着的重活在这里一次做完。
    func endPageEditing() {
        isPageManagerVisible = false
        performDeferredPageRefresh()
    }

    /// 把"改完页序之后的收尾"一次做完。
    ///
    /// 分出来是因为**改的时候可以先不做**（面板盖着，没人看得见），
    /// 关面板再做一次就够了。撤销/重做走的也是同一条路。
    func performDeferredPageRefresh() {
        guard let document = pdfView?.document else { return }
        if pendingPageRefresh {
            Diagnostics.shared.record("页面结构：统一刷新一次（页面管理期间攒了 \(deferredRefreshCount) 次）")
            deferredRefreshCount = 0
        }
        if let target = deferredJumpTarget {
            // 正看着的那页被删了 → 现在才真的跳过去（改的时候跳会让滚动位置乱跳）
            if let page = document.page(at: target) { pdfView?.go(to: page) }
            deferredJumpTarget = nil
        }
        reloadTOC()
        reloadAnnotations()
        applyDisplayPolicyToDocument()
        updateBookmarkStatus()
        pdfView?.needsDisplay = true
        pendingPageRefresh = false
    }

    /// 这一页**现在**在文档里的下标；已经不在文档里（被删了）返回 nil。
    ///
    /// ⚠️ 「页面管理」里的点击 / 拖拽一律**按页对象**定位，不要按下标 ——
    /// 下标会随重排变，而 SwiftUI 复用视图时那个下标可能已经是旧的
    ///（表现就是"点这一页却选中了别的页"）。页对象是不变的锚。
    func pageIndex(of page: PDFPage) -> Int? {
        guard let document = pdfView?.document else { return nil }
        return indexOf(page, in: document)
    }

    /// 删除若干页（页码按**当前**顺序给；连带页面上的批注一起消失）。
    ///
    /// - Returns: 真的删掉了才返回 true
    @discardableResult
    func deletePages(_ indices: Set<Int>) -> Bool {
        guard isEditable, let document = pdfView?.document else { return false }
        let valid = indices.filter { $0 >= 0 && $0 < document.pageCount }
        guard !valid.isEmpty else { return false }
        guard document.pageCount > valid.count else {
            pageEditNotice = "不能把所有页面都删掉 —— 至少留一页。"
            return false
        }

        // 撤销要的是"改动前的完整页序"（对象引用，见 `UndoStep.Payload.order`）
        let before = allPages(of: document)
        let keepingPage = document.page(at: min(max(currentPageIndex, 0), document.pageCount - 1))
        let bookmarkMap = bookmarkPageMap(document)

        // 从后往前删，下标不漂
        for index in valid.sorted(by: >) {
            document.removePage(at: index)
        }
        pushUndo(UndoStep(name: "删除页面", before: .order(before), after: nil))
        refreshAfterPageStructureChange(keeping: keepingPage, bookmarkMap: bookmarkMap)
        Diagnostics.shared.record("页面管理：删除 \(valid.count) 页 → 现在共 \(document.pageCount) 页")
        return true
    }

    /// 把选中的页**整块**移到 `destination`（插入位置，0...pageCount）。
    ///
    /// `destination` 按"移走**之前**"的下标给 —— 内部会折算成移走之后的下标。
    /// 例如把第 1 页拖到最后（8 页文档）：`destination = 8` → 结果它变成第 8 页。
    @discardableResult
    func movePages(_ indices: Set<Int>, to destination: Int) -> Bool {
        guard isEditable, let document = pdfView?.document else { return false }
        let sorted = indices.filter { $0 >= 0 && $0 < document.pageCount }.sorted()
        guard !sorted.isEmpty else { return false }
        let destination = min(max(destination, 0), document.pageCount)

        // 落点就在选中块自己身上 → 什么都不会变，别白记一步撤销
        if let first = sorted.first, let last = sorted.last,
           destination >= first, destination <= last + 1 { return false }

        let before = allPages(of: document)
        let keepingPage = document.page(at: min(max(currentPageIndex, 0), document.pageCount - 1))
        let moved = sorted.compactMap { document.page(at: $0) }
        guard moved.count == sorted.count else { return false }

        for index in sorted.reversed() { document.removePage(at: index) }
        // 移走之后，原来落在 destination 前面的那些也不在了 → 插入位置要往前挪
        let shift = sorted.filter { $0 < destination }.count
        let insertAt = min(max(destination - shift, 0), document.pageCount)
        for (offset, page) in moved.enumerated() {
            document.insert(page, at: insertAt + offset)
        }
        pushUndo(UndoStep(name: "调整页面顺序", before: .order(before), after: nil))
        refreshAfterPageStructureChange(keeping: keepingPage)
        Diagnostics.shared.record("页面管理：把 \(moved.count) 页移到 \(insertAt)")
        return true
    }

    /// 插入若干**空白页**（v1.3.44）。
    ///
    /// 插入点取 `anchorIndices` 里**最靠后**那一页的后面：
    /// 传 `[3]` = 插到第 4 页之前；传空集合 = 插到文档末尾；
    /// 传 `[-1]` = 插到文档**最前面**（-1 是"第 1 页之前"这个虚拟位置）。
    /// 尺寸跟随插入点**前面**那一页（见 `makeBlankPage(like:)`）。
    ///
    /// 走的是和删除 / 排序同一条撤销链（`.order` payload）—— 所以撤销插入 = 把新页摘掉，
    /// `applyPageOrder` 里"删掉目标页序之外的页"那一段正好干这件事。
    ///
    /// - Returns: 新页在文档里的下标范围（供界面选中它们）；没插成功返回 nil。
    @discardableResult
    func insertBlankPages(after anchorIndices: Set<Int>, count: Int) -> Range<Int>? {
        guard let document = pdfView?.document else { return nil }
        guard isEditable else {
            pageEditNotice = "当前是「只读」模式 —— 想插空白页先切到编辑模式。"
            return nil
        }
        guard count > 0 else { return nil }
        guard document.pageCount > 0 else {
            pageEditNotice = "文档里一页都没有，插不了空白页。"
            return nil
        }

        // -1 是"第 1 页之前"这个虚拟位置，所以下界是 -1 而不是 0
        let valid = anchorIndices.filter { $0 >= -1 && $0 < document.pageCount }
        let position = valid.max().map { $0 + 1 } ?? document.pageCount

        let before = allPages(of: document)
        let keepingPage = document.page(at: min(max(currentPageIndex, 0), document.pageCount - 1))
        // 尺寸参考：插入点前面那一页（在第一页之前插时就用第一页）
        let reference = document.page(at: min(max(position - 1, 0), document.pageCount - 1))

        // 上限只是防手滑一次插几千页，正常用不到
        let total = min(count, 200)
        let inserted = (0..<total).map { _ in makeBlankPage(like: reference) }
        for (offset, page) in inserted.enumerated() {
            document.insert(page, at: position + offset)
        }

        pushUndo(UndoStep(name: "插入空白页", before: .order(before), after: nil))
        refreshAfterPageStructureChange(keeping: keepingPage)
        let size = inserted[0].bounds(for: .mediaBox).size
        Diagnostics.shared.record("页面管理：在 \(position) 处插入 \(inserted.count) 页空白页"
                                  + "（\(Int(size.width))×\(Int(size.height))）")
        return position..<(position + inserted.count)
    }

    /// 造一张空白页，尺寸跟随 `reference`。
    ///
    /// ⚠️ **`PDFPage()` 新建出来是没有页面尺寸的**（`bounds(for:)` 是空矩形），
    /// 必须自己设一个 `mediaBox` —— 否则它在文档里是 0×0：缩略图渲染不出来，
    /// 存进文件之后在别的阅读器里也显示不正常。
    ///
    /// 尺寸跟随相邻页而不是写死 A4：扫描件、异形开本插进去一张 A4 会很突兀。
    private func makeBlankPage(like reference: PDFPage?) -> PDFPage {
        let raw = reference?.bounds(for: .mediaBox).size ?? .zero
        let size = (raw.width > 1 && raw.height > 1) ? raw : CGSize(width: 595, height: 842)
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        page.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
        return page
    }

    /// 页序 / 页数变了之后的统一收尾。
    ///
    /// `bookmarkMap` 是"改动前，书签指向的是哪一页对象"—— 有了它才能把书签
    /// 跟着页走（页号会变），指向**已被删掉**那些页的书签则一并去掉。
    private func refreshAfterPageStructureChange(keeping page: PDFPage?,
                                                 bookmarkMap: [UUID: PDFPage] = [:]) {
        guard let document = pdfView?.document else { return }
        pageCount = document.pageCount

        if let page, let index = indexOf(page, in: document) {
            currentPageIndex = index
            deferredJumpTarget = nil
        } else {
            // 正看着的那页被删了 → 落到新位置上的那一页。
            // ⚠️ 这里**先不跳**：等面板关掉再跳（见 `performDeferredPageRefresh`），
            //    改一次就跳一次会让滚动位置一直乱动。
            let clamped = min(max(currentPageIndex, 0), max(document.pageCount - 1, 0))
            currentPageIndex = clamped
            deferredJumpTarget = clamped
        }

        remapBookmarks(bookmarkMap, in: document)

        // 页对象没换，但页号变了 —— 目录条目 / 批注列表里缓存的页号要重算。
        // **面板开着就先不重算**：那些面板都被盖住了，看不见；而 `reloadTOC`
        // 在目录长的文档上要 70~240ms，改一下卡一下。
        pageRevision &+= 1
        if isPageManagerVisible {
            pendingPageRefresh = true
            deferredRefreshCount += 1
            return
        }
        performDeferredPageRefresh()
    }

    /// 改页序**之前**，把"书签 → 它指着的那一页对象"记下来
    private func bookmarkPageMap(_ document: PDFDocument) -> [UUID: PDFPage] {
        guard let url = document.documentURL else { return [:] }
        var map: [UUID: PDFPage] = [:]
        for bookmark in BookmarksStore.shared.bookmarks(for: url) {
            if let page = document.page(at: bookmark.pageIndex) { map[bookmark.id] = page }
        }
        return map
    }

    /// 改完页序之后，把书签重新指到"同一页内容"的新页号上。
    ///
    /// 不这么做的话，删掉第 2 页之后，原本指向第 5 页的书签就会跑到第 5 页
    /// （现在是原来第 6 页的内容）—— 静悄悄指错，比丢掉更糟。
    private func remapBookmarks(_ map: [UUID: PDFPage], in document: PDFDocument) {
        guard let url = document.documentURL, !map.isEmpty else { return }
        var updates: [UUID: Int] = [:]
        for (id, page) in map {
            if let index = indexOf(page, in: document) { updates[id] = index }
        }
        BookmarksStore.shared.reassignPages(documentURL: url, updates: updates)
    }

    // MARK: - 写入 PDF（手动保存与目录自动保存共用，v1.3.25 重构）

    /// "有没有没保存的改动"的标记。
    ///
    /// ⚠️ **它故意不是 `PDFViewModel` 上的 `@Published`。**
    ///
    /// 观察 `PDFViewModel` 的视图有一大票（PDF 视图、缩略图栏、批注栏、工具条、
    /// 标签栏、调色板…）。把这个标记做成 `PDFViewModel` 的 `@Published`，
    /// 那么**每次置位/清位都会让这一整票视图重算 body** —— 用户实测到的
    /// "改一下目录就顿一下 / 拖完卡几秒"里就有它一份。
    ///
    /// 拆成独立小对象之后，订阅面收窄到只有真正要显示它的两处：
    /// 标签页标题旁的小圆点、目录面板底部那句提示。
    let unsavedChanges = UnsavedChangesFlag()

    /// 有没有没保存的改动。
    ///
    /// **读它不会建立订阅**（这是个普通计算属性）。要在界面上跟着变，
    /// 请观察 `unsavedChanges` 那个对象。
    var hasUnsavedChanges: Bool { unsavedChanges.value }

    private func markDirty() {
        // 排查用（v1.3.57）：用户报"我什么都没改，关窗口却一直问要不要保存"
        //（实测日志：打开文件 → 只滚了一下 → 6 秒后关窗口，`未保存=true`）。
        // 光看 `未保存=true` 看不出是**哪一步**标的脏 —— 把"哪份文档、当时能不能编辑"
        // 和调用栈前几帧一起记下来，一眼就能看到是谁点的火。
        Diagnostics.shared.record("标脏 ← \(currentDocument?.documentURL?.lastPathComponent ?? "（无 URL）")"
                                  + " · 可编辑=\(isEditable) ← "
                                  + Thread.callStackSymbols.dropFirst().prefix(5)
            .map { frame -> String in
                let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count > 3 ? parts[3...].joined(separator: " ") : frame
            }
            .joined(separator: " ← "))
        unsavedChanges.mark()
    }

    // MARK: - 关闭前确认（v1.3.28）

    /// 关闭窗口 / 退出之前**需不需要问一句**。
    ///
    /// 判据就两条：有未保存的改动、而且用户开着「关闭时提醒」。
    /// 关窗口那条路要先拿它判断"这次到底要不要拦" —— 要拦的话
    /// `windowShouldClose` 得**先回 false**（见 `WindowCloseGuard`）。
    var needsCloseConfirmation: Bool {
        hasUnsavedChanges && AppPreferences.shared.promptToSaveOnClose
    }

    /// 关闭文档 / 退出之前的确认：有未保存改动就问一句。**异步**（v1.3.56）。
    ///
    /// - Parameters:
    ///   - window: 弹框挂在哪个窗口上当 sheet（见 `AlertPresenter`）。
    ///   - completion: `true` = 可以关（已保存好，或用户明说"不保存"）；
    ///     `false` = 用户取消，或者保存失败 —— 两种情况都不该继续关。
    ///
    /// ## 为什么从"同步返回 Bool"改成"异步回调"（v1.3.56，用户实测的卡死）
    ///
    /// 上一版为了满足 `windowShouldClose(_:) -> Bool` 的同步要求，写成
    /// "`beginSheet` 拿外观 + `NSApp.runModal(for:)` 拿同步"。杰哥实测的结果是：
    /// **点完「不保存」，窗口关不掉、app 卡住不动** ——
    /// 在 AppKit 正处理"关闭"的路上又开一个 modal session，两套状态机互相等。
    ///
    /// 现在把"等"这件事交回给 AppKit：`windowShouldClose` 先回 `false`、
    /// `applicationShouldTerminate` 先回 `.terminateLater`，问完再继续。
    /// 这个函数只负责"把框弹出去、把答复回调回来"。
    ///
    /// ## v1.3.32：用户的答复会把"有未保存改动"清掉
    ///
    /// 点红叉关窗口时，这条链路会被走**两遍**：
    /// ① `windowShouldClose`（窗口还没关，主路径）→ ② 窗口关掉之后的
    /// `applicationShouldTerminate`。如果答复不清标记，用户就会**连着看到两个弹框**
    /// （实测日志里点「取消」还会变成连弹三遍，因为取消又触发一次 terminate）。
    ///
    /// 所以「保存」和「不保存」两个答复都要 `unsavedChanges.clear()`：
    /// 前者改动已经落盘，后者用户明确决定丢弃 —— 两种情况下"还有没有没保存的东西"
    /// 的答案都是"没有"，第二遍自然不再问。只有「取消」不清（文档原样留着）。
    func confirmClose(in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let diag = Diagnostics.shared
        // 把判定过程记下来：用户报"关闭不提示"时，这一行就能区分
        // "根本没被调用" / "没有未保存的改动" / "偏好把提醒关了" / "弹窗被取消了"
        guard hasUnsavedChanges else {
            diag.record("    confirmClose：没有未保存的改动 → 直接放行")
            completion(true)
            return
        }
        guard AppPreferences.shared.promptToSaveOnClose else {
            diag.record("    confirmClose：有改动，但「关闭时提醒」是关的 → 直接放行")
            completion(true)
            return
        }
        diag.record("    confirmClose：准备弹窗（有未保存的改动）")

        // 把**文件名**写进提示（v1.3.55）。多窗口下用户可能同时开着好几份，
        // "这份 PDF"到底是哪一份说不清 —— 名字带上就一目了然。
        // 用**带扩展名**的完整文件名（窗口标题/标签栏上那个是去掉后缀的短名，
        // 但"要写回哪个文件"这件事说全名更明确）。
        // 图片文档要显示**原图**那个名字 —— 它没有 `documentURL`
        //（见 `ImageDocument` 的底线 1），名字只能从 `sourceURL` 取。
        let fileName = sourceKind == .image
            ? sourceFileName
            : currentDocument?.documentURL?.lastPathComponent
        diag.record("    confirmClose：弹框挂到窗口上 = \(window.map { "「\($0.title)」" } ?? "无（退回独立弹窗）")")

        let alert = NSAlert()
        // ⚠️ 文件名放**正文**而不是标题（v1.3.55 实测）：这版 macOS 的 alert 是一张窄卡片
        //（260pt 宽），标题只排一行 —— 塞进文件名就会截断成
        //「要保存对「unsaved-test.」。正文会自动换行、多长都显示得下。
        //
        // 图片的文案把「保存」说成「导出」（v1.3.66）：它的改动只能落成**一张新图片**，
        // 原图我们一根手指都不碰。说"保存"会让人以为要写回那张 jpg。
        if sourceKind == .image {
            alert.messageText = "要导出对这张图片的改动吗？"
            alert.informativeText = (fileName.map { "「\($0)」" } ?? "这张图片")
                + "上的批注还没导出成图片。不导出的话，这些改动会丢掉"
                + "（原图不会被改动）。"
        } else {
            alert.messageText = "要保存对这份 PDF 的改动吗？"
            alert.informativeText = (fileName.map { "「\($0)」的目录" } ?? "目录")
                + "或批注有改动还没写进文件。不保存的话，这些改动会丢掉"
                + "（原文件本身不会被动过）。"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: sourceKind == .image ? "导出为图片…" : "保存")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "不保存")        // .alertSecondButtonReturn
        alert.addButton(withTitle: "取消")          // 其余

        AlertPresenter.present(alert, on: window) { [weak self] response in
            guard let self else {
                completion(false)
                return
            }
            let diag = Diagnostics.shared
            switch response {
            case .alertFirstButtonReturn:
                if self.sourceKind == .image {
                    // ── 图片：走「导出为图片…」（v1.3.66）──
                    diag.record("    confirmClose：用户选「导出为图片」")
                    do {
                        // ⚠️ 保存面板被取消 → 等于"还没决定"，**不能**当成放行：
                        // 放行就是替用户选了"丢弃"，刚画的批注当场没了。
                        guard try self.exportImage() != nil else {
                            diag.record("    confirmClose：导出面板被取消 → 窗口不关")
                            completion(false)
                            return
                        }
                        // 图已经导出走了 —— 清掉脏标记，免得紧接着的
                        // `applicationShouldTerminate`（窗口关掉之后那一发）再问一遍
                        self.unsavedChanges.clear()
                        completion(true)
                    } catch {
                        diag.record("    confirmClose：导出失败 → \(error.localizedDescription)")
                        let failure = NSAlert()
                        failure.messageText = "导出失败，窗口没有关闭"
                        failure.informativeText = self.message(of: error)
                        failure.alertStyle = .critical
                        AlertPresenter.present(failure, on: window) { _ in completion(false) }
                    }
                } else {
                    diag.record("    confirmClose：用户选「保存」")
                    do {
                        try self.saveAnnotationsToDisk()
                        completion(true)
                    } catch {
                        diag.record("    confirmClose：保存失败 → \(error.localizedDescription)")
                        // 存不下去就别关了 —— 否则用户以为"已经保存好"，实际上改动没了
                        let failure = NSAlert()
                        failure.messageText = "保存失败，文档没有关闭"
                        failure.informativeText = self.message(of: error)
                        failure.alertStyle = .critical
                        AlertPresenter.present(failure, on: window) { _ in completion(false) }
                    }
                }
            case .alertSecondButtonReturn:
                // 用户明确决定丢弃这次改动 → 清掉脏标记。
                // 不清的话，紧接着的 `applicationShouldTerminate`（窗口关掉之后那一发）
                // 会**再弹一次**同样的框 —— 用户会以为"这个框关不掉"。
                self.unsavedChanges.clear()
                diag.record("    confirmClose：用户选「不保存」（脏标记已清，不会再问第二遍）")
                completion(true)
            default:
                diag.record("    confirmClose：用户选「取消」（rawValue=\(response.rawValue)）")
                completion(false)
            }
        }
    }

    /// 把批注（和目录）写回 PDF 文件。写入前**按偏好**决定是否备份，返回备份路径与实际落点。
    ///
    /// 默认落点：优先**原文件旁边**（用户一眼看得见），沙箱里那个目录写不进去时
    /// 才回退到应用数据目录 —— 落点靠返回值里的 `location` 如实告诉界面。
    /// 用户在设置里选了自定义目录、或把备份关掉了，就按偏好来（见 `makeBackup(of:)`）。
    @discardableResult
    func saveAnnotationsToDisk() throws -> DocumentBackup.Result? {
        // 图片文档**没有**可写回的 PDF —— 它的出口只有「导出为图片」（v1.3.66）。
        //
        // 底下那道 `guard let fileURL = document.documentURL` 本来就拦得住
        //（图片文档的 documentURL 是 nil），但报错会误导成"文档没有本地文件"。
        // 这里先拦住，说清楚该走哪条路。
        guard sourceKind == .pdf else { throw AnnotationSaveError.imageDocument }
        // 只读模式下不允许写回文件 —— 这是最"重"的编辑操作
        guard isEditable else { throw AnnotationSaveError.readOnly }
        // ⚠️ 用 `currentDocument` 而不是 `pdfView?.document`：
        // 关闭文档时视图树已经销毁（`pdfView` 是 weak，此刻已是 nil），
        // 但用户可能刚在关闭确认框里选了「保存」—— 那时只有 `boundDocument` 还留着文档。
        guard let document = currentDocument else {
            throw AnnotationSaveError.noDocument
        }
        guard let fileURL = document.documentURL, fileURL.isFileURL else {
            throw AnnotationSaveError.noFileURL
        }

        let backup = try makeBackup(of: fileURL)
        // 把"这一次写盘花了多久"记下来（阈值 150ms）。
        // 它是主线程上的同步整份重写，是"点一下要等几秒"最可能的来源之一 ——
        // 之前只能从慢轮次里猜（activity 标签还会误导），现在有确切数字。
        try Diagnostics.shared.measure("保存写盘（整份重写 + 注入目录 + 自检 + 原子替换）",
                                       threshold: 150) {
            try writeDocument(document, to: fileURL)
        }
        return backup
    }

    // MARK: - 图片文档的出口：导出为图片（v1.3.66）

    /// 图片文档的「保存」：把页面（**含批注**）渲染成一张**新图片**写出去。
    ///
    /// ⚠️ 全程**不碰原图** —— 落点由用户在保存面板里自己挑，名字默认带 `-导出`。
    /// 图片那份 `PDFDocument` 的 `documentURL` 是 `nil`，物理上就写不回 `.jpg`
    ///（见 `ImageDocument` 的底线 1）。
    ///
    /// - Returns: 写出的文件地址；**用户取消返回 `nil`**（调用方要区分"取消"和"失败"，
    ///   取消不该被当成"改动已处理"）。
    @discardableResult
    func exportImage() throws -> URL? {
        guard let document = currentDocument, document.pageCount > 0 else {
            throw AnnotationSaveError.noDocument
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // 默认名：原图名 + 「-导出」，一眼看得出是新东西、不是原图
        let stem = sourceURL?.deletingPathExtension().lastPathComponent ?? "导出"
        panel.nameFieldStringValue = "\(stem)-导出.png"
        guard panel.runModal() == .OK, let target = panel.url else { return nil }

        try exportImage(to: target)
        return target
    }

    /// 导出到**指定位置**，不弹面板。
    ///
    /// 单独拆出来是为了能自动化验证（`PDFREADER_AUTOTEST_EXPORT_IMAGE`）——
    /// 保存面板在脚本里没法点。顺带以后要做"导出到上次的位置"也是走它。
    func exportImage(to target: URL) throws {
        guard let document = currentDocument, document.pageCount > 0 else {
            throw AnnotationSaveError.noDocument
        }
        try render(page: exportPage(from: document), to: target)
        Diagnostics.shared.record("导出图片：「\(target.lastPathComponent)」（\(target.path)）")
    }

    /// 导出时该画哪一页。
    ///
    /// ⚠️ **图片文档不能直接拿屏幕上那一页去导**。它的页面内容里烘焙着一层
    /// **显示用的底色**（见 `ImageDocument.makePage` —— 那是为了盖住 PDFKit
    /// 擦的那层白，透明区域才看得出来）。那层是给**屏幕**看的：
    /// 直接导出就成了"我明明是张透明 PNG，导出来怎么带底色了"。
    ///
    /// 所以这里重新生成一页**不铺底色**的，再把批注搬过去 —— 透明还是透明。
    /// PDF 文档原样返回（它的页面本来就没掺这些东西）。
    private func exportPage(from document: PDFDocument) -> PDFPage? {
        let live = document.page(at: 0)
        guard isImageDocument, let sourceURL,
              let clean = ImageDocument.makePage(from: sourceURL, background: nil) else { return live }
        // 批注挂在**页**上，跟页面内容没关系 —— 换页就得搬（和 `rebuildImagePage` 一个道理）
        for annotation in live?.annotations ?? [] {
            guard let copy = annotation.copy() as? PDFAnnotation else { continue }
            clean.addAnnotation(copy)
        }
        return clean
    }

    /// 「保存」这个动作的**唯一入口** —— 按文档类型自动选路（v1.3.66）。
    ///
    /// - PDF → 写回原文件（`saveAnnotationsToDisk`）
    /// - 图片 → 弹「导出为图片…」（`exportImage`），**绝不碰原图**
    ///
    /// 之所以要包这一层：调用点有四五处（⌘S、批注侧栏的按钮、关闭确认框、自动化钩子），
    /// 每处都写 `if sourceKind == .image` 早晚会漏一处 —— 而漏掉的那处对图片来说
    /// 就是"保存失败"，用户会以为功能坏了（更糟的情况是靠 `documentURL` 写回，
    /// 那也是 nil，写不进去，仍然是失败）。集中在这里，加出口或改行为只动一个地方。
    ///
    /// - Returns: 图片导出时返回写出的地址；**用户取消返回 nil**。PDF 恒返回 nil。
    @discardableResult
    func performSave() throws -> URL? {
        guard sourceKind == .image else {
            try saveAnnotationsToDisk()
            return nil
        }
        return try exportImage()
    }

    /// 把一页（含批注）画进一张位图并写盘。
    ///
    /// 输出分辨率**跟着原图走** —— 一张 4000px 的照片加了批注再导出，
    /// 不该缩成 595px 的一页 A4 那样糊掉。
    private func render(page: PDFPage?, to url: URL) throws {
        guard let page else { throw AnnotationSaveError.exportFailed("这一页读不出来") }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw AnnotationSaveError.exportFailed("这一页的尺寸是空的")
        }

        let scale: CGFloat
        if let sourceURL, let pixels = ImageDocument.pixelSize(of: sourceURL) {
            scale = pixels.width / bounds.width
        } else {
            scale = 2      // 拿不到原图分辨率（理论上不会）→ 按 2 倍保守导出
        }
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))

        // PNG 还是 JPEG，决定了**要不要留透明**（v1.3.68）：
        //   · JPEG 不支持透明 —— 不铺白底的话透明区域会变成**黑**（底是 0,0,0,0）；
        //   · PNG 支持 —— 铺了白底等于把透明"焊死"成白，用户拿透明 PNG 导出回来就不透明了。
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())

        // ⚠️ 直接用 `CGContext`，不走 `NSBitmapImageRep` + `NSGraphicsContext`：
        // 后者的 CTM 里夹着 AppKit 自己的一层缩放，`scaleBy` 究竟乘在哪一层得靠试；
        // 直接建位图 context，坐标就是**像素**，心里有数。
        guard let context = CGContext(data: nil,
                                      width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: isJPEG
                                          ? CGImageAlphaInfo.noneSkipLast.rawValue
                                          : CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnnotationSaveError.exportFailed("开不出绘图上下文")
        }
        if isJPEG {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        context.scaleBy(x: scale, y: scale)
        // 整页画进去：页面内容 + **标准批注**（PDFKit 自己会画）
        page.draw(with: .cropBox, to: context)
        // ⚠️ **但自绘那批 PDFKit 一点都不会画** —— 它们的 `shouldDisplay` 被置成了
        // `false`（见 `AnnotationRenderer` 的架构说明），屏幕上是靠
        // `PDFView.drawPagePost` 补画的。导出这条路上没有 `drawPagePost`，
        // 所以必须在这儿自己补一遍 —— 漏了的话**用户画的批注一条都不会出现
        // 在导出文件里**（这正是"导出图片编辑的东西没了"的根因）。
        //
        // 用我们自己的渲染器还有一个好处：它的输出比 PDFKit 的批注层清晰
        //（PDFKit 那层 contentsScale 是 1.0，放大就发虚）。
        for annotation in page.annotations where AnnotationRenderer.isSelfRendered(annotation) {
            AnnotationRenderer.draw(annotation, in: context)
        }

        guard let image = context.makeImage() else {
            throw AnnotationSaveError.exportFailed("渲染不出位图")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: isJPEG ? .jpeg : .png,
                                               properties: isJPEG ? [.compressionFactor: 0.92] : [:]) else {
            throw AnnotationSaveError.exportFailed("编码失败")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AnnotationSaveError.exportFailed(error.localizedDescription)
        }
    }

    /// 按偏好做备份；备份被关掉时返回 nil（表示"这次没有备份"）。
    private func makeBackup(of fileURL: URL) throws -> DocumentBackup.Result? {
        let preferences = AppPreferences.shared
        guard preferences.backupEnabled else { return nil }
        guard let directory = preferences.backupDirectory else {
            return try DocumentBackup.backup(fileURL)
        }
        // 沙箱下访问用户选过的目录，必须成对 start / stop，否则访问不到
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        do {
            return try DocumentBackup.backup(fileURL, customDirectory: directory)
        } catch {
            // 指定的目录写不进去（被删、权限变了、外置盘没插）→
            // 如实说一声再退回默认落点，**不能让保存整个失败**
            preferences.backupDirectoryNotice = "指定的备份目录这次写不进去，已改存到默认位置。"
            return try DocumentBackup.backup(fileURL)
        }
    }

    /// 把文档写进 `fileURL`，并把目录注入进去。
    ///
    /// ## 为什么绕一圈写临时文件
    ///
    /// `PDFDocument.write(to:)` 是**直接覆盖**原文件的：一旦中途失败（磁盘满、
    /// 进程被杀、写到一半出错），原文件已经被截断，用户的东西就没了。
    ///
    /// 所以改成：先写**同目录下的隐藏临时文件** → 自检（能重新打开、页数对得上、
    /// 目录读得回）→ `replaceItemAt` **原子替换**。中间任何一步失败都**不碰原文件**。
    ///
    /// 有了这层保证，自动保存就可以不生成任何备份文件 ——
    /// 用户明确说过不要每次编辑都堆一份备份（见 `AppPreferences.backupEnabled` 的说明）。
    /// 实测（探针 21/21）：替换之后原 `PDFDocument` 实例仍完全正常，能继续编辑、再写盘。
    private func writeDocument(_ document: PDFDocument, to fileURL: URL) throws {
        // 写盘前把 ink 的 `/Rect` 校正到"包住墨迹"。
        //
        // ink 的墨迹在文件里是**绝对坐标**，改 `bounds` 不会带着它走 ——
        // 两者一旦脱节，别的阅读器就按 `/Rect` 把露在外面的墨迹裁掉
        // （用户的原话：「有一个涂鸦被裁切了一部分」）。
        // 打开时已经校正过一次，这里是最后一道保险：任何遗漏的操作路径都不会写坏文件。
        AnnotationRenderer.reconcileInkBounds(in: document)

        // ⚠️ 自绘的批注在内存里是 `shouldDisplay = false`（免得 PDFKit 再画一份），
        // 而这个标志**会被持久化到 PDF 的注释标志位里** ——
        // 实测：设 false 写盘后重新打开，`shouldDisplay` 仍是 false。
        // 不恢复的话，别的阅读器打开这份文件会**看不到我们的批注**。
        let restored = restoreDisplayFlags(in: document)
        defer {
            // 写完立刻回到自绘状态，屏幕上不要闪一下 PDFKit 的模糊版本
            for annotation in restored { annotation.shouldDisplay = false }
            pdfView?.needsDisplay = true
        }

        // ── 目录：PDFKit 不写，得自己注入 ──
        //
        // 顺序很重要：**必须在 `write` 之后**，因为注入器依赖
        // "文件是 PDFKit 刚写出来的"（那时结构最规矩：经典明文 xref、没有对象流）。
        // 而且 PDFKit 每次写盘都会把我们上次注入的目录丢掉，
        // 所以**每次保存都要重新注入一遍**（内存里的 `outlineRoot` 才是准的）。
        //
        // 注入失败**不算保存失败** —— 批注确实已经写进去了，
        // 只是目录没跟上，用 `outlineWriteNotice` 如实告诉界面。
        // ⚠️ 先把"目标页已经不在文档里"的目录条目钳到有效范围（页面管理删页之后就有）。
        //    不处理的话写入器会**整套目录都写不进去**。内存里的目录不动 ——
        //    用户还能在目录面板里改它、或者 ⌘Z 把页找回来。
        let resolved = PDFOutlineWriter.writeableItems(writeableOutlineItems(),
                                                       pageCount: document.pageCount)
        let items = resolved.items
        outlineWriteNotice = nil
        if resolved.clamped > 0 {
            outlineWriteNotice = "目录里有 \(resolved.clamped) 条的跳转目标页已经被删掉了，"
                + "这次写进文件时改指到了最接近的页（想改回来：撤销删页，或在目录面板里重新指定）。"
        }

        let folder = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        // 前导点 = 隐藏文件：万一哪次异常退出没清掉，用户也不会在访达里看到一地垃圾
        let tempURL = folder.appendingPathComponent(".\(stem).tmp-\(UUID().uuidString).pdf")

        if document.write(to: tempURL) {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            var injected = false
            var outlineFailure: Error?
            // ⚠️ **即使 `items` 是空的，也必须走一趟 `inject`。**
            //
            // 因为 PDFKit 的 `write` 会**保留**文件里原有的 `/Outlines` ——
            // 实测（`/tmp/tocdeleterun`）：在内存里把目录删光再写盘，
            // 文件里那份居然还在，重新打开就又冒出来了。用户报的
            // 「删除最顶层的目录，里面的子目录会再次恢复出来」根子就在这。
            //
            // `inject` 在 `items` 为空时会走 `removingOutlines`，把 catalog 里的
            // `/Outlines` 键**整个删掉**。跳过它就等于"删除只停留在内存里"。
            // （`inject` 自己会判断"文件里本来就没有目录 → 直接返回 0"，不会白跑。）
            do {
                try PDFOutlineWriter.inject(items,
                                            expectedPageCount: document.pageCount,
                                            into: tempURL)
                injected = true
            } catch {
                outlineFailure = error
            }
            // 自检：写出来的东西必须真的能读回来；读不回来就整个放弃，
            // 绝不拿一个可能有问题的文件去覆盖原文件（原文件这时还分毫未动）
            // 「目录被删光」那种情况要**反过来查**：文件里必须找不到目录。
            // 不查的话，"删了但文件里还在"这种半成功状态会静默通过。
            if let problem = selfCheck(tempURL,
                                       expectedPages: document.pageCount,
                                       requireOutline: injected ? items : [],
                                       requireNoOutline: injected && items.isEmpty) {
                throw AnnotationSaveError.selfCheckFailed(problem)
            }
            do {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } catch {
                // 替换失败（极少见）→ 原文件还是完整的
                throw AnnotationSaveError.writeFailed(nil)
            }
            if let outlineFailure {
                outlineWriteNotice = "批注已保存，但**目录没能写进文件**：\(message(of: outlineFailure))"
            }
            // 文件已经换成新的了 —— 改动在这里"落地"
            unsavedChanges.clear()
            return
        }

        // ── 同目录写不了临时文件（沙箱没给这个目录的写权限）→ 退回直接写原文件 ──
        // 这条老路径没有"失败不伤原文件"的保护，但至少功能可用（备份仍在，若开着）。
        guard document.write(to: fileURL) else {
            throw AnnotationSaveError.writeFailed(nil)
        }
        unsavedChanges.clear()
        // 同上：空目录也要走一趟，才能把文件里原有的 `/Outlines` 去掉
        do {
            let outcome = try PDFOutlineWriter.inject(items,
                                                      expectedPageCount: document.pageCount,
                                                      into: fileURL)
            // `addedBytes == 0` 有两种含义：真的没写进去（有目录却没加字节），
            // 或者"本来就没有目录、没什么可做"（items 为空）。只有前者算问题。
            if !items.isEmpty && outcome.addedBytes == 0 {
                outlineWriteNotice = "目录没有写进文件（文件结构不支持）。"
            }
        } catch {
            outlineWriteNotice = "批注已保存，但**目录没能写进文件**：\(message(of: error))"
        }
    }

    /// 自检写出的文件：能独立打开、页数一致、目录读得回。返回 nil 表示没问题。
    private func selfCheck(_ url: URL,
                           expectedPages: Int,
                           requireOutline items: [PDFOutlineWriter.Item],
                           requireNoOutline: Bool = false) -> String? {
        guard let probe = PDFDocument(url: url) else { return "写出的文件打不开" }
        guard probe.pageCount == expectedPages else {
            return "页数对不上（期望 \(expectedPages)，实际 \(probe.pageCount)）"
        }
        // 「目录被删光」：写出来必须**没有**目录。PDFKit 的 write 会保留原文件的
        // `/Outlines`，所以要在这里确认我们的 remove 真的落到了文件上。
        if requireNoOutline {
            let remaining = probe.outlineRoot?.numberOfChildren ?? 0
            guard remaining == 0 else {
                return "目录没被移除（文件里还剩 \(remaining) 个顶层项）"
            }
            return nil
        }
        guard !items.isEmpty else { return nil }
        let readBack = PDFOutlineWriter.items(from: probe.outlineRoot, in: probe)
        guard readBack.count == items.count else {
            return "目录没写全（期望 \(items.count) 条，读到 \(readBack.count) 条）"
        }
        return nil
    }

    private func message(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// 把文档里"本该可见"的批注都恢复成 `shouldDisplay = true`，返回被改动的那些。
    ///
    /// 判定依据不是 `AnnotationRenderer.isSelfRendered`：有些批注我们**渲染不了**
    /// （多段 quad 的高亮、图章等），它们的 `shouldDisplay` 一直是 true，不需要动。
    /// 只恢复"类型是我们能自绘的"那些 —— 因为只有它们的 false 是我们设的。
    private func restoreDisplayFlags(in document: PDFDocument) -> [PDFAnnotation] {
        var restored: [PDFAnnotation] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where AnnotationRenderer.isSelfRendered(annotation) && !annotation.shouldDisplay {
                annotation.shouldDisplay = true
                restored.append(annotation)
            }
        }
        return restored
    }

    enum AnnotationSaveError: LocalizedError {
        case readOnly
        case noDocument
        case noFileURL
        /// 写盘失败。带备份路径时提示去哪恢复；不带（自动保存没备份）时要说清"原文件没动"
        case writeFailed(URL?)
        /// 写出来的文件没通过自检 —— 已放弃写入，原文件未改动
        case selfCheckFailed(String)
        /// 这份文档是**图片**：它没有可写回的 PDF，出口只有「导出为图片」（v1.3.66）
        case imageDocument
        /// 导出图片失败（渲染不出来 / 写盘被拒）
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .readOnly:
                return "当前是只读模式。请先点顶部的「编辑」再保存。"
            case .noDocument:
                return "没有已打开的文档。"
            case .noFileURL:
                return "该文档没有对应的本地文件（可能是加密或临时文档），无法保存批注。"
            case .imageDocument:
                return "这是一张图片，改动要导出成新图片（用「导出为图片…」）。原图不会被改动。"
            case .exportFailed(let detail):
                return "导出图片失败：\(detail)"
            case .writeFailed(let backupURL):
                if let backupURL {
                    return "写入 PDF 失败，原文件可能已损坏。请从备份恢复：\(backupURL.path)"
                }
                return "写入 PDF 失败。**原文件没有被改动**（我们是先写临时文件、成功后才替换的）。"
            case .selfCheckFailed(let detail):
                return "写出的文件没通过自检（\(detail)），已放弃这次写入，**原文件没有被改动**。"
            }
        }
    }

    /// 当前可见区域在指定页上的矩形（PDF 页坐标）。用于确定插入位置。
    private func visibleRect(on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        guard let pdfView else { return pageBounds }

        let rect = pdfView.convert(pdfView.bounds, to: page)
        let clipped = rect.intersection(pageBounds)
        return clipped.isNull || clipped.isEmpty ? pageBounds : clipped
    }

    // MARK: - 文本朗读（v1.0）

    /// 有选中文本就读选中内容，否则读当前页。
    func speakSelectionOrCurrentPage() {
        if let selection = pdfView?.currentSelection,
           let text = selection.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speech.onFinish = nil
            speech.speak(text)
        } else {
            speakCurrentPage()
        }
    }

    func speakCurrentPage() {
        guard let text = pdfView?.document?.page(at: currentPageIndex)?.string, !text.isEmpty else { return }

        speech.onFinish = { [weak self] in
            guard let self, self.speech.autoAdvance else { return }
            self.speakNextPage()
        }
        speech.speak(text)
    }

    private func speakNextPage() {
        guard let document = pdfView?.document else { return }
        let next = currentPageIndex + 1
        guard next < document.pageCount else { return }
        goToPage(at: next)
        speakCurrentPage()
    }

    func stopSpeaking() {
        speech.stop()
        speech.onFinish = nil
    }

    func restartSpeechFromCurrentPosition() {
        speech.stop()
        speakCurrentPage()
    }

    // MARK: - 自动滚动（v1.0）

    func toggleAutoScroll() {
        guard let pdfView else { return }
        autoScroller.toggle(in: pdfView)
    }
}

/// "有未保存的改动"的小标记。
///
/// 单独做成一个对象，是为了把**订阅面收窄**：只有标签页上那个小圆点和目录面板底部那句提示
/// 需要跟着它变。如果把它挂在 `PDFViewModel` 上做成 `@Published`，
/// 每次置位都会让所有观察 `PDFViewModel` 的视图（PDF 视图、缩略图栏、批注栏、工具条…）
/// 重算一遍 body —— 用户实测到的"改一下目录就顿一下"就有它一份。
@MainActor
final class UnsavedChangesFlag: ObservableObject {
    @Published private(set) var value = false

    /// 置位。**只在真的从干净变脏时才发通知** —— 连续改动不会反复触发重绘。
    func mark() {
        if !value { value = true }
    }

    /// 清位（写盘成功、或刚打开文档时）。
    func clear() {
        if value { value = false }
    }
}
