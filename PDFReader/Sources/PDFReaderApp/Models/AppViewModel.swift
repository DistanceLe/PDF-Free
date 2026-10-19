import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// `ContentView` 与 `AppDelegate` 之间的桥。
///
/// ⚠️ **为什么不用 `NSApp.delegate as? AppDelegate`**：
/// SwiftUI 的 `@NSApplicationDelegateAdaptor` 会把我们的 delegate **包一层**，
/// `NSApp.delegate` 返回的是 SwiftUI 内部那个对象 —— 转换**必然失败**（返回 nil）。
/// 于是 `applicationShouldTerminate` 里取不到 viewModel，直接放行，
/// **关闭时永远不提示保存**。
///
/// 所以改成显式的注册表：`ContentView` 在出现时把自己那份 `AppViewModel` 放进来。
/// 放全局是因为 AppDelegate 是 AppKit 侧的入口，够不到 SwiftUI 的环境值。
///
/// （定义在这里而不是 `PDFReaderApp.swift`：那个文件带 `@main`，探针编不进去 ——
/// 把桥放在 models 里，探针就能引用**产品代码的同一份实现**去验证关闭链路。）
@MainActor
enum AppModelBridge {
    /// 一个**文档窗口**的登记项。
    struct Entry {
        let window: NSWindow
        let viewModel: AppViewModel
    }

    /// 按窗口登记的文档视图模型（v1.3.40：改成"一个文件一个窗口"）。
    ///
    /// **必须是强引用，不能写成 weak** —— 理由和 v1.3.32 那次完全一样，
    /// 实测（诊断日志）：
    ///
    /// ```
    /// [16:40:35.751] applicationShouldTerminateAfterLastWindowClosed 被调用 → true
    /// [16:40:35.773] ⚠️ applicationShouldTerminate：bridge 里没有 viewModel → 直接放行（不会提示）
    /// ```
    ///
    /// 点窗口红叉时，SwiftUI **先销毁窗口的视图树**（`@StateObject` 跟着一起没），
    /// AppKit **之后**才来问"要不要保存"。这中间的 weak 引用已经成了 nil，
    /// 于是"有没有未保存的改动"根本问不出去 —— 表现就是**关闭时永远不提示保存**。
    ///
    /// 窗口**真正关掉**时（`windowWillClose`）由 `WindowCloseGuard` 摘掉对应那一项，
    /// 所以不会一直堆着不放。
    private static var entries: [ObjectIdentifier: Entry] = [:]

    /// `openWindow` 动作（`ContentView` 拿到后放进来）。
    ///
    /// AppKit 侧的入口（菜单、Finder 打开文件）够不到 SwiftUI 的环境值，
    /// 但"开一个新标签页"必须靠它 —— 只能这样绕一道。
    static var openWindowAction: OpenWindowAction?

    static func register(_ viewModel: AppViewModel, for window: NSWindow) {
        let key = ObjectIdentifier(window)
        // 视图更新会反复调，同一个就跳过（否则日志会被刷屏）
        if let existing = entries[key], existing.viewModel === viewModel { return }
        entries[key] = Entry(window: window, viewModel: viewModel)
        Diagnostics.shared.record("窗口登记：现在有 \(entries.count) 个文档窗口")
    }

    /// 这个窗口正开着的文件（用来查"它该排在标签栏第几位"，见 `DocumentOpener`）。
    static func documentURL(of window: NSWindow) -> URL? {
        viewModel(for: window)?.tabs.first?.url
    }

    static func unregister(_ window: NSWindow) {
        if entries.removeValue(forKey: ObjectIdentifier(window)) != nil {
            Diagnostics.shared.record("窗口注销：还剩 \(entries.count) 个文档窗口")
        }
    }

    /// 这个窗口的文档视图模型；不是文档窗口（设置窗口、面板）就返回 nil。
    static func viewModel(for window: NSWindow?) -> AppViewModel? {
        guard let window else { return nil }
        return entries[ObjectIdentifier(window)]?.viewModel
    }

