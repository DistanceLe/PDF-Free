import AppKit

/// 探针：**标签页拖出去能不能成为独立窗口**、**最小化的窗口会不会把新窗口吸进它的标签组**。
///
/// ## 杰哥 2026-10-13 报的两个问题
///
/// 1. 「打开了多个文件，不能通过拖拽标签页独立出一个新的窗口」
/// 2. 「app 最小化的时候再打开其他文件，看起来是个新独立窗口，
///    但把最小化的那个窗口点开，就自动合并成一个窗口了」
///
/// ## 两个 bug 是**同一个根因**：`DocumentWindows.showTabBarAndMerge` 每次
/// `prepareWhenReady` 都会重新跑一遍"找同伴 → 并组"。它接不住这两种现场：
///
/// - **拖出去**：那个窗口会重新成为 key，于是又走一次并组。而那一刻
///   `tabbedWindows.count` 只剩 1（**不是**旧判断要的 `> 1`），于是我们**亲手**
///   把用户刚拖出来的标签并了回去 —— 用户看到的就是"拖不出来"。
/// - **最小化**：最小化的窗口 `isVisible` 仍是 true，被当成"落脚点"，
///   新窗口被并进它的组 —— 用户看到新窗口"独立"站着，点开 Dock 上那个才发现是同一个。
///
/// ## 修的两处（v1.3.71）
///
/// - `preparedWindows`：一个窗口的"入境手续"**只办一次**（放在函数最前面，
///   每条分支都要算"办过了"），之后无论它成为多少次 key 都不再动它；
/// - 找落脚点时加 `!$0.isMiniaturized`，最小化的窗口不算同伴。
///
/// ## 跑法
///
/// ```
/// swiftc -O -o /tmp/tabdetachprobe tools/probes/tabdetachprobe.swift -framework AppKit
/// /tmp/tabdetachprobe
/// ```
///
/// ⚠️ 会短暂弹出几个小窗口（还要最小化一个到 Dock），跑完自动退出。

final class ProbeWindow: NSWindow {
    convenience init(title: String) {
        // ⚠️ `.miniaturizable` 不能少 —— 少了它 `miniaturize(_:)` 会**静默失败**
        //（窗口纹丝不动，`isMiniaturized` 一直是 false）
        self.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                  backing: .buffered,
                  defer: false)
        self.title = title
        self.tabbingIdentifier = "Probe.Document"
        // 探针自己管生命周期，别让 AppKit 在 close 时顺手 release 掉（ARC 下会过释放）
        self.isReleasedWhenClosed = false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1 } else { fail += 1 }
    print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  —— \(detail)")")
}
func wait(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
func barVisible(_ window: NSWindow) -> Bool { window.tabGroup?.isTabBarVisible ?? false }
func tabCount(_ window: NSWindow) -> Int { window.tabbedWindows?.count ?? 0 }
func describe(_ window: NSWindow) -> String {
    // ⚠️ 先摸一下 `tabGroup` —— `tabbedWindows` 是**懒初始化**的：
    //    第一次访问可能返回 nil，紧接着再访问一次才变成 `[自己]`。
    //    不先摸这一下，同一行里两个值会自相矛盾（`[nil]` 却写着"1 个"）。
    let bar = barVisible(window) ? "显示" : "隐藏"
    let list = window.tabbedWindows?.map(\.title).joined(separator: " | ") ?? "nil"
    return "标签栏=\(bar)  同组=[\(list)]  \(tabCount(window)) 个"
}

// ══════════════════════════════════════════════════════════════════════
// 旧逻辑（v1.3.66 及之前）—— 只为复现 bug
// ══════════════════════════════════════════════════════════════════════
enum OldLogic {
    static var tabBarHandled = Set<ObjectIdentifier>()

    static func prepare(_ window: NSWindow) {
        window.tabbingMode = .preferred
        if tabCount(window) > 1 { return }
        if let sibling = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
        }) {
            let anchor = sibling.tabbedWindows?.last ?? sibling
            anchor.addTabbedWindow(window, ordered: .above)
            return
        }
        let key = ObjectIdentifier(window)
        guard !tabBarHandled.contains(key) else { return }
        tabBarHandled.insert(key)
        if !barVisible(window) { window.toggleTabBar(nil) }
    }
}

