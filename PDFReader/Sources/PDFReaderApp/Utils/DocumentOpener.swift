import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「打开文件」这件事的**唯一入口**（v1.3.40）。
///
/// ## 为什么改成一个文件一个窗口
///
/// 之前所有文件挤在一个窗口里、标签栏是自己画的（`TabBarView`）。改成
/// **一个文件一个窗口**之后，"标签栏"这整件事交给 macOS 的**系统窗口标签页**：
/// `+` 新建、拖动重排、⌘W 关当前标签、⌥⌘W 关窗口、⌘⇧[ / ⇧⌘] 切换 —— 全是白拿的，
/// 而且每个文件有自己的 `PDFView`，"切来切去状态会变"这类问题从结构上就不存在了。
///
/// ## ⚠️ 但"自动分页"是**不会**生效的（探针实测）
///
/// `tools/probes/tabprobe.swift` 在真机上的结论：
///
/// ```
/// 建同 identifier 的窗口（指望自动并） → 同组标签 = nil      ← 根本没并
/// 显式 addTabbedWindow(_:ordered:)     → 同组标签 = 2       ← 只有这条有用
/// ```
///
/// 窗口的 `tabbingIdentifier` 一样（`SwiftUI-WindowGroup-document`）、
/// `tabbingMode` 也是 `automatic`，但 macOS 就是**不自动合并** —— 系统偏好里
/// `AppleWindowTabbingMode` 这个键压根不存在（默认不是 always）。
/// 所以必须由我们自己调 `addTabbedWindow`，见下面的 `DocumentTabGroup`。
@MainActor
enum DocumentOpener {

    /// 新窗口的 scene id，对应 `PDFReaderApp` 里 `WindowGroup(id: "document")`。
    static let sceneID = "document"

    /// 排着队、等着被某个窗口认领的文件。
    private static var queue: [URL] = []

    /// 每个文件"**被要求打开**的先后"（越小越早）。
    ///
    /// ## 为什么需要它
    ///
    /// 标签栏里的顺序应该跟**打开顺序**一致，但下面两件事都**不是**按打开顺序发生的：
    ///
    /// - **窗口谁先上屏**：SwiftUI 建窗口是并行的，实测同样三个文件，三次跑出来的
    ///   出现次序就不一样；
    /// - **谁先准备好并组**：`DocumentWindows.prepareWhenReady` 要等各自的
    ///   `isVisible`，各窗口等的轮数不同。
    ///
    /// 只有 `open(_:)` 拿到的那个 `urls` 数组是真正有序的 —— 在这里给每个文件
    /// 记一个递增序号，并组时按它排，顺序才是稳的（见 `DocumentWindows.insert`）。
    private static var requestedOrder: [URL: Int] = [:]
    private static var nextRequestOrder = 0

    /// 这个窗口该排在标签栏第几位：按它开着的文件被要求打开的先后。
    /// 拿不到（空窗口、或不是走 `open(_:)` 进来的）就返回 nil。
    static func tabOrder(of window: NSWindow) -> Int? {
        guard let url = AppModelBridge.documentURL(of: window) else { return nil }
        return requestedOrder[url]
    }

    /// **已经请求打开、但还没认领到文件**的窗口数。
    ///
    /// 有它才能回答"队列里还有几个是真的没人管"：
    /// `queue.count - inFlight` 才是需要补开窗口的数量。
    /// 少了这个计数，每个新窗口 `onAppear` 都会把队列里剩下的全当成"没人管"再开一遍 ——
    /// 实测就是这么炸的：开 3 个文件开出了 **7 个窗口**。
    private static var inFlight = 0

    /// 有没有"正在打开、还没着落"的文件。
    ///
    /// `QuitWhenIdle` 用它区分"零窗口"的两种含义：**要退出**（用户把窗口都关了）
    /// 还是**正要换一个窗口**（文件正在路上）。少了这个判据，正好在"关掉旧窗口、
    /// 新窗口还没出现"那一瞬间就会把 app 退掉。
    static var hasPendingOpens: Bool { !queue.isEmpty || inFlight > 0 }

    // MARK: - 给新窗口用

    /// 新窗口出现时领一个文件；返回 nil 表示"这是一次普通的新建标签页"。
    static func claim() -> URL? {
        guard !queue.isEmpty else { return nil }
        if inFlight > 0 { inFlight -= 1 }
        let url = queue.removeFirst()
        Diagnostics.shared.record("新窗口认领文件：「\(url.lastPathComponent)」"
                                  + "（队列剩 \(queue.count) 个，在路上 \(inFlight) 个）")
        return url
    }

