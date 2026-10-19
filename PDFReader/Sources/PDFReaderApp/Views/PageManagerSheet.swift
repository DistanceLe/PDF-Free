import SwiftUI
import PDFKit
import AppKit

/// 「页面管理」面板：把所有页**平铺**出来，可以多选、调顺序、删除。
///
/// ## 形态：盖在主窗口上的**浮层**，不是 sheet（v1.3.43）
///
/// v1.3.42 用的是 `.sheet`，两个毛病：尺寸被父窗口卡着**盖不满**；而且是模态的
/// （开着的时候窗口都关不掉）。现在就是内容区里的一个普通视图，铺满整个可用区域 ——
/// 也就有地方把缩略图做大。
///
/// ## ⚠️ 一切**按页对象**定位，不按下标
///
/// 这是 v1.3.43 修的那个"选中的页乱跳 / 删的不是我想删的那页"的根子。
///
/// 下标会随重排变，而 SwiftUI 复用视图时，**覆盖层（AppKit）里那个闭包可能是旧的** ——
/// 它捕获的是"建这个视图时的下标"。于是点了第 5 页、实际选中的是别的页。
///
/// 页对象是不变的锚：闭包捕获页对象，点击那一刻再问 `viewModel.pageIndex(of:)`
/// 得到"它现在在第几位"。哪怕视图是复用的、闭包是旧的，算出来也是对的。
///
/// ## 拖拽用 AppKit 那一套
///
/// 目录栏那轮踩过：SwiftUI 的 `.onDrag` 在 drop 之后会进入"夹生"状态、把鼠标
/// 扣住一两秒（见 `SidebarView` 里 `TOCDragHandleView` 的长注释）。这里照搬当时
/// 验证过的组合 —— AppKit 自己控制拖拽源 + SwiftUI 的 `.onDrop` 接。
@MainActor
struct PageManagerSheet: View {

    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel

    /// 当前选中的页（按**现在的页序**给下标）
    @State private var selection: Set<Int> = []
    /// ⇧ 区间选择的锚点 —— 存**页对象**，算区间时再换成下标
    @State private var anchorPage: PDFPage?
    /// 落点提示 —— 同样按页对象记
    @State private var dropHint: PageDropHint?

    /// 一次会话一份缩略图缓存；关掉面板就丢掉，下次重新取（免得显示旧内容）
    @StateObject private var thumbnails = PageThumbnailCache()
    /// 落点提示的节流状态（引用类型，写它不触发重绘）
    @State private var dragState = PageDragState()
    /// 拖拽是不是正落在"网格下方那块空白"上（只用来显示那行提示）
    @State private var isEndTargeted = false

    /// 网格里的一格：**身份是页对象**（不是下标）。
    ///
    /// 用它当 `ForEach` 的 id，重排之后 SwiftUI 会把"还是那一页"的视图挪过去，
    /// 而不是按位置重建 —— 缩略图缓存因此一直命中，不会闪。
    struct PageSlot: Identifiable {
        let index: Int
        let page: PDFPage
        var id: ObjectIdentifier { ObjectIdentifier(page) }
    }

    private var slots: [PageSlot] {
        let document = tab.document
        return (0..<document.pageCount).compactMap { index in
            document.page(at: index).map { PageSlot(index: index, page: $0) }
        }
    }

    private var pageCount: Int { tab.document.pageCount }

    /// 「插入空白页」菜单里可选的张数
    private static let blankPageCounts = [1, 2, 5, 10]

