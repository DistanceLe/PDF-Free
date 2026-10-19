// windowdelegateprobe —— 窗口 delegate 代理的崩溃复现与修法验证
//
// 复现用户那次崩溃：
//
// ```
// -[PDFReader.WindowCloseGuard windowDidBecomeKey:]: unrecognized selector sent to instance
//   NSWindow becomeKeyWindow → postNotificationName → 观察者（代理）→ 崩
// ```
//
// 三个问题：
//   1. 窗口「成为 key」时，AppKit 是把回调**当通知**投给 delegate 的吗？
//   2. 产品那套代理（`responds(to:)` 转发 + `forwardingTarget` 转发）什么条件下会崩？
//   3. 把「通知类」delegate 方法**真的实现**出来之后，是不是就不崩了？
//
// ⚠️ 触发方式：**直接投 `NSWindow.didBecomeKeyNotification`**。
//    一开始用 `makeKeyAndOrderFront` —— 但探针进程从终端跑起时拿不到前台
//    （`NSApp.isActive=false`），窗口成不了 key，一次回调都不触发（白跑一轮）。
//    改成自己投通知：既不需要激活，又能精确回答"delegate 到底有没有被注册成观察者"。
//
// 试过但**不行**的一条路：`methodSignatureForSelector` + `forwardInvocation` 做万能兜底 ——
// Swift 里这两个 API 都被标成 unavailable（`NSInvocation and related APIs not available`）。
// 可行的兜底是运行时动态补实现（`resolveInstanceMethod` + `class_addMethod`），见代理 D。
//
// 运行：swiftc -O -o /tmp/windowdelegateprobe tools/probes/windowdelegateprobe.swift -framework AppKit && /tmp/windowdelegateprobe
// 最后一段**故意**会崩（复现用户现场），所以非 0 退出是预期的。

import AppKit

var pass = 0
var fail = 0
var hits: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name)  \(detail)") }
}

/// 投一条"窗口成为 key"的通知 —— `becomeKeyWindow` 内部干的就是这件事。
func postBecomeKey(_ window: NSWindow) {
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
}

func makeWindow(_ title: String) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                     styleMask: [.titled, .closable, .resizable],
                     backing: .buffered, defer: false)
    w.title = title
    w.tabbingMode = .preferred
    w.orderFront(nil)
    return w
}

// MARK: - 原 delegate（模拟 SwiftUI 的 AppKitWindowController）

final class RealDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
    func windowDidBecomeKey(_ notification: Notification) { hits.append("原.windowDidBecomeKey") }
    func windowDidResignKey(_ notification: Notification) { hits.append("原.windowDidResignKey") }
}

// MARK: - 代理 A：**完全照抄产品现在的写法**（v1.3.50）

final class OldProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    func takeOver(from delegate: NSWindowDelegate?) { original = delegate }
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

// MARK: - 代理 B：修好的写法 —— 把"通知类"delegate 方法**真的实现出来**