    /// 队列里还有文件、却没有任何窗口在路上（冷启动时 `openWindow` 动作还没注册）
    /// → 现在补开窗口。
    ///
    /// 按 `queue.count - inFlight` 算，所以**重复调用也不会多开**。
    static func drainIfNeeded() {
        guard let action = AppModelBridge.openWindowAction else { return }
        let needed = queue.count - inFlight
        guard needed > 0 else { return }
        Diagnostics.shared.record("补开 \(needed) 个标签页去认领排队的文件")
        for _ in 0..<needed {
            inFlight += 1
            action(id: sceneID)
        }
    }

    // MARK: - 打开

    /// 弹「打开文件」面板，选完交给 `open(_:)`。
    static func openPanel() {
        let panel = NSOpenPanel()
        // PDF + 系统认得的所有图片格式（v1.3.66）。
        // ⚠️ 别在这里列具体后缀 —— `ImageDocument.openableTypes` 用的是抽象类型 `.image`，
        // 它自动涵盖所有子类型，以后系统新增格式我们不用管。
        panel.allowedContentTypes = ImageDocument.openableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    /// 打开一组文件。
    ///
    /// 规则：
    /// - 已经在别的窗口里开着的 → 把那个窗口拎到前面，不重复开；
    /// - 当前 key 窗口还空着 → 第一个文件就地装进去（否则屏幕上会多出一个空窗口）；
    /// - 其余每个文件各开一个新窗口，由 `DocumentTabGroup` 并成标签页。
    static func open(_ urls: [URL]) {
        // 先按**传进来的顺序**记下"谁先被要求打开"—— 标签栏排序要用。
        // 已经记过的（在别的窗口里开着的）不重记，免得它被挪到末尾去。
        for url in urls where requestedOrder[url] == nil {
            requestedOrder[url] = nextRequestOrder
            nextRequestOrder += 1
        }

        var list: [URL] = []
        for url in urls {
            if let window = windowShowing(url) {
                Diagnostics.shared.record("打开文件：「\(url.lastPathComponent)」已在另一个窗口里 → 切过去")
                window.makeKeyAndOrderFront(nil)
            } else {
                list.append(url)
            }
        }
        guard !list.isEmpty else { return }

        if AppModelBridge.openWindowAction != nil,
           let viewModel = emptyDocumentViewModel {
            viewModel.addDocument(at: list.removeFirst())
            // ⚠️ 装完就把这个窗口推到前面（v1.3.72）。
            // 冷启动时 SwiftUI 会为这次 open 事件**另建一个窗口**，那个后来者才是 key ——
            // 于是"装了文件的窗口"反而排在后面，用户看到的是那个空标签。
            if let window = AppModelBridge.window(of: viewModel) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        guard !list.isEmpty else { return }
        queue.append(contentsOf: list)
        if let action = AppModelBridge.openWindowAction {
            for _ in list {
                inFlight += 1
                action(id: sceneID)
            }
            Diagnostics.shared.record("打开文件：新开 \(list.count) 个标签页")
        } else {
            // 冷启动：`openWindow` 动作还没注册（第一个窗口都还没出现）。
            // 留在队列里，等那个窗口 `onAppear` 时自己认领 + `drainIfNeeded()` 补开。
            Diagnostics.shared.record("打开文件：还没有窗口可开 → 排队 \(list.count) 个，等第一个窗口认领")
        }
    }

    /// **外部打开**的入口（Finder 双击 / 右键「打开方式」/ 拖到 Dock 图标 / `open` 命令）。
    ///
    /// 比 `open(_:)` 多做一件收尾：**把 SwiftUI 为这次事件额外建出来的空窗口清掉**。
    ///
    /// ## 为什么会有多余的窗口（用户日志实锤）
    ///
    /// 冷启动时 SwiftUI 会为"外部要求打开文档"这件事**另建一个窗口**，而 `WindowGroup`
    /// 自己在启动时已经建过一个 —— 一个文件于是有两个窗口：
    ///
    /// ```
    /// [15:18:00.723] 窗口登记：现在有 1 个文档窗口      ← WindowGroup 的启动窗口
    /// [15:18:18.173] 窗口登记：现在有 2 个文档窗口      ← SwiftUI 为外部打开事件建的
    /// [15:18:18.210] AppDelegate.application(open:)：1 个文件
    /// ```
    ///
    /// 文件装进其中一个之后，另一个就空在那儿 —— 系统标签栏上多一个写着 app 名的空标签。
    ///
    /// ⚠️ 只在"**发起时所有窗口都是空的**"这一种情况下才收尾。这条判据很要紧：
    /// 它排除了"用户自己按 ⌘T 开了个空标签、随后又用 Finder 打开文件"这种情形
    ///（那时不该去动用户开的窗口）。
    static func openExternally(_ urls: [URL]) {
        let startedEmpty = AppModelBridge.allViewModels.allSatisfy { $0.tabs.isEmpty }
        open(urls)
        if startedEmpty { sweepSurplusEmptyWindows() }
    }

    /// 收掉"多余的空窗口"：文件都装好了、队列也空了，却还有窗口什么都没装。
    ///
    /// ## ⚠️ 为什么要**尽早**动手（v1.3.72，杰哥报的"空白页停留一两秒"）
    ///
    /// 冷启动打开文件时，SwiftUI 会建**两个**窗口：`WindowGroup` 自带的启动窗口，
    /// 外加为这次 `odoc` 事件另建的一个。文件只会装进其中一个，另一个空着 ——
    /// 而**空掉的那个往往是后来者、抢到了 key**。
    ///
    /// 真机录屏（每 0.2 秒一帧）看到的现场：
    ///
    /// ```
    /// open +0.79s  窗口已出现，标签栏两个：「open-me」(装了文件) | 「PDF Free」(空)
    ///              选中的是右边那个空的 —— 内容区就是"最近打开"页
    /// open +2.00s  画面一动不动，还是那个空标签
    /// ```
    ///
    /// 原来这里固定延后 **1.5 秒**才收尾，那 1.5 秒就正好是用户抱怨的"停留"。
    /// 现在改成**轮询**：文件一装好就立刻收尾，不再干等。
    ///
    /// ## 两条判据都不能省
    ///
    /// - `hasPendingOpens`：还有文件在路上 → 那些空窗口是**给它们留的**，动不得；
    /// - "至少有一个窗口装到了文件"：否则可能只是"文件还没装完"或"文件根本打不开
    ///   （只弹了个错误提示），这时关窗口就是纯破坏 —— 所以没等到就继续轮询。
    private static func sweepSurplusEmptyWindows() {
        pollForSweep(attempt: 0)
    }

    /// 轮询实现。第一次等 0.2 秒（让 SwiftUI 把该建的窗口建完），之后每 0.15 秒看一次，
    /// 最多约 1.7 秒 —— 到点了还没等到就不动，宁可留着空窗口也不要误关。
    private static func pollForSweep(attempt: Int) {
        let delay: Double = attempt == 0 ? 0.2 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 还有文件在路上 → 那些空窗口是给它们留的，现在动不得。
            // ⚠️ 但**不能直接 return 走人** —— 文件到齐之后还得回来收尾，
            // 所以要接着轮询（只是这会儿先不干活）。
            guard !hasPendingOpens else {
                if attempt < 10 { pollForSweep(attempt: attempt + 1) }
                return
            }

            let entries = AppModelBridge.allEntries

            // 还没有任何窗口装到文件 → 可能只是还没轮到，再等等看
            guard let loaded = entries.first(where: { !$0.viewModel.tabs.isEmpty }) else {
                if attempt < 10 { pollForSweep(attempt: attempt + 1) }
                return
            }

            let empties = entries.filter { $0.viewModel.tabs.isEmpty }
            guard !empties.isEmpty else { return }

            for entry in empties {
                Diagnostics.shared.record("收尾：关掉多余的空窗口「\(entry.window.title)」"
                                          + "（一个文件一个窗口，这个没装到文件）")
                // 空窗口没有未保存改动，不用走 `windowShouldClose` 那套确认；
                // 这里用的是程序化 close()，所以"关完要不要退出"归 `QuitWhenIdle` 管
                entry.window.close()
            }

            // ⚠️ 收完必须把装着文件的窗口推到前面。空窗口之所以碍事，一半是因为它
            // **抢了 key**（它是后建的那个）—— 光关掉它不够，焦点得还给正主，
            // 否则用户看到的是"窗口没了、内容还是空的"。
            if loaded.window.isVisible {
                loaded.window.makeKeyAndOrderFront(nil)
                Diagnostics.shared.record("收尾：把「\(loaded.window.title)」推到前面")
            }
        }
    }

    /// 找一份"还空着的文档"来就地装文件 —— 优先当前的 key 窗口。
    ///
    /// ⚠️ 不能只认 `NSApp.keyWindow`：`keyWindow` 为 nil 的情形并不罕见
    ///（app 在后台、刚启动还没激活、自动化脚本从终端拉起来…）。
    /// 实测就是栽在这上面 —— 明明开着一个空窗口，却只是因为它不是 key，
    /// 结果三个文件之外又多开了一个空窗口，屏幕上一共 4 个标签。
    private static var emptyDocumentViewModel: AppViewModel? {
        if let key = NSApp.keyWindow,
           let viewModel = AppModelBridge.viewModel(for: key),
           viewModel.tabs.isEmpty {
            return viewModel
        }
        return AppModelBridge.allViewModels.first { $0.tabs.isEmpty }
    }

    /// 哪个窗口正在显示这个文件
    private static func windowShowing(_ url: URL) -> NSWindow? {
        for entry in AppModelBridge.allEntries
        where entry.viewModel.tabs.contains(where: { $0.url == url }) {
            return entry.window
        }
        return nil
    }
}

/// 新文档窗口的"入境手续"：装关闭确认代理 + 让标签栏显示出来 + 并进同组（v1.3.40 / v1.3.45）。
///
/// ## 一、标签栏**默认就显示**要靠手动开（v1.3.45）
///
/// macOS 只在系统偏好 `NSWindow.userTabbingPreference == .always` 时才让**单独一个窗口**
/// 也显示标签栏。真机实测这台机器上是 `inFullScreen`（「系统设置 → 桌面与程序坞 →
/// 优先以标签页方式打开文稿」选了"全屏时"），所以默认**根本看不到标签栏** ——
/// 要开第二个文件才冒出来，关到只剩一个又缩回去。
///
/// 探针 `tools/probes/tabmodeeprobe.swift` 的实测（真窗口）：
///
/// ```
/// userTabbingPreference = 2（inFullScreen）→ 默认不显示标签栏
/// 上屏之后设 tabbingMode = .preferred        → 标签栏**不会**自己冒出来
///   （头文件写明它 "should be set before a window is shown"，
///     而我们的窗口是 SwiftUI 建的，只能在它上屏之后才拿得到 —— 这条做不到）
/// 再调 toggleTabBar(_:)                      → 标签栏出现 ✅
/// 关到只剩一个标签                            → 标签栏仍然显示 ✅（正是用户要的）
/// ```
///
/// ## 二、为什么必须**手动**并成标签
///
/// 探针（同上）在真机上的结论：
///
/// ```
/// 只靠 automatic + 相同 tabbingIdentifier  → 同组标签 = 只有自己  ❌ 没并
/// 显式 addTabbedWindow(_:ordered:)          → 同组标签 = 2        ✅
/// ```
///
/// `allowsAutomaticWindowTabbing = true`、identifier 也一样，但 macOS 就是不自动合并
///（`AppleWindowTabbingMode` 这个键压根不存在）。所以每见到一个新文档窗口，
/// 就把它挂到已有的同组窗口上。
///
/// ⚠️ **顺序是"先并、再开标签栏"**。反过来的话，第二个窗口会先给自己开一条标签栏
/// （自成一组），之后就跟第一个窗口**并不到一起**了。
///
/// ## 三、为什么关闭确认代理也得在这里装
///
/// 原来只靠 `NSWindow.didBecomeKey/Main` 通知来装代理。但**并进标签栏之后，
/// 后台标签永远不会"成为 key"** —— 用户点的是标签栏上那一小块，窗口本身没换过 key。
/// 实测后果很严重：
///
/// ```
/// 关「测试文件」（宿主窗口）→ windowShouldClose 被调用 ✓
/// 关「tabB」（后台标签）    → 窗口确实关掉了，但 windowShouldClose **一次都没来**
///                             也没有 windowWillClose → 注册表里那份一直留着
/// ```
///
/// —— 也就是**有未保存改动也不会提示，改动被静默丢掉**。
/// 所以只要有窗口被登记成文档窗口，就地把代理装上，不等它成为 key。
@MainActor
enum DocumentWindows {

