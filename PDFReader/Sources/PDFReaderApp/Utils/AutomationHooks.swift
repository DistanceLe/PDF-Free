import AppKit
import PDFKit

/// **仅供自动化验证**的钩子集合（v1.3.37 集中到这里，v1.3.40 适配多窗口）。
///
/// 门槛全是环境变量：**正常使用一个都不设 → 完全没有行为**。
///
/// 单独放一个文件，是为了让"哪些代码只为验证而存在"一眼可见 ——
/// 之前它们散在 `AppDelegate.applicationDidFinishLaunching` 里，越堆越多，
/// 主线逻辑被挤得看不清了。
///
/// ⚠️ v1.3.40 起一个文件 = 一个窗口，所以以前那些"在标签之间切来切去"的钩子
///（`SWITCH_TABS`）没有意义了 —— 每个窗口有自己的 `PDFViewModel`，
/// "切标签回来状态变了"这类问题从结构上就不存在。取"当前文档"一律用
/// `AppModelBridge.keyViewModel`。
@MainActor
enum AutomationHooks {

    /// 当前 key 窗口那一份（测试里就当"当前文档"用）
    private static var documentViewModel: PDFViewModel? {
        AppModelBridge.keyViewModel?.selectedTab?.viewModel
    }

    static func install() {
        let env = ProcessInfo.processInfo.environment

        // ── 模拟"滚动页面"（v1.3.52）──
        //
        // 杰哥报：拿 `/Users/lijie/Desktop/合集2.3.pdf`（246MB / 84 页）**滚动一下就死**，
        // 而且不管用哪种方式打开都会。
        //
        // 真手滚轮没法自动化，但"滚"这件事的本质是**逼 PDFKit 渲染新进入视口的内容** ——
        // 直接滚 `clipView`（和 `centerOn` 同一条路径、也就是滚轮最终走的路）能复现同样的渲染。
        //
        // 用法：`PDFREADER_AUTOTEST_SCROLL=<步数>`，每步 220pt、间隔 0.12 秒。
        if let raw = env["PDFREADER_AUTOTEST_SCROLL"], let steps = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                Diagnostics.shared.record("自动验证：开始滚动页面 \(steps) 步（模拟滚轮逼 PDFKit 渲染）")
                scrollStep(remaining: steps, total: steps)
            }
        }

        // ── 投**真实的滚轮事件**（v1.3.53）──
        //
        // 上面那个 `AUTOTEST_SCROLL` 是直接滚 `clipView` —— 它绕过了事件系统和 PDFKit
        // 自己的滚动实现，只能逼出"渲染"。可用户是**真的在滚**：
        // 事件要经过 AppKit 命中测试 → `PDFView.scrollWheel` → 我们的
        // `ScrollZoomMonitor`（按着 ⌥ 时还会走缩放那条重活）→ PDFKit 的页面调度。
        //
        // 所以这里造一个**真的 CGEvent 滚轮事件**投进 app 的事件队列，
        // 走的就是用户手指/滚轮那一条路（`PDFREADER_AUTOTEST_WHEEL_OPTION=1` 时带 ⌥）。
        //
        // ⚠️ 事件必须落在 PDFView 上：`ScrollZoomMonitor` 会检查鼠标位置在不在视图里，
        // 落在工具栏/侧边栏上就什么都不发生（那正是它该有的行为）。
        if let raw = env["PDFREADER_AUTOTEST_WHEEL"], let steps = Int(raw) {
            let withOption = env["PDFREADER_AUTOTEST_WHEEL_OPTION"] != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                Diagnostics.shared.record("自动验证：开始投真实滚轮事件 \(steps) 步（⌥=\(withOption)）")
                postWheelStep(remaining: steps, total: steps, option: withOption)
            }
        }

        // ── 验证「主线程卡死能被后台线程记下来」（v1.3.53）──
        //
        // 主线程真睡 N 秒。判据：日志里必须出现「⛔️ 主线程卡死」，
        // 而且**必须在主线程还睡着的期间**写出来（写它的是后台那个检测线程）。
        // 修复前这条记录根本不存在（看门狗自己在主线程上，一起停了）。
        // 配 `PDFREADER_AUTOTEST_HANG=8` 用。
        if let raw = env["PDFREADER_AUTOTEST_HANG"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Diagnostics.shared.record("自动验证：故意让主线程睡 \(seconds) 秒（验证卡死检测）")
                Thread.sleep(forTimeInterval: seconds)
                Diagnostics.shared.record("自动验证：主线程醒了（这一步之后日志里应该有卡死记录）")
            }
        }

        // ── 验证「崩溃能留下调用栈」（v1.3.53）──
        //
        // 主动 `abort()`。判据：日志里出现「‼️ 进程收到致命信号 SIGABRT」
        // 加上一串调用栈 —— 这条不依赖 Objective-C 的异常机制，任何致命信号都留得下。
        // 修复前（靠 `NSSetUncaughtExceptionHandler`）这里一条都不会有。
        if env["PDFREADER_AUTOTEST_CRASH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Diagnostics.shared.record("自动验证：故意 crash（验证信号兜底能不能留下调用栈）")
                abort()
            }
        }

        // ── 打开「设置」窗口（v1.3.60）──
        //
        // `PDFREADER_AUTOTEST_SETTINGS=1` → 打开设置面板，然后把所有窗口的
        // `tabbingIdentifier` / 标签栏状态 dump 一遍。
        //
        // 为什么单独验：用户报"app 设置里也出现了那条白条 + `+`" ——
        // 根因是**装关闭确认代理会顺带改掉窗口的 `tabbingIdentifier`**，
        // 而设置窗口也被装了代理。这里就是那条的回归检查。
        if env["PDFREADER_AUTOTEST_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Diagnostics.shared.record("自动验证：请求打开设置窗口（合成 ⌘,）")
                // `NSApp.sendAction(showSettingsWindow:)` 在 SwiftUI 的 Settings 场景上
                // 实测**打不开**（发送成功、窗口不出现），所以改成合成一次真实的 ⌘, 按键 ——
                // 走的就是用户按快捷键那条路。
                // ⚠️ 用 `NSEvent` + `NSApp.postEvent`（不需要辅助功能权限）；
                //    `CGEvent.post(tap:.cghidEventTap)` 那条路要权限，这里不走。
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
                   let down = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: .command,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: ",", charactersIgnoringModifiers: ",",
                                               isARepeat: false, keyCode: 43),
                   let up = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                             modifierFlags: .command,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: ",", charactersIgnoringModifiers: ",",
                                             isARepeat: false, keyCode: 43) {
                    NSApp.postEvent(down, atStart: false)
                    NSApp.postEvent(up, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    dumpWindows(prefix: "开设置后")
                }
            }
        }

        // ── 验证「外框颜色可配置」（v1.3.61）──
        //
        // `PDFREADER_AUTOTEST_CHROME=#3E6FA8` → **由 app 自己**把外框色设成这个值再读回来。
        //
        // 为什么不直接 `defaults write`：那条路实测**不生效**（旁路写的 plist
        // 读不回来，`Bundle.main.bundleIdentifier` 还对得上也不行）——
        // 走 app 自己的 `AppPreferences` 才是用户点颜色选择器的那条真实路径。
        if let hex = env["PDFREADER_AUTOTEST_CHROME"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                AppPreferences.shared.chromeColorHex = hex
                let readBack = AppPreferences.shared.chromeColorHex
                Diagnostics.shared.record("自动验证[外框色]：设成「\(hex)」→ 读回「\(readBack)」"
                                          + "（重启后那句「偏好就绪」能读回来才算真的存住了）")
            }
        }

        // ── 验证「页面背景色」（v1.3.67）──
        //
        // `PDFREADER_AUTOTEST_PAGE_BG=#808080` → **由 app 自己**把页面底色设成这个值。
        //
        // 为什么不能在外头 `defaults write` 了事：实测那样写进去 app **读不到**
        //（bundle 域对不上），只有走 app 自己的 `AppPreferences` 才算数。
        //
        // 判据：设完之后**已经开着的那张图**要立刻变底色（`updateNSView` 那条路），
        // 而且**透明区域**要露成这个颜色 —— 这正是用户报的那个问题
        //（"透明的图片，看不出来是透明的还是白底的"）。
        if let hex = env["PDFREADER_AUTOTEST_PAGE_BG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                AppPreferences.shared.pageBackgroundHex = hex
                Diagnostics.shared.record("自动验证[页面底色]：请求设成 \(hex)，"
                                          + "实际读到=「\(AppPreferences.shared.pageBackgroundHex)」")
            }
        }

        // ── 验证「最小化窗口 + 打开新文件」不会被并成一个（v1.3.71）──
        //
        // 杰哥 2026-10-13 报的第二个问题：app 最小化的时候再打开其他文件，
        // 看起来是个**新的独立窗口**，但把最小化的那个窗口点开，两个就合并成一个了。
        //
        // 这条照他的动作走一遍（真窗口、真 `DocumentOpener`）：
        //
        // ```
        //  1.5s  打开 A                    → A 独立，标签栏显示
        //  4.0s  把 A 最小化到 Dock（⌘M）
        //  5.5s  在最小化状态下打开 B       → B 应该另立一个独立窗口
        //  8.0s  dump                      → 必须 2 个独立窗口、各 1 个标签
        //  8.0s  还原 A 并让它成为 key      ← 这一步以前会把 A 并进 B 的组
        // 10.0s  dump                      → 必须仍然是 2 个独立窗口
        // ```
        //
        // 用法：`PDFREADER_AUTOTEST_TABFLOW=/tmp/a.pdf,/tmp/b.pdf <app>`
        //（两个**都存在**的文件路径，逗号分隔）
        if let raw = env["PDFREADER_AUTOTEST_TABFLOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                tabFlow(raw)
            }
        }

        // ── 验证「重画页面时批注搬得走」（v1.3.67）──
        //
        // `PDFREADER_AUTOTEST_ADD_NOTE=1` → 在页面左上角盖一个红方块批注。
        //
        // 配上 `PDFREADER_AUTOTEST_PAGE_BG` 就能验那件要紧事：改底色会**重画页面**
        //（底色是画进页面内容里的，见 `ImageDocument.makePage`），
        // 而批注**必须跟着搬到新页** —— 搬丢了用户画的东西就没了。
        // 放在左上角是为了不和测试图中间那个透明洞重叠。
        if env["PDFREADER_AUTOTEST_ADD_NOTE"] != nil {
            // ⚠️ 用 2 秒（别的钩子大多是 3 秒）：`EXPORT_IMAGE` 也是 3 秒，
            // 同样延迟时谁先谁后只看注册顺序 —— 那太脆。提前一点，稳稳排在导出前面。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let vm = documentViewModel,
                      let page = vm.pdfView?.document?.page(at: 0) else {
                    Diagnostics.shared.record("自动验证[加批注]：拿不到当前页")
                    return
                }
                let pageBounds = page.bounds(for: .cropBox)
                let note = PDFAnnotation(bounds: CGRect(x: pageBounds.minX + 40,
                                                        y: pageBounds.maxY - 140,
                                                        width: 100, height: 100),
                                         forType: .square, withProperties: nil)
                note.color = .systemRed
                note.interiorColor = NSColor.systemRed.withAlphaComponent(0.6)
                page.addAnnotation(note)
                vm.reloadAnnotations()
                Diagnostics.shared.record("自动验证[加批注]：已盖一个红方块，当前页共 \(page.annotations.count) 条批注")
            }
        }

        // ── 验证「实际大小」的口径（v1.3.64）──
        //
        // 杰哥报："这个缩放比例和系统预览 app 还有其他 pdf app 都不一样，100% 的缩放
        // 看起来我们这个 app 要小 50%"。
        //
        // 真因不是"算错了"，是**口径不同**：PDFKit 的 `scaleFactor` 是「1 个 PDF 点占几个
        // **界面点**」，`1.0` 只等于"1 PDF 点 = 1 界面点"；而 1 界面点在物理上不等于
        // 1/72 英寸（这台 27" 4K 屏上是 1/108.5 英寸）——所以真正的"实际大小"是
        // `108.5 / 72 ≈ 1.507`（见 `ScreenMetrics`）。原来写死 1.0，标着 100% 其实
        // 只有真实尺寸的 66%。预览.app / Adobe 的 100% 用的是前一个口径。
        //
        // 判据：`PDFREADER_AUTOTEST_ACTUAL_SIZE=1` → 点一次「实际大小」，
        // 日志里 `scaleFactor` 要 ≈ 逻辑DPI/72，工具栏那个百分比要显示 100%。
        // 修复前是 `1.000` / `66%`。
        if env["PDFREADER_AUTOTEST_ACTUAL_SIZE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let vm = documentViewModel else {
                    Diagnostics.shared.record("自动验证[实际大小]：拿不到当前文档")
                    return
                }
                let screen = vm.pdfView?.window?.screen
                let expected = ScreenMetrics.actualSizeScale(for: screen)
                let before = vm.scaleFactor
                Diagnostics.shared.record(String(format: "自动验证[实际大小]：动手前 scaleFactor=%.3f"
                                                 + " · 工具栏显示 %.0f%%", before, vm.zoomPercent))
                vm.zoomToActualSize()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let got = vm.scaleFactor
                    let percent = vm.zoomPercent
                    let ok = abs(got - expected) < 0.002 && abs(percent - 100) < 1
                    Diagnostics.shared.record(String(format: "自动验证[实际大小]：期望 scaleFactor=%.4f"
                                                     + " → 实际 %.4f · 工具栏显示 %.0f%% · %@",
                                                     expected, got, percent, ok ? "✓ 通过" : "✗ 不对"))
                }
            }
        }

        // ── 验证「图片导出」（v1.3.66）──
        //
        // `PDFREADER_AUTOTEST_EXPORT_IMAGE=<输出路径>`：跳过保存面板，直接把当前页
        //（含批注）导出到指定位置。两件事靠它验：
        //   ① 批注**真的被画进**导出的图里（不是导出一张干净的原图）；
        //   ② 原图一根手指都没碰（对比导出前后的 md5）。
        //
        // 保存面板在脚本里点不了，所以走的是 `exportImage(to:)` 那个不弹面板的入口。
        if let path = env["PDFREADER_AUTOTEST_EXPORT_IMAGE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let vm = documentViewModel else {
                    Diagnostics.shared.record("自动验证[导出图片]：拿不到当前文档")
                    return
                }
                do {
                    try vm.exportImage(to: URL(fileURLWithPath: path))
                    Diagnostics.shared.record("自动验证[导出图片]：✅ 已写出 → \(path)")
                } catch {
                    Diagnostics.shared.record("自动验证[导出图片]：✗ 失败 → \(error.localizedDescription)")
                }
            }
        }

        // ── 自动点掉确认框的按钮（v1.3.56）──
        //
        // `PDFREADER_AUTOTEST_ALERT_CHOICE=0|1|2` → 弹框一出现就点
        // 「保存 / 不保存 / 取消」。
        //
        // 为什么需要它：这个位置出过一次**真实的卡死** —— v1.3.55 把弹框写成
        // "`beginSheet` 拿外观 + `NSApp.runModal(for:)` 拿同步"，用户点完「不保存」
        // 窗口就关不掉了。那种毛病**光看"弹框长什么样"的截图完全看不出来**，
        // 必须真的点一下、看流程走不走得完（窗口关掉 → app 退出）。
        // 判据就是**进程能不能自己退出**（外层 `timeout` 杀掉 = 124 = 卡死了）。
        if let raw = env["PDFREADER_AUTOTEST_ALERT_CHOICE"], let index = Int(raw) {
            scheduleAlertAutoClick(index: index)
        }

        // ── 走 ⌘Q 那条路（v1.3.56）──
        //
        // `PDFREADER_AUTOTEST_QUIT=<秒>` → 到点调 `NSApp.terminate`，等价于 ⌘Q。
        //
        // 为什么单独验：退出前问确认的那条路现在走 `applicationShouldTerminate`
        // 返回 **`.terminateLater`**（问完再 `reply`）—— 这个"挂起-答复"只要有一处
        // 忘了答复，app 就**永远停在"正在退出"**上。`PDFREADER_AUTOQUIT_SECONDS` 走的是
        // 关窗口（`performClose`），覆盖不到这条路。
        if let raw = env["PDFREADER_AUTOTEST_QUIT"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                Diagnostics.shared.record("自动验证：走 ⌘Q 那条路（NSApp.terminate）")
                NSApp.terminate(nil)
            }
        }

        // ── 复现"点系统标签栏崩溃"（v1.3.51）──
        //
        // 用户的崩溃现场（栈里写得很清楚）：
        //
        // ```
        // -[PDFReader.WindowCloseGuard windowDidBecomeKey:]: unrecognized selector sent to instance
        //   NSWindow becomeKeyWindow → postNotificationName → 观察者（我们的代理）→ 崩
        // ```
        //
        // 机制（探针 `tools/probes/windowdelegateprobe.swift` 已能稳定复现）：
        // 窗口的 delegate 会被 AppKit **注册成窗口通知的观察者**，对应关系按
        // `setDelegate` 那一刻的 `responds(to:)` 建立；我们的代理借用了原 delegate 的答案
        // 所以被注册了，但自己没实现那个方法 —— 过去靠 `forwardingTarget` 转发顶上，
        // 而原 delegate 一旦没了（`原 delegate（nil）`），转发链就断在 nil 上 → 崩。
        //
        // 这个钩子把那条路原样走一遍：
        //   ① 把代理里的原 delegate 丢掉（＝崩溃现场的前提）
        //   ② 投 `didBecomeKey` / `didResignKey` 通知（＝点标签栏时 AppKit 干的事）
        // 判据：**进程还活着**。修复前这一步必崩。
        if env["PDFREADER_AUTOTEST_KEY_NOTIFY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let windows = AppModelBridge.allEntries.map(\.window)
                Diagnostics.shared.record("自动验证：文档窗口 \(windows.count) 个，"
                                          + "把每个窗口代理里的原 delegate 丢掉（＝崩溃现场的前提）")
                for window in windows {
                    WindowCloseGuardInstaller.dropOriginalForSelfCheck(on: window)
                }
                Diagnostics.shared.record("自动验证：代理还装着 = "
                                          + "\(windows.map { WindowCloseGuardInstaller.isInstalled(on: $0) })")
                Diagnostics.shared.record("自动验证：现在投 didBecomeKey / didResignKey 通知"
                                          + "（＝点标签栏时 AppKit 干的事）")
                for window in windows {
                    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                    NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
                }
                Diagnostics.shared.record("自动验证：投完了 —— 进程还活着就说明没崩"
                                          + "（修复前这一步必崩）")
            }
        }

        // ── 复刻"右键打开方式"那条路：先多一个空窗口，再走外部打开 ──
        //
        // 冷启动时 SwiftUI 会为"外部要求打开文档"**额外建一个窗口**，加上 `WindowGroup`
        // 自己的启动窗口 —— 一个文件于是有两个窗口，多出来的那个空着。
        // 这个钩子把那个形状人工摆出来（多开一个空窗口），再调**外部打开**的入口，
        // 验证 `DocumentOpener.openExternally` 的收尾确实把多余的空窗口收掉。
        //
        // 判据：1 个文件 + 1 个多余空窗口 → 收尾后只剩 1 个窗口，且 app 还在（没被误退）。
        if let paths = env["PDFREADER_AUTOTEST_SPARE_WINDOW"] {
            let urls = paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                Diagnostics.shared.record("自动验证：先多开一个空窗口（模拟 SwiftUI 为外部打开建的那个）")
                AppModelBridge.openWindowAction?(id: DocumentOpener.sceneID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Diagnostics.shared.record("自动验证：走**外部打开**入口（右键「打开方式」同一条）")
                DocumentOpener.openExternally(urls)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
                let entries = AppModelBridge.allEntries
                Diagnostics.shared.record("自动验证[多余空窗口]：现在 \(entries.count) 个窗口 → "
                                          + entries.map {
                                              "「\($0.window.title)」\($0.viewModel.tabs.isEmpty ? "空" : "有文件")"
                                          }.joined(separator: " / "))
            }
        }

        // ── 打开文件（可给多个，**逗号分隔**；不造脏数据，所以关窗口时不会弹框） ──
        //
        // 现在每个文件会**各开一个窗口**，被 macOS 并成系统标签页。
        if let paths = env["PDFREADER_AUTOTEST_OPEN"] {
            let urls = paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                DocumentOpener.open(urls)
            }
        }

        // ── 搜一个词（验证结果列表的上下文摘要 / 页面上的搜索高亮） ──
        // `PDFREADER_AUTOTEST_SEARCH=<关键词>`：等文档装好、布局稳定之后执行一次搜索。
        if let query = env["PDFREADER_AUTOTEST_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                guard let vm = AppModelBridge.keyViewModel?.tabs.first?.viewModel else {
                    Diagnostics.shared.record("自动验证：搜索「\(query)」→ 没有可用的文档视图")
                    return
                }
                vm.searchQuery = query
                vm.performSearch()
                Diagnostics.shared.record("自动验证：搜索「\(query)」→ 等结果回来")
            }
        }

        // ── 开 N 个空标签页（验证系统标签栏确实把窗口并起来了） ──
        //
        // `PDFREADER_AUTOTEST_NEW_TAB=<数字>` → 走 `openWindow`（我们的菜单/⌘T 用它）
        // `PDFREADER_AUTOTEST_NEW_TAB=plus`  → 走 `newWindowForTab`，**系统标签栏上那个
        //   `+` 按钮干的就是这件事**。这条必须单独验：`+` 是用户直接会用到的入口，
        //   而 SwiftUI 到底接不接这个 AppKit 的 action，只能实测。
        if let raw = env["PDFREADER_AUTOTEST_NEW_TAB"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if raw == "plus" {
                    let before = AppModelBridge.allEntries.count
                    // ⚠️ 用 `sendAction` 发，**不能**直接 `window.newWindowForTab(nil)` ——
                    // SwiftUI 的窗口类没有这个 selector，直接调用会崩：
                    // `-[SwiftUI.AppKitWindow newWindowForTab:]: unrecognized selector`。
                    // sendAction 才是系统点 `+` 时走的同一条路（沿响应链找谁接）。
                    // ⚠️ 先把 app 激活：target=nil 的 action 是从 **key window** 的响应链
                    // 开始找接收者的，而从终端拉起来跑时 `keyWindow` 是 nil ——
                    // 那样这条 action 根本没人可找，看着像"实现了也没用"。
                    NSApp.activate(ignoringOtherApps: true)
                    Diagnostics.shared.record("自动验证：sendAction(newWindowForTab:)"
                                              + "（keyWindow=「\(NSApp.keyWindow?.title ?? "nil")」，"
                                              + "等价于点标签栏的 +）")
                    let handled = NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)),
                                                   to: nil, from: nil)
                    Diagnostics.shared.record("自动验证：sendAction 返回 \(handled)（false=响应链上没人接）")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        Diagnostics.shared.record("自动验证：点 + 之后文档窗口 \(before)"
                                                  + " → \(AppModelBridge.allEntries.count) 个")
                        dumpWindows(prefix: "点 + 之后")
                    }
                    return
                }
                guard let count = Int(raw), let action = AppModelBridge.openWindowAction else {
                    Diagnostics.shared.record("自动验证：openWindow 动作还没注册，开不了新标签页")
                    return
                }
                for _ in 0..<count { action(id: DocumentOpener.sceneID) }
                Diagnostics.shared.record("自动验证：已请求新开 \(count) 个标签页")
            }
        }

        // ── 打开文件 + 造一处未保存改动（验证"弹框在窗口关闭之前"） ──
        if let path = env["PDFREADER_AUTOTEST_UNSAVED"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                DocumentOpener.open([URL(fileURLWithPath: path)])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    let vm = AppModelBridge.keyViewModel?.selectedTab?.viewModel
                    vm?.outlineDidChange()      // 标脏：等价于"用户改了目录"
                    Diagnostics.shared.record("自动验证：已造出未保存改动（未保存=\(vm?.hasUnsavedChanges == true)）")
                }
            }
        }

        // ── 设置"位置 + 缩放"：`PDFREADER_AUTOTEST_SETPROGRESS="2:1.5"`（页号:缩放） ──
        // 关窗口时会走 `saveAllProgress()` 落盘，下一轮用 REPORT 读回来 —— 一轮往返验证。
        if let spec = env["PDFREADER_AUTOTEST_SETPROGRESS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let parts = spec.split(separator: ":")
                guard parts.count == 2,
                      let page = Int(parts[0]),
                      let zoom = Double(parts[1]),
                      let vm = documentViewModel else {
                    Diagnostics.shared.record("自动验证：拿不到当前文档，设置位置/缩放失败")
                    return
                }
                vm.goToPage(at: page)
                vm.pdfView?.autoScales = false
                vm.pdfView?.scaleFactor = CGFloat(zoom)
                Diagnostics.shared.record("自动验证：已设置 页=\(page) 缩放=\(zoom)"
                                          + "（实际 页=\(vm.currentPageIndex) 缩放=\(vm.pdfView?.scaleFactor ?? -1)）")
            }
        }

        // ── 报告"存储里 / 界面上"的位置与缩放（验证恢复生效） ──
        if let path = env["PDFREADER_AUTOTEST_REPORT_PROGRESS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                let url = URL(fileURLWithPath: path)
                let saved = BookmarksStore.shared.loadReadingPosition(documentURL: url)
                let savedZoom = BookmarksStore.shared.loadZoom(documentURL: url)
                let vm = documentViewModel
                Diagnostics.shared.record("自动验证：存储里 位置=\(String(describing: saved))"
                                          + " 缩放=\(savedZoom.map { String(format: "%.3f", $0) } ?? "nil")")
                Diagnostics.shared.record("自动验证：界面上 页=\(vm?.currentPageIndex ?? -1)"
                                          + " 缩放=\(String(format: "%.3f", vm?.scaleFactor ?? -1))")
            }
        }

        // ── 删掉第 N 个顶层目录项，顺带写盘（验证"删除真的进了文件"） ──
        if let raw = env["PDFREADER_AUTOTEST_DELETE_TOC"], let topIndex = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let vm = documentViewModel else {
                    Diagnostics.shared.record("自动验证：删目录 —— 拿不到当前文档")
                    return
                }
                vm.isEditable = true
                let topRows = vm.tocRows.filter { $0.depth == 0 }
                Diagnostics.shared.record("自动验证：删前 共 \(vm.tocRows.count) 条 / 顶层 \(topRows.count) 条"
                                          + " → \(topRows.map { $0.title })")
                guard topRows.indices.contains(topIndex) else {
                    Diagnostics.shared.record("自动验证：第 \(topIndex) 个顶层项不存在")
                    return
                }
                vm.removeTOCEntry(topRows[topIndex])
                let afterTop = vm.tocRows.filter { $0.depth == 0 }
                Diagnostics.shared.record("自动验证：删后 共 \(vm.tocRows.count) 条 / 顶层 \(afterTop.count) 条"
                                          + " → \(afterTop.map { $0.title })")
                do {
                    let backup = try vm.saveAnnotationsToDisk()
                    Diagnostics.shared.record("自动验证：写盘完成（备份=\(backup == nil ? "未做" : "已做")）")
                } catch {
                    Diagnostics.shared.record("自动验证：写盘失败 —— \(error.localizedDescription)")
                }
            }
        }

        // ── 合成一次目录拖拽（结论：走不通，见 TOCDragProbe 的注释） ──
        if env["PDFREADER_AUTOTEST_DRAG_TOC"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                guard let vm = documentViewModel else { return }
                vm.isLeftSidebarVisible = true
                vm.activeSidebar = .outline
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                TOCDragProbe.simulateDrag()
            }
        }

        // ── 页面管理：删除 / 调序 / 撤销的真数据自检（v1.3.42） ──
        //
        // 用"页对象身份"当判据（不是页号、也不是渲染结果）—— 重排之后
        // 每个位置上是**不是原来那一页**，只有比对象才知道。
        if env["PDFREADER_AUTOTEST_PAGE_EDITS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let vm = documentViewModel, let document = vm.pdfView?.document else {
                    Diagnostics.shared.record("自动验证[页面]：拿不到当前文档")
                    return
                }
                vm.isEditable = true
                var pass = 0
                var fail = 0
                func check(_ name: String, _ ok: Bool) {
                    if ok { pass += 1 } else { fail += 1 }
                    Diagnostics.shared.record("自动验证[页面]：\(ok ? "✓" : "✗") \(name)")
                }
                func order(_ document: PDFDocument) -> [PDFPage] {
                    (0..<document.pageCount).compactMap { document.page(at: $0) }
                }
                func identical(_ a: [PDFPage], _ b: [PDFPage]) -> Bool {
                    a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
                }

                let before = order(document)
                let n = before.count
                Diagnostics.shared.record("自动验证[页面]：起始 \(n) 页；目录页号 \(vm.tocRows.map(\.pageIndex))")

                // ① 把第 1 页移到最后
                _ = vm.movePages([0], to: n)
                var now = order(document)
                check("第 1 页移到末尾", now.count == n && now.last === before[0] && now[0] === before[1])
                Diagnostics.shared.record("自动验证[页面]：移动后第 1 位是「原第 \(now.firstIndex { $0 === before[1] }.map { $0 + 1 } ?? -1) 页」")

                // ② 撤销
                vm.undo()
                check("撤销移动 → 回到原样", identical(order(document), before))

                // ③ 重做
                vm.redo()
                check("重做移动 → 又到末尾", order(document).last === before[0])
                vm.undo()

                // ④ 删除第 2 页
                _ = vm.deletePages([1])
                now = order(document)
                check("删除第 2 页 → 少一页", now.count == n - 1)
                check("删掉的正好是原第 2 页", identical(now, [before[0]] + Array(before[2...])))

                // ⑤ 撤销删除
                vm.undo()
                check("撤销删除 → 页数 / 页序都复原", identical(order(document), before))

                // ⑥ 目录页号没有越界（删页之后 `index(for:)` 会返回 NSNotFound，必须挡住）
                check("目录页号都在 0..<\(n) 内", vm.tocRows.allSatisfy { $0.pageIndex >= 0 && $0.pageIndex < n })

                // ⑦ 多选整体移动
                if n >= 4 {
                    _ = vm.movePages([2, 3], to: 0)
                    now = order(document)
                    check("多选 [3,4] 移到最前", now[0] === before[2] && now[1] === before[3] && now.count == n)
                    vm.undo()
                    check("撤销多选移动", identical(order(document), before))
                }

                // ⑧ 重排之后批注还得在同一页上
                if let index = before.firstIndex(where: { !$0.annotations.isEmpty }) {
                    let count = before[index].annotations.count
                    _ = vm.movePages([index], to: n)
                    check("重排后批注跟着页走（\(count) 条）",
                          document.page(at: n - 1)?.annotations.count == count)
                    vm.undo()
                    check("撤销后仍回到原位", identical(order(document), before))
                } else {
                    Diagnostics.shared.record("自动验证[页面]：（这份文档没有批注，跳过批注跟随检查）")
                }

                // ⑨ 「点哪页选哪页」的依据：**按页对象定位下标**（v1.3.43 修的
                //    "选中的页乱跳"就靠它）。下标会随重排变，页对象不会。
                let probe = before[0]
                _ = vm.movePages([0], to: n)
                check("重排后按页对象能定位到新下标", vm.pageIndex(of: probe) == n - 1)
                vm.undo()
                check("撤销后定位回 0", vm.pageIndex(of: probe) == 0)

                let doomed = before[1]
                _ = vm.deletePages([1])
                check("已被删掉的页定位返回 nil", vm.pageIndex(of: doomed) == nil)
                vm.undo()
                check("撤销删除后又能定位到", vm.pageIndex(of: doomed) == 1)

                // ⑩ 插入空白页（v1.3.44）
                //
                //    ⚠️ 判据除了"页数 / 位置"，还要单独确认**新页有正规尺寸** ——
                //    `PDFPage()` 新建出来是不带尺寸的（0×0），不设 `mediaBox` 的话
                //    缩略图渲不出来、写进文件之后在别的阅读器里也是坏的。
                let inserted = vm.insertBlankPages(after: [0], count: 1)
                now = order(document)
                check("在开头插 1 页空白 → 页数 +1", now.count == n + 1)
                check("插入点落在下标 1", inserted == 1..<2)
                check("原来的页整体后移一位",
                      now[0] === before[0] && now[1] !== before[1] && now[2] === before[1])
                if let blank = document.page(at: 1) {
                    let size = blank.bounds(for: .mediaBox).size
                    let reference = before[0].bounds(for: .mediaBox).size
                    check("空白页有正规尺寸（\(Int(size.width))×\(Int(size.height))）",
                          size.width > 100 && size.height > 100)
                    check("尺寸跟随相邻那一页", abs(size.width - reference.width) < 1
                                              && abs(size.height - reference.height) < 1)
                    check("新页上没有批注", blank.annotations.isEmpty)
                } else {
                    check("空白页拿到了", false)
                }

                // 撤销插入 → 新页要真的从文档里摘掉
                //（`applyPageOrder` 里"删掉目标页序之外的页"那一段负责这件事）
                vm.undo()
                check("撤销插入 → 页序页数都复原", identical(order(document), before))

                vm.redo()
                check("重做插入 → 又是 \(n + 1) 页", document.pageCount == n + 1)
                vm.undo()

                // 末尾追加 / 开头插入
                _ = vm.insertBlankPages(after: [], count: 2)
                check("末尾追加 2 页", document.pageCount == n + 2)
                vm.undo()
                _ = vm.insertBlankPages(after: [-1], count: 1)
                check("开头插入 1 页（新的第 1 页）",
                      document.pageCount == n + 1 && document.page(at: 0) !== before[0])
                vm.undo()
                check("两次插入都能撤销回原样", identical(order(document), before))

                // ⑪ 删一页 + 末尾插两页，然后写盘 —— 验证两种改动都真的进了文件
                //   （要配一个**副本**跑，别拿用户的原文件试）
                if env["PDFREADER_AUTOTEST_PAGE_SAVE"] != nil {
                    _ = vm.deletePages([1])
                    _ = vm.insertBlankPages(after: [], count: 2)
                    do {
                        _ = try vm.saveAnnotationsToDisk()
                        Diagnostics.shared.record("自动验证[页面]：写盘成功，现在 \(document.pageCount) 页"
                                                  + "（删 1 + 末尾插 2，期望 \(n + 1)）")
                    } catch {
                        Diagnostics.shared.record("自动验证[页面]：写盘失败 —— \(error.localizedDescription)")
                    }
                }

                Diagnostics.shared.record("自动验证[页面]：\(pass) 通过 / \(fail) 失败"
                                          + (fail == 0 ? " —— 全部通过" : " —— 有失败"))

                // 自检把文档改脏了，别让自动关窗口卡在保存确认上
                vm.unsavedChanges.clear()
            }
        }

        // ── 页面管理面板冒烟：打开它，确认不崩、窗口还在 ──
        if env["PDFREADER_AUTOTEST_PAGE_MANAGER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                guard let vm = documentViewModel else { return }
                vm.isEditable = true
                vm.beginPageEditing()
                Diagnostics.shared.record("自动验证：已请求打开页面管理面板")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                guard let vm = documentViewModel else { return }
                // 顺手验一下"浮层遮挡判定" —— 两个全局事件监听器
                //（空格拖拽 / ⌥+滚轮缩放）就是靠它让位的
                let window = AppModelBridge.allEntries.first?.window
                Diagnostics.shared.record("自动验证：面板打开后 页数=\(vm.pageCount)"
                                          + " 面板还在=\(vm.isPageManagerVisible)"
                                          + " 文档窗口=\(AppModelBridge.allEntries.count)"
                                          + " 浮层遮挡判定=\(AppModelBridge.isPageManagerVisible(for: window))")
            }
            // 浮层不是模态的了，但这是"关闭后要刷新一次"的验证点：
            // 收起来之后目录/批注/页面才会真正刷新（见 `performDeferredPageRefresh`）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) {
                documentViewModel?.endPageEditing()
                let window = AppModelBridge.allEntries.first?.window
                Diagnostics.shared.record("自动验证：已收起页面管理面板"
                                          + "（浮层遮挡判定=\(AppModelBridge.isPageManagerVisible(for: window))，"
                                          + "应为 false）")
            }
        }

        // ── 「清除最近」（v1.3.48） ──
        //
        // 调的是"清除最近"按钮调的那两个方法（模型层），因为弹窗/按钮本身没法自动化点。
        if env["PDFREADER_AUTOTEST_CLEAR_RECENTS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let before = RecentDocuments.shared.urls.count
                RecentDocuments.shared.clear()
                RecentThumbnailStore.shared.removeAll()
                Diagnostics.shared.record("自动验证：清除最近 → \(before) → "
                                          + "\(RecentDocuments.shared.urls.count) 项")
            }
        }

        // ── 右栏"内容撑破栏宽"自检（v1.3.47） ──
        //
        // 这个 bug 只在「选中标注 + 栏拉到最窄」时暴露：属性栏里某个控件的最小宽度
        // 大于栏宽 → 内容溢出 `.frame` → 溢出的部分照样接收点击 → 盖住左边那条 6pt
        // 的分隔条 → **栏宽拖不动**（用户报的"得先取消选中标注才能拉宽"）。
        //
        // 判据是 `DocumentLayout` 里那条 `onPreferenceChange`：
        // 内容自然宽度 > 栏宽 就记 `⚠️ 属性栏内容比栏宽还宽`。
        if env["PDFREADER_AUTOTEST_RIGHT_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                guard let vm = documentViewModel else { return }
                vm.isEditable = true
                vm.isRightSidebarVisible = true
                // 拉到最窄 —— 宽栏是看不出来的（这个 bug 只在窄栏发生）
                UserDefaults.standard.set(200.0, forKey: "pdfreader.rightSidebarWidth")
                Diagnostics.shared.record("自动验证[右栏]：已打开右栏并设为最窄 200（还没选标注）")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                guard let vm = documentViewModel else { return }
                let index = vm.currentPageIndex
                guard let annotation = vm.pdfView?.document?.page(at: index)?.annotations.first else {
                    Diagnostics.shared.record("自动验证[右栏]：第 \(index + 1) 页没有标注，没法触发属性栏")
                    return
                }
                vm.select(annotation, pageIndex: index)
                Diagnostics.shared.record("自动验证[右栏]：已选中一条标注 → 属性栏出来（内容最宽的一刻）")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                guard let vm = documentViewModel else { return }
                // ⚠️ 这条文案里**故意不写**任何判据字符串 —— 否则 `grep` 会把自己的
                // 日志也数进去，看着像"出问题了"（实测被骗过两次：先写了警告原文，
                // 又写了 `⚠️` 这个判据本身）。
                // 外部判据：`grep -c "属性栏内容比栏宽还宽"`，修复后应为 **0**。
                Diagnostics.shared.record("自动验证[右栏]：自检结束 选中=\(vm.selectedAnnotation != nil)")
                // 把栏宽还原（这个钩子会改到持久化的偏好）
                UserDefaults.standard.set(260.0, forKey: "pdfreader.rightSidebarWidth")
            }
        }

        // ── 验证"空格拖拽 / ⌥+滚轮缩放"这两个监听在**多窗口**下是否都还挂着 ──
        //
        // 这两个曾经是单例、各自只记一个 pdfView（`attach` 里还先 `detach()`），
        // 于是"打开新文件 → 切回旧文件 → 两个快捷键全失效"。
        // 现在按窗口各记一份，这里就该看到**每个文档窗口各一条**。
        if env["PDFREADER_AUTOTEST_MONITORS"] != nil {
            let report: (String) -> Void = { tag in
                Diagnostics.shared.record("自动验证[\(tag)]：空格拖拽挂在这些窗口上 = "
                                           + "\(SpaceDragPanMonitor.shared.attachedWindowTitles)")
                Diagnostics.shared.record("自动验证[\(tag)]：⌥+滚轮缩放挂在这些窗口上 = "
                                           + "\(ScrollZoomMonitor.shared.attachedWindowTitles)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { report("开完两个文件") }
            // 关掉一个窗口之后，剩下那个必须**还在**（这是原来的 bug：会被一起摘掉）
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
                let windows = AppModelBridge.allEntries.map(\.window).filter { $0.isVisible }
                Diagnostics.shared.record("自动验证：准备关掉一个窗口（共 \(windows.count) 个）")
                windows.last?.performClose(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { report("关掉一个窗口后") }
        }

        // ── 诊断：把每个窗口的"标签页状态"打出来 ──
        //
        // 用来回答"窗口上那条居中的文件名 + `+` 到底是不是 macOS 的系统标签栏"：
        // `tabbingIdentifier` 非空 = 这个窗口参与系统自动分页，
        // 同 identifier 的窗口会被并成标签（`tabbedWindows` 是同一组里的兄弟）。
        if env["PDFREADER_AUTOTEST_DUMP_WINDOWS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                dumpWindows(prefix: "自动验证")
            }
        }

        // ── 复现"0 窗口僵尸态"：程序化 close() 逐个关掉标签，间隔照抄兜底那一下 ──
        //
        // 用户的实际情况（v1.3.49 日志，两次）：
        //
        // ```
        // [27.153] 放行（标签数=2）→ 没关成
        // [27.782] ⚠️ 兜底自己 close()   → windowWillClose → 注销（还剩 1 个）
        // [28.421] 放行（标签数=2）→ 没关成
        // [29.054] ⚠️ 兜底自己 close()   → windowWillClose → 注销（还剩 0 个）
        //          ← 就断在这儿：**没有 applicationShouldTerminateAfterLastWindowClosed**
        //            → app 带着 0 个窗口活着，用户说的"卡死"
        // ```
        //
        // 关键是**在标签组里连着关**：第一个窗口的收尾还没走完，第二个就关了 ——
        // AppKit 那条"最后一个窗口关了"的通知就丢了。所以这个钩子逐**个**关、间隔 0.6 秒
        //（= 兜底那一发的延迟），尽量复刻现场。
        //
        // 判据：**进程能不能自己退出**。修复前会卡住（外层 `timeout` 杀掉 → 退出码 124）；
        // 修复后由 `QuitWhenIdle` 收尾 → 退出码 0。
        //
        // ⚠️ 想单独验证那个兜底，再配 `PDFREADER_AUTOTEST_NO_LAST_WINDOW_QUIT=1`
        //    （让 AppKit 那条通知"不起作用"）—— 对照实验就是这么做的：
        //    摘掉兜底 → 124（复现用户的僵尸态）；有兜底 → 0。
        if env["PDFREADER_AUTOTEST_HARD_CLOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                closeOneByOneWithGap(remaining: AppModelBridge.allEntries.count)
            }
        }

        // ── 自动"点红叉关窗口"：`--autoquit-after N` 或 `PDFREADER_AUTOQUIT_SECONDS` ──
        //
        // `--autoquit-after N`（命令行）和 `PDFREADER_AUTOQUIT_SECONDS`（环境变量）都认。
        //
        // ⚠️ 关窗口用 `performClose` 而不是 `close`：`NSWindow.close()` **不经过**
        // `windowShouldClose(_:)`（AppKit 文档明确写了它"不考虑 delegate 是否同意"），
        // 用它验证不了关闭确认这条链路 —— 跑出来的日志会让人误以为"拦截没生效"。
        // `performClose(_:)` 才是"模拟点了一下红叉"，和用户的真实操作完全同一条路。
        var autoQuitSeconds: Double?
        if let raw = env["PDFREADER_AUTOQUIT_SECONDS"] {
            autoQuitSeconds = Double(raw)
        } else if let index = CommandLine.arguments.firstIndex(of: "--autoquit-after"),
                  index + 1 < CommandLine.arguments.count {
            autoQuitSeconds = Double(CommandLine.arguments[index + 1])
        }
        if let seconds = autoQuitSeconds {
            Diagnostics.shared.record("自动验证：\(seconds) 秒后开始逐个关窗口")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                dumpWindows(prefix: "关窗口前")
                let total = AppModelBridge.allEntries.count
                Diagnostics.shared.record("自动验证：文档窗口共 \(total) 个，逐个关（每个间隔 0.8 秒）")
                closeFrontDocumentWindow(remaining: total)
            }
        }
    }

    /// 滚动/切标签的"折磨测试"：**轮着滚每个文档窗口**，并且每 10 步切一次当前窗口。
    ///
    /// 为什么轮着来：杰哥报的是"特定文件滚动就死"，而他平时开着好几个标签 ——
    /// 只滚"最后打开的那个"覆盖不到"大文件在后台标签里也要渲染"这种情况。
    /// `makeKeyAndOrderFront` 等价于点一下标签栏（会走 `becomeKeyWindow` → 那条通知路径）。
    ///
    /// 走的是和滚轮/抓手最终相同的那条路（`clipView.scroll`）。
    private static func scrollStep(remaining: Int, total: Int) {
        guard remaining > 0 else {
            Diagnostics.shared.record("自动验证：滚动结束（共 \(total) 步），进程还活着")
            return
        }
        let entries = AppModelBridge.allEntries
        guard !entries.isEmpty else {
            Diagnostics.shared.record("自动验证：没有文档窗口可滚了")
            return
        }
        let step = total - remaining
        let entry = entries[step % entries.count]

        // 每 10 步换一个"当前窗口" —— 等价于点标签栏切过去（becomeKeyWindow）
        if step % 10 == 0 {
            entry.window.makeKeyAndOrderFront(nil)
        }
        if let pdfView = entry.viewModel.tabs.first?.viewModel.pdfView,
           let scrollView = pdfView.internalScrollView {
            let clipView = scrollView.contentView
            var bounds = clipView.bounds
            bounds.origin.y += 220
            let constrained = clipView.constrainBoundsRect(bounds)
            clipView.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
            if remaining % 20 == 0 {
                Diagnostics.shared.record("自动验证：第 \(step)/\(total) 步 · 滚「\(entry.window.title)」"
                                          + "（y=\(Int(constrained.origin.y)) / 视口高 \(Int(clipView.bounds.height))）")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            scrollStep(remaining: remaining - 1, total: total)
        }
    }

    /// 投一个**真的滚轮事件**（`PDFREADER_AUTOTEST_WHEEL` 用）。
    ///
    /// 造 `CGEvent` → 转 `NSEvent` → `NSApp.postEvent` 投回自己的事件队列。
    ///
    /// 为什么不直接 `window.sendEvent`：那样跳过了 `nextEventMatchingMask`，
    /// **本地事件监听器（`ScrollZoomMonitor`）就收不到** —— 而 ⌥+滚轮缩放正是挂在监听器上的。
    /// 投进队列才和真实滚轮一样：先过监听器，再走命中测试、`PDFView.scrollWheel`。
    private static func postWheelStep(remaining: Int, total: Int, option: Bool) {
        guard remaining > 0 else {
            Diagnostics.shared.record("自动验证：真实滚轮结束（共 \(total) 步），进程还活着")
            return
        }
        let entries = AppModelBridge.allEntries
        guard let entry = entries.first,
              let viewModel = entry.viewModel.tabs.first?.viewModel,
              let pdfView = viewModel.pdfView else {
            Diagnostics.shared.record("自动验证：没有 PDFView 可滚")
            return
        }
        let window = entry.window
        // 鼠标点定在视图正中 —— 监听器会检查它在不在 PDFView 里
        let inView = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let inWindow = pdfView.convert(inView, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)

        if remaining == total {
            // ⚠️ 先把位置挪回第 1 页。上一次实验会把"阅读位置"落盘（存在最后一页），
            // 下一次打开就停在末页 —— 那时往下滚**什么都没发生**，
            // 日志里一条"页码变了"都没有，看着像"滚轮事件没生效"（第一版就被骗过去了）。
            viewModel.goToPage(at: 1)
            Diagnostics.shared.record("自动验证[滚轮]：PDFView \(Int(pdfView.bounds.width))×"
                                      + "\(Int(pdfView.bounds.height)) · 窗口内 \(Int(inWindow.x)),\(Int(inWindow.y))"
                                      + " · 屏幕 \(Int(onScreen.x)),\(Int(onScreen.y))"
                                      + " · 窗口号 \(window.windowNumber) · 当前页 \(viewModel.currentPageIndex + 1)")
        }

        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0) {
            // ⚠️ 坐标这里有个坑：`NSEvent(cgEvent:)` **不做窗口坐标转换**
            //（滚轮事件本来就"没有窗口"，真实事件是 AppKit 在 `nextEventMatchingMask`
            //  那一步补上窗口、再把坐标换过去的；我们直接 `sendEvent` 跳过了那一步）。
            // 它只把 CGEvent 的 y（屏幕坐标、从顶部往下）翻成"从底部往上"：
            //      locationInWindow.y = 屏幕高 - cgEvent.location.y
            // 所以想让 `locationInWindow` 正好等于视图在窗口里的位置，
            // 就得**预先做一次反向翻转**。第一版直接把屏幕坐标塞进去，
            // 命中测试落在视图外 → 滚了 400 步页面一动不动（日志里连一条"页码变了"都没有）。
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            event.location = CGPoint(x: inWindow.x, y: screenHeight - inWindow.y)
            if option { event.flags = .maskAlternate }
            if let nsEvent = NSEvent(cgEvent: event) {
                if remaining == total {
                    Diagnostics.shared.record("自动验证[滚轮]：事件转换 OK · NSEvent.window="
                                              + "\(nsEvent.window.map { "「\($0.title)」" } ?? "nil")"
                                              + " · 想要的位置=\(Int(inWindow.x)),\(Int(inWindow.y))"
                                              + " · locationInWindow=\(Int(nsEvent.locationInWindow.x)),"
                                              + "\(Int(nsEvent.locationInWindow.y))"
                                              + " · deltaY=\(Int(nsEvent.scrollingDeltaY))")
                }
                // ⚠️ **不能** `NSApp.postEvent` 投进队列：`NSEvent(cgEvent:)` 转出来的事件
                // `window` 是 nil —— nil 窗口的事件 AppKit 没法路由 → 投了几百下发现在页面上
                // **什么都没动**（白测一轮）。直接交给目标窗口的 `sendEvent` 才走得到命中测试
                // → `NSScrollView` → `PDFView` → PDFKit 的页面渲染，也就是真实滚轮
                // 在窗口那一层最终走的路。
                window.sendEvent(nsEvent)
            } else {
                Diagnostics.shared.record("自动验证：CGEvent 转 NSEvent 失败")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postWheelStep(remaining: remaining - 1, total: total, option: option)
        }
    }

    /// 盯着 app 的确认框，出现后点掉指定的那个按钮。
    ///
    /// ⚠️ 按钮**按标题找**，不是按下标：`NSAlert` 视图树里的按钮顺序和
    /// `addButton` 的添加顺序**并不一样**（实测添加顺序是 保存/不保存/取消，
    /// 视图树里排列却是 保存/取消/不保存）—— 按下标点会点错。
    private static func scheduleAlertAutoClick(index: Int) {
        let titles = ["保存", "不保存", "取消"]
        guard titles.indices.contains(index) else { return }
        let target = titles[index]
        var attempts = 0
        func tick() {
            attempts += 1
            guard attempts <= 60 else { return }          // 最多盯 30 秒
            if clickAlertButton(titled: target) {
                Diagnostics.shared.record("自动验证[弹框]：已点「\(target)」")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tick() }
    }

    /// 找到当前挂着的确认框并点掉那个按钮。
    ///
    /// sheet 挂在窗口上（`attachedSheet`）；独立弹窗走 `NSApp.modalWindow`。两种都找。
    private static func clickAlertButton(titled title: String) -> Bool {
        let sheet = AppModelBridge.allEntries.compactMap { $0.window.attachedSheet }.first
            ?? NSApp.modalWindow
        guard let sheet, let content = sheet.contentView,
              let button = alertButton(titled: title, in: content) else { return false }
        button.performClick(nil)
        return true
    }

    private static func alertButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for sub in view.subviews {
            if let found = alertButton(titled: title, in: sub) { return found }
        }
        return nil
    }

    /// 逐个用**程序化 `close()`** 关窗口，每个之间隔 0.6 秒。    ///
    /// 这个间隔是照抄 `WindowCloseGuard.allowClose` 里那一发兜底的延迟 ——
    /// 目的就是复刻"两个标签连着关、AppKit 那条最后窗口关闭通知丢掉"的现场
    ///（见 `PDFREADER_AUTOTEST_HARD_CLOSE` 的说明）。
    private static func closeOneByOneWithGap(remaining: Int) {
        guard remaining > 0 else {
            Diagnostics.shared.record("自动验证：close() 全部调用完了 —— 接下来必须能自己退出")
            return
        }
        let target = NSApp.windows.first {
            $0.isVisible && AppModelBridge.viewModel(for: $0) != nil
        }
        guard let target else {
            Diagnostics.shared.record("自动验证：没有文档窗口可关了（剩 \(remaining) 个没关）")
            return
        }
        Diagnostics.shared.record("自动验证：程序化 close() 关「\(target.title)」"
                                  + "（还差 \(remaining) 个）· 标签数=\(target.tabbedWindows?.count ?? -1)")
        target.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            closeOneByOneWithGap(remaining: remaining - 1)
        }
    }

    /// 逐个关"最前面的文档窗口" —— 等价于用户挨个点标签上的叉。
    ///
    /// ⚠️ **必须一个一个来、中间留时间**。一次 `for` 循环把几个窗口全 `performClose`，
    /// 观察到的现象是"只走了一次 `windowShouldClose`，然后
    /// `applicationShouldTerminateAfterLastWindowClosed` 就来了" —— 那既不是用户的
    /// 操作方式，也会把"关掉一个标签之后 app 还活着吗"这个最要紧的问题掩盖掉。
    private static func closeFrontDocumentWindow(remaining: Int) {
        guard remaining > 0 else { return }
        let target = NSApp.windows.first {
            $0.isVisible && AppModelBridge.viewModel(for: $0) != nil
        }
        guard let target else {
            Diagnostics.shared.record("自动验证：已经没有文档窗口了")
            return
        }
        Diagnostics.shared.record("自动验证：切到「\(target.title)」再关（还剩 \(remaining) 个要关）")
        // ⚠️ 分两步、中间留时间 —— 这是**用户的真实动作**（点标签选中它、再点它的叉）。
        // 直接对后台标签调 `performClose` 实测**不会**走 `windowShouldClose`：
        // 窗口确实关掉了，但关闭确认整条链路被绕过，`windowWillClose` 也不来
        //（于是注册表里那份一直留着）。同一轮 runloop 里"先 makeKey 再 performClose"
        // 也一样 —— 切换还没生效。所以要隔一帧。
        target.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            target.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dumpWindows(prefix: "关掉一个后")
                closeFrontDocumentWindow(remaining: remaining - 1)
            }
        }
    }

    /// 把所有窗口的标签页状态记一条 —— 系统标签栏到底有没有把窗口并起来、有没有显示，看这个。
    private static func dumpWindows(prefix: String) {
        let diag = Diagnostics.shared
        diag.record("\(prefix)：allowsAutomaticWindowTabbing=\(NSWindow.allowsAutomaticWindowTabbing)"
                    + " userTabbingPreference=\(NSWindow.userTabbingPreference.rawValue)"
                    + "（0=永不 1=始终 2=仅全屏）")
        let documentWindows = Set(AppModelBridge.allEntries.map { ObjectIdentifier($0.window) })
        for (index, window) in NSApp.windows.enumerated() {
            // ⚠️ `tabbedWindows` 只在**标签栏显示着**的时候才非 nil（头文件：
            // "will return nil if the window is not showing a tab bar"），
            // 所以这两个字段要一起看：`isTabBarVisible` 才是"标签栏在不在"。
            let bar = window.tabGroup?.isTabBarVisible == true ? "显示" : "隐藏"
            diag.record("\(prefix)：窗口[\(index)]「\(window.title)」"
                        + " 是文档窗口=\(documentWindows.contains(ObjectIdentifier(window)))"
                        + " tabbingIdentifier=\(window.tabbingIdentifier)"
                        + " tabbingMode=\(window.tabbingMode.rawValue)"
                        + " 标签栏=\(bar)"
                        + " 同组标签数=\(window.tabbedWindows?.count ?? -1)"
                        + " visible=\(window.isVisible)")
        }
    }

    /// 见 `PDFREADER_AUTOTEST_TABFLOW`。全程用真窗口、真 `DocumentOpener`。
    ///
    /// 判据全在日志里：两次 `dumpWindows` 的"文档窗口"行数、以及各自的
    /// `同组标签数` —— 期望**两次都是 2 个文档窗口、各 1 个标签**。
    /// 修复前第一段也正常（B 确实是独立的），**坏在第二段**：还原 A 的那一下
    /// 它重新成为 key，被并进了 B 的组（两边都变成 2）。
    private static func tabFlow(_ raw: String) {
        let urls = raw.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        guard urls.count >= 2 else {
            Diagnostics.shared.record("自动验证[标签流]：需要两个文件路径（逗号分隔），收到「\(raw)」")
            return
        }
        let diag = Diagnostics.shared
        diag.record("自动验证[标签流]：开始 —— A=「\(urls[0].lastPathComponent)」"
                    + " B=「\(urls[1].lastPathComponent)」")

        DocumentOpener.openExternally([urls[0]])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            dumpWindows(prefix: "标签流：打开 A 之后")
            guard let windowA = NSApp.windows.first(where: {
                $0.isVisible && AppModelBridge.viewModel(for: $0) != nil
            }) else {
                diag.record("自动验证[标签流]：找不到 A 的窗口 → 停")
                return
            }
            diag.record("自动验证[标签流]：把「\(windowA.title)」最小化（模拟 ⌘M）")
            windowA.miniaturize(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                diag.record("自动验证[标签流]：在 A 最小化的状态下打开 B（模拟双击文件）")
                DocumentOpener.openExternally([urls[1]])

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    dumpWindows(prefix: "标签流：最小化状态下开 B 之后（期望 2 个独立窗口）")

                    diag.record("自动验证[标签流]：还原 A 并让它成为 key（模拟点 Dock 图标）")
                    NSApp.activate(ignoringOtherApps: true)
                    windowA.deminiaturize(nil)
                    windowA.makeKeyAndOrderFront(nil)

                    // ⚠️ **必须手动走一遍"成为 key"那条路。**
                    //
                    // 产品的并组挂在 `AppDelegate.windowDidBecomeKeyOrMain` 上。
                    // 而从终端裸跑的 app 拿不到真正的键盘焦点 —— 实测
                    // `deminiaturize` / `makeKeyAndOrderFront` **一条 `didBecomeKey` 都不发**
                    //（`tabdetachprobe` 里挂了个观察者专门确认过），于是这条路径
                    // 永远走不到，跑出来的日志会让人误以为"本来就不会合并" —— 踩过一次。
                    //
                    // 所以这里就把那个回调**干的事**直接做一遍（调的是产品代码本身，
                    // 不是复制的副本）：装代理 + `prepareWhenReady`。两者都幂等。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        diag.record("自动验证[标签流]：走一遍「成为 key」那条路"
                                    + "（裸跑时 didBecomeKey 不会自动发）")
                        WindowCloseGuardInstaller.install(on: windowA)
                        DocumentWindows.prepareWhenReady(windowA)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dumpWindows(prefix: "标签流：还原 A 之后（期望**仍然**是 2 个独立窗口）")
                            diag.record("自动验证[标签流]：结束")
                        }
                    }
                }
            }
        }
    }
}
