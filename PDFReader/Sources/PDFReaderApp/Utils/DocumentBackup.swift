import CoreGraphics
import Foundation
import PDFKit

/// 把批注写回 PDF 文件是**覆盖原文件**的不可逆操作，因此写入前统一把原文件复制一份留作还原。
///
/// ## 备份放在哪（v1.3.12 改过）
///
/// **优先放在原文件旁边**（`测试文件-备份-20261009-174236.pdf`）——
/// 用户一眼就能看见，也符合"文件在哪、备份就在哪"的直觉。
///
/// 早先只放应用数据目录（沙箱里是
/// `~/Library/Containers/<bundle id>/Data/Library/Application Support/PDFReader/Backups`），
/// 那个路径**又深、又带容器前缀**，用户按弹窗给的路径去 Finder 里根本找不到
/// （实测用户反馈"保存的备份并不存在"，其实文件就在那儿）。
///
/// 但沙箱下**不一定有权限**往原文件所在目录写新文件（
/// `com.apple.security.files.user-selected.read-write` 给的是"用户选中的那个文件"，
/// 不一定是整个目录），所以同目录写失败时**自动回退**到应用数据目录，
/// 并把实际落点告诉调用方（`Result.location`），由界面如实说明。
enum DocumentBackup {

    /// 最多保留的历史备份数量，超出后从最旧的开始删除
    private static let maxBackups = 20

    /// 文件名里用来标记"这是备份"的中缀
    private static let marker = "-备份-"

