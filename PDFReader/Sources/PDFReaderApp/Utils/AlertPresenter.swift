import AppKit

/// 把 `NSAlert` **挂在窗口上当 sheet** 显示，并**异步**把用户的选择回调给调用方。
///
/// ## 一、为什么是 sheet，不是独立弹窗
///
/// 原来的"要保存改动吗"用的是 `alert.runModal()` —— 那是一个**独立窗口**，
/// 会自己飘在屏幕上。杰哥截图看到的是：
///
/// ```
/// ┌──────────────────┬───┐
/// │   （空白的白条）      │ + │   ← 窗口自己的系统标签栏，压在提示框上
/// ├──────────────────┴───┤      而且那个 + 还能点
/// │  [app 图标被切掉一半]      │
/// ```
///
/// 根因：系统标签栏属于**窗口自己**，独立的 alert 窗口和它各画各的，
/// 位置一重叠就成了"谁在上面看运气"。挂成 sheet 就对了 —— 它从标题栏下方滑出、
/// 盖住整个内容区，天然不会和标签栏打架。
///
/// ## 二、为什么是**异步**，而不是"beginSheet + runModal 同步等"
///
/// 中途试过"`beginSheet` 拿外观 + `NSApp.runModal(for:)` 拿同步"这个组合 ——
/// 看着能同时满足两个约束（`windowShouldClose(_:) -> Bool` 和
/// `applicationShouldTerminate` 都是**同步**出口）。
///
/// **结果把 app 卡死了**（杰哥实测：点完「不保存」，窗口关不掉、app 没反应）：
/// 在"AppKit 正在处理关闭"的路上又开一个 modal session，两套状态机互相等。
///
/// 正确做法是**别在同步出口里等** —— 那两个出口本来就给了异步的路子：
///
/// | 出口 | 先回什么 | 问完之后 |
/// |---|---|---|
/// | `windowShouldClose(_:)` | 回 `false`（**这次先别关**） | 自己再 `performClose` 走一遍 |
/// | `applicationShouldTerminate` | 回 `.terminateLater` | `NSApp.reply(toApplicationShouldTerminate:)` |
///
/// 两次进入 `windowShouldClose` 不会重复弹框：用户的答复会把脏标记清掉
///（「不保存」会清、保存成功也算清），第二遍 `needsCloseConfirmation` 自然是 false。
///
/// ## 三、顺手治掉的两个小毛病（现场 dump 视图树查出来的）
///
/// - `alert.showsSuppressionButton = false` 这版 macOS 上**没用** ——
///   「不再显示此消息」那个未本地化的英文复选框照样画出来，只能建好窗口后按文案藏掉；
/// - `alert.window` 只把窗口建出来、**不按内容量高**，直接 `beginSheet` 会让
///   标题和正文各只剩一行、长一点就截断 —— 得补 `alert.layout()`。
@MainActor
enum AlertPresenter {

    /// 挂在 `window` 上问；窗口不可用就退回独立弹窗。答案走 `completion`。
    ///
    /// - Parameter completion: **一定**会被调用一次（在主线程）。调用方靠它决定
    ///   后续动作，别在里面再开嵌套的 modal。
    static func present(_ alert: NSAlert,
                        on window: NSWindow?,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        alert.showsSuppressionButton = false
        guard let window, window.isVisible, window.attachedSheet == nil else {
            // 没窗口可挂（退出流程里窗口可能已经没了）→ 退回独立弹窗。
            // ⚠️ 这里也**先 async 一轮**再 `runModal()`：调用方可能正站在
            //    "关窗口 / 退出"的同步出口上，就地阻塞会把状态机顶死（踩过）。
            DispatchQueue.main.async {
                let fallback = alert.window
                hideSuppressionButton(in: fallback)
                completion(alert.runModal())
            }
            return
        }
        // ⚠️ 先摸一下 `alert.window`：alert 的窗口是**懒创建**的，
        //    访问它才会真正建出来（按钮也在那一刻布局好）。
        let sheet = alert.window
        alert.layout()
        sheet.layoutIfNeeded()
        hideSuppressionButton(in: sheet)
        // ⚠️ **不许它跟文档窗口"拼标签页"**（v1.3.58）。
        //
        // 文档窗口在标签组里时，系统会顺手也给它的 sheet 画一条标签栏 ——
        // 于是弹框**上面多出一条"选项条 + `+`"**（用户的原话），
        // 那个 `+` 就是标签栏的"新建标签页"（点它真会开新标签）。
        //
        // 主因是 `WindowCloseGuardInstaller.install` 把关闭确认代理装到了面板上、
        // 顺带改了它的 `tabbingIdentifier`（已在那里修）；这里再把
        // "标识符清空 + 明确禁止"一起钉上 —— 两条一起才压得住
        //（只设 `tabbingMode` 实测不管用，系统照样给它画）。
        sheet.tabbingIdentifier = ""
        sheet.tabbingMode = .disallowed
        if ProcessInfo.processInfo.environment["PDFREADER_AUTOTEST_DUMP_ALERT"] != nil {
            dumpAlertTree(sheet)
        }
        // ⚠️ **必须用 `beginSheetModal(for:)`**，不能自己 `window.beginSheet(alert.window)`。
        //
        // 自己挂 sheet 的话，用户点按钮时 NSAlert 走的是它自己的那套收尾
        //（`stopModal`），**不会**去 `endSheet` —— 于是我们传进 `beginSheet` 的
        // completionHandler **永远不会被调用**：弹框看着点了、流程却停在原地。
        // 实测：点完「不保存」窗口关不掉、app 一直不动（`timeout` 40 秒后被杀，exit=124）。
        // `beginSheetModal` 是 NSAlert 专门为 sheet 给的接口，它内部会把
        // "结束 sheet + 回调"这两件事一起做掉。
        alert.beginSheetModal(for: window) { response in
            completion(response)
        }
    }

