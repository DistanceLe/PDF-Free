import AppKit
import Foundation

/// 版本信息。
///
/// 显示在设置窗口底部 —— 用户报问题时**先看这一行**就能确认跑的是哪一版构建，
/// 免得"改了却没生效"其实是跑着旧产物。
enum AppInfo {

    /// 界面上显示的版本号，形如 `1.0 (1)`。
    ///
    /// ⚠️ **唯一来源是 `Info.plist`，不要在这里硬编码**（v1.3.65）。
    ///
    /// 以前这里写着字面量 `"v1.3.64"`，于是同一份构建里冒出了**三个**版本号：
    /// 设置窗口 `v1.3.64`、"关于 PDF Free" 面板 `1.0 (1)`、Xcode 的 Version 字段 `1.0` ——
    /// 杰哥截图圈出来要求统一。现在统一从 bundle 取，"关于"面板显示什么这儿就显示什么。
    ///
    /// 以后要升版本，只改 `Info.plist` 这两个键，**别的地方都不用动**：
    /// - `CFBundleShortVersionString` —— 对外版本（如 `1.1`）
    /// - `CFBundleVersion` —— 构建号，每次发版 +1
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        switch (short.isEmpty, build.isEmpty) {
        case (false, false): return "\(short) (\(build))"
        case (false, true): return short
        case (true, false): return build
        case (true, true): return "1.0"
        }
    }

    /// 这份 `.app` 的**构建时刻**，形如 `10-13 11:05`。
    ///
    /// ⚠️ **只进诊断日志，不上界面。**
    ///
    /// 版本号统一成 `1.0 (1)` 之后，光看它分不清"这是哪一次构建"——
    /// 排查"我明明改了怎么没生效"（多半是跑着旧产物）时需要这个精确坐标，
    /// 比版本号可靠得多。取的是可执行文件自己的修改时间，也就是打包那一刻。
    static var buildStamp: String {
        guard let path = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 保存与备份相关的用户偏好（存在 `UserDefaults`）。
///
/// 为什么单独一个类型：这些偏好是**跨文档**的（所有标签页共用一份），
/// 而 `PDFViewModel` 每个标签页一个实例 —— 放它身上会变成各存各的。
///
/// 备份目录用 **security-scoped bookmark** 持久化：
/// 沙箱下用户通过面板选中的目录，进程一旦退出授权就没了，
/// 光存路径字符串下次启动**读不到**；必须存 bookmark 再解析回来
/// （entitlements 里已有 `com.apple.security.files.bookmarks.app-scope`）。
@MainActor
final class AppPreferences: ObservableObject {

    static let shared = AppPreferences()

    private enum Key {
        static let autoSaveOutline = "pref.autoSaveOutline"
        static let promptToSaveOnClose = "pref.promptToSaveOnClose"
        static let backupEnabled = "pref.backupEnabled"
        static let backupBookmark = "pref.backupDirectoryBookmark"
        static let backupDisplayPath = "pref.backupDirectoryDisplayPath"
        static let schemaVersion = "pref.schemaVersion"
        /// 「外框」颜色（工具栏 + 左右侧栏），存 `#RRGGBB`。空串 = 用内置的浅灰。
        static let chromeColorHex = "pref.chromeColorHex"
        /// 批注作者名 —— 写进 PDF 批注的 `/T` 字段，别人打开能看到"这条是谁标的"。
        static let annotationAuthor = "pref.annotationAuthor"
        /// **页面底色**（PDF 页面背后那一层，也管透明图片的透明区域），存 `#RRGGBB`。
        /// 空串 = 跟随系统（浅色白 / 深色近黑）。
        static let pageBackgroundHex = "pref.pageBackgroundHex"
        /// 诊断日志总开关。⚠️ **键名取自 `Diagnostics`** —— 那边也要读它，
        /// 两边必须是同一个字符串（`Diagnostics.defaultsKey`）。
        static let diagnosticsEnabled = Diagnostics.defaultsKey
    }

    /// 偏好结构的版本号。改默认值时要靠它做**一次性迁移** ——
    /// `register(defaults:)` 只在键**不存在**时生效，用户手上那份已经写进去的值改不动。
    private static let currentSchemaVersion = 2

    private let defaults = UserDefaults.standard

    // MARK: - 自动保存

    /// 目录改动后自动写盘（**默认关**，见下面的说明）。
    ///
    /// ⚠️ **它会让编辑变卡，所以默认关掉了。**
    ///
    /// 写盘是**同步的整份序列化**（`PDFDocument.write` + 注入目录 + 重新打开自检 + 原子替换），
    /// 全在主线程跑。文件一大就是几百毫秒的停顿；而且防抖只有 0.8 秒，
    /// 在目录里连续改几下就会反复触发 —— 手感上就是"一顿一顿"。
    ///
    /// 现在改成默认「关闭时提醒保存」（`promptToSaveOnClose`），
    /// 由用户自己按 ⌘S，或者关闭文档时统一决定。想开着它也行，代价如上。
    @Published var autoSaveOutline: Bool {
        didSet { defaults.set(autoSaveOutline, forKey: Key.autoSaveOutline) }
    }

    /// 关闭文档 / 退出时，如果有没保存的改动就问一句（默认开）。
    @Published var promptToSaveOnClose: Bool {
        didSet { defaults.set(promptToSaveOnClose, forKey: Key.promptToSaveOnClose) }
    }

    // MARK: - 外观：外框颜色（v1.3.61）

    /// 界面「外框」（工具栏 + 左右侧栏）的底色，存 `#RRGGBB`。
    ///
    /// **空串 = 用内置的浅灰**（见 `AppChrome.defaultChrome`）—— 不给用户强塞一个颜色，
    /// 他不动它就还是我们调好的那套（浅色 #CCCCCC / 深色 #2E2E2E）。
    @Published var chromeColorHex: String {
        didSet { defaults.set(chromeColorHex, forKey: Key.chromeColorHex) }
    }

    /// 界面上真正用的外框色 —— 实现在 `AppChrome.swift`（那里才有 SwiftUI 的 `Color`；
    /// 这个文件只依赖 AppKit，不引 SwiftUI）。
    ///
    /// 把外框色恢复成内置的默认（浅色 #CCCCCC / 深色 #2E2E2E）。
    func resetChromeColor() {
        chromeColorHex = ""
    }

    // MARK: - 外观：页面底色（v1.3.67）

    /// 文档**页面背后**那一层的颜色，存 `#RRGGBB`。
    ///
    /// **空串 = 跟随系统**（浅色白 / 深色近黑）—— 也就是加这个开关之前的行为。
    ///
    /// ## 为什么需要它
    ///
    /// 用户原话："透明的图片，看不出来是透明的还是白底的。"
    ///
    /// PDF 页面本身没有底色（PDF 规范里页面是透明的），`PDFView` 只画它的
    /// `backgroundColor`。所以一张**透明 PNG** 的透明区域会直接露成系统那个白，
    /// 跟"图片自己就是白底"**长得一模一样**，分不出来。
    /// 把这里调成浅灰，透明的地方立刻变灰 —— 一眼就分得清"哪儿是透明的"。
    ///
    /// ⚠️ 它同时管**页面外围**那块留白（PDFKit 只有一个 `backgroundColor`，
    /// 页面内外分不开）。想让页面和外围分出层次的话，把底色调深一点就行：
    /// 不透明的页面会盖住底色，透明的不会。
    @Published var pageBackgroundHex: String {
        didSet { defaults.set(pageBackgroundHex, forKey: Key.pageBackgroundHex) }
    }

    /// 把页面底色恢复成**跟随系统**。
    func resetPageBackground() {
        pageBackgroundHex = ""
    }

    // MARK: - 批注作者（v1.3.61）

    /// 批注的作者名 —— 会写进 PDF 批注标准的 `/T` 字段。
    ///
    /// 为什么要有它：PDF 的批注本来就带"谁标的"这一栏（Adobe、预览、Foxit 都读它），
    /// 我们的 app 之前没填，别人收到文件只看到一堆没有署名的标注。
    /// 默认取当前 macOS 用户的全名，用户可以自己改（比如署真名或笔名）。
    @Published var annotationAuthor: String {
        didSet { defaults.set(annotationAuthor, forKey: Key.annotationAuthor) }
    }

    /// 系统里的用户全名（`NSFullUserName()`），拿不到就退回短名。
    static var systemUserName: String {
        let full = NSFullUserName()
        if !full.isEmpty { return full }
        return NSUserName()
    }

    // MARK: - 诊断（v1.3.68）

    /// 记录诊断日志 —— **默认：Debug 构建开、Release 构建关**（效率优先）。
    ///
    /// 关着的时候 `Diagnostics` 什么都不做：不建日志文件、不装主线程看门狗
    ///（那个 runloop observer 每一轮都会被调一次）、不起卡死检测线程、不监听鼠标事件。
    ///
    /// ⚠️ 改这个值**立即生效**，不用重启 —— `didSet` 里直接驱动 `Diagnostics.setEnabled`。
    /// 唯一的例外是崩溃兜底：它永远装着（零开销，且是"用户报崩溃"时唯一的证据，见 `Diagnostics`）。
    @Published var diagnosticsEnabled: Bool {
        didSet {
            defaults.set(diagnosticsEnabled, forKey: Key.diagnosticsEnabled)
            Diagnostics.setEnabled(diagnosticsEnabled)
        }
    }

    // MARK: - 备份

    /// 手动保存（⌘S / 工具栏按钮）时先备份原文件（默认开）。
    ///
    /// ⚠️ **自动保存不看这个开关** —— 它永远不生成用户可见的备份文件。
    /// 每次编辑都堆一份备份会迅速占满目录，而它的安全性由
    /// 「先写临时文件、自检、再原子替换」保证（写失败时原文件分毫无损）。
    @Published var backupEnabled: Bool {
        didSet { defaults.set(backupEnabled, forKey: Key.backupEnabled) }
    }

    /// 自定义备份目录；nil = 默认（原文件旁边，写不进去则应用数据目录）
    @Published private(set) var backupDirectory: URL?

    /// 界面上显示的路径（书签解析失败时，也还能把当初选的路径显示出来）
    @Published private(set) var backupDirectoryDisplayPath: String?

    /// 备份目录相关的问题（选定失败 / 目录已失效 / 当前不可写），如实告诉界面
    @Published var backupDirectoryNotice: String?

    var usesCustomBackupDirectory: Bool { backupDirectory != nil }

    private init() {
        defaults.register(defaults: [
            Key.autoSaveOutline: false,
            Key.promptToSaveOnClose: true,
            Key.backupEnabled: true,
            Key.chromeColorHex: "",
            Key.annotationAuthor: Self.systemUserName,
            Key.pageBackgroundHex: "",
            Key.diagnosticsEnabled: Diagnostics.defaultEnabled,
        ])
        // ⚠️ 在 init 里给 @Published 赋值不会触发属性观察器（也就不会回写 defaults），正合需要
        autoSaveOutline = defaults.bool(forKey: Key.autoSaveOutline)
        promptToSaveOnClose = defaults.bool(forKey: Key.promptToSaveOnClose)
        backupEnabled = defaults.bool(forKey: Key.backupEnabled)
        backupDirectoryDisplayPath = defaults.string(forKey: Key.backupDisplayPath)
        chromeColorHex = defaults.string(forKey: Key.chromeColorHex) ?? ""
        annotationAuthor = defaults.string(forKey: Key.annotationAuthor) ?? Self.systemUserName
        pageBackgroundHex = defaults.string(forKey: Key.pageBackgroundHex) ?? ""
        // 直接读 `Diagnostics` 当前生效的值（它自己已经解析过"存过的值 / 构建默认值"），
        // 这样设置界面上的开关和真实行为**不可能不一致**
        diagnosticsEnabled = Diagnostics.isEnabled
        migrateIfNeeded()
        resolveBookmark()
        // 排查用（v1.3.61）：用户改了外框色/作者名却发现"没生效"时，
        // 这一行能立刻区分"没读到偏好" / "读到了但界面没用"。
        Diagnostics.shared.record("偏好就绪：外框色=「\(chromeColorHex.isEmpty ? "（默认灰）" : chromeColorHex)」"
                                  + " 页面底色=「\(pageBackgroundHex.isEmpty ? "（跟随系统）" : pageBackgroundHex)」"
                                  + " 批注作者=「\(annotationAuthor)」"
                                  + " 诊断=\(diagnosticsEnabled ? "开" : "关")"
                                  + " bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
    }

    /// 一次性把老版本写下的默认值纠正过来。
    ///
    /// v1.3.25 / v1.3.26 那两版把「目录改动后自动保存」默认开着，用户跑过之后
    /// `UserDefaults` 里已经落了 `true` —— 光改 `register` 的默认值**改不动它**。
    /// 所以这里按版本号强制改回一次。
    private func migrateIfNeeded() {
        let stored = defaults.integer(forKey: Key.schemaVersion)
        guard stored < Self.currentSchemaVersion else { return }
        defaults.set(false, forKey: Key.autoSaveOutline)
        defaults.set(true, forKey: Key.promptToSaveOnClose)
        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)
        autoSaveOutline = false
        promptToSaveOnClose = true
    }

    // MARK: - 备份目录

    /// 弹面板选一个备份目录。
    func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择备份文件的存放目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store(url)
    }

    /// 改回默认落点（原文件旁边）。
    func clearBackupDirectory() {
        defaults.removeObject(forKey: Key.backupBookmark)
        defaults.removeObject(forKey: Key.backupDisplayPath)
        backupDirectory = nil
        backupDirectoryDisplayPath = nil
        backupDirectoryNotice = nil
    }

    /// 在自定义备份目录的安全作用域里跑一段代码；没设自定义目录时返回 nil。
    ///
    /// 沙箱下访问用户选过的目录必须**成对**地 start / stop，否则要么访问不到、
    /// 要么把授权一直挂着。
    func withBackupDirectoryAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let directory = backupDirectory else { return nil }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        return try body(directory)
    }

    private func store(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            defaults.set(data, forKey: Key.backupBookmark)
            defaults.set(url.path, forKey: Key.backupDisplayPath)
            backupDirectory = url
            backupDirectoryDisplayPath = url.path
            backupDirectoryNotice = nil
        } catch {
            backupDirectoryNotice = "这个目录没法记住（\(error.localizedDescription)），换一个试试。"
        }
    }

    /// 启动时把 bookmark 解析回可用的 `URL`。
    private func resolveBookmark() {
        guard let data = defaults.data(forKey: Key.backupBookmark) else {
            backupDirectory = nil
            return
        }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            backupDirectory = url
            backupDirectoryDisplayPath = url.path
            if stale {
                // 目录被移动/改名过，旧 bookmark 只能解析出失效信息 —— 重存一份
                store(url)
            }
        } catch {
            // 目录被删、换了机器等：退回默认落点，并如实说明（不要静默）
            backupDirectory = nil
            backupDirectoryNotice = "原来选的备份目录已不可用，已改回默认位置。"
        }
    }
}
