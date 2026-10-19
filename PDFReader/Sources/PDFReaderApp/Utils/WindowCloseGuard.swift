import AppKit
import ObjectiveC

/// 窗口关闭确认（v1.3.32）。
///
/// ## 为什么需要它
///
/// 之前把「有没有未保存的改动」问在 `applicationShouldTerminate` 里 —— 那个出口
/// **太晚了**。点窗口红叉时，SwiftUI 先销毁窗口与视图树，AppKit 才来问
/// 「最后一个窗口关了，要不要退出」。于是用户看到的正是：
///
/// ```
/// [16:57:15.951] applicationShouldTerminateAfterLastWindowClosed 被调用 → true
/// [16:57:15.953] applicationShouldTerminate 被调用 · tabs=1        ← 2 毫秒后窗口已经没了
/// ```
///
/// —— **文件已经关了，才弹出提示框**。
///
/// 更糟的是：这时候窗口已经没了，用户点「取消」也没法把窗口找回来；而系统会
/// **再触发一次** `applicationShouldTerminate`，弹框又弹一遍。实测日志里连着三发：
///
/// ```
/// [16:56:03.180] confirmClose：用户选「取消」→ 中止终止
/// [16:56:03.193] applicationShouldTerminateAfterLastWindowClosed 被调用 → true   ← 12ms 后又来
/// [16:56:03.202] confirmClose：准备弹窗（有未保存的改动）
/// ```
///
/// 用户唯一的出路是选「保存 / 不保存」。
///
/// ## 怎么办
///
/// 拦 `NSWindowDelegate.windowShouldClose(_:)` —— 那是**窗口真正关闭之前**的同步出口。
/// 返回 `false` 窗口就留着，弹框时机和用户的直觉一致；点「取消」窗口纹丝不动。
///
/// SwiftUI 自己管着窗口的 delegate，所以这里做一层**代理**：把 `window.delegate`
/// 换成我们，除 `windowShouldClose` 之外的**所有消息原样转发回去**
/// （`responds(to:)` + `forwardingTarget(for:)`），SwiftUI 的状态恢复、
/// 窗口动画、`windowWillClose` 收尾等行为都不受影响。
///
/// 真正退出（⌘Q、Dock 菜单退出）那条路不经过窗口，仍然走
/// `AppDelegate.applicationShouldTerminate` —— 那时窗口还在，时机本来就是对的。
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {

    /// 被顶掉的原 delegate（SwiftUI 的 `AppKitWindowController`）。
    ///
    /// ## ⚠️ 必须**强引用**（v1.3.51 崩溃修复，有探针实证）
    ///
    /// 用户报的崩溃（点一下系统标签栏就崩）：
    ///
    /// ```
    /// -[PDFReader.WindowCloseGuard windowDidBecomeKey:]: unrecognized selector sent to instance
    ///   NSWindow becomeKeyWindow → postNotificationName → 观察者 → 崩
    /// ```
    ///
    /// 查出来的机制（`tools/probes/windowdelegateprobe.swift`，能稳定复现同一个崩溃）：
    ///
    /// 1. **窗口的 delegate 会被 AppKit 注册成窗口通知的观察者** ——
    ///    `NSWindowDidBecomeKeyNotification` 对应 `windowDidBecomeKey:`，
    ///    对应关系按 `setDelegate` 那一刻的 `responds(to:)` 建立；
    /// 2. 我们的代理**借用了原 delegate 的答案**（`responds(to:)` 里转发查询），
    ///    所以 AppKit 认为"它会实现 windowDidBecomeKey:"，把我们注册上了；
    /// 3. 但我们自己**没有实现**它 —— 过去靠 `forwardingTarget` 转给原 delegate 顶上；
    /// 4. 而 `original` 是 **weak**，它一旦被释放（产品日志里那句 `原 delegate（nil）`），
    ///    转发目标就没了 → `doesNotRecognizeSelector` → **崩**。
    ///
    /// 两条都修：**强引用**（这里）+ **把通知类回调真的实现出来**（下面那一组）。
    /// 光加 `forwardingTarget` 转发是不够的 —— 通知中心是 `objc_msgSend` 直接发，
    /// 不走 `responds(to:)` 那套礼貌询问。
    private var original: NSWindowDelegate?

    /// 接管的这一刻把原 delegate 记下来。
    func takeOver(from delegate: NSWindowDelegate?) {
        original = delegate
    }

    /// **仅供自检**：丢掉原 delegate（`PDFREADER_AUTOTEST_KEY_NOTIFY` 用）。
    func dropOriginalForSelfCheck() {
        original = nil
    }

    // MARK: - 拦截点

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let diag = Diagnostics.shared

        // ⚠️ **只拦承载文档的窗口。**
        //
        // app 里不止一个窗口 —— 设置窗口（⌘,）也被同一个安装器挂了代理。
        // 不分青红皂白地问下去，用户**关一下设置窗口都会弹"要不要保存 PDF 改动"**。
        // 登记过的（`AppModelBridge` 里那份注册表）才拦。
        //
        // v1.3.40 起"一个文件一个窗口"，所以这里查的是**这个窗口**的那一份，
        // 而不是全应用唯一的那一份。
        guard let appViewModel = AppModelBridge.viewModel(for: sender) else {
            diag.record("windowShouldClose：不是文档窗口（设置 / 面板）→ 直接放行")
            return originalAllowsClose(sender)
        }

        diag.record("windowShouldClose 被调用（点红叉 / ⌘W / 点标签上的叉）—— 窗口还没关，先问")
        for (index, tab) in appViewModel.tabs.enumerated() {
            diag.record("  tab[\(index)]「\(tab.title)」未保存=\(tab.viewModel.hasUnsavedChanges)"
                        + " 关闭提醒=\(AppPreferences.shared.promptToSaveOnClose)")
        }

        // 没有要问的 → 直接放行。
        // 绝大多数情况走这里：本来就没改过东西，或者**上一轮已经问过了**
        //（用户答「不保存」/ 保存成功都会把脏标记清掉，见 `confirmClose`）。
        let pending = appViewModel.tabs.map(\.viewModel).filter { $0.needsCloseConfirmation }
        guard !pending.isEmpty else {
            diag.record("  → 没有要问的 → 放行")
            // ⚠️ 把"看到哪儿了"落盘（位置 + 缩放）**必须在窗口关掉之前** ——
            // `PDFViewModel.pdfView` 是 weak，视图树一销毁就拿不到文档了。
            //（这条路上不会走 `unbind()`，所以要在这里补一次。）
            appViewModel.saveAllProgress()
            return allowClose(sender)
        }

        // 有要问的 → **这次先不放行**，弹完框自己再走一遍（v1.3.56）。
        //
        // ⚠️ 为什么不在这里同步等答案：那得在 AppKit 正处理"关闭"的路上再开一个
        //    modal session，两套状态机互相等 —— 实测会把 app 卡死（用户点完
        //    「不保存」窗口关不掉、app 没反应）。
        //    回 `false` 干净得多：用户答完我们自己 `performClose`，
        //    第二遍进到这里 `pending` 就是空的了。
        diag.record("  → 有 \(pending.count) 份要问 → 先回 false（这次不关），问完再关")
        askThenClose(sender, appViewModel: appViewModel, viewModels: pending)
        return false
    }

    /// 一份一份问；全同意了自己再 `performClose` 把关闭流程走一遍。
    ///
    /// 为什么"一份一份"而不是一次问完：现在一个窗口一个文件，通常只有一份；
    /// 但真有多份时，一次只问一个才对得上用户的直觉（也才对得上弹框里的文件名）。
    private func askThenClose(_ window: NSWindow,
                              appViewModel: AppViewModel,
                              viewModels: [PDFViewModel]) {
        let diag = Diagnostics.shared
        func ask(_ index: Int) {
            guard index < viewModels.count else {
                // ⚠️ 中间用户可能已经把窗口关了 → 别再 performClose 一次
                guard window.isVisible else { return }
                appViewModel.saveAllProgress()
                diag.record("  → 问完了，都同意 → 重新走一遍关闭")
                closeAfterSheetDismissed(window)
                return
            }
            viewModels[index].confirmClose(in: window) { allowed in
                guard allowed else {
                    diag.record("  → 用户取消（第 \(index + 1) 份），窗口保留")
                    return
                }
                ask(index + 1)
            }
        }
        ask(0)
    }

    /// 等窗口上的 sheet **真的收干净**再 `performClose`。
    ///
    /// ⚠️ 这一步不能省（实测踩到）：`beginSheetModal` 的回调是在**用户点完按钮**
    /// 就来的，那一刻 sheet 还在走关闭动画、`window.attachedSheet` 仍非 nil。
    /// 此时调 `performClose` 会被 AppKit **直接忽略** —— 现象是
    /// "日志停在『重新走一遍关闭』，第二次 `windowShouldClose` 压根不来"，
    /// 也就是用户说的**点了「不保存」窗口就关不掉了**。
    private func closeAfterSheetDismissed(_ window: NSWindow, attempt: Int = 0) {
        guard window.isVisible else { return }
        if window.attachedSheet == nil || attempt >= 20 {
            window.performClose(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.closeAfterSheetDismissed(window, attempt: attempt + 1)
        }
    }

    /// 放行，并且**盯住这一下到底关掉了没有**。
    ///
    /// ## 一、为什么**不手动调**原 delegate 的 `windowShouldClose`（v1.3.50）
    ///
    /// v1.3.49 这里会先调一次 `original.windowShouldClose?(sender)`（把最终决定权交给
    /// SwiftUI），拿到"允许"再放行。实跑日志（用户机器上）里连着两次出现这种组合：
    ///
    /// ```
    /// → 放行判定：原 delegate（AppKitWindowController） = 允许 · key=true 标签数=2 …
    /// （0.6 秒过去，窗口还在、可见、没关）
    /// ⚠️ 放行 0.6 秒后窗口还在（原 delegate 没关成）→ 兜底自己 close()
    /// ```
    ///
    /// 也就是说：**它回"允许"、我们也回了 `true`，AppKit 却没关窗口。**
    /// 而翻遍全部日志，那个手动调用**每次都回"允许"**（6/6），一次有用信息都没带回来 ——
    /// 只留下"手动调用别人 delegate 方法"这个副作用（很可能是它把 SwiftUI 那边的
    /// 关窗状态机搅了）。
    ///
    /// 所以现在：**文档窗口能不能关，判定权完全在 `confirmClose()` 手里**（上面刚问过），
    /// 不再去碰原 delegate。只有"不是文档窗口"（设置窗、面板）才照旧原样转发。
    ///
    /// ## 二、放行之后必须确认（不管上面那一条成不成立）
    ///
    /// **不管是谁拦下的，都不该让用户关不掉窗口。** 所以放行后回看一眼，
    /// 窗口还在就自己 `close()` —— 顺带把"关完最后一个窗口要退出"也补上，
    /// 因为程序化 `close()` **不会**触发 `applicationShouldTerminateAfterLastWindowClosed`
    ///（见 `QuitWhenIdle`）。
    private func allowClose(_ sender: NSWindow) -> Bool {
        let diag = Diagnostics.shared
        let originalName = original.map { String(describing: type(of: $0)) } ?? "nil"
        let bar = sender.tabGroup?.isTabBarVisible == true ? "显示" : "隐藏"
        // 这行长日志是"下次再出问题能一眼定位"用的：
        // 原 delegate 是谁、窗口当时什么状态、有没有 sheet 挂着（关不掉的经典原因）
        diag.record("  → 放行：原 delegate（\(originalName)）不参与判定"
                    + " · key=\(sender.isKeyWindow)"
                    + " 标签数=\(sender.tabbedWindows?.count ?? -1)"
                    + " 标签栏=\(bar)"
                    + " edited=\(sender.isDocumentEdited)"
                    + " 挂着的 sheet=\(sender.attachedSheet.map { "「\($0.title)」" } ?? "无")")

        // 兜底：放行了却没关掉 → 自己关（用户的"点了没反应"就是这种）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak sender] in
            guard let sender, sender.isVisible,
                  AppModelBridge.viewModel(for: sender) != nil else { return }
            diag.record("  ⚠️ 放行 0.5 秒后窗口还在（系统没关成）→ 兜底自己 close()")
            sender.close()
            // ⚠️ 这一下是**程序化 close**，AppKit 不会发"最后一个窗口关了"那条回调
            //    → 不自己收尾就变成"0 窗口的僵尸进程"（用户报的"卡死"）
            QuitWhenIdle.afterWindowClosed()
        }
        return true
    }

    /// **系统标签栏上那个 `+` 按钮发的就是这条 action**（"新建一个标签页"）。
    ///
    /// ⚠️ 为什么必须我们自己补：SwiftUI 的窗口类**根本没有这个方法**。实测直接调用会崩：
    ///
    /// ```
    /// *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    /// reason: '-[SwiftUI.AppKitWindow newWindowForTab:]: unrecognized selector sent to instance'
    /// ```
    ///
    /// 也就是说用户点那个 `+` 时，这条 action 在响应链上一路没人接 —— 点了等于没点。
    /// 而**窗口的 delegate 是响应链的一环**，在这里实现它，就等于把这个空补上了。
    ///
    /// ⚠️ 不要把它转发给原 delegate —— 原 delegate 是 SwiftUI 的对象，同样没有这个方法。
    @objc func newWindowForTab(_ sender: Any?) {
        Diagnostics.shared.record("系统标签栏「+」：收到 newWindowForTab → 开一个空标签页")
        AppModelBridge.openWindowAction?(id: DocumentOpener.sceneID)
    }

    /// 窗口真的关掉了 → 从注册表里摘掉这一份。
    ///
    /// ⚠️ 两份活都得干，缺一不可：
    /// 1. `prepareForClose()` 释放 security scope、取消 `unbind()` 该做的收尾
    ///    （窗口被关时 SwiftUI 会拆掉视图树，之后没人再有机会调它）；
    /// 2. 从 `AppModelBridge` 里摘掉 —— 那份引用是**强引用**（为了让关闭确认问得出来），
    ///    不摘就是内存泄漏，而且 `applicationShouldTerminate` 会对着已经关掉的窗口再问一遍。
    ///
    /// ⚠️ 我们实现了 `windowWillClose` 就等于**接下了**这条消息，
    /// `forwardingTarget` 不会再转发 —— 所以结尾必须手动交回原 delegate。
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           let viewModel = AppModelBridge.viewModel(for: window) {
            Diagnostics.shared.record("windowWillClose：收尾「\(viewModel.selectedTab?.title ?? "空窗口")」")
            viewModel.prepareForClose()
            AppModelBridge.unregister(window)
            // "这个窗口的标签栏已经处理过了"那条记录也清掉 —— 否则同一个
            // `ObjectIdentifier` 被新窗口复用时会误判成"已经开过了"（v1.3.45）
            DocumentWindows.forget(window)
            // ⚠️ 收尾完了就把代理自己从注册表里摘掉（**下一轮主队列**，见 `forget` 的说明）。
            //    我们手里现在强引用着原 delegate，不摘的话窗口/控制器会被一直扣着。
            DispatchQueue.main.async { WindowCloseGuardInstaller.forget(window) }
            // 最后一个文档窗口没了 → 该退出 app 了。
            // ⚠️ 不能只指望 `applicationShouldTerminateAfterLastWindowClosed` ——
            //    那条回调**只在"用户主动关窗"的路上**才会发，见 `QuitWhenIdle`。
            QuitWhenIdle.afterWindowClosed()
        }
        // 交回 SwiftUI 原本的 delegate
        original?.windowWillClose?(notification)
    }

    /// 通过之后把判断交回原 delegate —— SwiftUI 可能有自己的收尾逻辑。
    /// 它没实现这个方法就按「允许」处理。
    private func originalAllowsClose(_ sender: NSWindow) -> Bool {
        if let original,
           original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return original.windowShouldClose?(sender) ?? true
        }
        return true
    }

    // MARK: - 「通知类」回调：**动态兜底**（v1.3.51 崩溃修复）
    //
    // ## 背景
    //
    // AppKit 会把窗口的 delegate 注册成一批窗口通知的观察者，对应关系按名字来：
    // `NSWindowDidBecomeKeyNotification` → `windowDidBecomeKey:`。
    // 我们的代理借用了原 delegate 的 `responds(to:)` 答案，所以**会被注册**；
    // 但这些都是我们自己没实现的方法 —— 过去靠 `forwardingTarget` 转给原 delegate 顶上，
    // 而原 delegate 一旦没了，转发链断在 nil 上，通知中心是直接 `objc_msgSend` 发的
    // （**不会**先问 `responds(to:)`），于是 `doesNotRecognizeSelector` → **整个 app 崩掉**。
    //
    // ## 为什么不是"把这批方法一个个写出来"
    //
    // 试过：按公开通知名写全了 25 个，真 app 里紧接着又崩在
    // `windowDidOrderOffScreen:` 上 —— 而这个名字**在 AppKit 头文件里查不到**
    // （内部通知）。照名单枚举是打地鼠，补不完。
    //
    // ## 做法：让运行时按需补一个"转发实现"
    //
    // `+resolveInstanceMethod:` 是在"消息找不到实现"时被调用的第一个钩子，
    // 我们在这里用 `class_addMethod` + `imp_implementationWithBlock` 现补一个实现进去 ——
    // 于是任何窗口回调都有了着落：**原 delegate 能处理就转过去，处理不了就什么都不做**。
    // 补进去的实现会被运行时缓存，不会反复走这条路。
    //
    // ⚠️ 两个边界（都在探针里验过）：
    // - 只认"通知镜像"那一族：名字以 `windowDid` / `windowWill` 开头、且**只有一个冒号**。
    //   `window:willUseFullScreenContentSize:` 这类"窗口当第一个参数"的名字，
    //   `window` 后面紧跟冒号，不在范围内；
    // - `windowWillReturnUndoManager:` 这种名字像、但有返回值/多参数的，单独列进拒绝名单
    //   （塞个 `v@:@` 进去会把调用栈搞坏）。
    // - 另外：`methodSignatureForSelector:` + `forwardInvocation:` 那条路在 Swift 里
    //   **写不了**（`NSInvocation` 被标成 unavailable），所以才走运行时补实现这条路。

    /// 名字像通知镜像、但**不是**（有返回值 / 多参数）—— 一律不碰，交回运行时按老路走。
    private nonisolated static let notNotificationMirrors: Set<String> = [
        "windowWillReturnUndoManager:",
        "windowWillReturnFieldEditor:toObject:",
        "windowWillUseStandardFrame:defaultFrame:",
        "windowWillResizeForVersionBrowserWithMaxPreferredSize:maxAllowedSize:",
    ]

    nonisolated override class func resolveInstanceMethod(_ selector: Selector) -> Bool {
        let name = NSStringFromSelector(selector)
        guard name.hasPrefix("windowDid") || name.hasPrefix("windowWill") else { return false }
        // 通知镜像只有一个参数（那条通知）→ 恰好一个冒号
        guard name.filter({ $0 == ":" }).count == 1 else { return false }
        guard !notNotificationMirrors.contains(name) else { return false }

        let block: @convention(block) (AnyObject, Notification) -> Void = { object, notification in
            // ⚠️ 这个 block 是 nonisolated 的（运行时按 C 函数调它），
            //    而 `forwardWindowCallback` 是主线程隔离的 —— 窗口通知本来就都在主线程发，
            //    所以这里 `assumeIsolated` 是成立的（和本项目别处的写法一致）。
            MainActor.assumeIsolated {
                guard let guardObject = object as? WindowCloseGuard else { return }
                guardObject.forwardWindowCallback(selector, notification: notification)
            }
        }
        class_addMethod(self, selector, imp_implementationWithBlock(block), "v@:@")
        Diagnostics.shared.record("窗口代理：动态补上未实现的窗口回调 \(name)")
        return true
    }

    /// 动态补进来的实现干的事：**原 delegate 能处理就转过去，处理不了就什么都不做**。
    ///
    /// 转发用 `perform(_:with:)`（`Notification` 是对象参数，签名对得上）。
    private func forwardWindowCallback(_ selector: Selector, notification: Notification) {
        guard let original, original.responds(to: selector) else { return }
        _ = (original as AnyObject).perform(selector, with: notification)
    }

    // MARK: - 把其它消息还给原 delegate
    //
    // 只实现 `windowShouldClose` 的话，SwiftUI 那一整套 delegate 回调就全断了
    // （窗口动画、状态保存、`windowWillClose` 收尾…）。这两段负责把没实现的消息
    // 原样转发出去，等价于"我们只是中间加了一层过滤"。

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// 给窗口装关闭确认代理（幂等）。
///
/// 安装时机：窗口**第一次成为 key / main** 时（`AppDelegate` 里挂了通知）。
/// 必须是"关窗口之前"，否则拦截无从谈起。
@MainActor
enum WindowCloseGuardInstaller {

