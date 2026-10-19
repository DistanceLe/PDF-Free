import AppKit
import SwiftUI

/// 把「Xcode 的 Metal API Validation」挡掉（v1.3.53）。
///
/// ## 为什么需要它 —— 用户报的"滚动就死"就是这么来的
///
/// 杰哥报 `合集2.3.pdf`（246MB / 84 页）**不管怎么打开，滚动一下就死**。
/// 命令行 Release 版反复滚 500 步都好好的，一直复现不出来。
/// 差别在**运行方式**：他是在 Xcode 里 ⌘R 跑，而 Xcode 的
/// Run → Diagnostics → **Metal API Validation 默认是开着的**。
///
/// 复现出来之后，崩溃现场写得明明白白（`diagnostics.log` 里的信号遗言）：
///
/// ```
/// abort
/// MTLReportFailure
/// _MTLMessageContextEndNewNSErrorOrAbort
/// -[MTLDebugRenderCommandEncoder validateCommonDrawErrors:…]
/// -[MTLDebugRenderCommandEncoder drawPrimitives:…]
/// CA::OGL::MetalContext::draw
/// CA::OGL::MetalContext::stroke_lines      ← PDF 页面里的矢量线条
/// CA::CG::WideLineRenderer::flush
/// ```
///
/// 也就是：**PDFKit 画页面上的线条 → CoreAnimation 走 Metal → 验证层判定这次
/// draw call 有问题 → 直接 `abort()`**。跟我们的代码无关（项目里一行 Metal 都没有），
/// 是"给写 Metal 的人用的调试层"在 PDFKit 的内部实现上误报。
///
/// 对照实验（同一份二进制，只差这一个环境变量，都是沙盒 Debug 构建）：
///
/// | 运行条件 | 滚 600 步的结果 |
/// |---|---|
/// | `MTL_DEBUG_LAYER=1`（Xcode 默认开） | **13.9 秒后 SIGABRT** |
/// | 不设 | 滚完 600 步，进程好好的 |
///
/// ## 怎么办
///
/// 把 `MTL_DEBUG_LAYER` 摘掉。**时机必须极早** —— Metal 是在**创建 MTLDevice
/// 的那一刻**读它的（CoreAnimation 首次渲染时），晚一步就没用。
/// `App.init()` 是能拿到的最早位置：比 `NSApplicationMain` 还早，
/// 更远早于第一个窗口上屏。
///
/// ⚠️ 只摘这一个开关：`MTL_DEBUG_LAYER` 管的是"要不要启用验证层"，
/// 别的诊断（GPU 帧捕获、着色器验证）不受影响。项目不用 Metal，关掉零损失。
enum DebugMetalValidation {

    static func neutralize() {
        let env = ProcessInfo.processInfo.environment
        guard env["MTL_DEBUG_LAYER"] != nil || env["MTL_DEBUG_LAYER_ERROR_MODE"] != nil else { return }
        unsetenv("MTL_DEBUG_LAYER")
        unsetenv("MTL_DEBUG_LAYER_ERROR_MODE")
        unsetenv("MTL_DEBUG_LAYER_WARNING_MODE")
        Diagnostics.shared.record("⚠️ 检测到 Xcode 的「Metal API Validation」是开着的"
                                  + "（Run → Diagnostics 里那个调试开关）—— 已主动关掉："
                                  + "验证层会在 PDFKit 画页面线条时误报并 abort，"
                                  + "表现就是「大文件滚一下就死」")
    }
}