    /// 回退目录：沙箱里是 `…/Containers/<bundle id>/Data/Library/Application Support/PDFReader/Backups`
    static var fallbackDirectory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("PDFReader/Backups", isDirectory: true)
    }

    /// 备份实际落在哪里
    enum Location {
        /// 就在原文件旁边（默认首选）
        case besideOriginal
        /// 用户自己指定的备份目录（`AppPreferences.backupDirectory`）
        case custom
        /// 退回到了应用数据目录（原目录不可写时）
        case applicationSupport

        var description: String {
            switch self {
            case .besideOriginal: return "就在原文件旁边"
            case .custom: return "在你指定的备份目录里"
            case .applicationSupport: return "应用数据目录（原文件所在目录写不进去）"
            }
        }
    }

    struct Result {
        let url: URL
        let location: Location
    }

    /// 备份原文件，返回备份路径与实际落点。
    ///
    /// - Parameter customDirectory: 用户指定的备份目录（`nil` = 用默认落点）。
    ///   传了就往那儿写，**写不进去直接抛错**（由调用方决定是回退默认落点还是报错）——
    ///   这里不替用户改主意，否则"我明明选了目录，文件却跑到别处"很难排查。
    @discardableResult
    static func backup(_ fileURL: URL, customDirectory: URL? = nil) throws -> Result {
        let fm = FileManager.default
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let stamp = timestampFormatter.string(from: Date())
        let baseName = ext.isEmpty ? "\(stem)\(marker)\(stamp)" : "\(stem)\(marker)\(stamp).\(ext)"

        // 0) 用户指定了目录 → 只往那儿放
        if let customDirectory {
            try fm.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            let destination = uniqueDestination(customDirectory.appendingPathComponent(baseName))
            try fm.copyItem(at: fileURL, to: destination)
            pruneOldBackups(in: customDirectory, stem: stem)
            return Result(url: destination, location: .custom)
        }

        // 1) 首选：原文件旁边
        let beside = uniqueDestination(
            fileURL.deletingLastPathComponent().appendingPathComponent(baseName)
        )
        if copy(fileURL, to: beside) {
            pruneOldBackups(in: fileURL.deletingLastPathComponent(), stem: stem)
            return Result(url: beside, location: .besideOriginal)
        }

        // 2) 回退：应用数据目录（沙箱里一定可写）
        guard let base = fallbackDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = uniqueDestination(base.appendingPathComponent(baseName))
        try fm.copyItem(at: fileURL, to: destination)
        pruneOldBackups(in: base, stem: stem)
        return Result(url: destination, location: .applicationSupport)
    }

    /// 重名就往后加序号（时间戳只到秒，同一秒连存两次不该互相覆盖）。
    private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let base = url.deletingLastPathComponent()
        for index in 2...999 {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = base.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// 复制一份；目录不可写（沙箱没授权那个目录）时返回 false，交给调用方回退。
    private static func copy(_ source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// 清理超出上限的旧备份，避免无上限堆积。
    ///
    /// ⚠️ 只认**我们自己生成的备份名**（`<stem>-备份-<时间戳>`，以及 v1.3.12 之前的
    /// `<stem>-<时间戳>`）—— 目录现在可能是用户自己的文件夹，绝不能误删别人的文件。
    private static func pruneOldBackups(in base: URL, stem: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let mine = entries
            .filter { isBackupName($0.lastPathComponent, stem: stem) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }

        guard mine.count > maxBackups else { return }
        for url in mine.dropFirst(maxBackups) {
            try? fm.removeItem(at: url)
        }
    }

    /// 这个文件名像不像"我们为 `stem` 生成的备份"
    private static func isBackupName(_ name: String, stem: String) -> Bool {
        // 新格式：<stem>-备份-<yyyyMMdd-HHmmss>[.ext]
        if name.hasPrefix("\(stem)\(marker)") { return true }
        // 旧格式：<stem>-<yyyyMMdd-HHmmss>[.ext]
        let prefix = "\(stem)-"
        guard name.hasPrefix(prefix) else { return false }
        let stamp = name.dropFirst(prefix.count).prefix(while: { $0 != "." })
        guard stamp.count == 15, stamp.dropFirst(8).first == "-" else { return false }
        return stamp.allSatisfy { $0.isNumber || $0 == "-" }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

// MARK: - 把目录（outline）写进 PDF 文件

/// ## 为什么需要它：**PDFKit 完全写不了目录**
///
/// 实测（`/tmp/tocprobe`，每一条都跑过）：
///
/// | 尝试 | 结果 |
/// |------|------|
/// | 本没有目录的文档，自建一棵树设进 `document.outlineRoot` | 内存里正常（能读回 2 项），`write` 返回 true，但**文件里没有 `/Outlines`** |
/// | 换成"先 assign 空 root 再 insertChild" | 一样；子项的 `document` 始终是 nil（PDFKit 没"收养"这棵树） |
/// | `dataRepresentation()` 里有没有 | 也没有 |
/// | 用 `PDFActionGoTo` 代替 `PDFDestination` | 一样写不进去 |
/// | **改一个已存在的目录**（手工造的带目录 PDF，PDFKit 能正常读出两层结构） | 改名 / 加子项 / 删项在内存里都对，写盘后重开**还是原来的标题** —— 改动被丢弃 |
///
/// 读是好的，只有写不行。所以这里自己做。
///
/// ## 做法：增量更新（incremental update）
///
/// **原始字节一个都不动**，只在文件末尾追加：
///
/// 1. 目录树对象（`/Type /Outlines` + 各项 `/Title /Parent /Dest /First /Last /Next /Prev /Count`）
/// 2. 一份**新的 catalog**（复制原来的字典，把 `/Outlines` 指向我们这棵树）
/// 3. 一段**新的 xref 段**（只列新对象）+ trailer（`/Root` 指向新 catalog、`/Prev` 指回原 xref）
///
/// 这是 PDF 规范认可的标准做法，比"整份重写"安全得多 —— 原来的每一个对象都还在原处。
///
/// ## 只处理 PDFKit 刚写出的文件
///
/// 调用时机固定在 `document.write(to:)` **之后**，所以要解析的对象永远是 PDFKit 自己写的文件。
/// 实测这种文件结构非常规矩（见 `/tmp/tocprobe` 的结构探针）：
///
/// - **经典明文 xref 表**（不是压缩的 xref 流）
/// - **没有对象流**（`/ObjStm`），catalog 与页对象都是明文（连塞了大图的文件也是）
/// - catalog 就是 `<< /Type /Catalog /Pages 2 0 R >>` 这么简单
///
/// 任何一条不满足就**直接放弃**（抛错），绝不冒险写。`/Kids` 的顺序即页序也是规范要求。
///
/// ## 写完必须自检
///
/// 注入后先不落盘，用 `PDFDocument(data:)` 重新打开一次：**页数对得上、目录树读得回来、
/// 抽样页面的文字与注入前一致**。任何一条不过就丢掉结果、保留原文件。
enum PDFOutlineWriter {

    /// 一条要写进文件的目录项
    struct Item {
        var title: String
        /// 目标页（从 0 开始）
        var pageIndex: Int
        /// 页面坐标（左下原点）。nil → 用 `/Fit`（整页）
        var point: CGPoint?
        var children: [Item]

        init(title: String, pageIndex: Int, point: CGPoint? = nil, children: [Item] = []) {
            self.title = title
            self.pageIndex = pageIndex
            self.point = point
            self.children = children
        }
    }

    enum Failure: LocalizedError {
        case emptyOutline
        case noStartxref
        case notClassicXref
        case brokenXref(String)
        case noTrailer
        case cannotReadCatalog(String)
        case cannotReadPages(String)
        case pageCountMismatch(expected: Int, found: Int)
        case pageNumberOutOfRange(Int)
        case outlineKeyNotIndirect
        case selfCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyOutline: return "目录是空的，没有需要写入的内容。"
            case .noStartxref: return "这个 PDF 里找不到 startxref，结构不符合预期。"
            case .notClassicXref: return "这个 PDF 用的是压缩的交叉引用流，本版本不支持写入目录。"
            case .brokenXref(let detail): return "解析交叉引用表失败：\(detail)"
            case .noTrailer: return "找不到 PDF 的 trailer。"
            case .cannotReadCatalog(let detail): return "读不出 catalog：\(detail)"
            case .cannotReadPages(let detail): return "读不出页面树：\(detail)"
            case .pageCountMismatch(let expected, let found):
                return "页数对不上（期望 \(expected)，文件里 \(found)），已放弃写入以免损坏文件。"
            case .pageNumberOutOfRange(let index):
                // ⚠️ **这里绝对不能做算术。** `index` 可能是 `NSNotFound`
                //（`document.index(for:)` 对"不在这份文档里的页"就返回它），
                // 而 `NSNotFound + 1` 会**算术溢出**直接 SIGTRAP ——
                // 也就是说"报错的时候把进程带走"。v1.3.42 实测就是这么崩的：
                // 删掉一页 → 保存 → 目录里有条目指向那一页 → 崩在错误消息里。
                return "目录里有条目的目标页不存在（页号 \(index)），这一条没法写进文件。"
            case .outlineKeyNotIndirect: return "原文件的 /Outlines 不是间接引用，无法安全替换。"
            case .selfCheckFailed(let detail): return "写入后自检没通过（\(detail)），已放弃、原文件未改动。"
            }
        }
    }

    // MARK: - 入口

    /// 把 `items` 作为目录写进 `url`。
    ///
    /// - Important: **必须在 `document.write(to: url)` 之后再调用** ——
    ///   依赖"文件是 PDFKit 刚写出来的"这个前提（见类型注释）。
    /// - Parameters:
    ///   - items: 目录树。**空数组 = 把文件里的目录删掉**（目录被全部删光时要让它生效）
    ///   - expectedPageCount: 期望的页数，对不上就放弃（防止在错的文件上动手）
    /// - Returns: 追加的字节数（0 表示本来就没有目录、不用动）
    /// 写盘结果。`skippedEntries` 是"因为目标页已经不在文档里而没写进去"的条数 ——
    /// 有值就说明目录和文件对不上了，值得如实告诉用户一句（见调用方）。
    struct InjectOutcome {
        let addedBytes: Int
        /// 有几条目录的跳转目标原本指向已被删除的页、被改指到最接近的页
        let clampedEntries: Int
    }

    /// 把"目标页已经不在文档里"的条目**改指到最接近的有效页**。
    ///
    /// ## 为什么需要这一步
    ///
    /// 「页面管理」删掉一页之后，目录里很可能还有条目指着它 —— 而目录条目存的是
    /// **页对象引用**。写盘时那个页对象已经不在文档里，`document.index(for:)` 返回
    /// `NSNotFound`，旧代码就在 `build` 里 `throw`，结果**整套目录都写不进去**
    /// （用户看到"批注已保存，但目录没能写进文件"）。
    ///
    /// ## 为什么是"钳制"而不是"跳过这条"
    ///
    /// 一开始写成"跳过"，实测的后果是：顶层那条被跳过之后，**它的子项跟着一起消失**
    /// （子树连同丢），一份 3 条目的目录直接变成"无目录"。**静默丢目录比指错更糟** ——
    /// 用户在别处打开这个文件会发现目录没了，而且不知道为什么。
    ///
    /// 所以改成钳到 `0..<pageCount`：结构、标题全留着，只是那一条的跳转目标变成
    /// 最接近的有效页。用户在目录面板里可以再改（面板显示的就是钳制后的页号，
    /// 两边一致）。
    ///
    /// ⚠️ 内存里的目录**不动** —— 这样 ⌘Z 把页找回来之后，目标还是原来那一页。
    /// 只有"写进文件的那一份"是钳制过的。
    ///
    /// - Returns: (可以写进文件的树, 被钳制过的条数)
    static func writeableItems(_ items: [Item], pageCount: Int) -> (items: [Item], clamped: Int) {
        var result: [Item] = []
        var clamped = 0
        for node in items {
            // ⚠️ 落在范围外的**一律指到第 1 页**（不是"钳到最后一页"）。
            //    因为悬空条目的 `pageIndex` 是 `NSNotFound`（一个巨大的数），
            //    用 min/max 钳出来的会是**最后一页** —— 那就 AND 目录面板上显示的对不上了
            //    （面板里悬空条目显示的是第 1 页，见 `reloadTOC`）。两边一致更重要。
            let isValid = node.pageIndex >= 0 && node.pageIndex < pageCount
            let index = isValid ? node.pageIndex : 0
            if index != node.pageIndex { clamped += 1 }
            let children = writeableItems(node.children, pageCount: pageCount)
            clamped += children.clamped
            result.append(Item(title: node.title,
                               pageIndex: index,
                               point: node.point,
                               children: children.items))
        }
        return (result, clamped)
    }

    @discardableResult
    static func inject(_ rawItems: [Item],
                       expectedPageCount: Int,
                       into url: URL) throws -> InjectOutcome {
        let original = try Data(contentsOf: url)
        let layout = try parseLayout(original)

        let catalogText = try readObjectBody(original, at: layout.catalogOffset, layout: layout)
        guard catalogText.contains("/Type /Catalog") || catalogText.contains("/Type/Catalog") else {
            throw Failure.cannotReadCatalog("对象 \(layout.rootObject) 不是 catalog")
        }

        // ⚠️ 先把"目标页已经不在文档里"的条目钳到有效范围（页面管理删页之后很常见）。
        //    不处理的话 `build` 会直接抛错，**整套目录都写不进去**。
        let resolved = writeableItems(rawItems, pageCount: expectedPageCount)
        let items = resolved.items
        let clampedEntries = resolved.clamped
        if clampedEntries > 0 {
            Diagnostics.shared.record("目录写入：\(clampedEntries) 条的目标页已不在文档里，已改指到最接近的页")
        }

        // 目录已经空了、文件里本来也没有 → 什么都不用做
        let fileHasOutline = catalogText.contains("/Outlines")
        if items.isEmpty && !fileHasOutline {
            return InjectOutcome(addedBytes: 0, clampedEntries: clampedEntries)
        }

        let pagesObject = try firstReference(after: "/Pages", in: catalogText)
            ?? { throw Failure.cannotReadCatalog("catalog 里没有 /Pages") }()
        let pageObjects = try pageObjectNumbers(original, layout: layout, pagesObject: pagesObject)

        guard pageObjects.count == expectedPageCount else {
            throw Failure.pageCountMismatch(expected: expectedPageCount, found: pageObjects.count)
        }

        // ── 造新对象 ──
        var nextObject = layout.size          // /Size = 最大对象号 + 1，所以它是第一个空闲号
        var pending: [(number: Int, body: String)] = []

        func allocate() -> Int { defer { nextObject += 1 }; return nextObject }

        func build(_ nodes: [Item], parent: Int) throws -> [Int] {
            // 先把这一层的号全分好，才能互相写 /Next /Prev
            let numbers = nodes.map { _ in allocate() }
            for (index, node) in nodes.enumerated() {
                guard node.pageIndex >= 0, node.pageIndex < pageObjects.count else {
                    throw Failure.pageNumberOutOfRange(node.pageIndex)
                }
                let target = pageObjects[node.pageIndex]
                var pieces: [String] = [
                    "/Title \(pdfString(node.title))",
                    "/Parent \(parent) 0 R",
                ]
                if let point = node.point {
                    pieces.append("/Dest [\(target) 0 R /XYZ \(number(point.x)) \(number(point.y)) 0]")
                } else {
                    pieces.append("/Dest [\(target) 0 R /Fit]")
                }
                if index > 0 { pieces.append("/Prev \(numbers[index - 1]) 0 R") }
                if index < numbers.count - 1 { pieces.append("/Next \(numbers[index + 1]) 0 R") }
                if !node.children.isEmpty {
                    let childNumbers = try build(node.children, parent: numbers[index])
                    pieces.append("/First \(childNumbers[0]) 0 R")
                    pieces.append("/Last \(childNumbers[childNumbers.count - 1]) 0 R")
                    // 正数 = 展开显示（PDF 里 /Count 的符号就是"默认展开与否"）
                    pieces.append("/Count \(descendantCount(node))")
                }
                pending.append((numbers[index], "<< " + pieces.joined(separator: " ") + " >>"))
            }
            return numbers
        }

        // 新 catalog：复制原来的字典，把 /Outlines 指过去（空目录则是**删掉**这个键）
        var catalogBody: String
        if items.isEmpty {
            catalogBody = try removingOutlines(from: catalogText)
        } else {
            let rootNumber = allocate()
            let topLevel = try build(items, parent: rootNumber)
            pending.append((rootNumber, "<< /Type /Outlines /First \(topLevel[0]) 0 R"
                + " /Last \(topLevel[topLevel.count - 1]) 0 R"
                + " /Count \(items.reduce(0) { $0 + 1 + descendantCount($1) }) >>"))
            catalogBody = try replacingOutlines(in: catalogText, with: rootNumber)
        }
        let catalogNumber = allocate()
        pending.append((catalogNumber, catalogBody))

        // ── 拼字节 ──
        var output = original
        var newOffsets: [Int: Int] = [:]
        let firstNew = layout.size
        for entry in pending {
            newOffsets[entry.number] = output.count
            output.append(Data("\(entry.number) 0 obj\n\(entry.body)\nendobj\n".utf8))
        }
        let xrefOffset = output.count

        var tail = "xref\n0 1\n0000000000 65535 f \n"
        // 新号是连续的（allocate 每次 +1），所以可以合成一个子段
        tail += "\(firstNew) \(pending.count)\n"
        for number2 in firstNew..<(firstNew + pending.count) {
            guard let offset = newOffsets[number2] else {
                throw Failure.brokenXref("对象 \(number2) 没拿到偏移")
            }
            tail += String(format: "%010d 00000 n \n", offset)
        }
        tail += "trailer\n<< /Size \(nextObject) /Root \(catalogNumber) 0 R /Prev \(layout.xrefOffset) >>\n"
        tail += "startxref\n\(xrefOffset)\n%%EOF\n"
        output.append(Data(tail.utf8))

        // ── 自检（不过就丢掉结果）──
        try selfCheck(newData: output,
                      originalData: original,
                      expectedPageCount: expectedPageCount,
                      items: items)

        try output.write(to: url)
        return InjectOutcome(addedBytes: output.count - original.count,
                             clampedEntries: clampedEntries)
    }

    // MARK: - 自检

    private static func selfCheck(newData: Data,
                                  originalData: Data,
                                  expectedPageCount: Int,
                                  items: [Item]) throws {
        guard let after = PDFDocument(data: newData) else {
            throw Failure.selfCheckFailed("注入后 PDFKit 打不开")
        }
        guard after.pageCount == expectedPageCount else {
            throw Failure.selfCheckFailed("页数从 \(expectedPageCount) 变成了 \(after.pageCount)")
        }
        // 抽样页面的文字必须与注入前一致（能发现页面树/内容被写坏）
        let before = PDFDocument(data: originalData)
        let samples = Set([0, expectedPageCount / 2, expectedPageCount - 1]).filter { $0 >= 0 && $0 < expectedPageCount }
        for index in samples {
            let old = before?.page(at: index)?.string ?? ""
            let new = after.page(at: index)?.string ?? ""
            guard old == new else {
                throw Failure.selfCheckFailed("第 \(index + 1) 页的文字变了")
            }
        }
        // 目录树要能原样读回来
        let readBack = PDFOutlineWriter.items(from: after.outlineRoot, in: after)
        guard sameTree(readBack, items) else {
            throw Failure.selfCheckFailed("读回来的目录与写进去的不一致")
        }
    }

    /// 把 PDFOutline 树读成 `Item`（自检、以及"把内存里的目录拿去写盘"都用它）。
    ///
    /// ⚠️ **必须显式传所属文档**，不要靠 `child.document`：
    /// PDFKit **不会"收养"程序化插入的目录项** —— 实测我们 `insertChild` 进去的节点，
    /// 它的 `document` 恒为 nil（见类型注释里的实测表）。靠它会算不出页码（一律 -1）。
    static func items(from outline: PDFOutline?, in document: PDFDocument?) -> [Item] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let target = child.destination?.page
            let pageIndex: Int
            if let target, let document {
                pageIndex = document.index(for: target)
            } else {
                pageIndex = -1
            }
            return Item(title: child.label ?? "",
                        pageIndex: pageIndex,
                        point: child.destination?.point,
                        children: items(from: child, in: document))
        }
    }

    private static func sameTree(_ lhs: [Item], _ rhs: [Item]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.title == b.title, a.pageIndex == b.pageIndex,
                  a.children.count == b.children.count,
                  sameTree(a.children, b.children) else { return false }
        }
        return true
    }

    private static func descendantCount(_ item: Item) -> Int {
        item.children.reduce(0) { $0 + 1 + descendantCount($1) }
    }

    // MARK: - PDF 语法小工具

    private static func number(_ value: CGFloat) -> String {
        // PDF 不接受科学计数法，也不喜欢多余小数位
        String(format: "%.3f", Double(value))
    }

    /// 目录标题 → PDF 字符串。
    ///
    /// 中文不能直接塞进 `(...)`（那是 PDFDocEncoding），要用 **UTF-16BE + BOM 的十六进制串**，
    /// 这是各家阅读器都认的写法。
    private static func pdfString(_ text: String) -> String {
        let needsHex = text.unicodeScalars.contains { $0.value < 0x20 || $0.value > 0x7E }
            || text.contains("(") || text.contains(")") || text.contains("\\")
        guard needsHex else { return "(\(text))" }
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in text.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }

    /// 把 catalog 字典里的 `/Outlines` 整个键去掉（目录被删光时要让它生效）
    private static func removingOutlines(from catalog: String) throws -> String {
        guard let range = catalog.range(of: "/Outlines") else { return catalog }
        var index = range.upperBound
        func skipSpaces() {
            while index < catalog.endIndex,
                  catalog[index] == " " || catalog[index] == "\n"
                    || catalog[index] == "\r" || catalog[index] == "\t" {
                index = catalog.index(after: index)
            }
        }
        skipSpaces()
        var sawDigits = false
        while index < catalog.endIndex, catalog[index].isNumber {
            sawDigits = true
            index = catalog.index(after: index)
        }
        guard sawDigits else { throw Failure.outlineKeyNotIndirect }
        var sawR = false
        while index < catalog.endIndex {
            let char = catalog[index]
            if char == " " || char == "\n" || char == "\r" || char == "\t" || char.isNumber {
                index = catalog.index(after: index)
                continue
            }
            if char == "R" { index = catalog.index(after: index); sawR = true }
            break
        }
        guard sawR else { throw Failure.outlineKeyNotIndirect }
        return catalog.replacingCharacters(in: range.lowerBound..<index, with: "")
    }

    /// 把 catalog 字典里的 `/Outlines` 指向 `rootNumber`
    private static func replacingOutlines(in catalog: String, with rootNumber: Int) throws -> String {
        if let range = catalog.range(of: "/Outlines") {
            // 规范要求 /Outlines 的值必须是间接引用（`N G R`），所以要把**整个引用**换掉，
            // 不能只换键名（只换键名会剩下一个孤立的旧引用，等于两个值）。
            var index = range.upperBound
            var digits = ""
            func skipSpaces() {
                while index < catalog.endIndex,
                      catalog[index] == " " || catalog[index] == "\n"
                        || catalog[index] == "\r" || catalog[index] == "\t" {
                    index = catalog.index(after: index)
                }
            }
            skipSpaces()
            while index < catalog.endIndex, catalog[index].isNumber {
                digits.append(catalog[index])
                index = catalog.index(after: index)
            }
            guard !digits.isEmpty else { throw Failure.outlineKeyNotIndirect }
            // 再吃掉 "<世代数字> R"
            var sawR = false
            while index < catalog.endIndex {
                let char = catalog[index]
                if char == " " || char == "\n" || char == "\r" || char == "\t" || char.isNumber {
                    index = catalog.index(after: index)
                    continue
                }
                if char == "R" { index = catalog.index(after: index); sawR = true }
                break
            }
            guard sawR else { throw Failure.outlineKeyNotIndirect }
            return catalog.replacingCharacters(in: range.lowerBound..<index,
                                               with: "/Outlines \(rootNumber) 0 R")
        }
        // 没有就插在字典结尾之前
        guard let close = catalog.range(of: ">>", options: .backwards) else {
            throw Failure.cannotReadCatalog("catalog 字典没有结尾")
        }
        return catalog.replacingCharacters(in: close.lowerBound..<close.lowerBound,
                                           with: "/Outlines \(rootNumber) 0 R ")
    }

    /// 从 `text` 里 `/key` 后面取第一个间接引用 `N 0 R`
    private static func firstReference(after key: String, in text: String) -> Int? {
        guard let keyRange = text.range(of: key) else { return nil }
        var index = keyRange.upperBound
        var digits = ""
        while index < text.endIndex {
            let char = text[index]
            if char.isNumber { digits.append(char) }
            else if !digits.isEmpty { break }
            else if char == " " || char == "\n" || char == "\r" || char == "\t" { }
            else if char == "/" || char == "[" { return nil }   // 是别的值类型
            index = text.index(after: index)
        }
        return Int(digits)
    }

    // MARK: - 解析（只认 PDFKit 写出的那种规矩结构）

    private struct Layout {
        var xrefOffset: Int
        var offsets: [Int: Int]
        var size: Int
        var rootObject: Int
        var catalogOffset: Int
    }

    private static func parseLayout(_ data: Data) throws -> Layout {
        guard var xrefOffset = lastStartxrefOffset(data) else { throw Failure.noStartxref }
        let bytes = Array(data)

        var offsets: [Int: Int] = [:]
        var size = 0
        var rootObject = 0
        var sections = 0

        // ⚠️ 必须**沿 /Prev 链把各段 xref 都读了**：增量更新之后文件里会有多段 xref，
        // 最新那段只列"这次新增的对象"，页面等老对象仍在更早的段里。
        // 不跟 /Prev 的话，第二次注入同一个文件就会报"xref 里没有对象 N"。
        // （最多跟 64 段，防止环形 /Prev 把自己转死。）
        while sections < 64 {
            sections += 1
            guard bytes.count > xrefOffset + 4,
                  String(decoding: bytes[xrefOffset..<min(bytes.count, xrefOffset + 4)], as: UTF8.self) == "xref" else {
                if sections == 1 { throw Failure.notClassicXref }
                break          // 更早的段不是经典表（比如压缩的 xref 流）—— 就到这儿
            }

            var cursor = xrefOffset + 4
            while true {
                skipWhitespace(bytes, &cursor)
                guard let first = readInteger(bytes, &cursor) else { break }
                skipWhitespace(bytes, &cursor)
                guard let count = readInteger(bytes, &cursor) else { break }
                skipWhitespace(bytes, &cursor)
                for i in 0..<count {
                    // 每条固定 20 字节：10 位偏移 + 空格 + 5 位世代 + 空格 + 类型 + 2 字节行尾
                    guard cursor + 20 <= bytes.count else { throw Failure.brokenXref("xref 条目越界") }
                    let entry = String(decoding: bytes[cursor..<(cursor + 20)], as: UTF8.self)
                    let type = entry[entry.index(entry.startIndex, offsetBy: 17)]
                    if type == "n", let offset = Int(entry.prefix(10)) {
                        // 新的段优先（先到的不覆盖）
                        if offsets[first + i] == nil { offsets[first + i] = offset }
                    }
                    cursor += 20
                }
            }

            // trailer 紧跟其后
            skipWhitespace(bytes, &cursor)
            let trailerWord = "trailer"
            guard cursor + trailerWord.count <= bytes.count,
                  String(decoding: bytes[cursor..<(cursor + trailerWord.count)], as: UTF8.self) == trailerWord,
                  let dictStart = indexOf(bytes, "<<", from: cursor),
                  let dictEnd = matchingDictEnd(bytes, from: dictStart) else {
                throw Failure.noTrailer
            }
            let trailerText = String(decoding: bytes[dictStart..<min(bytes.count, dictEnd)], as: UTF8.self)
            if sections == 1 {
                // 最新的 trailer 决定"当前"的 /Root 与 /Size
                guard let root = firstReference(after: "/Root", in: trailerText),
                      let declaredSize = firstInt(after: "/Size", in: trailerText) else {
                    throw Failure.noTrailer
                }
                rootObject = root
                size = declaredSize
            }
            guard let previous = firstInt(after: "/Prev", in: trailerText), previous > 0 else { break }
            xrefOffset = previous
        }

        guard rootObject > 0, size > 0, let catalogOffset = offsets[rootObject] else {
            throw Failure.cannotReadCatalog("xref 里没有 catalog 对象 \(rootObject)")
        }
        return Layout(xrefOffset: lastStartxrefOffset(data) ?? xrefOffset,
                      offsets: offsets,
                      size: size,
                      rootObject: rootObject,
                      catalogOffset: catalogOffset)
    }

    /// 取最后一个 `startxref` 后面的数字
    private static func lastStartxrefOffset(_ data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "startxref", options: .backwards) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// 读对象在 `offset` 处的字典文本（`<< ... >>`）
    private static func readObjectBody(_ data: Data, at offset: Int, layout: Layout) throws -> String {
        let bytes = Array(data)
        guard offset >= 0, offset < bytes.count else {
            throw Failure.cannotReadCatalog("对象偏移越界")
        }
        guard let dictStart = indexOf(bytes, "<<", from: offset),
              let dictEnd = matchingDictEnd(bytes, from: dictStart) else {
            throw Failure.cannotReadCatalog("偏移 \(offset) 处不是字典对象")
        }
        return String(decoding: bytes[dictStart..<dictEnd], as: UTF8.self)
    }

    /// 从页面树里按顺序取所有页对象号
    private static func pageObjectNumbers(_ data: Data, layout: Layout, pagesObject: Int) throws -> [Int] {
        var result: [Int] = []
        var visited = Set<Int>()

        func walk(_ objectNumber: Int) throws {
            guard !visited.contains(objectNumber) else { return }
            visited.insert(objectNumber)
            guard let offset = layout.offsets[objectNumber] else {
                throw Failure.cannotReadPages("xref 里没有对象 \(objectNumber)")
            }
            let body = try readObjectBody(data, at: offset, layout: layout)
            let kids = references(inArrayAfter: "/Kids", in: body)
            if kids.isEmpty {
                result.append(objectNumber)          // 没有 /Kids 就是页对象
            } else {
                for kid in kids { try walk(kid) }
            }
        }
        try walk(pagesObject)
        return result
    }

    /// 取 `/key [ ... ]` 数组里的全部 `N 0 R` 的**对象号**。
    ///
    /// ⚠️ 必须按 `对象号 世代号 R` **三个一组**解析：早先按"遇到数字就收"来写，
    /// 结果把世代号 `0` 也当成了对象号（`[1 0 R 9 0 R]` 被读成 `[1, 0, 9, 0]`），
    /// 于是跑去读"对象 0" —— 探针里报的就是 `xref 里没有对象 0`。
    private static func references(inArrayAfter key: String, in text: String) -> [Int] {
        guard let keyRange = text.range(of: key),
              let open = text.range(of: "[", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: "]", range: open.upperBound..<text.endIndex) else { return [] }
        let tokens = text[open.upperBound..<close.lowerBound]
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map(String.init)
        var result: [Int] = []
        var index = 0
        while index + 2 < tokens.count {
            if let objectNumber = Int(tokens[index]),
               Int(tokens[index + 1]) != nil,
               tokens[index + 2] == "R" {
                result.append(objectNumber)
                index += 3
            } else {
                index += 1
            }
        }
        return result
    }

    private static func firstInt(after key: String, in text: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits)
    }

    // MARK: - 字节级小工具

    private static func indexOf(_ bytes: [UInt8], _ pattern: String, from: Int) -> Int? {
        let needle = Array(pattern.utf8)
        guard !needle.isEmpty, from >= 0, bytes.count >= needle.count else { return nil }
        var i = from
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0] {
                var match = true
                for k in 1..<needle.count where bytes[i + k] != needle[k] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// 从 `<<` 开始找配对的 `>>` 之后一位（会跳过字符串与嵌套字典）
    private static func matchingDictEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start + 1 < bytes.count, bytes[start] == 0x3C, bytes[start + 1] == 0x3C else { return nil }
        var depth = 0
        var i = start
        var inString = false
        while i < bytes.count {
            let byte = bytes[i]
            if inString {
                if byte == 0x5C { i += 2; continue }        // 反斜杠转义
                if byte == 0x29 { inString = false }        // )
            } else if byte == 0x28 {
                inString = true                             // (
            } else if byte == 0x3C, i + 1 < bytes.count, bytes[i + 1] == 0x3C {
                depth += 1; i += 2; continue
            } else if byte == 0x3E, i + 1 < bytes.count, bytes[i + 1] == 0x3E {
                depth -= 1
                if depth == 0 { return i + 2 }
                i += 2; continue
            }
            i += 1
        }
        return nil
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ cursor: inout Int) {
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { cursor += 1 } else { break }
        }
    }

    private static func readInteger(_ bytes: [UInt8], _ cursor: inout Int) -> Int? {
        var digits = ""
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte >= 0x30, byte <= 0x39 { digits.append(Character(UnicodeScalar(byte))); cursor += 1 } else { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}