    /// 所有文档窗口的视图模型 —— 关窗口要不要提示、⌘Q 之前逐个问，都靠它。
    static var allViewModels: [AppViewModel] {
        entries.values.map(\.viewModel)
    }

    /// 所有已登记的窗口（找"哪个窗口正开着这个文件"要用）。
    static var allEntries: [Entry] {
        Array(entries.values)
    }

    /// 这一份 viewModel 住在哪个窗口里。
    ///
    /// ⚠️ 别用 `NSApp.keyWindow` 代替它：现在是多窗口，`onChange` 触发的那一刻
    /// key 窗口未必是发起者 —— 拿错窗口就会把**别的标签**的标题改掉。
    static func window(of viewModel: AppViewModel) -> NSWindow? {
        entries.values.first { $0.viewModel === viewModel }?.window
    }

    /// 当前 key 窗口那一份；万一是设置窗口（没登记）就退回最后一个。
    /// 菜单命令这类"没有明确目标窗口"的调用方用它。
    static var keyViewModel: AppViewModel? {
        viewModel(for: NSApp.keyWindow) ?? allViewModels.first
    }

    /// 这个窗口上是不是盖着「页面管理」浮层（v1.3.44）。
    ///
    /// 两个全局事件监听器（`SpaceDragPanMonitor` 的空格拖拽、`ScrollZoomMonitor`
    /// 的 ⌥+滚轮缩放）都要先问这一句：浮层盖着的时候，底下那份 PDF 用户**看不见**，
    /// 但拖 / 缩是**真的生效**的 —— 关掉浮层才发现"页面怎么跑偏了"。
    ///
    /// 浮层现在是同窗口里的一层普通视图（不是 sheet），所以
    /// `event.window === pdfView.window` 那道判断拦不住它，只能显式问一句。
    static func isPageManagerVisible(for window: NSWindow?) -> Bool {
        guard let viewModel = viewModel(for: window) else { return false }
        return viewModel.tabs.contains { $0.viewModel.isPageManagerVisible }
    }
}

@MainActor
class AppViewModel: ObservableObject {
    /// 被释放时记一条日志。
    ///
    /// 这一条专门给"关闭不提示保存"当证据：如果它在 `applicationShouldTerminate`
    /// **之前**出现，就说明窗口关闭时 viewModel 已经被销毁 —— 那一刻
    /// `AppModelBridge` 里的引用就成了 nil（这正是 v1.3.31 之前那个 bug）。
    ///
    /// 注册表改成强引用之后，这条**正常情况下只应在进程结束时**出现。
    deinit {
        Diagnostics.shared.record("AppViewModel 被释放（deinit）")
    }

    /// 这个窗口里打开的文件。
    ///
    /// ⚠️ **v1.3.40 起一个窗口最多装一个** —— 多文件改用 macOS 的**系统窗口标签页**
    /// （每个文件一个窗口，系统自动并成标签栏）。保留数组是因为整套 UI 都是
    /// 按"从 `tabs` 里取当前这份"写的，改成单个属性只是徒增改动面；
    /// 但语义上它就是"0 或 1 个"。
    @Published var tabs: [DocumentTab] = []
    @Published var selectedTabID: UUID?

    /// 打开失败的文件。用于弹提示 —— 静默失败会让用户以为"点了没反应"。
    @Published var openFailure: URL?

    var selectedTab: DocumentTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var document: DocumentTab? { selectedTab }

    // MARK: - 打开文档

    /// 走 `DocumentOpener` —— 它会判断"装进这个空窗口"还是"另开一个标签页"。
    func openDocument() {
        DocumentOpener.openPanel()
    }