    /// 缩略图尺寸。v1.3.44 又放大了一档（150 → 210）：面板现在铺满整个窗口，
    /// 有地方摆，看得清才点得准。
    ///
    /// ⚠️ **列间距 / 行间距必须是 0**，由 cell 自己的 `padding` 补出视觉间距 ——
    /// 原因见 `cell(_:)` 里那段（间隙要能被**最近的格子**接住，而不是掉进兜底）。
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 360), spacing: 0)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !viewModel.isEditable { readOnlyBanner }
            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            viewModel.beginPageEditing()
            // 打开时默认选中"正在看的那一页"，用户一眼知道自己在哪
            let current = viewModel.currentPageIndex
            if current >= 0, current < pageCount {
                selection = [current]
                anchorPage = tab.document.page(at: current)
            }
        }
        .onDisappear {
            // 兜底：万一没收尾（窗口关了之类的），重活也得补上
            viewModel.endPageEditing()
        }
        // 页序变了 → 旧下标不作数了，重新映射；锚点和落点也丢掉
        .onChange(of: viewModel.pageRevision) { _, _ in
            selection = selection.filter { $0 >= 0 && $0 < pageCount }
            anchorPage = nil
            dropHint = nil
        }
        .alert(
            "改不了页面",
            isPresented: Binding(
                get: { viewModel.pageEditNotice != nil },
                set: { if !$0 { viewModel.pageEditNotice = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.pageEditNotice ?? "")
        }
    }

    private func close() {
        viewModel.endPageEditing()
    }

    // MARK: - 顶部操作条

    private var header: some View {
        HStack(spacing: 10) {
            Text("页面管理")
                .font(.system(size: 13, weight: .semibold))
            Text("共 \(pageCount) 页")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !selection.isEmpty {
                Text("· 已选 \(selection.count) 页")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button {
                toggleSelectAll()
            } label: {
                Label(selection.count == pageCount && pageCount > 0 ? "取消选择" : "全选",
                      systemImage: "checkmark.circle")
            }
            .disabled(pageCount == 0)

            Button {
                moveSelectionToTop()
            } label: {
                Label("移到最前", systemImage: "arrow.up.to.line")
            }
            .disabled(!canMove)

            Button {
                moveSelectionToBottom()
            } label: {
                Label("移到最后", systemImage: "arrow.down.to.line")
            }
            .disabled(!canMove)

            // 插入空白页：尺寸跟随相邻那一页，插完自动选中它们
            Menu {
                if selection.isEmpty {
                    Section("文档末尾") {
                        ForEach(Self.blankPageCounts, id: \.self) { count in
                            Button("插入 \(count) 页") { insertBlank(after: [], count: count) }
                        }
                    }
                } else {
                    Section("在选中页之后插入") {
                        ForEach(Self.blankPageCounts, id: \.self) { count in
                            Button("\(count) 页") { insertBlank(after: selection, count: count) }
                        }
                    }
                }
                Section("文档开头") {
                    Button("插入 1 页") { insertBlank(after: [-1], count: 1) }
                }
            } label: {
                Label("空白页", systemImage: "doc.badge.plus")
            }
            .disabled(!canEdit)
            .help("插入空白页 —— 纸张尺寸跟随相邻那一页")

            Button(role: .destructive) {
                deleteSelection()
            } label: {
                Label("删除", systemImage: "trash")
            }
            // ⌫ 直接删。页面管理盖着的时候 PDF 视图那边不会再抢这个键
            //（见 `EditablePDFView.handleKeyEvent` 里的 `isPageManagerVisible` 判断）
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!canEdit || selection.isEmpty || selection.count >= pageCount)

            Divider().frame(height: 16)

            // 撤销 / 重做：快捷键归菜单（⌘Z / ⇧⌘Z），这里只给鼠标一个入口
            Button {
                viewModel.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .help("撤销上一步改动（⌘Z）")

            Button {
                viewModel.redo()
            } label: {
                Label("重做", systemImage: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)
            .help("重做（⇧⌘Z）")

            Divider().frame(height: 16)

            Button("完成") { close() }
                .keyboardShortcut(.defaultAction)

            // Esc = 完成。`keyboardShortcut` 得挂在某个按钮上才注册得进窗口，
            // 所以放一个尺寸为零、看不见的按钮。
            Button("") { close() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11))
            Text("当前是「只读」模式 —— 可以看、可以跳页，改不了页面顺序和数量。")
                .font(.system(size: 11))
            Spacer()
            Button("进入编辑模式") { viewModel.isEditable = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.10))
    }

    // MARK: - 页面网格

    private var grid: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(slots) { slot in
                            cell(slot)
                        }
                    }
                    // 11 + cell 自带的 9 = 20，和之前的留白一致
                    .padding(.horizontal, 11)
                    .padding(.top, 11)

                    endDropZone
                }
                // 内容至少和视口一样高：网格短的时候，"下方那块空白"才仍然是一整块
                // 能接住拖拽的视图，而不是不属于任何视图的空虚处。
                .frame(minHeight: outer.size.height, alignment: .top)
            }
            .overlay(alignment: .bottom) { footerHint }
        }
    }

    /// 网格**下方**的空白：拖到这里松手 = 移到最后。
    ///
    /// ## ⚠️ 为什么必须是独立的一块，而不是把兜底挂在 `ScrollView` 上
    ///
    /// v1.3.43 是挂在 `ScrollView` 上的 —— 那样兜底的命中区就是**整个滚动区域**，
    /// 连网格里"两个缩略图之间的缝"也算。实测症状（用户报的）：
    /// **拖到两页中间 → 出现一个 `+` → 松手，那一页跑到最后一页去了。**
    /// 因为缝上松手落到的是兜底，而兜底的语义是"追加到末尾"。
    ///
    /// 现在：缝归**最近的格子**（见 `cell(_:)` 的 padding 说明），兜底只管这一块。
    private var endDropZone: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 170, maxHeight: .infinity)
            .overlay(alignment: .top) { endDropHint }
            .onDrop(of: [.utf8PlainText],
                    delegate: PageEndDropDelegate(viewModel: viewModel,
                                                  dragState: dragState,
                                                  isTargeted: $isEndTargeted,
                                                  dropHint: $dropHint))
    }

    @ViewBuilder
    private var endDropHint: some View {
        if isEndTargeted {
            Text("移到最后")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .padding(.top, 18)
                .allowsHitTesting(false)
        }
    }

    private var footerHint: some View {
        Text(viewModel.isEditable
             ? "点击选中 · ⌘/⇧ 点击多选 · 拖动缩略图调整顺序 · 双击跳到该页"
             : "只读模式下只能浏览")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cell(_ slot: PageSlot) -> some View {
        GeometryReader { proxy in
            PageManagerCell(
                page: slot.page,
                index: slot.index,
                isSelected: selection.contains(slot.index),
                isCurrent: viewModel.currentPageIndex == slot.index,
                thumbnails: thumbnails,
                dropSide: dropSide(for: slot.page),
                onClick: { event in handleClick(page: slot.page, event: event) }
            )
            // ⚠️ 这两句 padding 必须在 `onDrop` **之内**：命中区因此从卡片边缘往外扩到
            //    格子缝的中央（左右各 9、上下各 10 ≈ 原来的间距）。这样"拖到两页之间
            //    松手"就落到**最近的那一格**，插入点正好是两者之间 ——
            //    而不是掉进下方的兜底、把这一页送到最后（用户实测报的就是那个）。
            //    左右对称 → 命中区中点仍在卡片中心，`cellWidth / 2` 的左右半边判断不受影响。
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .overlay {
                // AppKit 拖拽源盖在缩略图上：起拖、单击（含页码那一行）都由它转回来。
                PageDragSource(
                    makePayload: { dragPayload(clicked: slot.page) },
                    onClick: { event in handleClick(page: slot.page, event: event) },
                    onSessionEnded: {
                        dragState.reset()
                        dropHint = nil
                    }
                )
            }
            .onDrop(of: [.utf8PlainText],
                    delegate: PageDropDelegate(targetPage: slot.page,
                                               cellWidth: proxy.size.width,
                                               viewModel: viewModel,
                                               dragState: dragState,
                                               dropHint: $dropHint,
                                               selection: $selection))
        }
        // 给个固定比例，避免网格随页面比例上下跳
        .aspectRatio(0.72, contentMode: .fit)
    }

    /// 这一格是不是落点：`0` 左边、`1` 右边、`nil` 不是
    private func dropSide(for page: PDFPage) -> Int? {
        guard let hint = dropHint, hint.page === page else { return nil }
        return hint.after ? 1 : 0
    }

    // MARK: - 选择

    /// ⚠️ `page` 是**页对象**（不是下标）—— 点击那一刻才换算成下标，见类型注释。
    private func handleClick(page: PDFPage, event: NSEvent) {
        guard let index = viewModel.pageIndex(of: page) else { return }
        // 双击 = 跳到这一页并关掉面板，省得再找
        if event.clickCount == 2 {
            viewModel.goToPage(at: index)
            close()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift),
           let anchorPage, let anchor = viewModel.pageIndex(of: anchorPage) {
            selection = Set(min(anchor, index)...max(anchor, index))
        } else if flags.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchorPage = page
        } else {
            selection = [index]
            anchorPage = page
        }
    }

    private func toggleSelectAll() {
        if selection.count == pageCount && pageCount > 0 {
            selection = []
            anchorPage = nil
        } else {
            selection = Set(0..<pageCount)
            anchorPage = tab.document.page(at: 0)
        }
    }

    // MARK: - 增删移

    private var canEdit: Bool { viewModel.isEditable }
    /// 「移到最前 / 最后」只有在"选中的不是已经在那一头"时才有意义
    private var canMove: Bool {
        guard canEdit, !selection.isEmpty, pageCount > 1 else { return false }
        if selection.count >= pageCount { return false }
        if let first = selection.min(), let last = selection.max(),
           first == 0, last == selection.count - 1 { return false }
        return true
    }

    private func deleteSelection() {
        guard viewModel.deletePages(selection) else { return }
        selection = []
        anchorPage = nil
    }

    private func moveSelectionToTop() {
        guard viewModel.movePages(selection, to: 0) else { return }
        selection = Set(0..<selection.count)
        anchorPage = nil
    }

    private func moveSelectionToBottom() {
        let count = selection.count
        guard viewModel.movePages(selection, to: pageCount) else { return }
        selection = Set((pageCount - count)..<pageCount)
        anchorPage = nil
    }

    // MARK: - 插入空白页

    /// 插完把**新页选中** —— 用户接着就能拖它、删它，不用再去点一遍。
    ///
    /// - Parameter anchorIndices: 插入点（集合里最靠后那一页的后面）。
    ///   空集合 = 文档末尾；`[-1]` = 文档开头。
    private func insertBlank(after anchorIndices: Set<Int>, count: Int) {
        guard let inserted = viewModel.insertBlankPages(after: anchorIndices, count: count) else { return }
        selection = Set(inserted)
        anchorPage = tab.document.page(at: inserted.lowerBound)
    }

    // MARK: - 拖拽

    /// 起拖时把"要搬哪几页"打包成逗号分隔的下标。
    ///
    /// ⚠️ **这里绝不写 `@State`。** 目录那轮实测过：起拖的瞬间动 `@State`
    /// 会让列表重建，拖拽会话当场断掉（"突然就拖不动了"）。
    /// 拖了一页"没被选中的页"时，就只搬它自己 —— 选中态等会话结束再说。
    ///
    /// 入参是**页对象**：那一刻才换算成下标，避免用到旧下标。
    private func dragPayload(clicked page: PDFPage) -> String? {
        guard canEdit, let index = viewModel.pageIndex(of: page) else { return nil }
        let indices = selection.contains(index) ? selection : [index]
        let sorted = indices.filter { $0 >= 0 && $0 < pageCount }.sorted()
        guard !sorted.isEmpty else { return nil }
        let text = sorted.map(String.init).joined(separator: ",")
        Diagnostics.shared.record("页面拖拽：起手 \(text)（指的「第 \(index + 1) 页」）")
        return text
    }

}