final class NewProxy: NSObject, NSWindowDelegate {
    /// ⚠️ **强引用**：`NSWindow.delegate` 是 weak，我们一接管，原 delegate 就只剩
    /// 我们手里这一份；用 weak 的话它随时可能变 nil，转发链直接断。
    var original: NSWindowDelegate?
    func takeOver(from delegate: NSWindowDelegate?) { original = delegate }
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    // ── 这一组：AppKit 通过 NSNotificationCenter 投给 delegate 的方法 ──
    //    ⚠️ 光靠 `forwardingTarget` 兜不住：通知中心用 `objc_msgSend` 直接发，
    //    对象没实现就进转发链，转发目标为 nil → `doesNotRecognizeSelector` → 崩。
    func windowDidBecomeKey(_ n: Notification) {
        hits.append("代理.windowDidBecomeKey"); original?.windowDidBecomeKey?(n)
    }
    func windowDidResignKey(_ n: Notification) {
        hits.append("代理.windowDidResignKey"); original?.windowDidResignKey?(n)
    }
    func windowDidBecomeMain(_ n: Notification) { hits.append("代理.windowDidBecomeMain"); original?.windowDidBecomeMain?(n) }
    func windowDidResignMain(_ n: Notification) { original?.windowDidResignMain?(n) }
    func windowWillMove(_ n: Notification) { original?.windowWillMove?(n) }
    func windowDidMove(_ n: Notification) { original?.windowDidMove?(n) }
    func windowDidResize(_ n: Notification) { original?.windowDidResize?(n) }
    func windowDidUpdate(_ n: Notification) { original?.windowDidUpdate?(n) }
    func windowWillMiniaturize(_ n: Notification) { original?.windowWillMiniaturize?(n) }
    func windowDidMiniaturize(_ n: Notification) { original?.windowDidMiniaturize?(n) }
    func windowDidDeminiaturize(_ n: Notification) { original?.windowDidDeminiaturize?(n) }
    func windowDidChangeScreen(_ n: Notification) { original?.windowDidChangeScreen?(n) }
    func windowDidChangeScreenProfile(_ n: Notification) { original?.windowDidChangeScreenProfile?(n) }
    func windowDidChangeBackingProperties(_ n: Notification) { original?.windowDidChangeBackingProperties?(n) }
    func windowDidChangeOcclusionState(_ n: Notification) { original?.windowDidChangeOcclusionState?(n) }
    func windowWillEnterFullScreen(_ n: Notification) { original?.windowWillEnterFullScreen?(n) }
    func windowDidEnterFullScreen(_ n: Notification) { original?.windowDidEnterFullScreen?(n) }
    func windowWillExitFullScreen(_ n: Notification) { original?.windowWillExitFullScreen?(n) }
    func windowDidExitFullScreen(_ n: Notification) { original?.windowDidExitFullScreen?(n) }
    func windowWillBeginSheet(_ n: Notification) { original?.windowWillBeginSheet?(n) }
    func windowDidEndSheet(_ n: Notification) { original?.windowDidEndSheet?(n) }
    func windowWillEnterVersionBrowser(_ n: Notification) { original?.windowWillEnterVersionBrowser?(n) }
    func windowDidEnterVersionBrowser(_ n: Notification) { original?.windowDidEnterVersionBrowser?(n) }
    func windowWillExitVersionBrowser(_ n: Notification) { original?.windowWillExitVersionBrowser?(n) }
    func windowDidExitVersionBrowser(_ n: Notification) { original?.windowDidExitVersionBrowser?(n) }
}

// MARK: - 代理 D：**动态兜底** —— 任何 window* 回调都不许崩
//
// 代理 C 那条路（`methodSignatureForSelector` + `forwardInvocation`）在 Swift 里
// **写不了** —— `NSInvocation` 被标成 unavailable in Swift。
//
// 换一条：让运行时**按需补一个方法实现**（`+resolveInstanceMethod:` + `class_addMethod`
// + `imp_implementationWithBlock`）。这样不管 AppKit 拿哪个窗口回调来敲，
// 我们都已经"实现了"它 —— 原 delegate 能处理就转过去，处理不了就吞掉。
// 好处是**不需要枚举**：以后 AppKit 再加新的窗口通知也不会崩。

final class DynamicProxy: NSObject, NSWindowDelegate {
    var original: NSWindowDelegate?
    func takeOver(from delegate: NSWindowDelegate?) { original = delegate }
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    // ⚠️ 类方法，而且必须 `nonisolated`（`NSObject` 的版本不是主线程隔离的）
    nonisolated override class func resolveInstanceMethod(_ sel: Selector) -> Bool {
        let name = NSStringFromSelector(sel)
        // 只管窗口回调那一族；别的一律交回运行时（避免把 NSObject 的私有方法也拦掉）
        guard name.hasPrefix("window") else { return false }
        let block: @convention(block) (AnyObject, Notification) -> Void = { object, note in
            guard let proxy = object as? DynamicProxy else { return }
            if let original = proxy.original, original.responds(to: sel) {
                _ = (original as AnyObject).perform(sel, with: note)
            } else {
                hits.append("动态吞掉.\(name)")
            }
        }
        class_addMethod(self, sel, imp_implementationWithBlock(block), "v@:@")
        return true
    }
}

