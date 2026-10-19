import AppKit

// 问清楚 macOS 的窗口分页（tab）到底怎么才会生效。
//
// 背景：PDFReader 改成"一个文件一个窗口"，指望系统把它们并成标签栏。
// 实测 `tabbingIdentifier` 一样、`tabbingMode = automatic`，但 `tabbedWindows` 全是 nil
// —— 也就是根本没并。这个探针把三种做法各试一遍：
//
//   1. 直接建一个同 identifier 的窗口（靠系统"自动分页"）
//   2. 显式 `addTabbedWindow(_:ordered:)`
//   3. 先设 `tabbingMode = .preferred` 再建
//
// 跑法：swiftc -O -o /tmp/tabprobe tools/probes/tabprobe.swift -framework AppKit && /tmp/tabprobe

final class ProbeDelegate: NSObject, NSApplicationDelegate {

    private var made: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("allowsAutomaticWindowTabbing = \(NSWindow.allowsAutomaticWindowTabbing)")
        let mode = UserDefaults.standard.string(forKey: "AppleWindowTabbingMode") ?? "(没有这个键)"
        print("AppleWindowTabbingMode = \(mode)")

        let first = makeWindow(0, tabbingMode: .automatic)
        made.append(first)

        print("\n──── 场景 1：再建一个同 identifier 的窗口（指望系统自动并） ────")
        made.append(makeWindow(1, tabbingMode: .automatic))
        dump("场景1")

        print("\n──── 场景 2：显式 addTabbedWindow ────")
        let third = makeWindow(2, tabbingMode: .automatic)
        first.addTabbedWindow(third, ordered: .above)
        made.append(third)
        dump("场景2")

        print("\n──── 场景 3：tabbingMode = .preferred 再建 ────")
        made.append(makeWindow(3, tabbingMode: .preferred))
        dump("场景3")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.dump("延迟 0.6 秒后（让 AppKit 把标签栏摆好）")
            NSApp.terminate(nil)
        }
    }

    private func makeWindow(_ index: Int, tabbingMode: NSWindow.TabbingMode) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 240 + CGFloat(index) * 40, y: 320,
                                                  width: 420, height: 300),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "文档 \(index)"
        window.tabbingIdentifier = "TabProbe"
        window.tabbingMode = tabbingMode
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func dump(_ tag: String) {
        let titled = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.isVisible }
        print("[\(tag)] 可见的标题窗口 \(titled.count) 个")
        for (index, window) in titled.enumerated() {
            print("   窗口\(index)「\(window.title)」"
                  + " mode=\(window.tabbingMode.rawValue)"
                  + " 同组标签=\(window.tabbedWindows?.count ?? -1)")
        }
    }
}

let application = NSApplication.shared
let probe = ProbeDelegate()
application.delegate = probe
application.setActivationPolicy(.regular)
application.run()