/// 拖拽落点提示：落在哪一页上、插在它左边还是右边。
///
/// 定义在文件作用域（不在 `@MainActor` 的类型里面）—— 免得 `Equatable` 的 `==`
/// 变成"非隔离上下文里读主线程隔离属性"，那在 Swift 6 下直接是错误。
struct PageDropHint: Equatable {
    let page: PDFPage
    let after: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.page === rhs.page && lhs.after == rhs.after
    }
}

// MARK: - 单元格

/// 一张缩略图 + 下面的页码。
///
/// 单独拆出来是为了它能 `Equatable`：拖动过程中落点提示每变一次，
/// 只有"那两格"需要重画。
@MainActor
struct PageManagerCell: View, Equatable {
    let page: PDFPage
    /// 页对象的身份。**`==` 里只能比它，不能直接比 `page`** ——
    /// `==` 是 `nonisolated` 的，而 `PDFPage` 不是 `Sendable`，
    /// 在非隔离上下文里读它会报"main actor-isolated property can not be referenced"。
    /// `ObjectIdentifier` 是 Sendable，比它既安全又是同一件事。
    let pageID: ObjectIdentifier
    let index: Int
    let isSelected: Bool
    let isCurrent: Bool
    let thumbnails: PageThumbnailCache
    /// 落点提示：0 = 插在这页左边，1 = 右边，nil = 不是落点
    let dropSide: Int?
    let onClick: (NSEvent) -> Void