// ══════════════════════════════════════════════════════════════════════
// 新逻辑（v1.3.71）—— 与产品代码 `DocumentWindows.showTabBarAndMerge` 一致
// ══════════════════════════════════════════════════════════════════════
enum NewLogic {
    static var prepared = Set<ObjectIdentifier>()

    static func prepare(_ window: NSWindow) {
        window.tabbingMode = .preferred
        // ⚠️ 入境手续只办一次，放最前面 —— 每条分支都要算"办过了"
        let key = ObjectIdentifier(window)
        guard !prepared.contains(key) else { return }
        prepared.insert(key)

        if tabCount(window) > 1 { return }
        if let sibling = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && !$0.isMiniaturized
                && $0.tabbingIdentifier == window.tabbingIdentifier
        }) {
            let anchor = sibling.tabbedWindows?.last ?? sibling
            anchor.addTabbedWindow(window, ordered: .above)
            return
        }
        if !barVisible(window) { window.toggleTabBar(nil) }
    }
}

/// 谁在"成为 key" —— 我们要知道"还原/拖出"那一下到底有没有发这个通知，
/// 因为产品代码的并组就挂在它上面（`windowDidBecomeKeyOrMain`）。
final class KeyReporter: NSObject {
    @objc func noted(_ note: Notification) {
        let window = note.object as? NSWindow
        print("    · didBecomeKey →「\(window?.title ?? "?")」")
    }
}
let keyReporter = KeyReporter()
NotificationCenter.default.addObserver(keyReporter,
                                       selector: #selector(KeyReporter.noted(_:)),
                                       name: NSWindow.didBecomeKeyNotification,
                                       object: nil)

print("════ 0. 环境 ════")
print("  allowsAutomaticWindowTabbing = \(NSWindow.allowsAutomaticWindowTabbing)")
let pref = NSWindow.userTabbingPreference.rawValue
let prefNames = ["manual（永不）", "always（始终）", "inFullScreen（仅全屏）"]
print("  userTabbingPreference = \(pref)  —— \(prefNames[min(max(pref, 0), 2)])")

// ══════════════════════════════════════════════════════════════════════
// 场景 A：把标签拖出去（detach）
// ══════════════════════════════════════════════════════════════════════
print()
print("════ 场景 A：把标签拖出去成为独立窗口 ════")

print("── A-1 旧逻辑（复现 bug）──")
do {
    let a = ProbeWindow(title: "A1")
    a.orderFront(nil)
    wait(0.5)
    OldLogic.prepare(a)
    wait(0.4)

    let b = ProbeWindow(title: "B1")
    b.orderFront(nil)
    wait(0.5)
    OldLogic.prepare(b)
    wait(0.5)
    print("  A1: \(describe(a))")
    print("  B1: \(describe(b))")
    check("前提：两个窗口先正常并成一组", tabCount(a) == 2, "A1 同组 \(tabCount(a)) 个")

    // 模拟用户拖拽分离：把 B1 从组里摘出来（这就是 AppKit 里 detach 干的事）
    a.tabGroup?.removeWindow(b)
    wait(0.6)
    print("  拖出后 A1: \(describe(a))")
    print("  拖出后 B1: \(describe(b))")
    check("前提：拖出瞬间 B1 确实独立了", tabCount(b) <= 1, "B1 同组 \(tabCount(b)) 个")

    // 拖出去的窗口会重新成为 key → `windowDidBecomeKeyOrMain` 又把它交给 prepare
    b.makeKeyAndOrderFront(nil)
    wait(0.3)
    OldLogic.prepare(b)
    wait(0.5)
    print("  再 prepare 后 A1: \(describe(a))")
    print("  再 prepare 后 B1: \(describe(b))")
    check("复现：旧逻辑把刚拖出去的 B1 **又并了回去**（这就是「拖不出来」）",
          tabCount(b) == 2, "B1 同组 \(tabCount(b)) 个")

    a.close()
    b.close()
    wait(0.4)
}