    /// ⚠️ **必须强引用。** `NSWindow.delegate` 是 weak —— 不在这里拿住的话，
    /// 装上去的那一瞬间就会被释放，窗口 delegate 变回 nil，什么都拦不到。
    private static var guards: [ObjectIdentifier: WindowCloseGuard] = [:]

    static func install(on window: NSWindow) {
        // 已经装过就别重装（这个通知会来很多次）
        if window.delegate is WindowCloseGuard { return }
        // 有些窗口不该拦：面板、弹出窗、我们的诊断/设置窗口都不是"文档窗口"
        guard window.styleMask.contains(.titled), window.isVisible else { return }
        // ⚠️ **面板 / 弹框一律不碰**（v1.3.58 踩到的大坑）。
        //
        // 给它们装代理会**顺带改掉它们的 `tabbingIdentifier`** —— 实测日志里 alert 窗口变成：
        //
        // ```
        // 窗口「」 是文档窗口=false
        // tabbingIdentifier=_NSAlertPanel-PDFReaderApp.WindowCloseGuard-(null)-HT-  标签栏=显示
        // ```
        //
        // 系统于是认为"这个窗口也参与自动标签页"，**给确认框画了一条标签栏 + `+` 按钮**。
        // 用户的原话就是："这个弹框上面出现一个选项条和 `+` 按钮"，
        // 而且点那个 `+` 真能开新标签（正是我们的代理把 `newWindowForTab` 接上了）。
        //
        // 判据用两条：面板类（`NSPanel`，`NSAlert` 的窗口就是）、以及非 normal 层级的窗口。
        guard !(window is NSPanel), window.level == .normal else {
            Diagnostics.shared.record("窗口关闭确认：跳过「\(window.title)」"
                                      + "（面板/弹框，level=\(window.level.rawValue)）")
            return
        }

        let guardObject = WindowCloseGuard()
        guardObject.takeOver(from: window.delegate)
        // ⚠️ **装之前先记下 `tabbingIdentifier`**（v1.3.60）。
        //
        // 换 `delegate` 会**顺带把这个窗口的 `tabbingIdentifier` 改掉** ——
        // 系统按 delegate 的类名重算它（v1.3.58 在 alert 上实测到
        // `_NSAlertPanel-…WindowCloseGuard-…`）。而这个属性非空就意味着
        // "这个窗口参与系统自动标签页"，**系统于是给窗口画一条标签栏**。
        //
        // 文档窗口本来就该有标签栏（那个 identifier 是 SwiftUI 给的
        // `SwiftUI-WindowGroup-document`，不改它就没事）；但**设置窗口不该有** ——
        // 用户看到的"app 设置里也冒出一条白条 + `+`"就是这么来的。
        let originalTabID = window.tabbingIdentifier
        guards[ObjectIdentifier(window)] = guardObject
        window.delegate = guardObject
        // 装完立刻把前后两个值都记下来 —— "到底是不是这一步把标签栏勾出来的"，
        // 靠这条日志一眼判断（不打就只能猜）。
        let afterTabID = window.tabbingIdentifier
        Diagnostics.shared.record("窗口关闭确认：「\(window.title)」装代理前后 tabbingIdentifier"
                                  + " = 「\(originalTabID)」→「\(afterTabID)」"
                                  + " tabbingMode=\(window.tabbingMode.rawValue)")
        if afterTabID != originalTabID {
            window.tabbingIdentifier = originalTabID
            Diagnostics.shared.record("  → 已还原成「\(originalTabID)」"
                                      + "（不还原系统会给这个窗口画标签栏）")
        }
        // 面板/弹框类窗口的标签页身份由 `windowDidBecomeKeyOrMain` 那条路统一处理
        Diagnostics.shared.record("窗口关闭确认：已安装（代理 window.delegate，拦截 windowShouldClose）")
    }

