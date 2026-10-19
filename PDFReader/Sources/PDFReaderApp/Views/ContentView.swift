import SwiftUI
import AppKit

/// 一个窗口 = 一个文件（v1.3.40）。
///
/// **不再有自绘的标签栏** —— 多文件改由 macOS 的**系统窗口标签页**承担：
/// 每打开一个文件就开一个同类型的窗口，系统自动并成标签栏（`+` 新建、拖动重排、
/// ⌘W 关当前标签，全是系统白给的）。
///
/// 这么改的直接好处：**每个文件有自己的 PDFView**，"切标签回来位置/缩放变了、
/// 脏标记丢了"那类问题从根上不存在（v1.3.38 修的其实就是它的症状）。
@MainActor
struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    /// 开新标签页要用（AppKit 那边的入口够不到环境值，只能从这里转交给 `AppModelBridge`）
    @Environment(\.openWindow) private var openWindow
    /// 观察偏好：用户在设置里改了外框颜色要立刻生效
    @ObservedObject private var preferences = AppPreferences.shared

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 顶栏：只读/编辑开关 · 常用操作 · 右上角搜索框
                ToolbarView(viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // 外框色（比内容页的白明显深一档）—— 见 `AppChrome`
                    .background(preferences.chromeColor)

                Divider()

                // 标注工具条：只在编辑模式出现
                if let tab = viewModel.selectedTab {
                    AnnotationPaletteHost(tab: tab)
                }

                // 主内容区
                if let tab = viewModel.selectedTab {
                    DocumentLayout(tab: tab)
                } else {
                    EmptyStateView(viewModel: viewModel)
                }
            }

            // ⚠️ 「页面管理」铺在**这一层**（不是 `PDFContentView` 里面）——
            // 它要把顶栏、标注工具条、左右侧边栏**一起盖住**，只留窗口标题栏那一排。
            // 系统窗口标签页长在标题栏上（多文件靠它切换），挡了就没法切文件了，
            // 所以高度就到这里为止。
            if let tab = viewModel.selectedTab {
                PageManagerOverlay(tab: tab)
            }
        }
        .onAppear {
            // 把 `openWindow` 动作交给 AppKit 那侧（菜单 / Finder 打开文件要靠它开新标签页）。
            // 放在这里而不是 accessor 里：`.onAppear` 一定早于"用户去点菜单"，
            // 而窗口本身的登记（异步、要等窗口存在）走下面的 `DocumentWindowAccessor`。
            AppModelBridge.openWindowAction = openWindow
            // ⚠️ 顺序要紧：**先认领、再补开**。
            // 本窗口（刚出现的这个）先把队列里的第一个拿走，剩下的才需要另开窗口 ——
            // 反过来的话，"本窗口能装的那个"也会被算成"没人管"，白白多开一个窗口。
            if let url = DocumentOpener.claim() {
                viewModel.addDocument(at: url)
            }
            DocumentOpener.drainIfNeeded()
            updateWindowTitle()
        }
        // 窗口标题（也就是系统标签栏上显示的字）跟着当前文件走
        .onChange(of: viewModel.selectedTabID) { _, _ in updateWindowTitle() }
        .onChange(of: viewModel.tabs.count) { _, _ in updateWindowTitle() }
        // 把这个窗口登记成"文档窗口"：关闭确认只该拦它。
        // 不登记的话，关一下设置窗口（⌘,）都会弹"要不要保存 PDF 改动"。
        .background(DocumentWindowAccessor(viewModel: viewModel))
        // 打开失败不再静默 —— 否则用户只会看到"点了没反应"
        .alert(
            "无法打开文件",
            isPresented: Binding(
                get: { viewModel.openFailure != nil },
                set: { if !$0 { viewModel.openFailure = nil } }
            ),
            presenting: viewModel.openFailure
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { url in
            Text("「\(url.lastPathComponent)」无法读取内容。\n\n如果它来自「最近打开」，多半是访问权限已失效——用「打开文件」重新选一次该文件就会恢复。")
        }
    }

    /// 窗口标题 = 当前文件的**文件名（不带扩展名）**。
    ///
    /// 这里这个 `title` 就是**系统标签栏上显示的字** —— 所以它决定了标签长什么样。
    /// 一个 PDF 阅读器里放的几乎都是 `.pdf`，后缀纯属占地方；系统标签栏本身
    /// 鼠标悬停会补全路径，同名也能分清。
    ///
    /// 触发点：打开文件 / 关掉文件 / 认领到一个文件。
    /// ⚠️ 一定要写**这个窗口**（`DocumentWindowAccessor` 登记的那一个），
    /// 不能再写 `NSApp.keyWindow` —— 现在是多窗口，`onChange` 触发的那一刻
    /// key 窗口未必是发起者，写错了会把**别的标签**的名字改掉。
    func updateWindowTitle() {
        guard let window = AppModelBridge.window(of: viewModel) else { return }
        window.title = viewModel.selectedTab?.displayName ?? "PDF Free"
    }
}