print("── A-2 新逻辑（修好之后）──")
do {
    let a = ProbeWindow(title: "A2")
    a.orderFront(nil)
    wait(0.5)
    NewLogic.prepare(a)
    wait(0.4)

    let b = ProbeWindow(title: "B2")
    b.orderFront(nil)
    wait(0.5)
    NewLogic.prepare(b)
    wait(0.5)
    check("新逻辑：多文件照常并成一组（合并行为没被改坏）", tabCount(a) == 2,
          "A2 同组 \(tabCount(a)) 个")

    a.tabGroup?.removeWindow(b)
    wait(0.6)
    check("新逻辑：拖出后 B2 独立", tabCount(b) <= 1, "B2 同组 \(tabCount(b)) 个")

    b.makeKeyAndOrderFront(nil)
    wait(0.3)
    NewLogic.prepare(b)
    wait(0.5)
    print("  再 prepare 后 A2: \(describe(a))")
    print("  再 prepare 后 B2: \(describe(b))")
    check("新逻辑：拖出去的 B2 **保持独立**，没被吸回去", tabCount(b) <= 1,
          "B2 同组 \(tabCount(b)) 个")
    check("新逻辑：另一边 A2 也还是一人一组", tabCount(a) <= 1,
          "A2 同组 \(tabCount(a)) 个")

    a.close()
    b.close()
    wait(0.4)
}

// ══════════════════════════════════════════════════════════════════════
// 场景 B：窗口最小化之后打开新文件
// ══════════════════════════════════════════════════════════════════════
print()
print("════ 场景 B：窗口最小化（⌘M）之后打开新文件 ════")

// ⚠️ 真正出问题的那一步**不是**"新窗口被并进最小化的组"，而是**还原的那一下**：
//    最小化期间 `isVisible == false`，所以新窗口本来就找不到它、老实另立一组
//   （用户看到的就是"新的独立窗口"）；等用户点 Dock 把老窗口还原，它重新成为 key，
//    才在这一步被并进**新窗口**那一组 —— 也就是"点开就合并成一个了"。

print("── B-1 旧逻辑（复现 bug）──")
do {
    let a = ProbeWindow(title: "A3")
    a.orderFront(nil)
    wait(0.5)
    OldLogic.prepare(a)
    wait(0.4)

    a.miniaturize(nil)
    wait(1.0)
    print("  最小化后：isVisible=\(a.isVisible)  isMiniaturized=\(a.isMiniaturized)"
          + "   ← 最小化之后 isVisible **就是 false**，新窗口本来就找不到它")

    let c = ProbeWindow(title: "C3")
    c.orderFront(nil)
    wait(0.5)
    OldLogic.prepare(c)
    wait(0.5)
    print("  C3: \(describe(c))")
    check("前提：新窗口 C3 起来的时候是独立的（用户看到的就是这个）", tabCount(c) <= 1,
          "C3 同组 \(tabCount(c)) 个")

    // ⚠️ 关键的一下：用户点 Dock 把最小化的窗口还原 → 它重新成为 key → 又走一遍 prepare
    a.deminiaturize(nil)
    wait(0.8)
    a.makeKeyAndOrderFront(nil)
    wait(0.3)
    OldLogic.prepare(a)
    wait(0.5)
    print("  还原 A3 并再 prepare 后：A3: \(describe(a))")
    print("  还原 A3 并再 prepare 后：C3: \(describe(c))")
    check("复现：旧逻辑把**还原的那一个**并进了新窗口的组（「点开就合并成一个」）",
          tabCount(a) == 2, "A3 同组 \(tabCount(a)) 个")

    if tabCount(a) > 1 { a.tabGroup?.removeWindow(c) }
    wait(0.4)
    a.close()
    c.close()
    wait(0.4)
}

print("── B-2 新逻辑（修好之后）──")
do {
    let a = ProbeWindow(title: "A4")
    a.orderFront(nil)
    wait(0.5)
    NewLogic.prepare(a)
    wait(0.4)

    a.miniaturize(nil)
    wait(1.0)

    let c = ProbeWindow(title: "C4")
    c.orderFront(nil)
    wait(0.5)
    NewLogic.prepare(c)
    wait(0.5)
    print("  C4: \(describe(c))")
    check("新逻辑：新窗口 C4 是独立窗口", tabCount(c) <= 1, "C4 同组 \(tabCount(c)) 个")

    a.deminiaturize(nil)
    wait(0.8)
    a.makeKeyAndOrderFront(nil)
    wait(0.3)
    NewLogic.prepare(a)
    wait(0.5)
    print("  还原 A4 并再 prepare 后：A4: \(describe(a))")
    print("  还原 A4 并再 prepare 后：C4: \(describe(c))")
    check("新逻辑：还原之后两个仍是独立窗口，不再自动合并",
          tabCount(a) <= 1 && tabCount(c) <= 1,
          "A4 \(tabCount(a)) 个 / C4 \(tabCount(c)) 个")

    a.close()
    c.close()
    wait(0.4)
}

