import AppKit

/// 探针：怎么让**系统窗口标签栏默认就显示**，以及怎么在"已经显示标签栏"的窗口上继续并。
///
/// ## 头文件里的三条关键事实
///
/// 1. `NSWindow.tabbedWindows` 注释："This is now a cover for `self.tabGroup.windows`,
///    but will **return nil if the window is not showing a tab bar**."
///    → 它反映的是"标签栏在不在"，不只是"组里有几个窗口"。
/// 2. `NSWindow.tabGroup.isTabBarVisible`（Swift 里 `tabBarVisible` 被改名为这个）
///    才是最准确的判据。
/// 3. `NSWindow.tabbingMode` 注释："This should be set **before a window is shown**."
///
/// ## 为什么这个探针要按"真实顺序"跑
///
/// 我们的窗口是 SwiftUI 建的，只能在**上屏之后**才拿到，"before a window is shown"
/// 做不到。于是问题变成：
///
/// - 上屏之后再设 `.preferred` 来不来得及？→ 第 2 段
/// - 来不及的话 `toggleTabBar(_:)` 能不能补上？→ 第 3 段
/// - ⚠️ **最要紧的一条**：第一个窗口 `toggleTabBar` 之后 `tabbedWindows` 会变成
///   `[自己]`（不再是 nil），而现有 `mergeIntoGroup` 里那句
///   `guard window.tabbedWindows == nil` 正是按"单个窗口时是 nil"写的 ——
///   不改的话**多窗口就永远并不起来了**。第 4~6 段完整模拟这条路径。
///
/// 跑法：
/// ```
/// swiftc -O -o /tmp/tabmodeeprobe tools/probes/tabmodeeprobe.swift -framework AppKit
/// /tmp/tabmodeeprobe
/// ```

final class ProbeWindow: NSWindow {
    convenience init(title: String) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                  styleMask: [.titled, .closable, .resizable],
                  backing: .buffered,
                  defer: false)
        self.title = title
        self.tabbingIdentifier = "Probe.Document"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1 } else { fail += 1 }
    print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  —— \(detail)")")
}

func barVisible(_ window: NSWindow) -> Bool {
    window.tabGroup?.isTabBarVisible ?? false
}

func describe(_ window: NSWindow) -> String {
    let tabs = window.tabbedWindows.map { list in
        "[\(list.map(\.title).joined(separator: " | "))] 共 \(list.count) 个"
    } ?? "nil"
    return "tabbingMode=\(window.tabbingMode.rawValue)"
        + "  标签栏=\(barVisible(window) ? "显示" : "隐藏")  tabbedWindows=\(tabs)"
}

func wait(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// 我们打算写进 `DocumentWindows.prepareWhenReady` 的那套动作
func prepare(_ window: NSWindow) {
    window.tabbingMode = .preferred
    // ① 有同组的别的窗口 → 并进去（⚠️ 判断不能再用 `tabbedWindows == nil`）
    if (window.tabbedWindows?.count ?? 0) <= 1,
       let sibling = NSApp.windows.first(where: {
           $0 !== window && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
       }) {
        let anchor = sibling.tabbedWindows?.last ?? sibling
        anchor.addTabbedWindow(window, ordered: .above)
        wait(0.3)
    }
    // ② 还是没有标签栏（说明它是第一个窗口）→ 手动开
    if !barVisible(window) { window.toggleTabBar(nil) }
}

print("════ 0. 环境 ════")
print("  allowsAutomaticWindowTabbing = \(NSWindow.allowsAutomaticWindowTabbing)")
let pref = NSWindow.userTabbingPreference.rawValue
let prefNames = ["manual（永不）", "always（始终）", "inFullScreen（仅全屏）"]
print("  userTabbingPreference = \(pref)  —— \(prefNames[min(max(pref, 0), 2)])")
print("  （系统设置 → 桌面与程序坞 →「优先以标签页方式打开文稿」）")

print()
print("════ 1. 第一个窗口，什么都不做 ════")
let a = ProbeWindow(title: "A")
a.orderFront(nil)
wait(0.5)
print("  A: \(describe(a))")
check("默认（automatic + 系统偏好非 always）→ 没有标签栏", !barVisible(a))

print()
print("════ 2. 上屏之后再设 .preferred ════")
a.tabbingMode = .preferred
wait(0.5)
print("  A: \(describe(a))")
check("上屏之后设 preferred，标签栏**不会**自己冒出来（头文件说该 before shown）",
      !barVisible(a))

print()
print("════ 3. 用 toggleTabBar(_:) 补 ════")
if !barVisible(a) { a.toggleTabBar(nil) }
wait(0.5)
print("  A: \(describe(a))")
check("toggleTabBar 能把标签栏显示出来（单独一个窗口也显示）", barVisible(a))
check("⚠️ 此时 tabbedWindows 变成「只有自己」、不再是 nil",
      a.tabbedWindows?.count == 1,
      "← 所以 mergeIntoGroup 里 `guard tabbedWindows == nil` 那句**必须改**")

print()
print("════ 4. 第二个窗口来了：先上屏（automatic）════")
let b = ProbeWindow(title: "B")
b.orderFront(nil)
wait(0.6)
print("  A: \(describe(a))")
print("  B: \(describe(b))")
check("新窗口只靠 automatic 不会自己并进来", (b.tabbedWindows?.count ?? 0) <= 1,
      "B 的 tabbedWindows = \(b.tabbedWindows?.count.description ?? "nil")")

print()
print("════ 5. 按 prepare 的完整动作处理第二个窗口 ════")
prepare(b)
wait(0.6)
print("  A: \(describe(a))")
print("  B: \(describe(b))")
check("两个窗口并成一组（标签栏里 2 个标签）",
      (a.tabbedWindows?.count ?? 0) == 2,
      "A 视角 \(a.tabbedWindows?.count.description ?? "nil") 个")
if let list = a.tabbedWindows {
    check("顺序是 A | B（新标签加在末尾）",
          list.first?.title == "A" && list.last?.title == "B",
          list.map(\.title).joined(separator: " | "))
}

print()
print("════ 6. 关掉 B —— 只剩一个标签，标签栏该留着 ════")
b.close()
wait(0.6)
print("  A: \(describe(a))")
check("关到只剩一个时标签栏仍然显示（这正是用户要的「默认显示」）", barVisible(a))

print()
print("════ 7. 再来一个窗口，看还能不能并进已有的组 ════")
let c = ProbeWindow(title: "C")
c.orderFront(nil)
wait(0.5)
prepare(c)
wait(0.6)
print("  A: \(describe(a))")
print("  C: \(describe(c))")
check("第三个窗口也能并进同一组", (a.tabbedWindows?.count ?? 0) == 2,
      "A 视角 \(a.tabbedWindows?.count.description ?? "nil") 个")

print()
print("════ 8. 重复处理同一个窗口（幂等）════")
let before = a.tabbedWindows?.count ?? -1
prepare(c)
wait(0.4)
print("  A: \(describe(a))")
check("重复 prepare 不会把窗口弄乱", (a.tabbedWindows?.count ?? -2) == before,
      "\(before) → \(a.tabbedWindows?.count.description ?? "nil")")

print()
print("════ 结果：\(pass) 通过 / \(fail) 失败 \(fail == 0 ? "✅ 全部通过" : "❌ 有失败")════")
exit(fail == 0 ? 0 : 1)
