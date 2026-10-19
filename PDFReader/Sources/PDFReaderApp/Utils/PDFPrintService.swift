import AppKit
import PDFKit

/// PDF 打印。负责把 `PDFPrintOptions` 变成一次真实的打印任务。
///
/// 关键设计：**所有"非整份原样打印"的需求，都先合成一份临时 PDFDocument 再交给 PDFKit**。
/// 这样页面范围（可能不连续）、剔除批注、每张纸多页这三件事可以用同一条路径处理，
/// 不用去跟 `NSPrintOperation.pageRange`（只支持连续范围）和"临时修改原文档"较劲。
@MainActor
enum PDFPrintService {

    enum PrintError: LocalizedError {
        case noPagesSelected
        case cannotDuplicatePage
        case cannotBuildDocument

        var errorDescription: String? {
            switch self {
            case .noPagesSelected:
                return "没有可打印的页面，请检查页面范围。"
            case .cannotDuplicatePage:
                return "无法复制文档页面，已取消打印。"
            case .cannotBuildDocument:
                return "无法生成拼版文档（每张纸多页模式）。"
            }
        }
    }

    // MARK: - 页面范围解析

    /// 解析 "1-3, 5, 8-10" 这类输入，返回从 0 开始、已排序去重的页索引。
    ///
    /// 分隔符同时接受中英文逗号/分号/顿号与空白；连字符接受 `-`、`~`、`—`。
    /// 超出文档范围或格式非法的片段直接忽略，不整段失败。
    static func parsePageRange(_ text: String, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }

        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "~", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        var result = Set<Int>()
        for token in normalized.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let part = token.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }

            if let separator = part.firstIndex(of: "-") {
                let lower = part[part.startIndex..<separator].trimmingCharacters(in: .whitespaces)
                let upper = part[part.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard let from = Int(lower), let to = Int(upper) else { continue }
                for value in min(from, to)...max(from, to) where (1...pageCount).contains(value) {
                    result.insert(value - 1)
                }
            } else if let value = Int(part), (1...pageCount).contains(value) {
                result.insert(value - 1)
            }
        }
        return result.sorted()
    }

    /// 按设置算出最终要打印哪些页（0-based）。自定义范围解析不出任何页时回退到全部。
    static func resolvePageIndices(options: PDFPrintOptions,
                                   currentPageIndex: Int,
                                   pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }

        switch options.rangeMode {
        case .all:
            return Array(0..<pageCount)
        case .currentPage:
            return [min(max(currentPageIndex, 0), pageCount - 1)]
        case .custom:
            let parsed = parsePageRange(options.customRange, pageCount: pageCount)
            return parsed.isEmpty ? Array(0..<pageCount) : parsed
        }
    }

    // MARK: - 打印

    /// 执行打印。返回 false 表示用户在系统打印面板里取消了。
    ///
    /// 用 `run()` 而不是 `runModal(for:delegate:...)`：后者的结果是通过 delegate 回调异步给的，
    /// 为了拿到"是否真的打印了"还要自己搭一层桥；`run()` 直接返回 Bool，语义正好。
    // MARK: - 纸张

    /// 拼版实际使用的纸张尺寸（已考虑方向）。
    /// `systemDefault` 时取系统当前设置，不擅自规范化方向。
    static func resolvedPaperSize(for options: PDFPrintOptions) -> CGSize {
        guard let portrait = options.paperSize.portraitSize else {
            return NSPrintInfo.shared.paperSize
        }
        return options.orientation == .portrait
            ? portrait
            : CGSize(width: portrait.height, height: portrait.width)
    }

    /// 把纸张选择和方向写进 `NSPrintInfo`。`systemDefault` 时保持系统原样，不动它。
    private static func applyPaperSettings(_ options: PDFPrintOptions, to printInfo: NSPrintInfo) {
        guard let portrait = options.paperSize.portraitSize else { return }
        // paperSize 始终按纵向设、方向另设，避免设置成"已旋转的尺寸"再叠一次方向
        printInfo.paperSize = portrait
        printInfo.orientation = options.orientation == .portrait ? .portrait : .landscape
    }

    // MARK: - 合成待打印文档

    /// 按设置合成出"最终要打印的那份文档"。
    ///
    /// **预览和实际打印都调用这个方法** —— 保证两者看到的是同一份产物，
    /// 不会出现"预览是这样、打出来是那样"。
    static func makePrintableDocument(document: PDFDocument,
                                      options: PDFPrintOptions,
                                      currentPageIndex: Int) throws -> PDFDocument {
        let indices = resolvePageIndices(
            options: options,
            currentPageIndex: currentPageIndex,
            pageCount: document.pageCount
        )
        guard !indices.isEmpty else { throw PrintError.noPagesSelected }

        // 整份原样打印时不做任何复制，直接交给 PDFKit，保留文档级元数据与链接
        let isWholeDocument = indices.count == document.pageCount && indices.first == 0
        // ⚠️ 还有一条隐藏前提：文档里**不能有被设成"不显示"的批注**。
        // 为了让批注清晰显示，我们在内存里把可自绘的批注设成 `shouldDisplay = false`
        // （PDFKit 不画、由 AnnotationRenderer 自绘）。这种批注打印时**不会出现**，
        // 而"原样打印"这条路径直接交的是原文档，没法在不影响屏幕的前提下改它 ——
        // 所以只要存在这种批注，就必须走重建路径（在副本上恢复可见性）。
        let hasHiddenAnnotations = containsHiddenAnnotations(in: document)
        let needsRebuild = options.pagesPerSheet > 1
            || !options.includeAnnotations
            || !isWholeDocument
            || hasHiddenAnnotations

        let base: PDFDocument
        if needsRebuild {
            base = try duplicatePages(of: document,
                                      indices: indices,
                                      includeAnnotations: options.includeAnnotations)
        } else {
            base = document
        }

        guard options.pagesPerSheet > 1 else { return base }
        guard let imposed = imposePages(base,
                                        pagesPerSheet: options.pagesPerSheet,
                                        paperSize: resolvedPaperSize(for: options)) else {
            throw PrintError.cannotBuildDocument
        }
        return imposed
    }

    /// 文档里有没有"被设成不显示"的批注（我们为了自绘而关掉 PDFKit 显示的那些）。
    private static func containsHiddenAnnotations(in document: PDFDocument) -> Bool {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if page.annotations.contains(where: { !$0.shouldDisplay }) { return true }
        }
        return false
    }

    // MARK: - 打印

    @discardableResult
    static func print(document: PDFDocument,
                      options: PDFPrintOptions,
                      currentPageIndex: Int) throws -> Bool {

        let printable = try makePrintableDocument(
            document: document,
            options: options,
            currentPageIndex: currentPageIndex
        )

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        applyPaperSettings(options, to: printInfo)
        let scalingMode = resolveScalingMode(options: options, printInfo: printInfo)

        guard let operation = printable.printOperation(
            for: printInfo,
            scalingMode: scalingMode,
            autoRotate: options.autoRotate
        ) else {
            throw PrintError.cannotBuildDocument
        }

        // 已经由本面板决定的项从系统面板里去掉，避免两处设置打架。
        // 纸张/方向只在用户明确指定时才隐藏 —— 选「跟随系统」时仍留给系统面板，
        // 这样"打印机里装的是别的纸"这种情况用户还有办法处理。
        var panelOptions: NSPrintPanel.Options = [.showsPreview, .showsCopies]
        if options.paperSize == .systemDefault {
            panelOptions.insert(.showsPaperSize)
            panelOptions.insert(.showsOrientation)
        }
        operation.printPanel.options = panelOptions

        return operation.run()
    }

    private static func resolveScalingMode(options: PDFPrintOptions,
                                           printInfo: NSPrintInfo) -> PDFPrintScalingMode {
        switch options.scaleMode {
        case .fitPage:
            // 允许放大也允许缩小，让页面填满纸张的可打印区域
            return .pageScaleToFit
        case .actualSize:
            return .pageScaleNone
        case .custom:
            // PDFKit 没有"自定义百分比"的缩放模式，用 NSPrintInfo.scalingFactor 叠加上去
            let factor = min(max(options.customScalePercent / 100, 0.1), 4.0)
            printInfo.scalingFactor = factor
            return .pageScaleNone
        }
    }

    // MARK: - 临时文档构建

    /// 按给定页索引复制出一份新文档；`includeAnnotations` 为 false 时剔除批注。
    ///
    /// 必须先 `page.copy()` 再动批注 —— 否则剔除操作会改到**原文档**的页面。
    /// （非 private：便于用探针直接验证"副本改动不污染原文档"这条安全性。）
    static func duplicatePages(of source: PDFDocument,
                               indices: [Int],
                               includeAnnotations: Bool) throws -> PDFDocument {
        let output = PDFDocument()
        for (slot, index) in indices.enumerated() {
            guard let original = source.page(at: index),
                  let page = original.copy() as? PDFPage else {
                throw PrintError.cannotDuplicatePage
            }
            if !includeAnnotations {
                for annotation in page.annotations {
                    page.removeAnnotation(annotation)
                }
            } else {
                handOverToSelfRendered(on: page)
            }
            output.insert(page, at: slot)
        }
        return output
    }

    /// 把副本页上的批注**交给我们自己的渲染器**画（打印用）。
    ///
    /// **打印必须走这一步。** 为了让批注以矢量方式清晰显示，我们在内存里把可自绘的批注
    /// 设成了 `shouldDisplay = false`（PDFKit 不画，改由 `AnnotationRenderer` 画）。
    /// 实测 `page.copy()` **会保留这个标志**，于是打印出来**一个批注都没有**。
    ///
    /// 旧做法是把它们设回 `shouldDisplay = true`、让 PDFKit 自己画 —— 但 PDFKit 按 `/LE`
    /// 画出来的是**平底三角**，和屏幕上的倒钩箭头对不上，用户看到的就是
    /// "预览一个样、打出来另一个样"。文件层面没有出路（`/Polygon` 被 PDFKit 拒绝、
    /// `/Ink` 的 `/IC` 不填充，实测见 `SelfRenderedAnnotation`），
    /// 所以改成**换成 `SelfRenderedAnnotation` 代理** —— PDFKit 会调用子类 override 的
    /// `draw(with:in:)`，打印于是走屏幕上同一套渲染器。
    ///
    /// ⚠️ **顺序有讲究**：先给"我们不接管的 ink"校正 `/Rect`，再做替换。
    /// 替换后绘制不再依赖 `bounds`，校正就没意义了；反过来的话，校正会平移
    /// `bounds.origin`，把已经接管的 ink 画歪。
    ///
    /// 改的是副本，不影响原文档与写盘内容。
    /// （非 private：便于探针验证。）
    static func handOverToSelfRendered(on page: PDFPage) {
        // 1) 别的应用留下的 ink（我们不接管）仍需保证 `/Rect` 包住墨迹，
        //    否则 PDFKit 会裁掉一块（见 `AnnotationRenderer` 的「涂鸦（ink）的几何一致性」）
        for annotation in page.annotations
            where annotation.shouldDisplay && AnnotationItem.Kind(subtype: annotation.type) == .ink {
            reconcileInkBounds(on: annotation)
        }

        // 2) 我们自绘的批注 → 换成绘制代理
        let targets = page.annotations.filter { !$0.shouldDisplay }
        for annotation in targets {
            page.removeAnnotation(annotation)
            page.addAnnotation(SelfRenderedAnnotation.wrapping(annotation))
        }
    }

    /// 单条 ink 的 `/Rect` 校正（`AnnotationRenderer.reconcileInkBounds` 是整文档版）
    private static func reconcileInkBounds(on annotation: PDFAnnotation) {
        guard let ink = AnnotationRenderer.inkStrokeBounds(of: annotation) else { return }
        let current = annotation.bounds
        let tolerance: CGFloat = 0.5
        let covers = current.minX <= ink.minX + tolerance
            && current.minY <= ink.minY + tolerance
            && current.maxX >= ink.maxX - tolerance
            && current.maxY >= ink.maxY - tolerance
        if !covers { annotation.bounds = ink }
    }

    /// 每张纸排 `pagesPerSheet` 页，生成一份新的拼版文档。
    /// （非 private：便于用探针验证拼版页数与各单元格内容。）
    static func imposePages(_ source: PDFDocument,
                            pagesPerSheet: Int,
                            paperSize: CGSize) -> PDFDocument? {
        guard pagesPerSheet > 1, source.pageCount > 0 else { return source }
        guard paperSize.width > 0, paperSize.height > 0 else { return nil }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let (rows, columns) = gridDimensions(for: pagesPerSheet)
        let cellWidth = paperSize.width / CGFloat(columns)
        let cellHeight = paperSize.height / CGFloat(rows)
        let sheetCount = (source.pageCount + pagesPerSheet - 1) / pagesPerSheet
        // 单元格内缩，留出页间距，也避免贴着切线
        let gutter: CGFloat = 10

        for sheetIndex in 0..<sheetCount {
            context.beginPDFPage(nil)

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)

            for slot in 0..<pagesPerSheet {
                let pageIndex = sheetIndex * pagesPerSheet + slot
                guard pageIndex < source.pageCount, let page = source.page(at: pageIndex) else { continue }

                let row = slot / columns
                let column = slot % columns
                let cell = CGRect(
                    x: CGFloat(column) * cellWidth,
                    // PDF 坐标系原点在左下角，行号要从上往下数
                    y: paperSize.height - CGFloat(row + 1) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                let target = cell.insetBy(dx: gutter, dy: gutter)

                context.saveGState()
                context.clip(to: target)
                draw(page: page, in: target, context: context)
                context.restoreGState()

                // 裁切线：方便打印后裁开
                context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
                context.setLineWidth(0.5)
                context.stroke(cell.insetBy(dx: gutter / 2, dy: gutter / 2))
            }

            context.endPDFPage()
        }
        context.closePDF()

        return PDFDocument(data: data as Data)
    }

    /// 把单页等比居中画进目标矩形。
    private static func draw(page: PDFPage, in target: CGRect, context: CGContext) {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = min(target.width / bounds.width, target.height / bounds.height)
        context.saveGState()
        context.translateBy(x: target.midX, y: target.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }

    /// 每张纸页数 → (行, 列)
    private static func gridDimensions(for pagesPerSheet: Int) -> (rows: Int, columns: Int) {
        switch pagesPerSheet {
        case 2: return (1, 2)
        case 4: return (2, 2)
        case 6: return (2, 3)
        case 9: return (3, 3)
        default: return (1, 1)
        }
    }
}