    /// 把文件装进**这个窗口**。
    ///
    /// 要不要"另开一个标签页"由 `DocumentOpener` 决定，这里只负责装。
    /// 所以调用前这个窗口应当还是空的；万一不是（重复调用），静默忽略 ——
    /// 把已有文档换掉会让用户莫名其妙地丢掉当前这个。
    func addDocument(at url: URL) {
        // 同一个文件在这个窗口里已经开着 → 什么都不用做
        if let existing = tabs.first(where: { $0.url == url }) {
            selectedTabID = existing.id
            return
        }
        guard tabs.isEmpty else {
            Diagnostics.shared.record("装文档：本窗口已有「\(tabs[0].title)」→ 忽略（应走新标签页）")
            return
        }

        // ⚠️ 必须**先**取得安全作用域再读文件。
        // 从「最近打开」用 security-scoped bookmark 恢复出来的 URL，不 start 就完全读不到内容，
        // PDFDocument(url:) 会直接返回 nil —— 表现就是"点了没反应"。
        // 从打开面板/拖拽进来的文件由系统临时授权，这一步只是把作用域正式持有下来，
        // 以便后续写回批注时仍然有权限。
        let holdsScope = url.startAccessingSecurityScopedResource()

        // 图片走另一条读取路径：读成 `NSImage` → 包成**单页 PDF**（v1.3.66）。
        // 之后就完全复用 PDF 那条链路了 —— 缩放、空格拖拽、批注、缩略图都不用另写。
        let kind: DocumentTab.Kind
        let document: PDFDocument
        if ImageDocument.isImage(url) {
            kind = .image
            // 底色传进去 —— 它会**画进页面内容**，透明图片的透明区域才看得出来
            //（PDFView 会把页面擦成白，只有画在内容里的东西盖得住，见 `ImageDocument.makePage`）
            guard let wrapped = ImageDocument.makeDocument(from: url,
                                                           background: AppPreferences.shared.pageBackgroundNSColor) else {
                if holdsScope { url.stopAccessingSecurityScopedResource() }
                openFailure = url
                return
            }
            document = wrapped
        } else {
            kind = .pdf
            guard let loaded = PDFDocument(url: url) else {
                if holdsScope { url.stopAccessingSecurityScopedResource() }
                openFailure = url
                return
            }
            document = loaded
        }

        // 排查用：一眼看出这份是 PDF 还是被包成单页 PDF 的图片
        Diagnostics.shared.record("装文档：「\(url.lastPathComponent)」"
                                  + "类型=\(kind == .image ? "图片（已包成单页 PDF）" : "PDF")"
                                  + " 页数=\(document.pageCount)")

        let tab = DocumentTab(url: url, document: document, kind: kind, holdsSecurityScope: holdsScope)
        tabs.append(tab)
        selectedTabID = tab.id

        RecentDocuments.shared.add(url)
    }

    // MARK: - 关闭

    /// 窗口真的要关了（`windowShouldClose` 已经放行）→ 收尾。
    ///
    /// ⚠️ **不需要**在这里问"要不要保存" —— 那是 `WindowCloseGuard` 的事，
    /// 它在窗口关闭**之前**问（时机才对）。这里只做保存后的清理。
    func prepareForClose() {
        for tab in tabs {
            tab.viewModel.flushOutlineAutoSave()      // 自动保存还开着的话，可能有一笔挂在防抖里
            tab.viewModel.unbind()
            tab.releaseSecurityScope()
        }
        tabs.removeAll()
        selectedTabID = nil
    }

    /// 退出前把"看到哪儿了"记下来（页号 + 页内比例 + 缩放）。
    ///
    /// `unbind()` 那条路也会存；但"点红叉关窗口"不经过它，
    /// 所以窗口关闭之前和退出之前都要在这里补一次（见 `WindowCloseGuard` 与 `AppDelegate`）。
    func saveAllProgress() {
        for tab in tabs { tab.viewModel.saveProgress() }
    }

    // MARK: - 全屏

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}