    init(page: PDFPage, index: Int, isSelected: Bool, isCurrent: Bool,
         thumbnails: PageThumbnailCache, dropSide: Int?,
         onClick: @escaping (NSEvent) -> Void) {
        self.page = page
        self.pageID = ObjectIdentifier(page)
        self.index = index
        self.isSelected = isSelected
        self.isCurrent = isCurrent
        self.thumbnails = thumbnails
        self.dropSide = dropSide
        self.onClick = onClick
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // ⚠️ 比的是**页对象身份**和它现在的下标 —— 身份用来认出"还是那一页"，
        // 下标用来捕捉"它挪位了、页码要重画"。
        lhs.pageID == rhs.pageID
            && lhs.index == rhs.index
            && lhs.isSelected == rhs.isSelected
            && lhs.isCurrent == rhs.isCurrent
            && lhs.dropSide == rhs.dropSide
    }

    /// 请求尺寸给得比显示大一截，Retina 下不糊；缓存按"页对象 + 尺寸"存，
    /// 重排之后同一页还是命中同一张图。
    private var requestSize: CGSize {
        CGSize(width: 560, height: 780)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)

                Image(nsImage: thumbnails.image(for: page, size: requestSize))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(3)

                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.12),
                            lineWidth: isSelected ? 2.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                }
            }

            Text("\(index + 1)")
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .monospacedDigit()
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if dropSide == 0 { insertionBar }
        }
        .overlay(alignment: .trailing) {
            if dropSide == 1 { insertionBar }
        }
        .overlay(alignment: .topLeading) {
            if isCurrent {
                Text("当前")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .padding(5)
            }
        }
    }

    private var insertionBar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(width: 3)
    }
}