@main
struct PDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        DebugMetalValidation.neutralize()
    }

    var body: some Scene {
        // ⚠️ **一个文件 = 一个窗口**（v1.3.40）。
        //
        // 加了 `id:` 之后才给 SwiftUI 一个稳定的场景标识 ——
        // 不过真正让"多窗口自动并成标签页"生效的，是 `WindowGroup` 本身：
        // 它给窗口设了 `tabbingIdentifier = SwiftUI-WindowGroup-…`，
        // 而 `tabbingMode` 是 automatic（实测诊断日志）。所以同类型的窗口会被
        // macOS 自动收进**系统标签栏**，`+` 新建、拖动重排、⌘W 关当前标签全都白拿。
        //
        // 关闭确认也因此还是走 `windowShouldClose`（每个窗口一次），
        // 而"关到最后一个才退出"就是系统对标签页天然的行为。
        WindowGroup(id: "document") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") {
                    DocumentOpener.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                // 和系统标签栏上那个 `+` 完全等价：开一个空标签页
                Button("新建标签页") {
                    AppModelBridge.openWindowAction?(id: DocumentOpener.sceneID)
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            // 打印：替换系统的「打印…」项，⌘P 打开我们的打印设置面板
            CommandGroup(replacing: .printItem) {
                Button("打印…") {
                    NotificationCenter.default.post(name: .pdfPrint, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            // 查找：放进「编辑」菜单的粘贴板组之后，这是 macOS 的惯用位置
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("查找…") {
                    NotificationCenter.default.post(name: .pdfFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("查找下一个") {
                    NotificationCenter.default.post(name: .pdfFindNext, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("查找上一个") {
                    NotificationCenter.default.post(name: .pdfFindPrevious, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            // 阅读与批注相关命令（v1.0）
            CommandMenu("阅读") {
                Button("朗读 / 暂停") {
                    NotificationCenter.default.post(name: .pdfSpeakToggle, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("停止朗读") {
                    NotificationCenter.default.post(name: .pdfSpeakStop, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("自动滚动开关") {
                    NotificationCenter.default.post(name: .pdfToggleAutoScroll, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }

            CommandMenu("批注") {
                Button("添加文本注释…") {
                    NotificationCenter.default.post(name: .pdfAddTextAnnotation, object: nil)
                }

                Button("添加便签…") {
                    NotificationCenter.default.post(name: .pdfAddNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("手写签名…") {
                    NotificationCenter.default.post(name: .pdfAddSignature, object: nil)
                }

                Button("OCR 文字识别…") {
                    NotificationCenter.default.post(name: .pdfRunOCR, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                Button("保存批注到 PDF") {
                    NotificationCenter.default.post(name: .pdfSaveAnnotations, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            // 窗口菜单：把"最大化 / 还原"和"进入全屏"的键位补上（v1.3.37）
            //
            // SwiftUI 的 `WindowGroup` 只自动提供「最小化 ⌘M」，**没有**给
            // 「缩放（最大化 / 还原）」任何键位 —— 那个动作只能双击标题栏或
            // 点绿色按钮，用户要的就是给它一个快捷键。
            //
            // 键位选择：`⌃⌘F` 是 macOS 上「进入全屏」的**系统默认**，原样沿用；
            // 「缩放」在 macOS 上本来就没有官方默认键位，取 `⌘⌥M`
            //（和系统的「最小化 ⌘M」成对，好记）。
            CommandGroup(before: .windowList) {
                Button("缩放窗口（最大化 / 还原）") {
                    NSApp.keyWindow?.performZoom(nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Button("进入全屏") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])

                Divider()
            }

            // 显示菜单：「页面管理」——平铺所有页，可多选 / 调序 / 删除 / 插空白页（v1.3.42）
            CommandGroup(after: .toolbar) {
                Divider()
                Button("页面管理…") {
                    NotificationCenter.default.post(name: .pdfManagePages, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                // 插入空白页（v1.3.44）。
                //
                // ⚠️ 这里**不走通知广播**，而是直接拿 key 窗口那份 viewModel 调 ——
                // 菜单命令的广播在"一个文件一个窗口"之后要在每个接收方自己做
                // `isInActiveWindow` 过滤（见 `PDFContentView`），而这条命令的目标
                // 本来就是"当前窗口"，直接取过来更简单，也不用再往那条
                // 已经很长的 `.onReceive` 链上加东西了。
                Button("插入空白页") {
                    guard let viewModel = AppModelBridge.keyViewModel?.tabs.first?.viewModel
                    else { return }
                    viewModel.insertBlankPages(after: [viewModel.currentPageIndex], count: 1)
                }
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
            }

            // 撤销 / 重做（⌘Z / ⇧⌘Z）
            //
            // ⚠️ 用 `replacing: .undoRedo` 把系统默认那对换掉：它们在本 app 里是**死的**
            // （没有任何响应者实现 `undo:`，点了没反应），留着只会让人以为不支持撤销。
            //
            // 但**文本框里的 ⌘Z 必须留给文字**（搜索框、便签/文本注释输入框）——
            // 所以先看焦点在不在文本框上，是就把标准的 `undo:` 交回响应链。
            CommandGroup(replacing: .undoRedo) {
                Button("撤销批注") {
                    routeUndo(selector: "undo:", notification: .pdfUndo)
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("重做批注") {
                    routeUndo(selector: "redo:", notification: .pdfRedo)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        // 设置窗口（⌘,）：保存与备份的偏好。
        //
        // 用 `Settings` scene 而不是自己弹 sheet —— macOS 的惯例入口就是
        // app 菜单里的「设置…」，声明它之后系统会自动接好菜单项与 ⌘,。
        // （目录面板底部还有一个齿轮按钮，指向同一个视图。）
        Settings {
            SavePreferencesView()
        }
    }

    /// ⌘Z / ⇧⌘Z 的分流：焦点在文本框里时交给文本系统，否则发给批注撤销。
    ///
    /// 这里**显式判断焦点**，而不是"`sendAction(undo:)` 返回 false 才兜底" ——
    /// `NSWindow` 自己也可能接住 `undo:`（它的响应链里有 undoManager），
    /// 那样 `sendAction` 会返回 true，批注撤销就永远轮不到了。
    private func routeUndo(selector name: String, notification: Notification.Name) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(Selector(name), to: nil, from: nil)
            return
        }
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// ⌘W 的自定义处理**已经删掉了**（v1.3.40）。
    ///
    /// v1.3.37 时用 `NSEvent.addLocalMonitorForEvents` 抢 `⌘W`，因为那时所有文件挤在
    /// 一个窗口里、系统不知道"关闭"该关谁。现在一个文件一个窗口、系统标签页自己管：
    /// **`⌘W` 关当前标签、`⌥⌘W` 关整个窗口、关到最后一个才退出 app** —— 系统全包了，
    /// 我们再拦一次反而会把系统行为搅乱。
    ///
    /// ⚠️ v1.3.68 起鼠标事件监听搬进了 `Diagnostics`（`installMouseMonitor`）——
    /// 它是常驻开销，得归「诊断」总开关统一装 / 拆，而开关是运行时就能改的，
    /// 放在 AppDelegate 里够不着。这里不再保留任何诊断设施。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 版本号统一成 `1.0 (1)` 之后分不清是哪次构建，日志里带上构建时刻（见 `AppInfo.buildStamp`）
        //
        // ⚠️ 诊断关着（Release 默认）时这一句**什么都不做**：不建日志文件、
        // 不装看门狗、不起卡死检测线程。用户在「设置 → 诊断」里打开即可。
        Diagnostics.shared.startSession(version: "\(AppInfo.version) · 构建 \(AppInfo.buildStamp)")

        // 关闭确认的拦截点（v1.3.32）：把窗口 delegate 换成我们的代理，
        // 这样"有没有未保存的改动"是在**窗口真正关闭之前**问的。
        // 不装的话就退回 `applicationShouldTerminate`，那是窗口关掉之后 ——
        // 用户看到的正是"文件已经关了才弹框"，点取消还找不回窗口。
        installCloseGuards()

        // 崩溃也要留下遗言（v1.3.52）。**这一条不受诊断开关影响**（见下）。
        installCrashLogging()

        // 仅供**自动化验证**：打开文件 / 造脏 / 删目录 / 合成拖拽 / 位置与缩放往返 /
        // `--autoquit-after N` 自动关窗口… 全在 `AutomationHooks` 里。
        // **正常使用一个都不设 → 完全没有行为。**
        AutomationHooks.install()
    }

    /// 给每个文档窗口装一层关闭确认代理（见 `WindowCloseGuard`）。
    ///
    /// 为什么盯 "成为 key / main" 两个通知：窗口由 SwiftUI 创建，我们插不进它的
    /// 创建流程；而"第一次成为 key"一定发生在用户点红叉之前，时机够用。
    /// `didBecomeMain` 一起盯是为了兜住"窗口没被 key 化就切过去"的情况。
    private func installCloseGuards() {
        // 用 selector 版的通知订阅：block 版要求 `@Sendable` 闭包，
        // 而 `Notification` 本身不是 Sendable —— 强转会被编译器判为数据竞争隐患（会报 warning）。
        // 这两个通知本来就在主线程发，selector 版没有任何额外代价。
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidBecomeKeyOrMain(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidBecomeKeyOrMain(_:)),
                           name: NSWindow.didBecomeMainNotification, object: nil)

        // 启动时窗口可能已经存在（那两个通知在 launch 之前就发过了）→ 补装一次
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if AppModelBridge.viewModel(for: window) == nil {
                    WindowCloseGuardInstaller.stripTabbingIdentity(of: window)
                } else {
                    WindowCloseGuardInstaller.install(on: window)
                }
            }
        }
    }

    @objc private func windowDidBecomeKeyOrMain(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        // ⚠️ **先分流**（v1.3.62）：不是文档窗口的（SwiftUI 自己弹的 `.alert`、
        // 系统面板…），**就地摘掉"标签页身份"** —— 系统见 `tabbingIdentifier` 非空
        // 就会给它画一条标签栏 + `+`，用户两次报"弹框上面浮着白条"都是这个。
        // 那些窗口是 SwiftUI/系统创建的，我们够不着，只能趁它成为 key 的这一下动手。
        //
        // 判据用"登记表里有没有"：文档窗口在 `ContentView.onAppear` 就登记了，
        // 实测**早于**成为 key（日志：登记 09:25:34.443 → 装代理 09:25:34.562）。
        if AppModelBridge.viewModel(for: window) == nil {
            WindowCloseGuardInstaller.stripTabbingIdentity(of: window)
            return
        }
        // 每个文档窗口都要装（现在是多窗口）—— 安装器幂等，重复调没有代价
        WindowCloseGuardInstaller.install(on: window)
        // 新窗口"成为 key"时再补一道：装代理 + 并进系统标签栏（都幂等）。
        // ⚠️ 不能只靠这个通知 —— 并进标签栏之后后台标签永远不会成为 key，
        // 代理就装不上了（见 `DocumentWindows` 的说明）。这里只是多一层保险。
        DocumentWindows.prepareWhenReady(window)
    }

    /// 系统标签栏上那个 `+` 按钮发的 action（"新建标签页"）。
    ///
    /// ⚠️ 必须自己接：SwiftUI 的窗口类没有这个方法（实测直接调用会崩
    /// `-[SwiftUI.AppKitWindow newWindowForTab:]: unrecognized selector`），
    /// 所以这条 action 在响应链上原本**一路没人接** —— 用户点 `+` 等于没点。
    ///
    /// `WindowCloseGuard`（窗口 delegate）那边也实现了一份：`target = nil` 的 action
    /// 会先走 key window 的响应链，走到哪一环因窗口状态而异，两处都放最稳。
    @objc func newWindowForTab(_ sender: Any?) {
        Diagnostics.shared.record("系统标签栏「+」：AppDelegate 收到 newWindowForTab → 开一个空标签页")
        AppModelBridge.openWindowAction?(id: DocumentOpener.sceneID)
    }

    /// 崩溃之前把"遗言"写进诊断日志。
    ///
    /// ## 它管哪一路 —— 和信号兜底分工（v1.3.53 补的说明）
    ///
    /// 落盘方式在 v1.3.53 已经改成**同步直写**（见 `Diagnostics.record`），
    /// 所以"异步队列没来得及写"这个老问题不存在了。现在日志里的遗言有两路，
    /// 各管各的，谁也替不了谁：
    ///
    /// | 这条路 | 管什么 | 典型现场 |
    /// |---|---|---|
    /// | `NSSetUncaughtExceptionHandler`（这里） | **ObjC 异常**（`unrecognized selector`、KVC 之类） | v1.3.51 修的那两次崩溃 |
    /// | 信号 handler（`Diagnostics.installCrashSignalHandlers`） | **SIGABRT / SIGSEGV / SIGBUS / SIGILL / SIGTRAP** | v1.3.53 这次：Metal 验证层直接 `abort()` |
    ///
    /// 为什么两个都要：Objective-C 异常如果**一路没人接**，最后是被 C++ 的
    /// `std::terminate` 收掉的（`__cxa_throw → std::__terminate → abort`），
    /// 这条路**不会**经过 uncaught handler —— 只能靠信号那一侧兜住。
    ///
    /// ## 为什么它不看「诊断」开关（v1.3.68）
    ///
    /// 因为它平时**零开销**（只在崩溃那一刻才动），而它是"用户报崩溃"时唯一的证据来源 ——
    /// 关掉它，问题就永远查不出来了。所以这一路和信号兜底一样**永远装着**：
    /// 诊断开着就写进日志文件，关着就退到 `stderr`（Console.app 能看到）。
    ///
    /// ⚠️ 一点限制：**在 Xcode 里跑时未必轮得到它** —— 调试器会在异常抛出的那一刻
    /// 先停下来，用户点了继续才会走到这里。所以 Xcode 里还是以调试器给的栈为准。
    private func installCrashLogging() {
        NSSetUncaughtExceptionHandler { exception in
            let diag = Diagnostics.shared
            // ⚠️ 用 `recordCrash` 而不是 `record`：前者**不受总开关影响**
            diag.recordCrash("‼️ 未捕获异常：\(exception.name.rawValue)")
            diag.recordCrash("   原因：\(exception.reason ?? "（无）")")
            for (index, frame) in exception.callStackSymbols.prefix(20).enumerated() {
                diag.recordCrash("   [\(index)] \(frame)")
            }
            diag.recordCrash("   —— 上面就是这个崩溃的现场，进程马上要结束了")
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Diagnostics.shared.record("applicationShouldTerminateAfterLastWindowClosed 被调用 → true")
        // ⚠️ 仅供自动化验证：返回 false = **假装 AppKit 没让 app 退出**，
        // 用来单独验证 `QuitWhenIdle` 那个兜底真的能救场（用户报的"0 窗口僵尸态"
        // 就是这条通知没来）。正常使用不设这个变量 → 永远返回 true。
        if ProcessInfo.processInfo.environment["PDFREADER_AUTOTEST_NO_LAST_WINDOW_QUIT"] != nil {
            Diagnostics.shared.record("  （自动化：假装这条通知不起作用 → 只看 QuitWhenIdle 兜底）")
            return false
        }
        return true
    }

    /// 退出前问一句有没有没保存的改动。
    ///
    /// ⚠️ **主路径已经不是这里了。**「点红叉 / ⌘W 关窗口」走的是
    /// `WindowCloseGuard.windowShouldClose` —— 那才是"窗口还没关"的时机。
    /// 这里只负责**真正退出应用**那条路（⌘Q、Dock 菜单退出、退出登录…），
    /// 那种情况窗口还在，问的时机本来就是对的。
    ///
    /// 之所以留这一份而不是删掉：⌘Q 不经过窗口关闭，没人问就真的会丢改动。
    /// 两条路问的是同一个 `confirmClose()`，而它一旦得到"保存 / 不保存"的答复就会
    /// 把"有未保存改动"清掉 —— 所以点红叉那条路问完之后，这里**不会再弹第二遍**。
    ///
    /// 返回 `.terminateCancel` 时窗口可能已经被关掉了，所以下面配了
    /// `applicationShouldHandleReopen` —— 点一下 Dock 图标就能把窗口找回来。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let diag = Diagnostics.shared
        // 这一行是用来回答"关闭时到底有没有走到这里"的：
        // 如果用户报"关闭不提示"而日志里**连这一行都没有**，
        // 那就说明 AppKit/SwiftUI 压根没把这个回调转发过来
        // （或者进程是被 ⌘R / Stop 强杀的 —— 那两种方式不走这里）。
        //
        // ⚠️ 多窗口（v1.3.40）：这里问的是**所有还开着的文档窗口**。
        // 点红叉一个个关过去时，关掉的那些窗口已经在 `windowWillClose` 里注销了，
        // 它们的"要不要保存"在 `windowShouldClose` 那一刻就问完了 ——
        // 走到这里通常已经没有窗口可问（`isEmpty` 直接放行，不会重复弹框）。
        let viewModels = AppModelBridge.allViewModels
        guard !viewModels.isEmpty else {
            diag.record("applicationShouldTerminate：已经没有文档窗口（前面各自问过了）→ 直接放行")
            return .terminateNow
        }
        diag.record("applicationShouldTerminate 被调用 · 文档窗口 \(viewModels.count) 个")

        // 把所有"要问的"收集齐（每份都带上它所在的窗口，弹框才挂得到地方）
        var pending: [(window: NSWindow?, viewModel: PDFViewModel)] = []
        for (index, appViewModel) in viewModels.enumerated() {
            for tab in appViewModel.tabs {
                diag.record("  窗口[\(index)]「\(tab.title)」未保存=\(tab.viewModel.hasUnsavedChanges)"
                            + " 关闭提醒=\(AppPreferences.shared.promptToSaveOnClose)")
                if tab.viewModel.needsCloseConfirmation {
                    pending.append((AppModelBridge.window(of: appViewModel), tab.viewModel))
                }
            }
        }
        guard !pending.isEmpty else {
            diag.record("  → 没有要问的 → 允许退出")
            viewModels.forEach { $0.saveAllProgress() }
            return .terminateNow
        }

        // 有要问的 → **先取消这次退出**，弹完框再重新发起（v1.3.56）。
        //
        // ⚠️ 为什么不用 `.terminateLater`：那条路要求稍后
        // `reply(toApplicationShouldTerminate:)`，而**退出挂起状态下 sheet 根本挂不上** ——
        // 实测 `beginSheetModal` 调了、弹框却没真的显示，用户什么都看不到，
        // app 就永远停在"正在退出"上（40 秒后被杀，exit=124）。
        //
        // 改成"先 `terminateCancel` 从退出流程里退出来，问完再 `NSApp.terminate` 重新走一遍"：
        // 和 `windowShouldClose` 那边（先回 `false`、问完再 `performClose`）是同一个套路，
        // 而且重新发起时 `pending` 已经空了，不会来回打转。
        diag.record("  → 有 \(pending.count) 份要问 → 先取消这次退出，问完再重新发起")
        askForTermination(pending, at: 0) { allowed in
            guard allowed else { return }
            viewModels.forEach { $0.saveAllProgress() }
            diag.record("  → 全部通过 → 重新发起退出")
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    /// 退出前一份一份问；全部同意才算通过。
    private func askForTermination(_ pending: [(window: NSWindow?, viewModel: PDFViewModel)],
                                   at index: Int,
                                   completion: @escaping (Bool) -> Void) {
        guard index < pending.count else {
            completion(true)
            return
        }
        let item = pending[index]
        item.viewModel.confirmClose(in: item.window) { allowed in
            guard allowed else {
                completion(false)
                return
            }
            self.askForTermination(pending, at: index + 1, completion: completion)
        }
    }

    /// 真正退出之前，把还挂在后台队列里的日志写掉。
    ///
    /// 少了这一步，"关闭时到底发生了什么"就永远看不到 —— 那几条记录是异步写的，
    /// 进程一走就丢（E2E 自检时就是这个现象）。
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.shared.record("applicationWillTerminate：进程即将结束")
        Diagnostics.shared.flush()
    }

    /// 点 Dock 图标（或 app 还活着但没有窗口时被重新激活）时，让 SwiftUI 把窗口找回来。
    ///
    /// ⚠️ 多了一句"没有文档窗口就主动开一个"（v1.3.50）：用户报过
    /// 「窗口都关了、app 还在，再点它没反应、再打开文件也没反应」——
    /// 那是"0 窗口僵尸态"。根因已经修掉（见 `QuitWhenIdle`），但这里再兜一层：
    /// 万一又落到这个状态，点一下 Dock 图标就能拿到一个新窗口，不用重启 app。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppModelBridge.allViewModels.isEmpty {
            Diagnostics.shared.record("applicationShouldHandleReopen：一个文档窗口都没有 → 主动开一个")
            AppModelBridge.openWindowAction?(id: DocumentOpener.sceneID)
        }
        return true
    }

    /// Finder 双击、拖到 Dock 图标、「打开方式」都会走这里。
    /// 只在真正的 .app bundle 下才触发，所以必须声明了 CFBundleDocumentTypes 才有意义。
    ///
    /// ⚠️ 直接交给 `DocumentOpener`（**不再发通知**）：现在是多窗口，
    /// 通知是广播的，每个窗口都会收到一遍 —— 那就会一个文件开出好几个标签页。
    ///
    /// 冷启动（app 还没窗口）时 `openWindow` 动作还没注册，`DocumentOpener`
    /// 会把文件排进队列，等第一个窗口出现时认领 —— 见那里的注释。
    ///
    /// 走的是 `openExternally` 而不是 `open`：冷启动这条路 SwiftUI 会多建一个窗口，
    /// 由它负责收尾（见 `DocumentOpener.openExternally`）。
    func application(_ application: NSApplication, open urls: [URL]) {
        Diagnostics.shared.record("AppDelegate.application(open:)：\(urls.count) 个文件")
        DocumentOpener.openExternally(urls)
    }
}

extension Notification.Name {
    // ⚠️ 「打开文件」**不再走通知**（v1.3.40）：一个文件一个窗口之后，
    // 广播式通知会被每个窗口各收一遍 —— 一个文件就会开出好几个标签页。
    // 现在的入口统一在 `DocumentOpener`（菜单、Finder、拖拽、最近打开都走它）。

    /// 查找（⌘F / ⌘G / ⇧⌘G）
    static let pdfFind = Notification.Name("pdfFind")
    static let pdfFindNext = Notification.Name("pdfFindNext")
    static let pdfFindPrevious = Notification.Name("pdfFindPrevious")

    /// 打印（⌘P）
    static let pdfPrint = Notification.Name("pdfPrint")

    static let pdfSpeakToggle = Notification.Name("pdfSpeakToggle")
    static let pdfSpeakStop = Notification.Name("pdfSpeakStop")
    static let pdfToggleAutoScroll = Notification.Name("pdfToggleAutoScroll")
    static let pdfAddNote = Notification.Name("pdfAddNote")
    static let pdfAddTextAnnotation = Notification.Name("pdfAddTextAnnotation")
    static let pdfAddSignature = Notification.Name("pdfAddSignature")
    static let pdfRunOCR = Notification.Name("pdfRunOCR")
    static let pdfSaveAnnotations = Notification.Name("pdfSaveAnnotations")

    /// 页面管理面板（⌥⌘P）
    static let pdfManagePages = Notification.Name("pdfManagePages")

    /// 撤销 / 重做（⌘Z / ⇧⌘Z）
    static let pdfUndo = Notification.Name("pdfUndo")
    static let pdfRedo = Notification.Name("pdfRedo")

    /// 书签**已经改完并写盘**之后发（见 `BookmarksStore.save`）。
    /// 不要用 `BookmarksStore.$bookmarks` 代替它 —— 那是 willSet，读到的是旧值。
    static let pdfBookmarksDidChange = Notification.Name("pdfBookmarksDidChange")
}