    /// 新文档窗口**就绪之后**要做的三件事。
    ///
    /// ⚠️ 要**等它可见**：SwiftUI 建窗口是"先有 window 对象、再 orderFront"，
    /// 太早动手会被 `isVisible` 那道判断挡掉（`toggleTabBar` 也要求窗口已经上屏）。
    /// 所以做几次短重试（约 1 秒），而不是赌某一刻一定就绪。
    static func prepareWhenReady(_ window: NSWindow, attempt: Int = 0) {
        guard window.isVisible else {
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                prepareWhenReady(window, attempt: attempt + 1)
            }
            return
        }
        // ① 关闭确认代理（幂等）
        WindowCloseGuardInstaller.install(on: window)
        // ② 并进同组的标签栏；它是第一个窗口就把标签栏开出来（幂等）
        showTabBarAndMerge(window)
    }

    /// 让 `window` 的标签栏显示出来，并把它并进同组的其它窗口。
    ///
    /// **先并、再开** —— 理由见类型注释（反过来会各自成组，永远并不起来）。
    ///
    /// ⚠️ **一个窗口只办一次入境手续**（v1.3.71）。判据在 `preparedWindows` 里 ——
    /// 那是"拖不出独立窗口"的修复，见那个属性的说明。
    private static func showTabBarAndMerge(_ window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        let identifier = window.tabbingIdentifier
        guard !identifier.isEmpty else { return }

        // 让它之后新开的同 identifier 窗口也倾向分页。
        // ⚠️ 对**已经上屏**的窗口它不会立刻生效，所以下面还有一段"没显示就手动开"。
        window.tabbingMode = .preferred

        // ⚠️ **入境手续一个窗口只办一次**，放在最前面 —— 下面每条分支都要算"办过了"。
        //    理由见 `preparedWindows`。
        let key = ObjectIdentifier(window)
        guard !preparedWindows.contains(key) else { return }
        preparedWindows.insert(key)

        // 已经在别人的组里了（组里不止自己）→ 不用管
        if (window.tabbedWindows?.count ?? 0) > 1 { return }

        // ① 找同一组的另一个窗口当"落脚点" —— `addTabbedWindow` 把新窗口挂到它旁边，
        //    两个就成了一组；之后再来新窗口会挂进这一组。
        //
        // ⚠️ 这段的进入条件**不能**写成 `tabbedWindows == nil`。
        //    实测：用 `toggleTabBar` 开过标签栏之后，单独一个窗口的 `tabbedWindows`
        //    是 `[自己]`（不是 nil）—— 按 nil 判断的话这里会**永远跳过**，
        //    多窗口再也不会并到一起（探针第 3 段专门验了这一条）。
        //
        // `!$0.isMiniaturized`：最小化（⌘M）的窗口不算落脚点。
        //    探针实测最小化之后 `isVisible` **就是 false**（`tabdetachprobe` 场景 B），
        //    所以这半句其实已经被上面那半句挡住了 —— 留着是把意图写明白：
        //    "Dock 里那个不算数"，不依赖 `isVisible` 对最小化窗口的具体取值。
        if let sibling = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && !$0.isMiniaturized
                && $0.tabbingIdentifier == identifier
        }) {
            insert(window, intoGroupOf: sibling)
            return
        }

        // ② 没有同伴 → 它是第一个窗口：手动把标签栏显示出来。
        //
        // 这样"只开着一个文件"时标签栏也在（用户一眼就知道这儿能放多个文件），
        // 而且关到只剩一个时它也不会缩回去（实测）。
        showTabBarOnce(for: window)
    }

    /// 把 `window` 插进 `sibling` 所在的那个标签栏组，位置**按文件的打开顺序**排。
    ///
    /// ## 为什么不能只靠 `addTabbedWindow(ordered:)`
    ///
    /// 那样只能"挂在某个标签的旁边"，也就是只能决定**末尾**；而下面这两件事都
    /// **不是**按打开顺序发生的：
    ///
    /// - 窗口**谁先上屏**（SwiftUI 并行建窗口）；
    /// - 谁先**准备好并组**（要等各自的 `isVisible`）。
    ///
    /// 实测就是这两个原因让标签顺序倒过来：
    ///
    /// ```
    /// 窗口分页：「tabC」并进同组（现在 2 个标签：测试文件 | tabC）
    /// 窗口分页：「tabB」并进同组（现在 3 个标签：测试文件 | tabC | tabB）   ← 打开顺序是 B 在前
    /// ```
    ///
    /// 改用 `NSWindowTabGroup.insertWindow(_:atIndex:)`，拿
    /// `DocumentOpener.tabOrder(of:)`（**文件的打开序号**，在 `open(_:)` 里记的）
    /// 比大小，插到第一个"序号比我大"的窗口前面 —— 与快慢无关，只跟打开顺序有关。
    private static func insert(_ window: NSWindow, intoGroupOf sibling: NSWindow) {
        let myOrder = DocumentOpener.tabOrder(of: window) ?? Int.max

        if let group = sibling.tabGroup {
            let current = group.windows
            let index = current.firstIndex {
                (DocumentOpener.tabOrder(of: $0) ?? Int.max) > myOrder
            } ?? current.count
            group.insertWindow(window, at: index)
            let titles = group.windows.map(\.title).joined(separator: " | ")
            Diagnostics.shared.record("窗口分页：「\(window.title)」插到第 \(index + 1) 位"
                                      + "（现在 \(group.windows.count) 个标签：\(titles)）")
            return
        }

        // 退路：拿不到 `tabGroup` 时退回老写法（挂在最后一个标签后面）。
        //
        // ⚠️ 这里有个反直觉的地方（实测）：`ordered:` 给 `.above` 才是**往后排**；
        // 用 `.below` 新标签会跑到宿主前面，顺序整个倒过来。
        let anchor = sibling.tabbedWindows?.last ?? sibling
        anchor.addTabbedWindow(window, ordered: .above)
        let tabs = anchor.tabbedWindows ?? [anchor]
        Diagnostics.shared.record("窗口分页：「\(window.title)」并进同组（现在 \(tabs.count) 个标签："
                                  + tabs.map(\.title).joined(separator: " | ") + "）")
    }

    /// 已经办过"入境手续"（并组 / 开标签栏）的窗口。
    ///
    /// **一个窗口只办一次**，两条理由：
    ///
    /// 1. 用户在菜单里手动**隐藏**了标签栏之后，切走再切回来不该又给它打开
    ///    （那会变成"关不掉"）；
    /// 2. ⚠️ **用户把标签拖出去、成为独立窗口之后，绝不能把它再并回来**（v1.3.71）。
    ///
    /// 第 2 条是杰哥 2026-10-13 报的**两个** bug，成因是同一个 ——
    /// 窗口事后每一次"成为 key"都会重跑一遍并组，而那道 `tabbedWindows > 1`
    /// 的判断接不住下面这两种现场：
    ///
    /// - **拖出去的标签**：`tabbedWindows` 只剩它自己（不是 `> 1`），于是我们
    ///   **亲手**把用户刚拖出来的标签又并了回去 → 表现"标签拖不出独立窗口"；
    /// - **还原最小化的窗口**：最小化期间它 `isVisible == false`，所以此时打开的文件
    ///   老老实实另立了一组（用户看到的就是"新独立窗口"）；等用户点 Dock 把它还原，
    ///   它重新成为 key，这一步就把它并进了**新窗口**那一组
    ///   → 表现"点开最小化的那个，两个就自动合并成一个了"。
    ///
    /// 两处都靠这一条判重挡住：入境手续只办一次，办过就不再动它。
    /// （`tools/probes/tabdetachprobe.swift` 用真窗口把这两条都复现+验过。）
    ///
    /// 窗口真关掉时由 `forget(_:)` 清掉 —— 否则同一个 `ObjectIdentifier`
    /// 被新窗口复用时会被误判成"已经办过了"，新窗口就并不进任何组。
    private static var preparedWindows = Set<ObjectIdentifier>()

    /// 窗口关掉时清掉记录（`WindowCloseGuard.windowWillClose` 里调）。
    static func forget(_ window: NSWindow) {
        preparedWindows.remove(ObjectIdentifier(window))
    }

    /// 把标签栏打开 —— 只给"第一个窗口"用（判断与调用都只在 `showTabBarAndMerge` 里，
    /// 那里已经保证一个窗口只走一次）。
    private static func showTabBarOnce(for window: NSWindow) {
        // ⚠️ 先查 `isTabBarVisible` 再调 —— `toggleTabBar` 是**开关**，
        //    不看状态就调会把已经显示的标签栏关掉。
        //（系统偏好设成"始终"时它本来就是显示的，那就不用动。）
        if window.tabGroup?.isTabBarVisible != true {
            window.toggleTabBar(nil)
            Diagnostics.shared.record("标签栏：「\(window.title)」是第一个窗口 → 手动显示标签栏")
        }
    }
}