    /// 把**不是文档窗口**的那些窗口的"标签页身份"摘掉（v1.3.61 起，v1.3.62 推广）。
    ///
    /// ## 为什么
    ///
    /// 系统只看 `tabbingIdentifier` 非空就认为"这窗口参与自动标签页"，**给它画一条标签栏**。
    /// 而下面这些窗口**不是我们创建的**（是 SwiftUI 或系统弹的），我们够不着它们 ——
    /// 但它们**成为 key 窗口时会经过 `windowDidBecomeKeyOrMain`**，就地摘掉即可：
    ///
    /// - **SwiftUI 的 `.alert`**（用户两次报"弹框上浮着一条白条 + `+`"，就是它）；
    /// - **SwiftUI 的 `Settings` 场景窗口**（`tabbingIdentifier = "SwiftUI-Settings"`）；
    /// - 其它系统面板。
    ///
    /// 文档窗口**不能**摘 —— 它的标签栏是多文件切换的功能（v1.3.40）。
    static func stripTabbingIdentity(of window: NSWindow) {
        guard !window.tabbingIdentifier.isEmpty else { return }
        let before = window.tabbingIdentifier
        window.tabbingIdentifier = ""
        window.tabbingMode = .disallowed
        Diagnostics.shared.record("摘掉标签页身份：「\(window.title)」（原 identifier=「\(before)」）"
                                  + " —— 它不是文档窗口，不该有标签栏")
    }