// ══════════════════════════════════════════════════════════════════════
// 场景 C：`tabbingMode = .preferred` **在上屏之前**设 —— 系统自己就会并
// ══════════════════════════════════════════════════════════════════════
//
// 上一版探针（`tabmodeeprobe`）验过"上屏**之后**设 `.preferred` 不生效"，
// 所以产品代码是上屏后才设的。这一条补上另一半：
//
// ⚠️ **在上屏之前设 `.preferred`，系统就会自己把同 identifier 的新窗口并进来**
//（`tabbingMode` 头文件："This should be set before a window is shown."）。
//
// 这解释了为什么产品代码不能"提前设 `.preferred` 了事" —— 那样连用户
// **主动拖出去**的窗口也会在下次上屏时被系统吸回去。现在的做法
//（上屏后设 + 手动 `addTabbedWindow`）+ 本版的"只办一次"，才控得住。
print()
print("════ 场景 C：`.preferred` 在**上屏前**设 —— 系统自己就会并 ════")
do {
    let a = ProbeWindow(title: "C-A")
    a.tabbingMode = .preferred
    a.orderFront(nil)
    wait(0.5)
    if !barVisible(a) { a.toggleTabBar(nil) }
    wait(0.4)

    let b = ProbeWindow(title: "C-B")
    b.tabbingMode = .preferred
    b.orderFront(nil)
    wait(0.5)
    if !barVisible(b) { b.toggleTabBar(nil) }
    wait(0.5)
    print("  刚开好 A: \(describe(a))")
    print("  刚开好 B: \(describe(b))")

    wait(3.0)
    print("  干等 3 秒后 A: \(describe(a))")
    print("  干等 3 秒后 B: \(describe(b))")
    check("`.preferred` 在上屏**前**设 → 系统自己就把两个并起来了"
          + "（所以产品代码只能上屏**后**设，并组也才必须我们自己来）",
          tabCount(a) == 2, "A 同组 \(tabCount(a)) 个")

    a.close()
    b.close()
    wait(0.4)
}

// ══════════════════════════════════════════════════════════════════════
// 场景 D：**用户点 Dock 还原**的那一下，系统自己会不会合并？
// ══════════════════════════════════════════════════════════════════════
//
// 与场景 B 的区别：这里**不调用任何 prepare**，纯看系统。
// 如果系统自己就并了，那杰哥报的问题 2 跟我们的代码无关；
// 如果不并，那"还原时被并"就只可能来自 `didBecomeKey → prepareWhenReady`。
print()
print("════ 场景 D：只还原，不动我们的代码 —— 看系统自己合不合并 ════")
do {
    let a = ProbeWindow(title: "D-A")
    a.tabbingMode = .preferred
    a.orderFront(nil)
    wait(0.5)
    if !barVisible(a) { a.toggleTabBar(nil) }
    wait(0.4)

    a.miniaturize(nil)
    wait(0.8)

    let b = ProbeWindow(title: "D-B")
    b.tabbingMode = .preferred
    b.orderFront(nil)
    wait(0.5)
    if !barVisible(b) { b.toggleTabBar(nil) }
    wait(0.5)
    print("  B 起来时 B: \(describe(b))")

    app.activate(ignoringOtherApps: true)
    a.deminiaturize(nil)
    a.makeKeyAndOrderFront(nil)
    wait(2.0)
    print("  还原 A 后 A: \(describe(a))")
    print("  还原 A 后 B: \(describe(b))")
    check("系统自己**不会**在还原时合并（说明合并一定来自我们的并组代码）",
          tabCount(a) <= 1 && tabCount(b) <= 1,
          "A \(tabCount(a)) 个 / B \(tabCount(b)) 个")

    a.close()
    b.close()
    wait(0.4)
}

print()
print("════ 结果：\(pass) 通过 / \(fail) 失败  \(fail == 0 ? "✅ 全部通过" : "❌ 有失败") ════")
exit(fail == 0 ? 0 : 1)