@MainActor
func run() {
    print("════ 1. delegate 是不是被注册成了通知观察者？════")
    do {
        let real = RealDelegate()
        let w = makeWindow("A")
        w.delegate = real
        hits.removeAll()
        postBecomeKey(w)
        check("投 didBecomeKey 通知 → 原 delegate 收到 windowDidBecomeKey",
              hits.contains("原.windowDidBecomeKey"), "hits=\(hits)")
        w.close()
    }

    print("════ 2. 照抄产品的代理写法 + 原 delegate 活着 → 能转发过去吗 ════")
    do {
        let real = RealDelegate()
        let proxy = OldProxy()
        let w = makeWindow("B")
        w.delegate = real
        proxy.takeOver(from: w.delegate)
        w.delegate = proxy
        hits.removeAll()
        postBecomeKey(w)
        check("转发到了原 delegate（转发链有效）",
              hits.contains("原.windowDidBecomeKey"), "hits=\(hits)")
        w.close()
    }

    print("════ 4. 修好的代理 + 接管时窗口没有 delegate（original=nil）→ 不崩 ════")
    do {
        let proxy = NewProxy()
        let w = makeWindow("D")
        proxy.takeOver(from: nil)
        w.delegate = proxy
        hits.removeAll()
        postBecomeKey(w)
        check("代理自己接到了 windowDidBecomeKey", hits.contains("代理.windowDidBecomeKey"), "hits=\(hits)")
        check("没有崩", true)
        w.close()
    }

    print("════ 5. 修好的代理 + 原 delegate 活着 → 两边都收到 ════")
    do {
        let real = RealDelegate()
        let proxy = NewProxy()
        let w = makeWindow("E")
        w.delegate = real
        proxy.takeOver(from: w.delegate)
        w.delegate = proxy
        hits.removeAll()
        postBecomeKey(w)
        check("代理收到", hits.contains("代理.windowDidBecomeKey"), "hits=\(hits)")
        check("原 delegate 也收到（转发有效）", hits.contains("原.windowDidBecomeKey"), "hits=\(hits)")
        w.close()
    }

    print("════ 8. 动态兜底代理 + 原 delegate 是 nil → 投一堆通知都不许崩 ════")
    do {
        let proxy = DynamicProxy()
        let w = makeWindow("H")
        proxy.takeOver(from: nil)
        w.delegate = proxy
        hits.removeAll()
        for name: Notification.Name in [NSWindow.didBecomeKeyNotification,
                                        NSWindow.didResignKeyNotification,
                                        NSWindow.didBecomeMainNotification,
                                        NSWindow.didResignMainNotification,
                                        // ⚠️ 这两个是**内部通知**：头文件里没有公开常量，
                                        //    但真 app 崩溃证明它在（`windowDidOrderOffScreen:`）。
                                        //    也正是它证明了"照公开名单枚举"不完整。
                                        Notification.Name("NSWindowDidOrderOffScreenNotification"),
                                        Notification.Name("NSWindowDidOrderOnScreenNotification"),
                                        NSWindow.didUpdateNotification,
                                        NSWindow.didChangeScreenNotification,
                                        NSWindow.didExposeNotification,
                                        NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.post(name: name, object: w)
        }
        check("投了 10 条窗口通知 → 没有崩", true)
        check("未实现的都被动态兜住（共 \(hits.count) 条）", !hits.isEmpty, "hits=\(hits)")
        print("     兜住的：\(hits.joined(separator: " / "))")
        w.close()
    }

    print("════ 9. 动态兜底代理 + 原 delegate 活着 → 转过去（不吞）════")
    do {
        let real = RealDelegate()
        let proxy = DynamicProxy()
        let w = makeWindow("I")
        w.delegate = real
        proxy.takeOver(from: w.delegate)
        w.delegate = proxy
        hits.removeAll()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        check("原 delegate 收到了 windowDidBecomeKey", hits.contains("原.windowDidBecomeKey"), "hits=\(hits)")
        check("没有被误吞", !hits.contains { $0.hasPrefix("动态吞掉.") }, "hits=\(hits)")
        w.close()
    }

    print()
    print("  \(pass) 通过 / \(fail) 失败  \(fail == 0 ? "✅" : "❌")")

    print("════ 3. 复现用户那次崩溃 ════")
    print("  ⚠️ 关键在于「**注册的时候原 delegate 还在，之后才没有**」：")
    print("     AppKit 是在 `setDelegate` 那一刻按 `responds(to:)` 决定把我们注册成")
    print("     哪些窗口通知的观察者的 —— 一旦注册上，就一直是我们在收。")
    print("     而 `original` 是 weak，它一消失，转发链就断在 nil 上。")
    let real: RealDelegate? = RealDelegate()
    var strongRef: RealDelegate? = real
    let proxy = OldProxy()
    let w = makeWindow("C")
    w.delegate = real
    proxy.takeOver(from: w.delegate)        // 这时原 delegate 还在 → 我们会被注册
    w.delegate = proxy
    strongRef = nil                         // 撤掉外部强引用（模拟它被释放）
    proxy.original = nil                    // 直接模拟 weak 已经变成 nil
    print("  投一条 didBecomeKey 通知 —— 预期这一下崩掉（unrecognized selector）：")
    postBecomeKey(w)
    print("  ❌ 没崩？那说明机制判断错了，得重新查。")
    NSApp.terminate(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async { run() }
app.run()
