import SwiftUI
import PDFKit
import AppKit

/// 侧边栏面板。定义在顶层（而非 SidebarView 内嵌）是为了让 `PDFViewModel` 也能引用，
/// 这样菜单快捷键就能切换它。
///
/// 注意：**搜索不在侧边栏里** —— 搜索框在顶栏右上角常驻，结果在右侧栏显示。
enum SidebarItem: String, CaseIterable {
    case thumbnails = "缩略图"
    case outline = "目录"
    case annotations = "批注"
    case bookmarks = "书签"

    var icon: String {
        switch self {
        case .thumbnails: return "square.grid.2x2"
        case .outline: return "list.bullet"
        case .annotations: return "square.and.pencil"
        case .bookmarks: return "bookmark"
        }
    }
}

struct SidebarView: View {
    /// 观察偏好：外框颜色改了要立刻生效
    @ObservedObject private var preferences = AppPreferences.shared
    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // 面板切换器。
            //
            // ⚠️ 这里**不放"关闭侧边栏"的 X**（v1.3.46 去掉）：顶栏已经有开/关
            // 左右侧栏的按钮了，面板里再放一个既是重复入口，也让这个切换器白占窄
            // 一截宽度（四个分段被挤得更小）。
            Picker("", selection: $viewModel.activeSidebar) {
                ForEach(SidebarItem.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            // 内容
            switch viewModel.activeSidebar {
            case .thumbnails:
                ThumbnailSidebar(tab: tab)
            case .outline:
                OutlineSidebar(tab: tab)
            case .annotations:
                AnnotationSidebar(viewModel: tab.viewModel)
            case .bookmarks:
                BookmarkSidebar(documentURL: tab.url, viewModel: tab.viewModel)
            }
        }
        // 侧边栏也归"外框"（和顶栏同一个色）—— 这样"界面"是一整圈深灰、
        // 页面是白的，层次一眼分得开（见 `AppChrome`）
        .background(preferences.chromeColor)
    }
}

// MARK: - 缩略图

struct ThumbnailSidebar: View {
    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel

    /// 缩略图显示高度（点），自动记忆
    @AppStorage("pdfreader.thumbnailHeight") private var displayHeight: Double = 70

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
    }

    /// 请求尺寸按显示高度的 2 倍取，保证 Retina 下不糊
    private var requestSize: CGSize {
        let height = displayHeight * 2
        return CGSize(width: height * 0.78, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(0..<tab.document.pageCount, id: \.self) { index in
                    ThumbnailCell(
                        document: tab.document,
                        pageIndex: index,
                        isSelected: viewModel.currentPageIndex == index,
                        displayHeight: CGFloat(displayHeight),
                        requestSize: requestSize
                    )
                    .id(index)
                    .onTapGesture {
                        viewModel.goToPage(at: index)
                    }
                }
                .listStyle(.plain)
                .onChange(of: viewModel.currentPageIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            Divider()
            sizeControl
        }
    }

    private var sizeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Slider(value: $displayHeight, in: 40...160)
                .controlSize(.small)

            Image(systemName: "photo")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Text("\(Int(displayHeight))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            Button {
                viewModel.beginPageEditing()
            } label: {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("页面管理：平铺所有页，可多选、调顺序、删除（⌥⌘P）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("缩略图尺寸，自动记忆")
    }
}

struct ThumbnailCell: View {
    let document: PDFDocument
    let pageIndex: Int
    let isSelected: Bool
    let displayHeight: CGFloat
    let requestSize: CGSize

    var body: some View {
        HStack(spacing: 10) {
            // 页码
            Text("\(pageIndex + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            // 缩略图
            if let page = document.page(at: pageIndex) {
                let thumbnail = page.thumbnail(of: requestSize, for: .cropBox)
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: displayHeight)
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}

// MARK: - 目录

/// 侧边栏「目录」面板（v1.3.23 起可编辑）。
///
/// ## 目录存哪儿
///
/// 内存里就是文档自己的 `document.outlineRoot`（**和批注一个模型：改内存 → 保存时写文件**），
/// 没有另建一份应用内的数据。落盘靠 `PDFOutlineWriter`：
/// **PDFKit 完全写不了目录**（实测结论见那个类型的注释），所以写盘走"增量更新"注入。
///
/// 好处是"其他 PDF 软件也能看到" —— 已用 pypdf（独立的另一套实现）验证过能读出标题、
/// 层级与目标页。
@MainActor
struct OutlineSidebar: View {
    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel
    /// 只订阅"有未保存改动"这个小标记（而不是 `PDFViewModel` 的那一大票 `@Published`）
    @ObservedObject private var unsavedChanges: UnsavedChangesFlag

    /// 当前选中那一行（单选；`PDFOutline` 是类，用对象标识当 id）
    @State private var selection: ObjectIdentifier?
    /// 正在改名的那一行
    @State private var renaming: ObjectIdentifier?
    @State private var draftTitle = ""
    /// 收起来的节点（只影响显示，不写进文件）
    @State private var collapsed = Set<ObjectIdentifier>()
    @State private var showAddSheet = false
    @State private var newTitle = ""
    /// 表单里的一句说明（"用选中文字"没拿到选区时会换一句提示）
    @State private var selectionHint: String?
    /// 正在被拖动的行 —— **故意用引用类型**，见 `TOCDragState` 的说明
    @State private var dragState = TOCDragState()
    /// 当前落点提示（哪一行、落在前/后/里面）
    @State private var dropHint: DropHint?
    /// 提示线的自清理任务（见 `startDropHintWatchdog`）
    @State private var dropHintWatchdog: DispatchWorkItem?
    /// 要不要弹「保存与备份」设置
    @State private var showPreferences = false
    @FocusState private var renameFocused: Bool

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
        self.unsavedChanges = tab.viewModel.unsavedChanges
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.tocRows.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            toolbar
        }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(isPresented: $showPreferences) {
            SavePreferencesView()
        }
        // 落点提示一出现就派人盯着（见 `startDropHintWatchdog`）
        .onChange(of: dropHint) { _, newValue in
            if newValue != nil { startDropHintWatchdog() }
        }
        // 侧边栏切走时视图会销毁，但 viewModel 上的选中项**不会自己清** ——
        // 留着的话切到别的面板按 Delete 会去打一个已经不存在的列表
        .onDisappear {
            viewModel.tocSelectedID = nil
            // 顺手把还挂着的自动保存写掉：防抖窗口内切走面板不该丢改动
            viewModel.flushOutlineAutoSave()
        }
        .onChange(of: tab.id) { _, _ in
            // 换标签页了：选中项、折叠状态都是按对象标识记的，得清掉
            selection = nil
            renaming = nil
            collapsed = []
            viewModel.tocSelectedID = nil
            viewModel.reloadTOC()
        }
    }

    // MARK: - 派生

    private var selectedRow: PDFViewModel.TOCRow? {
        guard let selection else { return nil }
        return viewModel.tocRows.first { $0.id == selection }
    }

    /// 折叠之后实际要显示的行
    private var visibleRows: [PDFViewModel.TOCRow] {
        var result: [PDFViewModel.TOCRow] = []
        var skippingBelowDepth: Int?
        for row in viewModel.tocRows {
            if let skip = skippingBelowDepth {
                if row.depth > skip { continue }
                skippingBelowDepth = nil
            }
            result.append(row)
            if row.hasChildren, collapsed.contains(row.id) { skippingBelowDepth = row.depth }
        }
        return result
    }

    // MARK: - 子视图

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("此文档没有目录")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(viewModel.isEditable
                 ? "用下面的「新增目录项」加一条，或先在页面上选中一行文字再点「用选中文字」"
                 : "点顶部「编辑」后可以在这里整理目录")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        // ⚠️ 这里**故意不用 `List(selection:)`**。
        //
        // 用 selection 绑定时，macOS 会在行上**另外画一层系统选中态**（强调色实底 + 白字），
        // 而且 `listRowBackground` **清不掉它** —— 于是"我们自绘的浅底"和"系统的深蓝实底"
        // 会同时出现在不同行上，看着就像"突然冒出一个蓝条"（用户截图里两行同时高亮就是它）。
        //
        // 去掉 selection 之后：选中完全由行内自绘（`TOCRowView` 的 background），
        // 顺带把 List 那个**会和拖拽打架**的选择手势也一起拿掉了。
        // 键盘 Delete 不受影响 —— 主路径一直是全局键盘监听转发（`tocDeleteRequestTick`）。
        List {
            ForEach(visibleRows) { row in
                TOCRowView(
                    row: row,
                    viewModel: viewModel,
                    isSelected: selection == row.id,
                    isRenaming: renaming == row.id,
                    isCollapsed: collapsed.contains(row.id),
                    hint: dropHint?.id == row.id ? dropHint?.position : nil,
                    menuState: menuState(for: row),
                    dragState: dragState,
                    draftTitle: $draftTitle,
                    dropHint: $dropHint,
                    renameFocus: $renameFocused,
                    actions: actions(for: row)
                )
                // 只在**这一行自己**的显示内容真的变了时才重新求值。
                // 没有它的话，拖拽时落点提示每变一次、整列表的可见行都要重建一遍
                // （每行还挂着 contextMenu，重建要构造 NSMenu）—— 那就是"一顿一顿"。
                .equatable()
                // 行自己的内边距已经给足，别让 List 再套一层（否则行高不可控）
                .listRowInsets(EdgeInsets())
                // 截图里行之间那些细线是 List 的默认分隔线，这里不需要
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // ── 拖到**行的下方空白**松手 = 追加到顶层末尾（v1.3.36 恢复） ──
        //
        // ⚠️ v1.3.34 曾把这个兜底删掉（当时怀疑它和行内的 drop 打架）。删错了 ——
        // 它其实承担着**一个真实功能**：
        //
        // `List` 会占满剩余高度，目录项少的时候下面留着一大片空白。而用户
        // "把某一项移到最后"最自然的动作，就是**往那片空白上拖**。
        // 没有这一条，那次拖拽就**没有任何目标接受**（日志里明明白白：
        // `拖拽会话结束：operation=0（没有任何目标接受）`，然后什么也不发生）——
        // 杰哥报的「倒数第二条要移动到最后一条，一直不能成功，但其他的可以」
        // 正是它（其他行拖到**最后一条本身上**就有效，只有"往底部空白拖"没反应）。
        //
        // 至于"父子两层都当拖拽目标会打架"：AppKit 的拖拽只会发给**最深的那个**
        // 接受者 —— 鼠标在某一行上就只调那一行的 delegate，落在空白处才轮到
        // `List`。两者互斥，不存在谁先谁后。（v1.3.33 那次看到的"父子抢"
        // 是看门狗提前清掉载荷造成的，那个根因已经单独修掉了。）
        .onDrop(of: [.utf8PlainText], isTargeted: nil) { _ in
            guard let id = dragState.id,
                  let moving = viewModel.tocRows.first(where: { $0.id == id }) else {
                if dropHint != nil { dropHint = nil }
                return true
            }
            Diagnostics.shared.record("拖到列表空白处 → 移到最后：「\(moving.title.prefix(12))」")
            // 和 `performDrop` 一样：数据变更留到下一轮主队列，
            // 先让系统的拖拽收尾做完（见 performDrop 里的说明）
            DispatchQueue.main.async {
                viewModel.moveTOCEntry(moving, relativeTo: nil, as: .after)
            }
            if dropHint != nil { dropHint = nil }
            dragState.id = nil
            return true
        }
        // Delete / 退格键：主路径是键盘监听转发（`.onDeleteCommand` 要焦点，靠不住），
        // 这里留一份兜底，两处走同一个删除入口、不会重复。
        .onDeleteCommand {
            if let row = selectedRow { delete([row]) }
        }
        .onChange(of: viewModel.tocDeleteRequestTick) { _, _ in
            if let row = selectedRow { delete([row]) }
        }
    }

    /// 选中某一行并跳过去（单击）。
    ///
    /// 这里**直接同步做**是安全的：`onTapGesture` 是事件回调，不在视图求值期间 ——
    /// 和 `Binding` 的 `set` 里那种"在更新过程中改状态"的情况不同。
    private func select(_ row: PDFViewModel.TOCRow) {
        // 记一条点击。用户报"拖完点其他目录没反应" —— 有这一条就能区分
        // "点击根本没到达视图"（事件被吞）和"到了但没反应"（逻辑问题）。
        Diagnostics.shared.record("点击目录项「\(row.title.prefix(14))」")
        selection = row.id
        // 让键盘监听知道现在选了哪一条（普通属性，不进 SwiftUI 的依赖跟踪）
        viewModel.tocSelectedID = row.id
        // 正在改名时不要跳（会把输入打断）
        guard renaming == nil else { return }
        viewModel.goToTOCEntry(row)
    }

    private func toggleCollapse(_ row: PDFViewModel.TOCRow) {
        if collapsed.contains(row.id) { collapsed.remove(row.id) }
        else { collapsed.insert(row.id) }
    }

    /// 盯住落点提示，鼠标一松就收掉。
    ///
    /// 为什么需要这个 —— 拖拽**正常落在某一行**时 `performDrop` 会清提示，
    /// 鼠标从一行移到另一行时 `dropExited` 也会清，但下面两种情况**没有任何回调**：
    ///
    /// - 按 Esc 取消拖拽；
    /// - 把鼠标拖到列表外面（比如 PDF 页面上）再松手。
    ///
    /// 那之后提示线会一直留在画面上 —— 用户看到的就是"突然出现一个蓝色横条"。
    /// 这里用"鼠标还按不按着"判断拖拽是否已经结束：松手了就补一次清理。
    ///
    /// 拖拽进行期间它每 0.12 秒只看一眼、**不写任何状态**（所以不引起重绘）；
    /// 提示被清掉后下一轮自己退出，不会空转。
    private func startDropHintWatchdog() {
        dropHintWatchdog?.cancel()
        let work = DispatchWorkItem { [self] in
            // 提示已经没了 → 收工（正常路径就是从这里退出的）
            guard dropHint != nil else {
                dropHintWatchdog = nil
                return
            }
            if NSEvent.pressedMouseButtons == 0 {
                // 鼠标松开了、提示却还在 → 这次拖拽是被取消或在列表外结束的
                dropHint = nil
                dropHintWatchdog = nil

                // ⚠️ "谁在拖"**不能立刻清**，要等一小会儿。
                //
                // 松开鼠标和 `performDrop` 之间隔着 AppKit 的收尾和 SwiftUI 的下一帧，
                // 实测能差出 100 毫秒以上。这里立刻清掉的话，正好把本次 drop 的载荷
                // 抹了 —— 行的 `performDrop` 就会报「找不到被拖的行」并返回 false，
                // 而 false 又会让 AppKit 认为没人接受这次拖拽（会话悬着 → 鼠标几秒失灵）。
                //
                // 等 1.5 秒再清；清之前核对一次时间戳 —— 这期间要是用户已经起了新的一次
                // 拖动（`onDrag` 会更新 `idSetAt`），就说明这是新载荷，不能动它。
                let stamp = dragState.idSetAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    if dragState.idSetAt == stamp {
                        dragState.id = nil
                    }
                }
            } else {
                startDropHintWatchdog()      // 还按着，继续盯着
            }
        }
        dropHintWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 右键菜单里各项的可用性。
    ///
    /// ⚠️ 这些东西**必须参与 `TOCRowView.==` 的比较**：菜单现在建在行 body 内部
    /// （否则 `.equatable()` 拦不住它重建），一旦漏比，菜单就会出现"该灰的不灰"。
    private func menuState(for row: PDFViewModel.TOCRow) -> TOCRowMenuState {
        TOCRowMenuState(
            isEditable: viewModel.isEditable,
            canIndent: viewModel.canIndent(row),
            canOutdent: viewModel.canOutdent(row),
            canMoveUp: sibling(of: row, offset: -1) != nil,
            canMoveDown: sibling(of: row, offset: 1) != nil,
            currentPageIndex: viewModel.currentPageIndex
        )
    }

    private func actions(for row: PDFViewModel.TOCRow) -> TOCRowActions {
        TOCRowActions(
            tap: { select(row) },
            toggleCollapse: { toggleCollapse(row) },
            beginRename: { beginRename(row) },
            commitRename: { commitRename(row) },
            cancelRename: { renaming = nil },
            goTo: { viewModel.goToTOCEntry(row) },
            retarget: { viewModel.retargetTOCEntry(row, pageIndex: viewModel.currentPageIndex) },
            indent: { viewModel.indentTOCEntry(row) },
            outdent: { viewModel.outdentTOCEntry(row) },
            moveUp: { moveUp(row) },
            moveDown: { moveDown(row) },
            delete: { delete([row]) }
        )
    }


    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    newTitle = selectedRow.map { $0.title } ?? "第 \(viewModel.currentPageIndex + 1) 页"
                    selectionHint = nil
                    showAddSheet = true
                } label: {
                    Label("新增目录项", systemImage: "plus")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        // ⚠️ 把 `frame` 撑出来的**空白**也算进命中区。
                        // 不加的话命中区只有"图标 + 文字"那一小条，点按钮两侧就落空
                        //（和 `AnnotationPalette.toolButton` 是同一个坑）。
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                .disabled(!viewModel.isEditable)
                .help("在选中的那一条后面插入一条目录项，目标默认是当前页")

                Button {
                    addFromSelectionOrAsk()
                } label: {
                    Label("用选中文字", systemImage: "text.cursor")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                // ⚠️ 这里**不能**按"当前有没有选区"来置灰：选区变化不会触发 SwiftUI 刷新，
                // 按钮会一直灰着（用户选了字也不会亮）。改成永远可点，
                // 没选区时走"新增目录项"那张表单并把话说清楚。
                .disabled(!viewModel.isEditable)
                .help("把页面上选中的文字做成一条目录项（标题取自选中文字，位置也一起记住）")
            }

            HStack(spacing: 6) {
                Button {
                    if let row = selectedRow { viewModel.outdentTOCEntry(row) }
                } label: {
                    Label("升级", systemImage: "arrow.left")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                .disabled(!viewModel.isEditable || !(selectedRow.map(viewModel.canOutdent) ?? false))

                Button {
                    if let row = selectedRow { viewModel.indentTOCEntry(row) }
                } label: {
                    Label("降级", systemImage: "arrow.right")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                .disabled(!viewModel.isEditable || !(selectedRow.map(viewModel.canIndent) ?? false))

                Button(role: .destructive) {
                    if let row = selectedRow { delete([row]) }
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .controlSize(.small)
                .disabled(!viewModel.isEditable || selectedRow == nil)
            }

            HStack(spacing: 6) {
                if let notice = viewModel.autoSaveNotice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(notice.hasPrefix("自动保存失败") ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(statusHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    showPreferences = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("保存与备份设置")
            }
        }
        .padding(8)
    }

    /// 面板底部那行说明（有未保存改动时先说这件事）
    private var statusHint: String {
        guard viewModel.isEditable else { return "只读模式：点顶部「编辑」后可整理目录" }
        if unsavedChanges.value {
            return AppPreferences.shared.autoSaveOutline
                ? "有未保存的改动（稍后会自动写入）"
                : "有未保存的改动 · 按 ⌘S 写入，或关闭时选择保存"
        }
        let gesture = "拖动可同级调序，拖到某一条的中段可变成它的子项"
        return AppPreferences.shared.autoSaveOutline
            ? "\(gesture) · 改动会自动保存"
            : "\(gesture) · 改动在「保存批注到 PDF」（⌘S）时写进文件"
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增目录项").font(.headline)
            TextField("标题", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { commitAdd() }
            Text(selectionHint ?? (selectedRow == nil
                 ? "会追加到目录末尾，目标：第 \(viewModel.currentPageIndex + 1) 页"
                 : "会插在「\(selectedRow?.title ?? "")」后面，目标：第 \(viewModel.currentPageIndex + 1) 页"))
                .font(.caption)
                .foregroundStyle(selectionHint == nil ? .secondary : .primary)
            HStack {
                Spacer()
                Button("取消") { showAddSheet = false }
                Button("添加") { commitAdd() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - 行为

    private func beginRename(_ row: PDFViewModel.TOCRow) {
        guard viewModel.isEditable else { return }
        selection = row.id
        viewModel.tocSelectedID = row.id
        draftTitle = row.title
        renaming = row.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ row: PDFViewModel.TOCRow) {
        viewModel.renameTOCEntry(row, to: draftTitle)
        renaming = nil
    }

    private func commitAdd() {
        showAddSheet = false
        viewModel.addTOCEntry(title: newTitle,
                              pageIndex: viewModel.currentPageIndex,
                              point: nil,
                              after: selectedRow)
    }

    /// 「用选中文字」：有选区就用选区；没选区就把"新增目录项"那张表单打开（并提示先选字）
    private func addFromSelectionOrAsk() {
        if viewModel.addTOCEntryFromSelection(after: selectedRow) { return }
        newTitle = "第 \(viewModel.currentPageIndex + 1) 页"
        selectionHint = "没有选中文字 —— 先在页面上选一行字，再点「用选中文字」；"
            + "或者直接在这里填标题（目标为当前页）。"
        showAddSheet = true
    }

    private func delete(_ rows: [PDFViewModel.TOCRow]) {
        for row in rows {
            viewModel.removeTOCEntry(row)
            if selection == row.id {
                selection = nil
                viewModel.tocSelectedID = nil
            }
        }
    }

    /// 同一层里相邻的第 `offset` 个兄弟；跨层 / 越界都返回 nil。
    ///
    /// 用 `tocRows`（全量）而不是 `visibleRows`：折叠起来看不见的兄弟也算数，
    /// 否则"展开后上移"和"折叠时上移"会得到不同结果。
    private func sibling(of row: PDFViewModel.TOCRow, offset: Int) -> PDFViewModel.TOCRow? {
        let rows = viewModel.tocRows
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        let target = index + offset
        guard rows.indices.contains(target), rows[target].depth == row.depth else { return nil }
        return rows[target]
    }

    private func moveUp(_ row: PDFViewModel.TOCRow) {
        guard let previous = sibling(of: row, offset: -1) else { return }
        viewModel.moveTOCEntry(row, relativeTo: previous, as: .before)
    }

    private func moveDown(_ row: PDFViewModel.TOCRow) {
        guard let next = sibling(of: row, offset: 1) else { return }
        viewModel.moveTOCEntry(row, relativeTo: next, as: .after)
    }
}

/// 目录列表里的一行。
///
/// 抽成独立类型**只为了一件事**：能加 `.equatable()`。
///
/// 拖拽时落点提示每变一次、`List` 里的可见行就要全部重算一遍，而每行都挂着
/// `contextMenu`（重建它要构造 NSMenu）—— 叠加起来就是"一顿一顿 / 卡卡的"，
/// 而且这种重绘本身还可能把**正在进行的拖拽会话**打断（表现是"突然就拖不动了"）。
///
/// 所以要记住三条：
/// - `==` 里必须列出**所有影响显示或菜单可用性**的东西，漏一个就会出现"该刷新的不刷新"；
/// - 闭包不参与比较（它们每次父视图重算都是新实例，比了等于永远不等）；
/// - `contextMenu` 也必须建在 body **内部** —— 建在外面的话，`==` 相等也拦不住它重建。
@MainActor
fileprivate struct TOCRowView: View, Equatable {
    let row: PDFViewModel.TOCRow
    let viewModel: PDFViewModel
    let isSelected: Bool
    let isRenaming: Bool
    let isCollapsed: Bool
    let hint: PDFViewModel.TOCDropPosition?
    let menuState: TOCRowMenuState
    let dragState: TOCDragState
    @Binding var draftTitle: String
    @Binding var dropHint: DropHint?
    let renameFocus: FocusState<Bool>.Binding
    let actions: TOCRowActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.isRenaming == rhs.isRenaming
            && lhs.isCollapsed == rhs.isCollapsed
            && lhs.hint == rhs.hint
            && lhs.menuState == rhs.menuState
    }

    var body: some View {
        // 数一下行 body 到底被求值了多少次（`flushCounters` 会写进日志）。
        // 拖一次目录之后如果这个数字是几十上百，说明"一次拖动 = 整列表重建" ——
        // 那就是"拖完要等两秒"最可能的来源。
        let _ = Diagnostics.shared.count("目录行 body 求值")
        HStack(spacing: 4) {
            // 缩进（层级）
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)

            if row.hasChildren {
                Button(action: actions.toggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        // ⚠️ **热区要比图标大得多。**
                        //
                        // 原来只有 14×14、图标本身 9pt —— 按偏一两个点就没反应，
                        // 用户的原话是"折叠小三角偶尔点了没反应"。
                        // 20×20 是"鼠标能稳稳点中"的下限（人眼对 14pt 以下的
                        // 可点区域判断很不准）。图标仍然只有 10pt，所以看着没变化。
                        // `contentShape` 必须写：`Button` 的命中区默认只认**不透明**内容，
                        // 光有 frame 不算数。
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 占位宽度要和上面的按钮**一致**，否则同级行的标题会对不齐
                Color.clear.frame(width: 20, height: 1)
            }

            if isRenaming {
                TextField("目录项标题", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused(renameFocus)
                    .onSubmit(actions.commitRename)
                    .onExitCommand(perform: actions.cancelRename)
            } else {
                Text(row.title.isEmpty ? "(无标题)" : row.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // ⚠️ 这里**不能**在选中时改成强调色文字：底色本来就用强调色，
                    // 蓝底 + 蓝字会把标题糊得看不清（用户的原话是「文字都看不清」）。
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                dragTarget
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.12)
                      : (hint == .inside ? Color.accentColor.opacity(0.18) : Color.clear))
        )
        // 落点提示：前/后是同层插入 → 一条横线；里面 → 描个边。
        // **按需构建**（不再"常驻 + opacity 0"）：没提示时连视图都不建。
        .overlay(alignment: .top) { if hint == .before { dropLine } }
        .overlay(alignment: .bottom) { if hint == .after { dropLine } }
        .overlay {
            if hint == .inside {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onTapGesture(perform: actions.tap)
        .contextMenu { menu }
        .onDrop(of: [.utf8PlainText],
                delegate: TOCDropDelegate(row: row,
                                          viewModel: viewModel,
                                          dragState: dragState,
                                          dropHint: $dropHint))
    }

    /// 行尾的「页号 + 拖拽把手」。
    ///
    /// ⚠️ **拖拽热区必须是整块，不能只有那个小图标。**
    /// 一开始只把拖拽挂在 18pt 的图标上 —— 按偏一点点就完全起不了拖，
    /// 表现就是"有时候能拖、大部分拖不动"。现在热区是「页号 + 把手」这一整块
    /// （约 66×22），怎么按都能起手。
    ///
    /// 起手之后**拖到哪儿都行**：拖拽会话一旦开始就由系统接管，不受这块区域限制。
    ///
    /// ## v1.3.35：起拖改由 `TOCDragHandle`（AppKit）负责，不再用 `.onDrag`
    ///
    /// 原因见 `TOCDragHandleView` 的类型注释 —— 一句话：
    /// SwiftUI 的 `.onDrag` 在 drop 之后会把鼠标"扣住"一两秒（按下收得到、
    /// 抬起收不到、点击也不触发）。
    ///
    /// ## 这里也**不再挂 `.help`**
    ///
    /// 它原来挂在这块热区上，而用户拖完一松手，鼠标正好停在这块区域 ——
    /// AppKit 的 tooltip 管理器紧接着就开始计时。虽然 tooltip 本身不该吃事件，
    /// 但它和"刚拖完那一两秒点不动"的时间窗高度重合，属于没必要留的变量。
    /// 拖动说明在面板底部那行提示里本来就有（见 `statusHint`）。
    private var dragTarget: some View {
        HStack(spacing: 4) {
            Text("第 \(row.pageIndex + 1) 页")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .overlay {
            // 透明覆盖层，负责起拖 + 补一次单击
            TOCDragHandle(row: row,
                          viewModel: viewModel,
                          dragState: dragState,
                          onTap: actions.tap)
        }
    }

    private var dropLine: some View {
        // 粗一点（3pt）：这是"会插到哪一行"的唯一提示，细了等于没有
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var menu: some View {
        Button("跳转到该目录项") { actions.goTo() }
        Divider()
        Button("重命名") { actions.beginRename() }
            .disabled(!menuState.isEditable)
        Button("把目标改成当前页（第 \(menuState.currentPageIndex + 1) 页）") { actions.retarget() }
            .disabled(!menuState.isEditable)
        Divider()
        Button("降级（变成上一项的次级）") { actions.indent() }
            .disabled(!menuState.isEditable || !menuState.canIndent)
        Button("升级（和上一级并列）") { actions.outdent() }
            .disabled(!menuState.isEditable || !menuState.canOutdent)
        Divider()
        // 拖拽之外的备用通道：万一拖不动，至少还能靠菜单一项一项挪
        Button("上移") { actions.moveUp() }
            .disabled(!menuState.isEditable || !menuState.canMoveUp)
        Button("下移") { actions.moveDown() }
            .disabled(!menuState.isEditable || !menuState.canMoveDown)
        Divider()
        Button("删除", role: .destructive) { actions.delete() }
            .disabled(!menuState.isEditable)
    }
}

/// 行右键菜单里各项的可用性。
///
/// 打包成一个 `Equatable` 值是为了能**整体参与 `TOCRowView.==`** ——
/// 菜单现在建在行 body 内部（否则 `.equatable()` 拦不住它重建），
/// 一旦漏比，菜单就会出现"该灰的不灰"。
fileprivate struct TOCRowMenuState: Equatable {
    let isEditable: Bool
    let canIndent: Bool
    let canOutdent: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let currentPageIndex: Int
}

/// 行的各种动作。
///
/// **故意不参与 `==`**：闭包每次父视图重算都是新实例，拿它们比较等于永远不相等，
/// `.equatable()` 就完全白加了。
fileprivate struct TOCRowActions {
    let tap: () -> Void
    let toggleCollapse: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let goTo: () -> Void
    let retarget: () -> Void
    let indent: () -> Void
    let outdent: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
}

/// 目录行的**拖拽把手**：自己用 AppKit 发起拖拽。
///
/// ## 为什么不用 SwiftUI 的 `.onDrag`
///
/// 实测（v1.3.34，杰哥机器上的诊断日志）—— `.onDrag` 在 drop 之后会进入一个
/// **"夹生"状态**：鼠标按下还能被事件监听记到，但**抬起收不到、点击也不触发**，
/// 连着点三四次都没用，要等一两秒才自己恢复：
///
/// ```
/// [17:29:58.584] performDrop：… 成功
/// [17:29:59.923] 鼠标按下 · 距上次放下 1338 ms     ← 按下了
/// [17:30:00.412] 鼠标按下 · 距上次放下 1827 ms     ← 又按（上一次的"抬起"根本没来）
/// [17:30:00.851] 鼠标按下 · 距上次放下 2266 ms
/// [17:30:01.467] 鼠标按下 · 距上次放下 2883 ms
/// [17:30:01.563] 鼠标抬起 · 距上次放下 2979 ms     ← 隔了近 3 秒才收到"抬起"
/// ```
///
/// 关键：这几次点击**都没有**触发 `拖放.onDrag 起手` —— 拖拽会话根本没建起来，
/// 鼠标却被拖拽机制**扣住**了（mouseUp 被它吃掉，`onTapGesture` 也轮不到）。
/// 主线程被同步的鼠标跟踪占着，连 runloop 观察器都跑不到 —— 所以日志里
/// **一条慢轮次都没有**，看着完全不像卡顿。
///
/// 自己实现就没这个问题：会话什么时候开始、什么时候结束，由
/// `draggingSession(_:endedAt:operation:)` 明确回调，中间不留夹生态。
///
/// ## 和 drop 那一端的兼容性
///
/// 载荷用 `NSItemProvider` 注册 `public.utf8-plain-text` ——
/// 这正是 SwiftUI `.onDrag` 内部做的事（它也是 `beginDraggingSession` +
/// `NSDraggingItem(pasteboardWriter: itemProvider)`）。所以 SwiftUI 的
/// `.onDrop(of: [.utf8PlainText])` 照常能接住，`TOCDropDelegate` 一行都不用改。
@MainActor
fileprivate final class TOCDragHandleView: NSView, NSDraggingSource {

    /// 按下之后移动多少才认定为"拖拽"（少于它就当单击，交给 `onTap`）
    private static let dragThreshold: CGFloat = 3

    /// 拖拽开始时取载荷（要放上剪贴板的字符串）；返回 nil 表示这次不起拖
    var makePayload: (() -> String?)?
    /// 会话结束（无论放没放下）
    var onSessionEnded: (() -> Void)?
    /// 没成拖拽（就当单击）→ 交给行去选中 / 跳转
    var onTap: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var dragging = false

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 仅供自动化：把手自己报个到，好让合成拖拽算得出"第几行在屏幕哪儿"
        DragHandleProbe.register(self)
    }

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

        // ⚠️ 用 `NSPasteboardItem` 而不是 `NSItemProvider`：
        // Swift 里 `NSItemProvider` **没有**暴露 `NSPasteboardWriting` 这层 conformance
        // （Objective-C 头文件里有，Swift 接口里没有），编译不过。
        // 而 `.string` 的类型标识就是 `public.utf8-plain-text` ——
        // 和 SwiftUI 的 `.onDrop(of: [.utf8PlainText])` 要的**完全一致**，
        // 所以 `TOCDropDelegate` 那边一个字都不用改。
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload, forType: .string)

        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let size = NSSize(width: max(bounds.width, 40), height: max(bounds.height, 20))
        let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        item.setDraggingFrame(NSRect(origin: .zero, size: size), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        guard !dragging else { dragging = false; return }
        // 没起拖 → 这是一次单击。行上的 `onTapGesture` 被我们挡住了（我们是覆盖层），
        // 所以在这里手动补一次。
        onTap?()
    }

    /// ⚠️ 我们是覆盖层，右键也会先到我们手上 —— 必须显式还回去，
    /// 否则行上的 `contextMenu`（重命名 / 降级 / 删除…）就点不出来了。
    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
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
        // `operation` 是"这次拖拽有没有被接受"的**明确答案**，而且只有自己控制
        // 拖拽源才拿得到（SwiftUI 的 `.onDrag` 没有对应回调）。
        // 空 = 没有任何目标接住 —— 要么用户松手时不在某一行上，
        // 要么 SwiftUI 的 `.onDrop` 没认 AppKit 发起的这次拖拽。一句话就能分开。
        Diagnostics.shared.record("拖拽会话结束：operation=\(operation.rawValue)"
                                  + (operation.isEmpty ? "（没有任何目标接受）" : "（已被接受）"))
        // 这是**明确的**会话结束信号 —— 拖放收尾的状态清理都挂在这里，
        // 顺序清楚、不留尾巴。
        onSessionEnded?()
    }
}

/// 仅供**自动化验证**：记录当前活着的拖拽把手，算出"屏幕上第几行在哪儿"。
///
/// 为什么需要它：合成一次拖拽要有坐标，而 SwiftUI 这一侧拿不到子视图的 frame
/// （`GeometryReader` 给的是布局坐标，不是屏幕坐标）。让把手自己把屏幕 frame
/// 报进这个弱引用表里就解决了 —— 正常使用**没有任何读取方**。
@MainActor
fileprivate enum DragHandleProbe {
    private static let table = NSHashTable<TOCDragHandleView>.weakObjects()

    static func register(_ view: TOCDragHandleView) {
        table.add(view)
    }

    /// 屏幕坐标（左上原点），按纵向从上到下排
    static func framesTopToBottom() -> [CGRect] {
        table.allObjects.compactMap { view -> CGRect? in
            guard let window = view.window, !view.isHidden, view.bounds.height > 0 else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        .sorted { $0.minY < $1.minY }
    }

    /// 把手所在的那个窗口
    static func hostWindow() -> NSWindow? {
        table.allObjects.compactMap { $0.window }.first
    }
}

/// 仅供**自动化验证**：用合成的鼠标事件真拖一次目录项。
///
/// 它回答的是本轮改动里**唯一的未知数** ——
/// 「SwiftUI 的 `.onDrop(of: [.utf8PlainText])` 能不能接住 AppKit
/// `NSDraggingSession` 发起的拖拽？」。载荷的类型标识两边都是
/// `public.utf8-plain-text`，理论上没问题，但这件事只有真拖一次才能确认。
///
/// ## ⚠️ 实测结论：这个合成**走不通**，留作记录
///
/// 试过两条路，都启动不了拖拽会话（日志里能看到"合成拖拽：…"，
/// 但**没有** `拖放.onDrag 起手`）：
///
/// 1. `CGEvent(...).postToPid(getpid())` —— 事件不经过 WindowServer，
///    鼠标的"按下状态"在系统层面根本没建立；
/// 2. 造 `NSEvent` + `NSApp.sendEvent(_:)` —— 位置和 windowNumber 都对，
///    `mouseDown` 也送到了，但随后的 `leftMouseDragged` 依然走不动。
///
/// 根子在于 `NSView.beginDraggingSession` 需要**真实的鼠标按下**（WindowServer
/// 那一层要认可），合成事件给不了。所以"SwiftUI 的 `.onDrop` 能不能接住
/// AppKit 的拖拽"这件事**只能靠真手拖一次来确认** —— 载荷的类型标识两边都是
/// `public.utf8-plain-text`，理论上没问题，但理论不算数。
///
/// 保留这段代码是因为它至少能把"把手在屏幕上的位置"打出来，排查时有用。
///
/// 发送本身是**分步异步**的（每步 40ms）：主线程必须能跑 runloop。
@MainActor
enum TOCDragProbe {
    static func simulateDrag() {
        let frames = DragHandleProbe.framesTopToBottom()
        guard frames.count >= 3, let window = DragHandleProbe.hostWindow() else {
            Diagnostics.shared.record("合成拖拽：把手不足（只有 \(frames.count) 个）")
            return
        }
        // 屏幕坐标 → 窗口坐标
        let from = window.convertPoint(fromScreen: CGPoint(x: frames[0].midX, y: frames[0].midY))
        let to = window.convertPoint(fromScreen: CGPoint(x: frames[2].midX, y: frames[2].minY + 2))
        Diagnostics.shared.record("合成拖拽：窗口内 \(from) → \(to)（共 \(frames.count) 个把手）")

        let total = 10
        var step = 0

        func tick() {
            if step > total {
                send(window, .leftMouseUp, to)
                Diagnostics.shared.record("合成拖拽：抬起（结束）")
                return
            }
            let t = CGFloat(step) / CGFloat(total)
            let point = CGPoint(x: from.x + (to.x - from.x) * t,
                                y: from.y + (to.y - from.y) * t)
            send(window, step == 0 ? .leftMouseDown : .leftMouseDragged, point)
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { tick() }
        }
        tick()
    }

    private static func send(_ window: NSWindow, _ type: NSEvent.EventType, _ location: CGPoint) {
        guard let event = NSEvent.mouseEvent(with: type,
                                             location: location,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: 1) else { return }
        NSApp.sendEvent(event)
    }
}

/// 把上面那个 AppKit 把手包成 SwiftUI 视图（透明覆盖层）。
@MainActor
fileprivate struct TOCDragHandle: NSViewRepresentable {
    let row: PDFViewModel.TOCRow
    let viewModel: PDFViewModel
    let dragState: TOCDragState
    /// 没成拖拽时（＝单击）回调
    let onTap: () -> Void

    func makeNSView(context: Context) -> TOCDragHandleView {
        TOCDragHandleView()
    }

    func updateNSView(_ view: TOCDragHandleView, context: Context) {
        // ⚠️ 闭包每次都要重绑：行会被重建，捕获的 `row` 必须是最新那一份
        view.makePayload = { [weak viewModel] in
            guard let viewModel else { return nil }
            Diagnostics.shared.count("拖放.onDrag 起手")
            Diagnostics.shared.record("拖放.onDrag 起手：「\(row.title.prefix(12))」")
            Diagnostics.shared.activity = "拖动目录起手"
            dragState.lastHintWrite = .distantPast
            dragState.id = row.id
            // 拖动期间暂停页码轮询（它会写 @Published → 全界面重算），见 `syncState`
            viewModel.tocInteractionUntil = Date().addingTimeInterval(1.0)
            return String(describing: row.id)
        }
        view.onTap = onTap
        view.onSessionEnded = {
            // 「这一下放下了」的时刻：鼠标监听据此报出"距上次放下多少毫秒"
            Diagnostics.shared.noteDropEnded()
        }
    }
}

/// 目录行的落点提示（哪一行、落在前 / 后 / 里面）
fileprivate struct DropHint: Equatable {
    let id: ObjectIdentifier
    let position: PDFViewModel.TOCDropPosition
}

/// "正在被拖的是哪一行"。
///
/// ⚠️ **故意用引用类型而不是 `@State`。** 用 `@State` 时，在 `onDrag` 闭包里赋值会触发
/// body 重算 —— 重算发生在**拖拽会话刚建立的那一刻**，列表一重建行，拖拽就可能直接断掉。
/// 换成引用类型后，"谁在拖"读得到、又不会引起重绘（`@State` 持的是这个对象的引用，
/// 改它内部的属性不触发视图更新）。
@MainActor
fileprivate final class TOCDragState {
    /// 正在被拖的那一行。写入时自动记下时刻（见 `idSetAt`）。
    var id: ObjectIdentifier? {
        didSet { idSetAt = Date() }
    }

    /// `id` 最后一次写入的时刻。
    ///
    /// 用来回答"这次 drop 用的还是不是同一个载荷"：`startDropHintWatchdog` 的延迟清理
    /// 会拿它跟清理前记下的时间戳比，不相等说明用户已经起了新的一次拖动，旧清理不该动手。
    private(set) var idSetAt = Date.distantPast

    /// 上次写落点提示的时刻 —— 给 `TOCDropDelegate.updateHint` 做节流用。
    /// 放在这个引用类型里（而不是 `@State`）：它变了**不该**引起重绘。
    var lastHintWrite = Date.distantPast
}

/// 目录行的拖放处理。
///
/// 落点按行内**纵向位置**分三段，跟文件管理器一个手感：
///
/// | 位置 | 效果 |
/// |------|------|
/// | 上 35% | 放到这一行**前面**（同级） |
/// | 中间 30% | 放进这一行**里面**（成为它的子项） |
/// | 下 35% | 放到这一行**后面**（同级） |
///
/// 真正能不能放由 `PDFViewModel.moveTOCEntry` 判定 —— 它会挡掉"拖到自己或自己的
/// 子孙里"这种会把树弄坏的情况（环检测在那边，不在界面层）。
fileprivate struct TOCDropDelegate: DropDelegate {
    let row: PDFViewModel.TOCRow
    let viewModel: PDFViewModel
    let dragState: TOCDragState
    @Binding var dropHint: DropHint?

    /// 行高按固定值估算：`DropInfo` **不给**被 drop 视图的尺寸，只能估。
    /// （`TOCRowView`：内容最高的是 22pt 的拖拽热区，上下各 6pt 内边距 → 约 34pt。）
    private static let assumedRowHeight: CGFloat = 34

    /// ⚠️ **只看"载荷类型对不对"，一个字都不要依赖 `dragState.id`。**
    ///
    /// 拖拽回调（`validateDrop` / `dropUpdated`）与 `onDrag` 闭包之间没有先后保证，
    /// 依赖它就变成"有时候能放、大部分放不了"（杰哥报过的症状）。而且 `dragState.id`
    /// 在两次拖动之间还可能残留上一轮的值 —— 一旦残留的正是这一行，这里就会**静默拒绝**
    /// 所有落点（前 / 后 / 里面都在同一行上），表现就是"这一行怎么拖都没反应"。
    ///
    /// "拖到自己或自己的子孙"这种真该拒绝的落点，`PDFViewModel.moveTOCEntry` 里
    /// 有环检测会挡掉。提示线那边也另有判断（`updateHint` 里的 `dragState.id != row.id`），
    /// 所以不会画出"能放"的假象。这里放开不会让任何坏事发生。
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        Diagnostics.shared.count("拖放.dropEntered")
        updateHint(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // ⚠️ `dropUpdated` 在拖动期间被调得**非常密**（每秒几十次）。
        // 这里只累加一个整数计数（`NSLock`，微秒级）；
        // 真正写 `dropHint` 要走 `updateHint` 的节流 —— 写一次就让列表重新求值一次。
        Diagnostics.shared.count("拖放.dropUpdated")
        // 拖动期间别让 0.3 秒一次的页码轮询插进来做全界面重算（见 `syncState` 的说明）。
        // 每帧都往后推 → 拖动全程有效；松手后 1 秒恢复，不能让页码"卡住不走"。
        viewModel.tocInteractionUntil = Date().addingTimeInterval(1.0)
        updateHint(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        Diagnostics.shared.count("拖放.dropExited")
        // ⚠️ 这里**故意不写 `dropHint = nil`**。
        //
        // 拖动时鼠标每离开一行都会调它，而写 `@State` = 让整个列表重新求值一次。
        // "离开"这件事不需要单独通知：鼠标进入下一行时 `dropEntered` 会直接把
        // `dropHint` 覆盖过去（提示只记一行；"谁在拖"另有一个引用类型在记）。
        // 唯一漏掉的情形是"从某一行直接拖到列表外" —— 那由 `startDropHintWatchdog` 兜底。
    }

    /// ⚠️ **无论结果如何都返回 `true`。**
    ///
    /// 这个返回值在 AppKit 那层的意思是"这次拖拽有没有人接手"。返回 `false`
    /// 等于"没人接受" —— 拖拽会话会悬在那里不走，随后几秒里鼠标的点击和拖动
    /// **全都失去响应**，直到系统超时。用户报的
    /// 「拖完点其他目录都没反应 / 点了也没反应、还得等几秒才能继续拖」就是它，
    /// 日志里对应的现场是 16:54:51 那次 `找不到被拖的行 → 当作没处理`（返回了 false）。
    ///
    /// 我们确实"处理了这一下"（只是可能选择不移动数据），所以一律按已处理收场。
    func performDrop(info: DropInfo) -> Bool {
        Diagnostics.shared.count("拖放.performDrop")
        Diagnostics.shared.activity = "放下目录项（写目录树 + 重载列表）"
        defer {
            // ⚠️ 只在真的有提示时才写 —— 写 `nil` 到已经是 `nil` 的 `@State`
            // 一样会让整列表重新求值一次，而这次求值正好挤在拖拽收尾那一帧里
            if dropHint != nil { dropHint = nil }
            dragState.id = nil
            // 记下"这一下放下了"的时刻：鼠标监听会据此报出"距上次放下多少毫秒"，
            // 用来判断拖完之后那两秒里鼠标事件到底有没有到达（见 Diagnostics.recordMouse）
            Diagnostics.shared.noteDropEnded()
            // 这次拖动引起的「列表重建」发生在**下一帧**，所以计数要延后一点再取 ——
            // 紧跟着取的话只会拿到 0，什么也说明不了。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Diagnostics.shared.flushCounters("放下一半秒后（含列表重建）")
            }
        }
        // 这一次拖动期间累计的拖放回调次数：异常多（几百上千）说明落点在反复触发重绘
        Diagnostics.shared.flushCounters("本次拖动期间")

        guard let id = dragState.id,
              let moving = viewModel.tocRows.first(where: { $0.id == id }) else {
            Diagnostics.shared.record("performDrop：找不到被拖的行（载荷已失效）→ 不动数据，按已处理收场")
            return true
        }
        let spot = position(for: info)

        // ⚠️ **数据变更放到下一轮主队列，不在 drop 回调里同步做。**
        //
        // 回调返回之后，SwiftUI / AppKit 还要给这次拖拽**收尾**（把拖拽快照归位、
        // 复位命中测试区域、结束内部会话状态）。我们一旦在这里同步改数据，
        // 列表内容会在**同一帧**里重排 —— 两件事挤在一起，收尾就容易留个尾巴，
        // 表现正是 v1.3.34 日志里那种"按下收得到、抬起收不到、点击不触发"的夹生态。
        // 挪到下一轮：先让收尾做完，再改数据。
        DispatchQueue.main.async {
            let started = Date()
            let ok = viewModel.moveTOCEntry(moving, relativeTo: row, as: spot)
            Diagnostics.shared.record(String(format: "performDrop：「%@」→ 落点=%@（第 %d 页）→ %@，数据层耗时 %.1f ms",
                                             String(moving.title.prefix(12)),
                                             String(describing: spot), row.pageIndex + 1,
                                             ok ? "成功" : "被拒（拖到自己 / 自己的子孙）",
                                             Date().timeIntervalSince(started) * 1000))
        }
        return true
    }

    /// 落点分三段。**两侧各给 35%、中间只留 30%** ——
    /// 早先按 25/50/25 分时，"插到某条前面/后面"只有 6pt 宽的一条带，
    /// 实际几乎命中不了（用户的原话是"大部分都拖动不了"，一半原因在这）。
    private func position(for info: DropInfo) -> PDFViewModel.TOCDropPosition {
        let y = info.location.y
        if y < Self.assumedRowHeight * 0.35 { return .before }
        if y > Self.assumedRowHeight * 0.65 { return .after }
        return .inside
    }

    /// 更新落点提示。两道闸：**值真的变了** + **距上次写入够久**。
    ///
    /// 拖到自己身上不给任何提示（那边也会拒绝），免得画一个"能放"的假象。
    private func updateHint(_ info: DropInfo) {
        guard dragState.id != row.id else { return }
        let target = DropHint(id: row.id, position: position(for: info))
        guard dropHint != target else { return }
        // 100ms 的粒度人眼仍然看不出来（拖拽本身只关心"落到哪一段"，不关心刷新率），
        // 但能把拖动途中的重绘次数压下来一半以上 —— 实测一次拖动里
        // `dropUpdated` 会被调 30~280 次，每次写 `dropHint` 就是一次整列表求值。
        let now = Date()
        guard now.timeIntervalSince(dragState.lastHintWrite) >= 0.10 else { return }
        dragState.lastHintWrite = now
        dropHint = target
    }
}

// MARK: - 书签

@MainActor
struct BookmarkSidebar: View {
    let documentURL: URL
    @ObservedObject var viewModel: PDFViewModel
    @ObservedObject var store = BookmarksStore.shared

    /// 待删除的书签，等确认弹窗后才真删（多选时用）
    @State private var pendingDeletions: [BookmarksStore.Bookmark] = []

    /// 列表里的多选（用 `Bookmark.id` 当 tag）。
    ///
    /// 用 `List(selection:)` 而不是自己抓点击 —— Cmd 点选、Shift 范围选系统都替我们做好了。
    /// 代价是**这一层不能再挂 `onTapGesture`**（它会吃掉点击、让 List 收不到选择事件，
    /// 多选就永远触发不了）：所以「点了就跳转」改由 `listSelection` 这个 Binding 的 `set` 承担。
    @State private var selection = Set<UUID>()

    var documentBookmarks: [BookmarksStore.Bookmark] {
        store.bookmarks(for: documentURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            if documentBookmarks.isEmpty {
                Spacer()
                Image(systemName: "bookmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("暂无书签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Text("在工具栏点书签图标，把当前页加进来")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Spacer()
            } else {
                list
                Divider()
                toolbar
            }
        }
        // 侧边栏切走时视图会销毁，但 viewModel 上的计数**不会自己归零** ——
        // 留着的话，切到别的面板后按 Delete 会去打一个已经不存在的列表（被吞掉、什么都不发生）。
        .onDisappear {
            viewModel.bookmarkListSelectionIDs = []
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) {
                delete(pendingDeletions)
            }
            Button("取消", role: .cancel) {
                pendingDeletions = []
            }
        } message: {
            Text(deleteAlertMessage)
        }
    }

    // MARK: - 列表

    private var list: some View {
        List(selection: listSelection) {
            ForEach(documentBookmarks) { bookmark in
                row(bookmark)
                    .tag(bookmark.id)
                    // 常量 —— 作用是清掉系统默认的选中底色，选中底色画在行内
                    // （和批注列表同一套做法，见 AnnotationSidebar）
                    .listRowBackground(Color.clear)
                    .contextMenu { contextMenu(for: bookmark) }
            }
        }
        .listStyle(.plain)
        // Delete / 退格键删除。
        //
        // ⚠️ **主路径不是这里，而是键盘监听**：`onDeleteCommand` 要列表拿到焦点才触发，
        // 而焦点一般在 PDF 视图那边。真正生效的是 `bookmarkDeleteRequestTick`
        // （`EditablePDFView` 的全局键盘监听看到 Delete、且书签栏有选中时 +1）。
        // 这里留一份只为兜底，两处共用同一个确认弹窗，不会重复触发（监听会吞掉事件）。
        .onDeleteCommand {
            requestDeleteOfSelection()
        }
        .onChange(of: viewModel.bookmarkDeleteRequestTick) { _, _ in
            requestDeleteOfSelection()
        }
    }

    /// 列表选择 —— **跳转写在这里，不写在 `onChange` 里**。
    ///
    /// `onChange` 的语义是"视图更新**之后**"才回调，也就是下一帧；写在 `set` 里，
    /// 选中态和翻页落在同一次更新，不会先闪一下再跳（与批注列表同理）。
    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                // 告诉键盘监听现在选了什么（普通属性，它在视图更新过程中被写入）
                viewModel.bookmarkListSelectionIDs = newValue

                // 只有"恰好选中一条"才跳转 —— 多选是批量操作，别把页面拽来拽去
                guard newValue.count == 1, let id = newValue.first,
                      let bookmark = documentBookmarks.first(where: { $0.id == id }) else { return }
                viewModel.goToPage(at: bookmark.pageIndex)
            }
        )
    }

    /// 一行书签。
    ///
    /// 视觉语义与批注列表统一：**整行底色只表示"选中"**，
    /// 「这条就是当前页」改用左侧一根 3pt 竖条 —— 两种状态不再抢同一套视觉语言。
    private func row(_ bookmark: BookmarksStore.Bookmark) -> some View {
        let isSelected = selection.contains(bookmark.id)
        let isCurrentPage = viewModel.currentPageIndex == bookmark.pageIndex

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isCurrentPage ? Color.accentColor.opacity(0.55) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 1)

            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                // 选中只由行底色表达（强调色文字压在强调色底上会糊）
                .foregroundStyle(isCurrentPage ? Color.primary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Text(bookmark.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                delete([bookmark])
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                // 0.12：和批注列表、目录面板统一，选中看得出来又不压文字
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    @ViewBuilder
    private func contextMenu(for bookmark: BookmarksStore.Bookmark) -> some View {
        Button("跳转到该页") {
            viewModel.goToPage(at: bookmark.pageIndex)
        }
        Divider()
        Button("删除", role: .destructive) {
            delete([bookmark])
        }
        if selection.count > 1, selection.contains(bookmark.id) {
            Button("删除选中的 \(selection.count) 条", role: .destructive) {
                pendingDeletions = selectedBookmarks
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            if !selection.isEmpty {
                Button(role: .destructive) {
                    pendingDeletions = selectedBookmarks
                } label: {
                    Label("删除选中的 \(selection.count) 条", systemImage: "trash")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            Text("按 Delete 或退格键也能删除选中的")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
    }

    // MARK: - 派生状态

    /// 当前选中的书签（按列表顺序）
    private var selectedBookmarks: [BookmarksStore.Bookmark] {
        documentBookmarks.filter { selection.contains($0.id) }
    }

    private var deleteAlertTitle: String {
        pendingDeletions.count > 1 ? "确认删除这 \(pendingDeletions.count) 个书签？" : "确认删除书签？"
    }

    private var deleteAlertMessage: String {
        let titles = pendingDeletions.map { "· \($0.title)" }
        var text = titles.prefix(8).joined(separator: "\n")
        if titles.count > 8 {
            text += "\n…共 \(titles.count) 个"
        }
        return text
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeletions.isEmpty },
            set: { if !$0 { pendingDeletions = [] } }
        )
    }

    // MARK: - 行为

    /// 键盘监听发来的删除请求，或者列表自己的 `onDeleteCommand`。
    ///
    /// 只选了一条就直接删（和行尾那个 ✕ 一致，不必多一次确认）；
    /// 多条才弹确认框 —— 一次清掉一批书签值得先问一句。
    private func requestDeleteOfSelection() {
        let items = selectedBookmarks
        guard !items.isEmpty else { return }
        if items.count == 1 {
            delete(items)
        } else {
            pendingDeletions = items
        }
    }

    /// 删除并清掉选择（**统一走 viewModel**，这样工具栏那个书签图标会立刻刷新）。
    private func delete(_ items: [BookmarksStore.Bookmark]) {
        let ids = items.map(\.id)
        viewModel.removeBookmarks(ids)
        selection.subtract(ids)
        // 直接改 `@State` 绕过了 Binding 的 `set`，计数要顺手补上
        viewModel.bookmarkListSelectionIDs = selection
        pendingDeletions = []
    }
}

// MARK: - 保存与备份设置（v1.3.25）

/// 「保存与备份」设置面板。
///
/// 两个入口指向同一个视图：
/// ① app 菜单的「设置…」（⌘,，由 `Settings` scene 提供）；
/// ② 目录面板底部的齿轮按钮（sheet）。
/// 备份位置是**跨文档**的偏好，所以不挂在某个标签页的 viewModel 上（见 `AppPreferences`）。
@MainActor
struct SavePreferencesView: View {
    @ObservedObject private var preferences = AppPreferences.shared

    /// 备份位置的二选一（`usesCustomBackupDirectory` 是派生值，得包一层才好绑）
    private enum BackupLocation: Hashable {
        case besideOriginal
        case custom
    }


    /// 颜色选择和偏好之间搭一座桥：偏好里存的是 hex 字符串（好持久化、好迁移），
    /// 而 `ColorPicker` 要的是 `Color`。
    private var chromeColorBinding: Binding<Color> {
        Binding(get: { preferences.chromeColor },
                set: { preferences.chromeColorHex = $0.hexString })
    }

    /// 页面底色的选择器桥 —— 和上面那个同一套路（偏好里存 hex，选择器要 `Color`）。
    private var pageBackgroundBinding: Binding<Color> {
        Binding(get: { preferences.pageBackgroundColor },
                set: { preferences.pageBackgroundHex = $0.hexString })
    }

    var body: some View {
        Form {
            Section("保存") {
                Toggle("关闭文档时提醒我保存", isOn: $preferences.promptToSaveOnClose)
                Text("有没保存的改动时，关闭标签或退出会先问一句「保存 / 不保存 / 取消」。"
                     + "关掉它之后，关闭文档不会保存任何东西 —— 记得自己按 ⌘S。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("改动后自动保存（不推荐）", isOn: $preferences.autoSaveOutline)
                Text("默认关闭。开启之后，每改一下（停手约 1 秒）就把**整份 PDF 重写一遍** —— 写盘是同步的，文件大了会有几百毫秒的停顿，编辑时就是一顿一顿的。建议还是用 ⌘S，或者靠上面的关闭提醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("备份") {
                Toggle("手动保存时创建备份", isOn: $preferences.backupEnabled)
                Text("备份副本命名成「文件名-备份-时间戳.pdf」。"
                     + "自动保存（若开启）不会创建备份 —— 它靠「先写临时文件、确认没问题再替换」"
                     + "保证安全，写失败时原文件不会有任何改动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("备份位置", selection: backupLocation) {
                    Text("原文件旁边").tag(BackupLocation.besideOriginal)
                    Text("指定目录").tag(BackupLocation.custom)
                }
                .pickerStyle(.radioGroup)
                .disabled(!preferences.backupEnabled)

                HStack(spacing: 8) {
                    Text(preferences.backupDirectoryDisplayPath ?? "还没选目录")
                        .font(.caption)
                        .foregroundStyle(preferences.usesCustomBackupDirectory ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(preferences.backupDirectoryDisplayPath ?? "")
                    Spacer(minLength: 8)
                    Button("选择…") { preferences.chooseBackupDirectory() }
                    Button("清除") { preferences.clearBackupDirectory() }
                        .disabled(!preferences.usesCustomBackupDirectory)
                }
                .disabled(!preferences.backupEnabled)

                if let notice = preferences.backupDirectoryNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("外观") {
                ColorPicker("界面外框颜色", selection: chromeColorBinding, supportsOpacity: false)
                Text("工具栏和左右侧栏的底色。默认是一档浅灰 —— 和内容页的白拉开距离，"
                     + "界面和文档才分得清。想换随时换，改完立刻生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("恢复默认颜色") { preferences.resetChromeColor() }
                        .disabled(preferences.chromeColorHex.isEmpty)
                    Spacer()
                }

                Divider()

                ColorPicker("页面背景色", selection: pageBackgroundBinding, supportsOpacity: false)
                Text("文档页面背后那一层，也是透明图片的透明区域显示成什么颜色。"
                     + "默认跟随系统（浅色白 / 深色近黑）。"
                     + "拿透明 PNG 分不清哪儿是透明、哪儿是白底的时候，"
                     + "把这里调成浅灰，透明的地方立刻变灰，一眼就分出来了。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("恢复默认（跟随系统）") { preferences.resetPageBackground() }
                        .disabled(preferences.pageBackgroundHex.isEmpty)
                    Spacer()
                }
            }

            Section("批注") {
                TextField("作者名", text: $preferences.annotationAuthor)
                Text("新建的批注会署上这个名字（写进 PDF 标准里的作者栏），"
                     + "别人用 Adobe / 预览打开能看到「这条是谁标的」。"
                     + "留空就不署名。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 诊断：默认关（Release），要用的时候自己打开；外加版本号 —— 反馈问题时先看这两样
            Section("诊断") {
                HStack {
                    Text("版本")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AppInfo.version)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)

                Toggle("记录诊断日志（排查问题时打开）", isOn: $preferences.diagnosticsEnabled)
                Text("**默认关闭**（Release 版本一律关着），一切以效率优先：关掉时不建日志文件、不装主线程看门狗、不起卡死检测线程、也不监听鼠标事件。排查「操作卡顿」「关闭不提示保存」这类问题时打开它，日志会记下主线程卡了多久、当时在干什么、关闭时的判定过程 —— **改完立即生效，不用重启**。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("日志文件")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.logURL])
                    }
                    .controlSize(.small)
                    .disabled(!preferences.diagnosticsEnabled)
                }
                .font(.caption)

                Text("顺带一提：**崩溃兜底一直开着**，跟上面这个开关无关 —— 它平时不花任何时间，只在进程要崩的那一刻把调用栈记下来。诊断关着时它写进系统日志（Console.app 里能看），开着时写进上面这个文件。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // 高度够放下「页面背景色」+「诊断」那两组（v1.3.68）；超了 Form 自己会滚
        .frame(width: 460, height: 700)
    }

    private var backupLocation: Binding<BackupLocation> {
        Binding(
            get: { preferences.usesCustomBackupDirectory ? .custom : .besideOriginal },
            set: { choice in
                switch choice {
                case .besideOriginal:
                    preferences.clearBackupDirectory()
                case .custom:
                    // 选了「指定目录」就顺手弹面板 —— 不选目录的话这个选项没有意义
                    preferences.chooseBackupDirectory()
                }
            }
        )
    }
}