    /// 旧的专用版（v1.3.61）—— 现在统一走 `stripTabbingIdentity`。

    /// 窗口真关掉之后把代理放掉。
    ///
    /// ⚠️ 必须做，而且**要延后一轮主队列**（`windowWillClose` 里安排的）：
    ///
    /// - 不摘的话，`guards` 这个静态字典会一直扣着代理；而代理现在**强引用着**原 delegate
    ///   （SwiftUI 的 `AppKitWindowController`）—— 那会连带把窗口/文档一起扣住，是实打实的泄漏；
    /// - 延后是为了让**本次关闭流程剩下的回调**还能转发出去（`windowWillClose` 之后
    ///   AppKit 还会发几条通知），过了这一轮再放手就安全了。
    static func forget(_ window: NSWindow) {
        guards.removeValue(forKey: ObjectIdentifier(window))
    }

    /// 供自检用：这个窗口现在是不是被我们代理着
    static func isInstalled(on window: NSWindow) -> Bool {
        window.delegate is WindowCloseGuard
    }

    /// 供自检用：现在还扣着几个代理（关掉的窗口应该都被摘掉了）
    static var installedCount: Int { guards.count }

    /// **仅供自检**：把某个窗口那份代理里的"原 delegate"丢掉，
    /// 复现用户崩溃的前提条件（注册时它还在、之后它没了）。
    ///
    /// 正常使用永远不会调到 —— 只有 `PDFREADER_AUTOTEST_KEY_NOTIFY` 那个钩子会调。
    static func dropOriginalForSelfCheck(on window: NSWindow) {
        (guards[ObjectIdentifier(window)])?.dropOriginalForSelfCheck()
    }
}