    /// 便利版：按一个视图找它所在的窗口（`PDFContentView` 那类地方手上只有 `pdfView`）。
    static func present(_ alert: NSAlert,
                        near view: NSView?,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        present(alert, on: view?.window, completion: completion)
    }

    /// 便利版：给标题 + 正文 + 一串按钮，直接弹（v1.3.62）。
    ///
    /// 专给"SwiftUI 的 `.alert` 搬过来"用 —— 那些地方原来都是声明式的 state 驱动，
    /// 搬到这边只要给个按钮数组和"点了第几个"的回调。
    ///
    /// - Parameter completion: 参数是**按钮下标**（0 = 第一个）。
    @discardableResult
    static func present(title: String,
                        message: String,
                        buttons: [String],
                        style: NSAlert.Style = .informational,
                        on window: NSWindow?,
                        completion: @escaping (Int) -> Void = { _ in }) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        present(alert, on: window) { response in
            let base = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            completion(response.rawValue - base)
        }
        return alert
    }

    /// 藏掉系统那个「不再显示此消息」复选框。
    ///
    /// ## 为什么设了 `showsSuppressionButton = false` 还得手动藏
    ///
    /// 实测（这版 macOS，视图树 dump 出来的）：
    ///
    /// ```
    /// _NSAlertContentView 0,0 260×328
    ///   NSButton 20,147 218×18 hidden=false title=「<Do not show this message again>」
    /// ```
    ///
    /// —— 设成 false 它照样画，标题还是**未本地化的英文**（还带着尖括号）。
    /// 既然就挂在 alert 的视图树上，那就窗口一建好把它藏掉。
    ///
    /// 为什么非要藏掉：这是个"要不要保存"的确认框，
    /// **让用户能"不再提示"是危险的** —— 勾一次以后所有改动都悄悄丢掉。
    /// 想要这个效果的人应该去设置里关「关闭时提醒」，那里才是正经入口。
    private static func hideSuppressionButton(in window: NSWindow) {
        guard let content = window.contentView,
              let button = firstSuppressionButton(in: content) else { return }
        button.isHidden = true
    }

    /// 按**文案**找那个复选框。
    ///
    /// 不按私有类名找（`_NSAlertButton` 那类是私有 API，名字随时会变）；
    /// 中英文两种写法都认一下，免得系统语言一变就失效。
    private static func firstSuppressionButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           button.title.contains("Do not show") || button.title.contains("不再显示") {
            return button
        }
        for sub in view.subviews {
            if let found = firstSuppressionButton(in: sub) { return found }
        }
        return nil
    }

    /// **仅供排查**：把这个 alert 窗口的视图树写进诊断日志
    ///（`PDFREADER_AUTOTEST_DUMP_ALERT=1` 开）。
    ///
    /// 就是靠它查出上面那个复选框的真身、以及"文字被截成一行"的原因 ——
    /// 不然只能对着截图猜。
    private static func dumpAlertTree(_ window: NSWindow) {
        let diag = Diagnostics.shared
        diag.record("[alert 视图树] 窗口 \(Int(window.frame.width))×\(Int(window.frame.height))")
        func walk(_ view: NSView, depth: Int) {
            let indent = String(repeating: "  ", count: depth + 1)
            var extra = ""
            if let button = view as? NSButton {
                let action = button.action.map { NSStringFromSelector($0) } ?? "nil"
                extra = " title=「\(button.title)」 action=\(action)"
                    + " enabled=\(button.isEnabled)"
                    + " id=\(button.identifier?.rawValue ?? "nil")"
                    + " tip=\(button.toolTip ?? "nil")"
            }
            diag.record("[alert 视图树] \(indent)\(type(of: view)) "
                        + "\(Int(view.frame.origin.x)),\(Int(view.frame.origin.y)) "
                        + "\(Int(view.frame.width))×\(Int(view.frame.height))"
                        + " hidden=\(view.isHidden)\(extra)")
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        if let content = window.contentView { walk(content, depth: 0) }
    }
}