// MARK: - 缩略图缓存

/// 一次面板会话一份。键里带**页对象身份**，所以重排之后同一页还是命中同一张图。
///
/// 不做跨会话缓存：页面内容可能因为改批注而变，缓存久了会显示旧图。
@MainActor
final class PageThumbnailCache: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()

    func image(for page: PDFPage, size: CGSize) -> NSImage {
        let key = "\(UInt(bitPattern: ObjectIdentifier(page).hashValue))-\(Int(size.width))x\(Int(size.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = page.thumbnail(of: size, for: .cropBox)
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - 拖拽源（AppKit）

/// 为什么要自己实现拖拽源：见 `SidebarView` 里 `TOCDragHandleView` 的类型注释
/// （SwiftUI 的 `.onDrag` 在 drop 之后会把鼠标扣住一两秒）。
/// 载荷用 `NSPasteboardItem` 写 `.string` ＝ `public.utf8-plain-text`，
/// 和 SwiftUI `.onDrop(of: [.utf8PlainText])` 要的类型标识完全一致。
@MainActor
private final class PageDragSourceView: NSView, NSDraggingSource {

    /// 按下之后移动多少才算拖拽（少于它当单击）
    private static let dragThreshold: CGFloat = 4

    var makePayload: (() -> String?)?
    var onClick: ((NSEvent) -> Void)?
    var onSessionEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var dragging = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // ⚠️ 不调 super：调用链下去会变成"窗口拖拽"之类的默认行为
        mouseDownEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= Self.dragThreshold else { return }
        guard let payload = makePayload?() else { return }
        dragging = true

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload, forType: .string)

        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let size = NSSize(width: max(bounds.width, 60), height: max(bounds.height, 40))
        item.setDraggingFrame(NSRect(origin: .zero, size: size),
                              contents: draggingImage(size: size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        guard !dragging else { dragging = false; return }
        // 没起拖 → 这就是一次单击。单元格的点击被我们挡住了（我们是覆盖层），
        // 在这里补回去。
        onClick?(event)
    }

    /// ⚠️ 覆盖层会先拿到右键 —— 必须显式还回去，否则下面 SwiftUI 的
    /// `contextMenu` 就点不出来了。
    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    /// 拖动时鼠标下面跟着的那张图
    private func draggingImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        return image
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
        mouseDownEvent = nil
        Diagnostics.shared.record("页面拖拽：会话结束 operation=\(operation.rawValue)"
                                  + (operation.isEmpty ? "（没有落在任何一页上）" : "（已被接受）"))
        onSessionEnded?()
    }
}

/// 把上面那个 AppKit 拖拽源包成 SwiftUI 视图（透明覆盖层）
@MainActor
private struct PageDragSource: NSViewRepresentable {
    let makePayload: () -> String?
    let onClick: (NSEvent) -> Void
    let onSessionEnded: () -> Void

    func makeNSView(context: Context) -> PageDragSourceView {
        let view = PageDragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: PageDragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: PageDragSourceView) {
        view.makePayload = makePayload
        view.onClick = onClick
        view.onSessionEnded = onSessionEnded
    }
}

// MARK: - 落点

/// 落点提示的节流状态。
///
/// 写成引用类型（不是 `@State`）：`dropUpdated` 在一次拖动里能被调几百次，
/// 每次都写 `@State` 就是每次都让整块网格重算。
@MainActor
final class PageDragState {
    var lastHintWrite = Date.distantPast
    func reset() {
        lastHintWrite = .distantPast
    }
}