/// 窗口关完之后的收尾：**一个文档窗口都不剩了就退出 app**（v1.3.50）。
///
/// ## 为什么必须自己退 —— 用户日志实锤
///
/// `applicationShouldTerminateAfterLastWindowClosed` **只在"用户主动关窗"那条路上**
/// （`performClose:` / 点红叉 / ⌘W）才会被 AppKit 发出。我们自己调 `NSWindow.close()`
/// 关掉最后一个窗口时，它**不会**发。用户机器上两次都是这样，日志断在这里：
///
/// ```
/// ⚠️ 放行 0.5 秒后窗口还在（系统没关成）→ 兜底自己 close()
/// windowWillClose：收尾「合集2.3.pdf」
/// 窗口注销：还剩 0 个文档窗口
///            ← 就断在这儿：没有 applicationShouldTerminateAfterLastWindowClosed，
///              也没有退出
/// ```
///
/// 对照同一份日志里"点红叉关掉最后一个窗口"那次：注销后 **62 毫秒**就
/// `applicationShouldTerminateAfterLastWindowClosed 被调用 → true` 并正常退出。
///
/// 于是用户看到的是「窗口全没了、app 还在 Dock 里、点它没反应、再打开文件也没反应」——
/// 就是他说的"卡死"。
@MainActor
enum QuitWhenIdle {

    /// 有窗口刚被关掉时调一次：确认"真的一个都不剩"了就退出。
    ///
    /// 查两轮（0.25s / 再加 0.4s）而不是查一次 —— 期间可能正好有一个新窗口在出现
    /// （打开新文件、⌘T），那种情况**不该退**。
    static func afterWindowClosed(attempt: Int = 0) {
        let delay: Double = attempt == 0 ? 0.25 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 还有文档窗口 → 正常，什么都不做
            guard AppModelBridge.allViewModels.isEmpty else { return }
            // 正在打开文件（队列里有、或者窗口在路上）→ 那是"换一个窗口"，不是"要退出"
            guard !DocumentOpener.hasPendingOpens else { return }
            guard attempt < 2 else { return }
            if attempt == 0 {
                afterWindowClosed(attempt: 1)     // 再确认一轮
                return
            }
            Diagnostics.shared.record("最后一个文档窗口已关闭 → 主动退出"
                                      + "（程序化 close() 不会触发最后窗口关闭回调）")
            NSApp.terminate(nil)
        }
    }
}