/// 把"这个窗口 ↔ 这份 viewModel"登记给 `AppModelBridge`。
///
/// 登记用来回答两个问题：
/// 1. **关闭确认该问谁** —— `WindowCloseGuard` 拿到被关的窗口，要查它那份 viewModel
///    有没有未保存的改动（同一个代理也挂在设置窗口上，不能一视同仁）；
/// 2. **哪个窗口正开着这个文件** —— `DocumentOpener` 判断"要不要另开一个标签页"。
///
/// 为什么绕这一下而不是在 `onAppear` 里读 `NSApp.keyWindow`：`onAppear` 跑的时候
/// 窗口未必已经是 key（现在是多窗口，同时有好几个），拿到的会是 nil 或别人。
/// 用 `NSViewRepresentable` 就能直接问"我被放进哪个窗口了"—— 答案永远是对的。
@MainActor
private struct DocumentWindowAccessor: NSViewRepresentable {
    let viewModel: AppViewModel

    func makeNSView(context: Context) -> NSView {
        let view = WindowProbeView()
        view.onWindow = { window in register(on: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 已经上屏的就顺手再登记一次（幂等），还没上屏的等 `viewDidMoveToWindow`
        if let window = nsView.window { register(on: window) }
    }

    private func register(on window: NSWindow) {
        AppModelBridge.register(viewModel, for: window)
        // 标题（也就是系统标签栏上显示的字）在这里兜一次底 ——
        // `onAppear` 那一刻还没登记，`updateWindowTitle()` 查不到窗口，
        // 装文件触发的那次 `onChange` 也未必赶在登记之后。
        window.title = viewModel.selectedTab?.displayName ?? "PDF Free"
        // 装关闭确认代理 + 并进系统标签栏
        //（为什么这两件事都得在这里主动做 —— 见 `DocumentWindows` 的实测结论）
        DocumentWindows.prepareWhenReady(window)
    }
}

/// 只干一件事：**在上屏的那一刻**把"我在哪个窗口里"报出来。
///
/// ⚠️ 不能用"`makeNSView` 之后下一轮主队列读 `view.window`"那种写法 ——
/// 实测会**静默失效**：那一刻窗口还没 attach，`view.window` 是 nil，
/// 于是一个 `guard` 直接返回，窗口就永远没被登记。后果是一连串的：
/// 标题不改（标签栏上显示成 "PDFReader"）、不并进标签栏、**关闭确认代理也装不上**，
/// 而且日志里只会看到"窗口登记"那一条少了一次 —— 极难猜。
///
/// `viewDidMoveToWindow()` 是 AppKit 给这件事的**确定时机**：视图一挂上窗口就会调，
/// 不用赌时间、也不用轮询。
@MainActor
private final class WindowProbeView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

// MARK: - 依赖 PDFViewModel 的两块区域
//
// ⚠️ 它们的显示条件**不能**写在 `ContentView.body` 里判断。
//
// `ContentView` 观察的是 `AppViewModel`，而 `isEditable` / `searchQuery` / `hasSelection`
// 都是 `PDFViewModel` 的 `@Published` —— 在父视图里读这些属性，值变了也不会触发重绘。
// 症状：点「编辑」工具条不出来、输入搜索词右侧结果栏不出来，切换标签后才"突然"正常。
//
// 所以拆成独立子视图，各自 `@ObservedObject` 观察对应的 `PDFViewModel`。

/// 「页面管理」浮层的宿主：开着的时候把它铺满**整个内容区**。
///
/// 两件事单独成立一个类型：
///
/// 1. **位置**：放在 `ContentView` 这一层（而不是 `PDFContentView` 里），
///    才能把顶栏 / 标注工具条 / 左右侧边栏一起盖住。窗口标题栏不动 ——
///    macOS 的系统标签页长在那儿，用户还要靠它切文件。
/// 2. **观察**：`ContentView` 观察的是 `AppViewModel`，而 `isPageManagerVisible`
///    是 `PDFViewModel` 的 `@Published` —— 在父视图里读它**不会触发重绘**
///    （症状：点菜单打开了，面板却不出来）。这里 `@ObservedObject` 观察它。
@MainActor
private struct PageManagerOverlay: View {
    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
    }

    var body: some View {
        ZStack {
            if viewModel.isPageManagerVisible {
                PageManagerSheet(tab: tab, viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isPageManagerVisible)
    }
}

/// 标注工具条宿主：只在编辑模式渲染
@MainActor
private struct AnnotationPaletteHost: View {
    let tab: DocumentTab
    @ObservedObject var pdfVM: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.pdfVM = tab.viewModel
    }

    var body: some View {
        if pdfVM.isEditable {
            VStack(spacing: 0) {
                AnnotationPalette(viewModel: pdfVM)
                Divider()
            }
        }
    }
}

/// 主内容区的三栏布局。
///
/// 单独拆出来是因为它要读 `PDFViewModel` 的侧边栏可见性 —— 在 `ContentView` 里读
/// 这些 `@Published` 不会触发重绘（`ContentView` 观察的是 `AppViewModel`）。
///
/// **栏宽用 `@AppStorage` 记住**：`GeometryReader` 把实际宽度写回，下次启动用它做
/// `idealWidth`。用户拖过分隔条之后就不会每次复位了。
@MainActor
private struct DocumentLayout: View {
    let tab: DocumentTab
    @ObservedObject var pdfVM: PDFViewModel

    @AppStorage("pdfreader.leftSidebarWidth") private var leftWidth: Double = 220
    @AppStorage("pdfreader.rightSidebarWidth") private var rightWidth: Double = 260

    init(tab: DocumentTab) {
        self.tab = tab
        self.pdfVM = tab.viewModel
    }

    var body: some View {
        HStack(spacing: 0) {
            if pdfVM.isLeftSidebarVisible {
                SidebarView(tab: tab)
                    .frame(width: leftWidth)
                    // 内容真撑破了也不许溢出到分隔条上（`clipped` 会连**命中区**一起裁掉）
                    .clipped()
                ResizeHandle(width: $leftWidth, range: 180...400, inverted: false,
                             onDragStart: { pdfVM.beginPreservingZoom() })
                    // ⚠️ 分隔条要画在邻居**上面**（见下面右栏那段说明）
                    .zIndex(1)
            }

            PDFContentView(tab: tab)
                .frame(minWidth: 320, maxWidth: .infinity)

            // 右侧栏：选中标注时是属性栏，有搜索词时是结果列表。
            // 显示条件只看 `isRightSidebarVisible` —— **删掉标注不会让它消失**
            // （内容变空只留白），避免页面宽度跟着抖一下。隐藏要用户点关闭。
            if pdfVM.isRightSidebarVisible {
                ResizeHandle(width: $rightWidth, range: 200...420, inverted: true,
                             onDragStart: { pdfVM.beginPreservingZoom() })
                    // ⚠️ **分隔条必须画在邻居上面**（v1.3.47）。
                    //
                    // 侧边栏里某个控件的最小宽度如果大于栏宽，内容就会溢出 `.frame` ——
                    // 而**溢出的部分照样接收点击**。它会正好盖住这 6pt 宽的分隔条，
                    // 表现就是"**栏宽拖不动了，得先取消选中标注**"（用户报的）。
                    // zIndex 让分隔条拿到事件优先权，`clipped`（下面那句）再从源头
                    // 把溢出的部分连命中区一起裁掉 —— 两道一起上。
                    .zIndex(1)
                RightPanelView(tab: tab)
                    .frame(width: rightWidth)
                    .clipped()
                    // 内容宽度 > 栏宽 就说明又有控件的最小宽度太大了，记一条警告
                    .onPreferenceChange(PanelContentWidthKey.self) { width in
                        guard width > rightWidth + 0.5 else { return }
                        Diagnostics.shared.record(String(format:
                            "⚠️ 属性栏内容比栏宽还宽：内容 %.0f > 栏宽 %.0f —— "
                            + "有控件的最小宽度太大（已被裁掉，检查 ColorSwatchRow / FontControls 这类横排）",
                            width, rightWidth))
                    }
            }
        }
    }
}

/// 侧边栏**内容**的自然宽度（可能大于栏宽）。
///
/// ⚠️ 专门用来抓"内容撑破栏宽"这个 bug：它在窄栏里会让内容溢出到分隔条上、
/// 害得**栏宽拖不动**。已经出过两次 —— 先是 `FontControls`（改成分两行），
/// 后是 `ColorSwatchRow`（v1.3.47 改成窄栏自动换行）。
/// 有了这条，以后谁再把某个横排控件撑宽，日志里会直接报出来。
private struct PanelContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 可拖动的分隔条。
///
/// 用它替代 `HSplitView` 的原因：`HSplitView` 在**动态增删子视图**时会重新分配宽度，
/// `idealWidth` 不被尊重 —— 表现就是"关掉侧边栏再打开，宽度又回到默认值了"。
/// 这里把宽度直接绑到 `@AppStorage` 上，关掉再开也还是那个宽度。
@MainActor
private struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// 右侧栏的分隔条：往左拖是变宽，方向相反
    let inverted: Bool
    /// 拖动**开始前**调一次 —— 用来记下当前缩放，免得拖栏位把页面也缩放了。
    /// 只在起始调：拖动过程中每帧都调的话，记下的会是"已被 PDFKit 改过"的值。
    var onDragStart: () -> Void = {}

    /// 一次拖动开始时的宽度。用拖动**起始值**算增量，
    /// 否则每次 onChanged 都基于上一次的结果累加，会越来越偏。
    @State private var widthAtDragStart: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if widthAtDragStart == nil {
                        onDragStart()
                        widthAtDragStart = width
                    }
                    let base = widthAtDragStart ?? width
                    let delta = inverted ? -value.translation.width : value.translation.width
                    width = min(max(base + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in widthAtDragStart = nil }
        )
    }
}