/// 落在某一页上：按指针在这格里的左右半边决定"插到它前面还是后面"。
///
/// ⚠️ 目标页存的是**页对象**：落点计算在下拉那一刻才换算成下标，
/// 这样即使视图被复用、或者中途发生过重排，插的位置也是对的。
@MainActor
private struct PageDropDelegate: DropDelegate {
    let targetPage: PDFPage
    let cellWidth: CGFloat
    let viewModel: PDFViewModel
    let dragState: PageDragState
    @Binding var dropHint: PageDropHint?
    @Binding var selection: Set<Int>

    /// 只看"载荷类型对不对"，**不要**依赖任何跨回调的共享状态
    /// （目录那轮的经验：靠它就变成"有时候能放、大部分放不了"）。
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHint(info)
        return DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        updateHint(info)
    }

    /// 只清提示，**绝不碰别的状态** —— 父子两侧的 drop 回调先后没有保证
    func dropExited(info: DropInfo) {}

    func performDrop(info: DropInfo) -> Bool {
        let destination = insertPosition(info)
        dropHint = nil
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return true }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let indices = Set(text.split(separator: ",").compactMap { Int($0) })
            Task { @MainActor in
                // 移完之后选中的是**同一批页的新位置**，用户接着还能再挪
                guard let destination,
                      viewModel.movePages(indices, to: destination) else { return }
                selection = PageManagerSheet.selectionAfterMove(indices, to: destination,
                                                                pageCount: viewModel.pageCount)
            }
        }
        // ⚠️ **无条件返回 true**：返回值在 AppKit 那层的含义是"这次拖拽有没有人接手"，
        // 返回 false 会让拖拽会话悬空、随后几秒鼠标失灵（目录那轮实测过）。
        return true
    }

    /// 指针在这一格的左半边 → 插到它前面；右半边 → 插到它后面。
    /// 目标页已经被删掉了（拖拽中途理论上不会发生）→ 返回 nil，这次不动。
    private func insertPosition(_ info: DropInfo) -> Int? {
        guard let index = viewModel.pageIndex(of: targetPage) else { return nil }
        return info.location.x < cellWidth / 2 ? index : index + 1
    }

    private func updateHint(_ info: DropInfo) {
        let now = Date()
        guard now.timeIntervalSince(dragState.lastHintWrite) >= 0.08 else { return }
        dragState.lastHintWrite = now
        let after = info.location.x >= cellWidth / 2
        guard dropHint?.page !== targetPage || dropHint?.after != after else { return }
        dropHint = PageDropHint(page: targetPage, after: after)
    }
}

/// 网格**下方那块空白**的落点：把拖过来的页追加到文档末尾。
///
/// ⚠️ 用 `DropDelegate` 而不是 `.onDrop(isTargeted:)`：后者提交给 AppKit 的操作是
/// **copy**，鼠标旁会挂一个 `+` 徽标 —— 而我们做的是移动，语义对不上，
/// 用户也会误以为"复制了一份"。这里显式声明 `.move`。
@MainActor
private struct PageEndDropDelegate: DropDelegate {
    let viewModel: PDFViewModel
    let dragState: PageDragState
    @Binding var isTargeted: Bool
    @Binding var dropHint: PageDropHint?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        // 落到这里就不是"插在某一页旁边"了，把那根插入线收掉
        dropHint = nil
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        dropHint = nil
        let destination = viewModel.pageCount
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return true }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let indices = Set(text.split(separator: ",").compactMap { Int($0) })
            Task { @MainActor in
                _ = viewModel.movePages(indices, to: destination)
            }
        }
        // ⚠️ **无条件返回 true** —— 返回值在 AppKit 那层的含义是"这次拖拽有没有人接手"，
        // 返回 false 会让会话悬空、随后几秒鼠标失灵（目录那轮实测过）。
        return true
    }
}

extension PageManagerSheet {
    /// 一批页被搬到 `destination` 之后，它们的新下标是多少
    static func selectionAfterMove(_ indices: Set<Int>, to destination: Int,
                                   pageCount: Int) -> Set<Int> {
        let sorted = indices.sorted()
        guard !sorted.isEmpty else { return [] }
        // 和 `PDFViewModel.movePages` 里的折算保持一致：移走的那批会占位往前挪
        let shift = sorted.filter { $0 < destination }.count
        let insertAt = min(max(destination - shift, 0), pageCount)
        return Set(insertAt..<(insertAt + sorted.count))
    }
}