/// 右侧栏。同一块地方两用：
/// - 选中了标注 → 属性栏（改颜色/线宽/字号、删除）
/// - 有搜索词   → 搜索结果
///
/// 两者同时存在时上下排：属性栏在上（它更"当下"），结果列表在下。
@MainActor
private struct RightPanelView: View {
    let tab: DocumentTab

    @ObservedObject var pdfVM: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.pdfVM = tab.viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            if pdfVM.selectedAnnotation == nil && pdfVM.searchQuery.isEmpty {
                // 内容空了就**留白**，而不是让整栏消失 —— 删一条标注就抽掉一整栏，
                // 页面的宽度会跟着横跳一下，很晃眼。
                emptyState
            } else {
                if let item = pdfVM.selectedAnnotation {
                    AnnotationInspector(viewModel: pdfVM, item: item)
                        .frame(maxHeight: pdfVM.searchQuery.isEmpty ? .infinity : 340)
                    if !pdfVM.searchQuery.isEmpty { Divider() }
                }

                if !pdfVM.searchQuery.isEmpty {
                    SearchResultsPanel(viewModel: pdfVM)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        // 把这一栏**内容的自然宽度**报上去（`DocumentLayout` 用它发现"内容撑破栏宽"）。
        // 读到的会是内容真正需要的宽度 —— 撑破时它 > 栏宽，正常时等于栏宽。
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelContentWidthKey.self, value: proxy.size.width)
        })
    }

    /// 空状态。留白 + 一句说明。
    ///
    /// ⚠️ **不放"关闭属性栏"的 X**（v1.3.46 去掉）：顶栏右侧那个按钮就是这个作用，
    /// 两处各放一个只会让人犹豫该点哪个。
    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("属性")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "sidebar.right")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("未选中标注")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("在页面上点选一条标注，\n这里会显示它的颜色、线宽等属性")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
