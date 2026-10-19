import AppKit
import PDFKit
import CoreText

/// 把 PDF 批注用 Core Graphics **矢量**绘制到页面上。
///
/// ## 为什么要自己画（两条实测结论）
///
/// **一、PDFKit 的批注显示是模糊的。**
/// 屏幕 `backingScaleFactor` 是 2.0，但 `PDFDocumentView` / `PDFPageView` 的
/// `layer.contentsScale` 是 **1.0** —— 也就是用 1x 分辨率栅格化再放大到 2x 显示。
/// 实测同一页上，PDFKit 画的批注（红框/蓝圆/紫斜线）边缘有明显柔化，
/// 而在 `drawPagePost` 里用 CGContext 画的同样形状边缘干脆利落。
///
/// **二、PDFKit 的批注层在鼠标拖拽期间不刷新。**
/// 实测：按住拖动时连续改批注 bounds，屏幕纹丝不动（红色像素恒为 32），
/// 松手后重建 document 才出现（红色像素 52334）。
/// 而 `drawPagePost` 属于 PDFView 自己的层，拖拽期间被持续调用、实时可见
/// （红色像素随拖动 251 → 20922 → 38467 → 51410）。
///
/// ## 因此的架构
///
/// **批注依然存成标准 PDFAnnotation**（写盘、与其他阅读器互操作都靠它），
/// **但显示改由这里自绘**：把这些批注的 `shouldDisplay` 置为 `false`，
/// 免得 PDFKit 再画一份模糊的叠在下面。
///
/// > ⚠️ `shouldDisplay = false` 会被持久化到文件里（实测重载后仍是 false），
/// > 所以**写回 PDF 之前必须把它们恢复成 `true`**，
/// > 否则别的阅读器打开会看不到批注。见 `PDFViewModel.saveAnnotationsToDisk`。
enum AnnotationRenderer {

    /// 一条批注的绘制几何（**页坐标**）。
    ///
    /// - `stroke`：描边路径
    /// - `fill`：填充路径（高亮整块、箭头的实心三角）
    struct Shape {
        var stroke: CGPath?
        var fill: CGPath?
    }

    // MARK: - 判定

    /// 这个批注是否由我们自绘。
    ///
    /// 原则：**只接管我们能完整正确渲染的**。任何"可能画得和 PDFKit 不一样"的情况
    /// 一律交回 PDFKit —— 宁可那一个批注保持 PDFKit 的观感，也不要画错或画丢。
    static func isSelfRendered(_ annotation: PDFAnnotation) -> Bool {
        guard let kind = kind(of: annotation) else { return false }

        switch kind {
        case .highlight, .underline, .strikeOut:
            // 这三种可能由多个 quad 组成（跨行文字选择）。我们能画任意段数的 quad
            // （见 `quadBoxes`），所以只要点数合法就接管。
            // 点数不是 4 的倍数说明不是"每段四点"的正常形态 —— 交回 PDFKit。
            if let quads = annotation.quadrilateralPoints, quads.count % 4 != 0 {
                return false
            }

        case .ink:
            // 没有笔迹的 ink 我们画不出东西 —— 交给 PDFKit，免得它整个消失
            guard let paths = annotation.paths, !paths.isEmpty else { return false }

        case .line:
            // 起终点全为零等于一条退化线，交给了也看不出来；但更怕的是我们画的
            // 和 PDFKit 不同，所以保守交回
            let start = annotation.startPoint
            let end = annotation.endPoint
            if start == .zero && end == .zero { return false }

        default:
            break
        }
        return true
    }

    // MARK: - 涂鸦（ink）的几何一致性
    //
    // ⚠️ **这一节修的是一个会把文件写坏的坑，别再简化掉。**
    //
    // PDF 里 ink 批注有两份几何：
    //   · `/InkList` —— 墨迹坐标（**默认用户空间 = 页坐标**，绝对值）
    //   · `/Rect`    —— 批注矩形（我们代码里的 `bounds`）
    // 规范要求 `/Rect` **必须包住** `/InkList`，阅读器也会按 `/Rect` **裁剪**墨迹。
    //
    // **而 PDFKit 改 `bounds` 时不会动墨迹**。实测（线宽 6 的一条笔画）：
    //
    // | 操作 | /Rect | /InkList |
    // |------|-------|----------|
    // | 画完就存 | 77…203 / 117…163 | 80…200 / 120…160 ✅ 一致 |
    // | 再把 bounds 平移 (60,−25) | **137…263 / 92…138** | **80…200 / 120…160 一个数都没变** ❌ |
    //
    // 于是墨迹伸出 `/Rect` 57 点，**别的阅读器（预览……）就把这部分裁掉** ——
    // 用户看到的是"涂鸦被切掉一块"。而**我们自绘看不出来**：自绘是
    // `paths（相对 bounds 原点）+ bounds.origin`，一减一加正好抵消，屏幕上始终完整。
    // 这就是"我们看着好好的，用预览打开少一块"的根源。
    //
    // 两个对策（都在用）：
    // 1. `reanchorInkStrokes` —— 移动批注时把笔迹重新锚定到新的原点，让墨迹**真的跟着走**；
    // 2. `reconcileInkBounds` —— 打开/保存/打印前把 `/Rect` 校正到"包住墨迹"，
    //    既救回已经被写坏的老文件，也防止有任何遗漏路径再写出坏文件。

    /// 一条 ink 批注的墨迹在**页坐标**下的包围盒（已含描边外扩的半个线宽）。
    ///
    /// `paths` 给的是**相对 `bounds` 原点**的笔迹（PDFKit 读盘时已经减过原点），
    /// 所以要加回 `bounds.origin` 才是页坐标。没有笔迹时返回 nil。
    ///
    /// ⚠️ **只在"批注与 `bounds` 自洽"时可靠** —— 也就是刚 `add` 完、或刚从磁盘读入的时候。
    /// PDFKit 改 `bounds` 时**不会**更新 `paths`（它们固定在 `add` 那一刻的相对坐标），
    /// 所以"在内存里拖过但没重建笔迹"的批注，这里算出来的其实是"当前框内的相对位置"，
    /// 并不代表墨迹真正的绝对位置（会误判成"框包住了墨迹"）。
    /// 换句话说：**要让墨迹真的动，只能靠 `reanchorInkStrokes`，这个函数只是用来看的。**
    static func inkStrokeBounds(of annotation: PDFAnnotation) -> CGRect? {
        guard let strokes = annotation.paths, !strokes.isEmpty else { return nil }

        var union = CGRect.null
        for stroke in strokes { union = union.union(stroke.bounds) }
        guard !union.isNull,
              union.origin.x.isFinite, union.origin.y.isFinite,
              union.width.isFinite, union.height.isFinite else { return nil }

        let pad = strokeWidth(of: annotation) / 2
        let origin = annotation.bounds.origin
        return union.insetBy(dx: -pad, dy: -pad)
                    .offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 把 ink 的笔迹**按当前 `bounds` 原点重新锚定**一遍，让墨迹跟着框走。
    ///
    /// 原理：`remove` + `add` 这个动作本身会让 PDFKit 用**当前**的 `bounds.origin`
    /// 重算墨迹的绝对坐标。实测同一条笔画（`bounds` 平移 (60,−25)）：
    ///
    /// | 做法 | `/InkList` |
    /// |------|-----------|
    /// | 只改 bounds | 80…200（**没动**）❌ |
    /// | 改完再 `remove`+`add` 一遍 | **140…260**（正好跟着走）✅ |
    /// | 改完再把点平移一次 delta | 200…320（多走一次）❌ |
    ///
    /// ⚠️ **不要把笔迹的坐标再平移一次** —— 和箭头 `startPoint` 那个坑同源：
    /// 相对坐标的语义由原点决定，多平移一次就是移动两倍。
    ///
    /// 成本（实测，一次完整重建）：50 点 0.09 ms、500 点 0.7 ms、1000 点 1.4 ms、
    /// 4000 点 5 ms —— 拖动每一帧做一次可以接受，超长的笔迹见 `PDFViewModel.reanchorInkIfNeeded`。
    @discardableResult
    static func reanchorInkStrokes(of annotation: PDFAnnotation) -> Bool {
        guard let strokes = annotation.paths, !strokes.isEmpty else { return false }

        // 先留副本再 remove —— 直接拿 remove 掉的对象 add 回去不安全
        let saved = strokes.compactMap { $0.copy() as? NSBezierPath }
        guard saved.count == strokes.count else { return false }

        for stroke in strokes { annotation.remove(stroke) }
        for stroke in saved { annotation.add(stroke) }
        return true
    }

    /// 把文档里所有 ink 批注的 `/Rect` 校正到"包住墨迹"。返回被校正的条数。
    ///
    /// 判据只看**方向性**的：`/Rect` 没包住墨迹才改（往外扩），**包住的不动** ——
    /// 不主动把框缩小，免得动到用户（或别的应用）有意留出的边距。
    ///
    /// 用在三个地方：`applyDisplayPolicyToDocument`（打开后）、`saveAnnotationsToDisk`
    /// （写盘前）、`PDFPrintService`（打印前）。**改的是框、不是墨迹** ——
    /// 墨迹才是内容，框只是包装。
    @discardableResult
    static func reconcileInkBounds(in document: PDFDocument) -> Int {
        var fixed = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where kind(of: annotation) == .ink {
                guard let ink = inkStrokeBounds(of: annotation) else { continue }
                let tolerance: CGFloat = 0.5
                let current = annotation.bounds
                let covers = current.minX <= ink.minX + tolerance
                    && current.minY <= ink.minY + tolerance
                    && current.maxX >= ink.maxX - tolerance
                    && current.maxY >= ink.maxY - tolerance
                guard !covers else { continue }
                annotation.bounds = ink
                fixed += 1
            }
        }
        return fixed
    }

    // MARK: - 多行文字批注的 quad

    /// 把 `quadrilateralPoints` 拆成一组**页坐标**的包围盒。
    ///
    /// ## 两个实测踩出来的坑（都验过，别再踩）
    ///
    /// 1. **坐标是批注空间**（相对 `bounds` 原点），不是页坐标。
    ///    直接塞页坐标进去，PDFKit 会把整组 quad 平移出选区（实测"画到选区外 17 行"）。
    /// 2. **每个 quad 的四点顺序是「左上、右上、左下、右下」**（PDF 规范 Table 8.47，
    ///    PDFKit 自己产出的批注也是这个顺序）。顺序写错会画成"蝴蝶结"，
    ///    表现是同一行里出现上下两段、中间空一条。
    ///
    /// 顶点顺序无所谓我们只取包围盒 —— 我们的 quad 都是轴对齐的（跨行文字选区）。
    static func quadBoxes(of annotation: PDFAnnotation) -> [CGRect] {
        guard let raw = annotation.quadrilateralPoints,
              raw.count >= 4, raw.count % 4 == 0 else { return [] }
        let origin = annotation.bounds.origin
        var boxes: [CGRect] = []
        var index = 0
        while index + 3 < raw.count {
            let points = (0..<4).map { offset -> CGPoint in
                let point = raw[index + offset].pointValue
                return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
            }
            let xs = points.map(\.x), ys = points.map(\.y)
            boxes.append(CGRect(x: xs.min()!, y: ys.min()!,
                                width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            index += 4
        }
        return boxes
    }

    /// PDFKit 的 `annotation.type` 不带前导斜杠（"Square"），
    /// 而 `PDFAnnotationSubtype.rawValue` 带（"/Square"）—— 实测确认过。
    private static func kind(of annotation: PDFAnnotation) -> AnnotationItem.Kind? {
        let name = (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch name {
        case "Highlight": return .highlight
        case "Underline": return .underline
        case "StrikeOut": return .strikeOut
        case "Text": return .note
        case "FreeText": return .freeText
        case "Ink": return .ink
        case "Square": return .square
        case "Circle": return .circle
        case "Line": return .line
        default: return nil
        }
    }

    // MARK: - 线宽

    /// 批注的描边宽度。
    ///
    /// 批注的描边宽度（**页坐标**下的值）。
    ///
    /// 多数情况在 `border.lineWidth`；但**别的应用产出的 ink 常把线宽存在笔迹路径上**
    /// （`PDFAnnotationInk` 的每个路径各有一个 `lineWidth`），border 可能是空的。
    /// 所以这里做回退，免得那些批注被画成 1pt 的细线。
    ///
    /// 拖动预览层也用它 —— 那里要再乘 `scaleFactor` 才是视图坐标下的线宽。
    static func strokeWidth(of annotation: PDFAnnotation) -> CGFloat {
        if let width = annotation.border?.lineWidth, width > 0 { return width }
        let fromPaths = (annotation.paths ?? []).map(\.lineWidth).max() ?? 0
        return fromPaths > 0 ? fromPaths : 1
    }

    // MARK: - 形状构建（页坐标）

    /// 批注的绘制路径，**页坐标**。
    ///
    /// 抽出来是为了让「画进 CGContext」和「拖动预览层（CAShapeLayer）」**用同一套几何** ——
    /// 否则拖动时看到的预览和松手后的结果会有肉眼可见的跳变。
    ///
    /// - `stroke`：描边路径
    /// - `fill`：填充路径（高亮整块、箭头的实心三角）
    ///
    /// `freeText` 与 `note` 返回 nil：文字用 CTFrame 画、便签有自己的描边色，
    /// 都不走这条通用路径（它们也不参与拖拽绘制）。
    static func paths(for annotation: PDFAnnotation) -> Shape? {
        guard let kind = kind(of: annotation) else { return nil }
        let bounds = annotation.bounds

        switch kind {
        case .highlight:
            // 跨行选择是**一组** quad（每行一段）。只画 `bounds` 那个大框的话，
            // 行间空隙和没选到的横向范围都会被涂上 —— 用户的原话是
            // "选择多行的时候，松开鼠标会与实际的选择不一致"。
            let boxes = quadBoxes(of: annotation)
            guard boxes.count > 1 else {
                return Shape(stroke: nil, fill: CGPath(rect: bounds, transform: nil))
            }
            let path = CGMutablePath()
            for box in boxes { path.addRect(box) }
            return Shape(stroke: nil, fill: path)

        case .underline:
            let path = CGMutablePath()
            for box in underlineSegments(of: annotation, bounds: bounds) {
                path.move(to: CGPoint(x: box.minX, y: box.minY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            }
            return Shape(stroke: path, fill: nil)

        case .strikeOut:
            let path = CGMutablePath()
            for box in underlineSegments(of: annotation, bounds: bounds) {
                path.move(to: CGPoint(x: box.minX, y: box.midY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            }
            return Shape(stroke: path, fill: nil)

        case .square:
            return shapeForBox(bounds, lineWidth: strokeWidth(of: annotation), round: false)

        case .circle:
            return shapeForBox(bounds, lineWidth: strokeWidth(of: annotation), round: true)

        case .line:
            return linePaths(annotation, bounds: bounds)

        case .ink:
            // ⚠️ ink 的 paths 坐标是相对 bounds 原点的。
            // 必须**先把路径变换好再 addPath** —— CGContext 的当前路径在 addPath
            // 那一刻就被 CTM 固定，之后再 translateBy 完全无效（实测会画在 (0,0)）。
            var transform = CGAffineTransform(translationX: bounds.minX, y: bounds.minY)
            let path = CGMutablePath()
            for stroke in annotation.paths ?? [] {
                if let moved = stroke.cgPath.copy(using: &transform) {
                    path.addPath(moved)
                }
            }
            return path.isEmpty ? nil : Shape(stroke: path, fill: nil)

        case .freeText, .note, .other, .stamp, .popup, .link, .widget:
            return nil
        }
    }

    /// 下划线 / 删除线要逐段画的区域（页坐标）。
    ///
    /// 多行选择时每个 quad 一段 —— 只画 `bounds` 的话会得到一整条横跨
    /// 最宽那行的线，和实际选中的文字对不上。
    private static func underlineSegments(of annotation: PDFAnnotation,
                                          bounds: CGRect) -> [CGRect] {
        let boxes = quadBoxes(of: annotation)
        return boxes.isEmpty ? [bounds] : boxes
    }

    // MARK: - 矩形 / 圆

    /// 矩形 / 圆的描边路径 —— **就画在 `bounds` 上**（线宽压在框线上，向两侧各一半）。
    ///
    /// ## 为什么不再往内缩（这是第二次返工，记下来）
    ///
    /// PDFKit 是把方框的描边压在 `bounds` **内侧**的（实测它的墨迹与 `bounds` 完全重合），
    /// 我们一开始照抄。但它有个致命副作用：**拖出来的框比线宽还小时，内缩会把矩形缩成 0**
    /// —— 实测细步长慢拖（每步 1 个页面点，线宽 3）：
    ///
    /// | 拖动 | 框 | 内缩后路径 | 屏幕上的红像素 |
    /// |------|----|-----------|--------------|
    /// | 0 点 | 0×0    | 0（退化成圆点） | 50 |
    /// | 1 点 | 1.3×1.3 | 1.25×1.25 | 90 |
    /// | 2 点 | 2.5×2.5 | 1.25×1.25 | 94 |
    /// | 4 点 | 5×5     | 1.4×1.4  | 95 |
    /// | 5 点 | 6.3×6.3 | 2.5×2.5  | 151 |
    ///
    /// 前 4 个点里**形状尺寸几乎不动**（内缩量把增长全吃掉了），用户的原话是
    /// 「最开始的几个移动点还是没有真正画出来」。
    ///
    /// 内缩还只是小事：把它做成"带下限的内缩"后仍然跟不动 —— 数学上不可能既内缩
    /// 又让形状 1:1 跟随。所以干脆**不内缩**：拖多大就是多大，形状从第一个像素
    /// 就跟着手走，预览与最终结果也天然一致。
    ///
    /// 代价：描边外缘比 `bounds` 多出半个线宽（常见线宽下 1.5~4 点），
    /// 与 PDFKit 的画法差这一点点 —— 用肉眼看不出，但换来的是"画得跟手"。
    ///
    /// 框还是 0×0（刚按下没动）时画一个**圆点**：跟画笔"点一下就留个点"一致。
    private static func shapeForBox(_ bounds: CGRect,
                                    lineWidth: CGFloat,
                                    round: Bool) -> Shape {
        guard bounds.width > 0, bounds.height > 0 else {
            return Shape(stroke: nil,
                         fill: dotPath(at: CGPoint(x: bounds.midX, y: bounds.midY),
                                       lineWidth: lineWidth))
        }
        return Shape(stroke: round ? CGPath(ellipseIn: bounds, transform: nil)
                                   : CGPath(rect: bounds, transform: nil),
                     fill: nil)
    }

    /// 一个实心圆点（直径 = 线宽）。给"刚按下还没拉开"当反馈用，也是单点笔迹的兜底形状。
    private static func dotPath(at center: CGPoint, lineWidth: CGFloat) -> CGPath {
        let radius = max(lineWidth / 2, 0.5)
        return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2),
                      transform: nil)
    }

    // MARK: - 涂鸦（按点直接构建）

    /// 由一串**页坐标**的点构建笔迹路径，不经过 `PDFAnnotation`。
    ///
    /// 为什么不复用 `paths(for:)`：拖动涂鸦时，若每来一个点就去改
    /// `PDFAnnotation` 的笔迹（`remove` + `add` + `bounds`），PDFKit 那边会
    /// 一路重建内部状态。实测（真实窗口 + 合成事件，125Hz 投递）：
    ///
    /// | 笔迹点数 | 每事件处理器耗时 | 事件滞后 P90 |
    /// |---------|----------------|-------------|
    /// | 24      | 0.57 ms        | 0.1 ms      |
    /// | 900     | **1.09 ms**    | **40 ms**   |
    ///
    /// 滞后随点数一路涨：900 点时最大 80 ms，画到两千点就是肉眼可见的"手和笔
    /// 差一截"。把「改批注」从拖动路径里摘掉之后，同样 900 点降到 14 ms
    /// （与矩形/箭头同级）。所以**拖动期间只追加点**，落成批注放到松手那一次做。
    ///
    /// 几何和最终批注完全一致：都是「过这些点的折线 + 圆头圆角 + 同样的线宽」，
    /// 单点退化成一个小圆点（和 `PDFAnnotationInk` 的兜底画法一致）。
    static func inkPaths(points: [CGPoint], lineWidth: CGFloat) -> Shape? {
        guard let first = points.first else { return nil }

        if points.count == 1 {
            return Shape(stroke: nil, fill: dotPath(at: first, lineWidth: lineWidth))
        }

        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return Shape(stroke: path, fill: nil)
    }

    // MARK: - 绘制入口

    /// 完全透明（调色板里的「透明」）就等于不上色。
    ///
    /// ⚠️ **必须显式判断，不能指望 CGContext 什么都不画。**
    /// 实测：`annotation.color` 的 alpha 为 0 时，PDFKit 会把颜色变成**空 NSColor**
    /// （`usingColorSpace(.sRGB)` 返回 nil、`/C` 变 nil —— 不管我们赋的是
    /// `NSColor.clear` 还是 `NSColor(srgbRed:1,green:0,blue:0,alpha:0)`，结果一样）。
    /// 把这个空色交给 `setStrokeColor`，CGContext 不报错，而是**沿用上一次的颜色**兜底，
    /// 默认就是黑色 —— 用户看到的就是"选了透明，形状画出来是黑的"。
    static let transparentThreshold: CGFloat = 0.004

    /// 这条批注是不是"完全不上色"
    static func isTransparent(_ annotation: PDFAnnotation) -> Bool {
        annotation.color.alphaComponent <= transparentThreshold
    }

    /// 这条批注的"主颜色"是否派得上用场 —— 派不上就别画。
    ///
    /// `freeText` 例外：它的 `color` 只是**背景**，透明背景照样要画文字。
    static func isVisible(_ annotation: PDFAnnotation) -> Bool {
        if kind(of: annotation) == .freeText { return true }
        return !isTransparent(annotation)
    }

    /// 这个种类的批注有没有"透明"这回事。
    ///
    /// 只有**带背景/填充**的（高亮、文本注释背景）才谈得上"无色"；
    /// 描边类的（形状 / 涂鸦 / 直线 / 下划线 / 删除线 / 便签）没有颜色就是**看不见**，
    /// 那不是用户想要的结果 —— 界面上会把「透明」藏掉（见 `AnnotationStyle.supportsTransparent`）。
    static func supportsTransparent(_ kind: AnnotationItem.Kind) -> Bool {
        switch kind {
        case .highlight, .freeText: return true
        default: return false
        }
    }

    /// 在**页坐标系**里绘制一条批注。
    ///
    /// `context` 必须是页坐标系的 CGContext（`PDFView.drawPagePost` 给的就是），
    /// 这样绘制结果自动跟随缩放，且是矢量。
    static func draw(_ annotation: PDFAnnotation, in context: CGContext) {
        guard let kind = kind(of: annotation) else { return }
        let bounds = annotation.bounds
        guard bounds.width > 0 || bounds.height > 0 || kind == .line || kind == .ink else { return }
        // 「透明」= 不上色，直接不画（原因见 `transparentThreshold`）
        guard isVisible(annotation) else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 这两个走专用绘制
        switch kind {
        case .freeText:
            drawFreeText(annotation, in: context, bounds: bounds)
            return
        case .note:
            drawStickyNote(annotation, in: context, bounds: bounds, color: annotation.color)
            return
        default:
            break
        }

        guard let shape = paths(for: annotation) else { return }
        draw(shape, color: annotation.color, lineWidth: strokeWidth(of: annotation), in: context)
    }

    /// 把一份几何按统一样式描边 + 填充。
    ///
    /// 单独抽出来给「拖动预览」用 —— 涂鸦草稿不落成 `PDFAnnotation`，
    /// 只有几何（见 `inkPaths`），所以两边共用这一个绘制实现，保证观感一致。
    static func draw(_ shape: Shape,
                     color: NSColor,
                     lineWidth: CGFloat,
                     in context: CGContext) {
        // 透明色不能交给 CGContext（它会拿上一次的颜色兜底 = 黑），自己拦掉
        guard color.alphaComponent > transparentThreshold else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if let fill = shape.fill {
            context.addPath(fill)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        if let stroke = shape.stroke {
            context.addPath(stroke)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
    }

    // MARK: - 线 / 箭头

    /// 线的几何：**线身与实心端点合成一条闭合轮廓，一次填充**。
    ///
    /// ## 为什么必须"一次填充"（v1.3.13，别再拆回两个图元）
    ///
    /// 旧实现是「描边画线身 + 填充画箭头」两个独立图元，而线条端头是圆头（`lineCap = .round`）。
    /// 圆头与箭头的平底边**只相切于一个点**，两个图元各自抗锯齿、各自铺色，
    /// 接缝那一列的 alpha 只有 0.75（0.5 + 0.5×0.5）—— 4 倍放大就是一条贯穿的浅色竖缝，
    /// 看着像"一根管子顶着一个帽子"。用户的原话是「没有完全贴合，看着很奇怪」。
    ///
    /// 合成一条轮廓后：
    /// - 线身与箭头**共用边界**，不再是"两段几何靠在一起"，接缝无从而生；
    /// - 重叠部分落在同一次填充里，**不会叠出更深的色**（半透明也干净）；
    /// - 箭头与线身真正长成一体 —— 不重叠、不凸出。
    ///
    /// ## 箭头形状：倒钩
    ///
    /// 轮廓是 `尖端 → 钩尖 → 内凹 → 线身`：钩尖向后张开，再从钩尖斜切回线身边缘，
    /// 形成锐角倒钩（深度由 `barbNotch` 控制），线身正好接在倒钩的凹口里。
    ///
    /// 端点样式的分工：
    /// - `.closedArrow` / `.none`（圆头）→ 并入这条轮廓（见 `solidOutline`）；
    /// - `.circle` / `.square` → 追加到同一份 `fill`（圆和方块都比线宽大，会把线身端头整个包住）；
    /// - `.openArrow` → 只能描边（V 形是空的），与线身放进**同一次描边**，交汇处不叠色。
    private static func linePaths(_ annotation: PDFAnnotation,
                                  bounds: CGRect) -> Shape {
        // ⚠️ start/end 是**相对 bounds 原点**的坐标（实测：只改 bounds 时它们原样不动）
        let start = CGPoint(x: bounds.minX + annotation.startPoint.x,
                            y: bounds.minY + annotation.startPoint.y)
        let end = CGPoint(x: bounds.minX + annotation.endPoint.x,
                          y: bounds.minY + annotation.endPoint.y)

        let lineWidth = strokeWidth(of: annotation)
        let startStyle = annotation.startLineStyle
        let endStyle = annotation.endLineStyle

        let fill = CGMutablePath()
        let stroke = CGMutablePath()

        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)

        // 起终点重合：画一个点（与圆头端帽同形）
        guard length > 0.0001 else {
            fill.addEllipse(in: circleRect(at: start, radius: lineWidth / 2))
            return Shape(stroke: nil, fill: fill)
        }

        let ux = dx / length, uy = dy / length

        if let outline = solidOutline(start: start, end: end,
                                      ux: ux, uy: uy,
                                      startStyle: startStyle, endStyle: endStyle,
                                      lineWidth: lineWidth) {
            // ① 线身 + 实心箭头 / 圆头 → 一条轮廓
            fill.addPath(outline)
        } else {
            // ② 有圆点 / 方块端点时退回"线身 + 各端形状"：
            //    圆和方块都比线宽大，会把线身端头整个包住，同样是"一次填充、不叠色"。
            //
            // ⚠️ 矩形的**绕向必须是逆时针**，跟 `addEllipse` / `addRect` 一致。
            //    一旦相反，nonzero 规则会把重叠区算成 winding = 1 − 1 = 0 —— **直接挖空**。
            //    （实测就是圆点端帽被啃掉一块白弧，看着像"被咬了一口的圆"。）
            let px = -uy, py = ux
            let half = lineWidth / 2
            fill.move(to: CGPoint(x: start.x + px * half, y: start.y + py * half))
            fill.addLine(to: CGPoint(x: start.x - px * half, y: start.y - py * half))
            fill.addLine(to: CGPoint(x: end.x - px * half, y: end.y - py * half))
            fill.addLine(to: CGPoint(x: end.x + px * half, y: end.y + py * half))
            fill.closeSubpath()

            // 没有端点样式的那一端要补圆头端帽（原来是靠 `lineCap = .round` 得到的）
            if startStyle == .none {
                fill.addEllipse(in: circleRect(at: start, radius: half))
            }
            if endStyle == .none {
                fill.addEllipse(in: circleRect(at: end, radius: half))
            }
        }

        // ③ 圆点 / 方块 / 开放箭头（实心倒钩箭头与圆头都已在 ① 的轮廓里）
        let ends: [(tip: CGPoint, tail: CGPoint, style: PDFLineStyle)] = [
            (end, start, endStyle),
            (start, end, startStyle),
        ]
        for item in ends {
            switch item.style {
            case .circle, .square, .openArrow:
                let (head, isFilled) = arrowHead(at: item.tip, from: item.tail,
                                                 style: item.style, lineWidth: lineWidth)
                guard let head else { continue }
                // 开放箭头的 V 是空的、只能描边；它与线身在**同一次**描边里，交汇处不会叠深
                if isFilled { fill.addPath(head) } else { stroke.addPath(head) }
            default:
                // `.none` / `.closedArrow` 已并入 ① 的一体化轮廓；
                // 其余（`.diamond` / `.slash`）本工程不用，保持原样不画
                break
            }
        }

        return Shape(stroke: stroke.isEmpty ? nil : stroke,
                     fill: fill.isEmpty ? nil : fill)
    }

    /// 「圆头 / 圆点」端帽的外接矩形（圆心在 `point`）。
    private static func circleRect(at point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius,
               width: radius * 2, height: radius * 2)
    }

    // MARK: - 实心箭头的一体化轮廓

    /// 倒钩深度：内凹点落在"钩尖往回"的这个比例上。
    ///
    /// `1` = 平底（内凹与钩尖齐平）；越小倒钩越深。`0.75` 是按用户给的参考图定的 ——
    /// 再小钩子会长得像"回旋镖"，再大就和普通三角没区别了。
    private static let barbNotch: CGFloat = 0.75

    /// 一支实心箭头的五个关键点（页坐标）。
    private struct ArrowCap {
        var apex: CGPoint       // 尖端
        var barbUp: CGPoint     // 上钩尖
        var notchUp: CGPoint    // 上内凹点（线身从这里接出去）
        var barbDn: CGPoint     // 下钩尖
        var notchDn: CGPoint    // 下内凹点
    }

    /// 按"头尖朝向 `dir`"算出一支箭头的五个点。
    ///
    /// ⚠️ **`perp` 必须由调用方统一给**（整条线的 `(-uy, ux)`），不能在这里用 `dir` 现推 ——
    /// start 端的 `dir` 是反向的，现推出来的垂直方向会跟着翻 180°，
    /// 于是那一端的"上钩尖"跑到下方去，轮廓上下自交、线身整段画不出来。
    /// （这个 bug 探针一测就现形：双头箭头的线身高度量到 `300:0`。）
    ///
    /// 尺寸沿用 PDFKit 的实测标定（**头长 3.6×线宽**、**半宽 2.25×线宽**、**尖端外扩 1×线宽**，
    /// 数据来源见 `arrowHead` 的表格），这样自绘轮廓的大小和别处一致 ——
    /// 与旧实现相比只有两处不同：不再有接缝，形状从平底三角变成倒钩。
    private static func arrowCap(tip: CGPoint,
                                 dirX: CGFloat, dirY: CGFloat,
                                 perpX: CGFloat, perpY: CGFloat,
                                 lineWidth: CGFloat) -> ArrowCap {
        let overshoot = lineWidth
        let back = 3.6 * lineWidth
        let halfWidth = 2.25 * lineWidth
        let half = lineWidth / 2

        func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - dirX * along + perpX * side,
                    y: tip.y - dirY * along + perpY * side)
        }
        return ArrowCap(
            apex: CGPoint(x: tip.x + dirX * overshoot, y: tip.y + dirY * overshoot),
            barbUp: pt(back, halfWidth),
            notchUp: pt(back * barbNotch, half),
            barbDn: pt(back, -halfWidth),
            notchDn: pt(back * barbNotch, -half)
        )
    }

    /// 线身与两端连成的**一条闭合轮廓**（整条线一份几何、一次填充）。
    ///
    /// 只接管 `.closedArrow`（实心倒钩箭头）与 `.none`（圆头）两种端点 —— 它们是最常见的组合，
    /// 也是接缝最刺眼的地方。其余端点（圆点 / 方块 / 开放箭头）返回 `nil`，由 `linePaths` 走通用分支。
    ///
    /// 路径自 `end` 端起笔 → 沿上侧走到 `start` 端 → 沿下侧折回，整体**逆时针**。
    /// 两个"内凹点"之间那段直线就是线身的上边缘（下侧同理），
    /// 所以线身天然长在箭头上，不存在"接上去"这个动作，也就没有接缝可言。
    private static func solidOutline(start: CGPoint,
                                     end: CGPoint,
                                     ux: CGFloat, uy: CGFloat,
                                     startStyle: PDFLineStyle,
                                     endStyle: PDFLineStyle,
                                     lineWidth: CGFloat) -> CGPath? {
        // `.openArrow` 也一并收进来 —— 它的 V 形是空的、只能描边，但**线身**仍然要算在这条轮廓里。
        // 否则线身会被画两遍（轮廓里一遍、描边里一遍），半透明时中间叠出一条深带。
        let supported: (PDFLineStyle) -> Bool = {
            $0 == .closedArrow || $0 == .none || $0 == .openArrow
        }
        guard supported(startStyle), supported(endStyle) else { return nil }

        let px = -uy, py = ux
        let half = lineWidth / 2
        let path = CGMutablePath()

        // ⚠️ 两端用的 `perp` 是**同一个**（整条线的 `(-uy, ux)`），只有 `dir` 反向 ——
        // 否则 start 端的上下会翻过去，轮廓自交（理由见 `arrowCap` 的注释）。
        let endCap = endStyle == .closedArrow
            ? arrowCap(tip: end, dirX: ux, dirY: uy,
                       perpX: px, perpY: py, lineWidth: lineWidth)
            : nil
        let startCap = startStyle == .closedArrow
            ? arrowCap(tip: start, dirX: -ux, dirY: -uy,
                       perpX: px, perpY: py, lineWidth: lineWidth)
            : nil

        // ── 上侧：end → start
        if let cap = endCap {
            path.move(to: cap.apex)
            path.addLine(to: cap.barbUp)
            path.addLine(to: cap.notchUp)
        } else {
            path.move(to: CGPoint(x: end.x + px * half, y: end.y + py * half))
        }

        if let cap = startCap {
            path.addLine(to: cap.notchUp)
            path.addLine(to: cap.barbUp)
            path.addLine(to: cap.apex)
            path.addLine(to: cap.barbDn)
            path.addLine(to: cap.notchDn)
        } else {
            path.addLine(to: CGPoint(x: start.x + px * half, y: start.y + py * half))
            // 圆头端帽：绕"远离 end 的一侧"画半圆，方向与轮廓一致（逆时针）
            path.addArc(center: start, radius: half,
                        startAngle: atan2(py, px), endAngle: atan2(-py, -px),
                        clockwise: false)
        }

        // ── 下侧：start → end
        if let cap = endCap {
            path.addLine(to: cap.notchDn)
            path.addLine(to: cap.barbDn)
        } else {
            path.addLine(to: CGPoint(x: end.x - px * half, y: end.y - py * half))
            path.addArc(center: end, radius: half,
                        startAngle: atan2(-py, -px), endAngle: atan2(py, px),
                        clockwise: false)
        }

        path.closeSubpath()
        return path
    }

    /// **不参与一体化**的那几种端点（圆点 / 方块 / 开放箭头）的路径。
    /// 返回 (路径, 是否应填充) —— 开放箭头只描边。
    ///
    /// `.closedArrow` 不在这里：实心箭头必须和线身连成**同一条轮廓**（否则接缝无法消除），
    /// 走的是 `solidOutline`。改这里之前先看那个函数。
    ///
    /// ## 尺寸按 PDFKit 实测标定（不是拍脑袋定的）
    ///
    /// 探针做法：让 PDFKit 自己画一条带 `.closedArrow` 的 Line 批注，
    /// 把页面栅格化后按「沿线段方向 / 垂直方向」投影，量出箭头的可见轮廓：
    ///
    /// | 线宽 | 可见头长 | 可见半宽 | 尖端超出端点 |
    /// |------|---------|---------|-------------|
    /// | 2    | 8.8     | 3.8     | 1.6         |
    /// | 3    | 13.6    | 6.5     | 2.9         |
    /// | 5    | 22.9    | 11.0    | 5.1         |
    /// | 8    | 36.0    | 18.1    | 8.3         |
    ///
    /// 三条规律：**头长 ≈ 4.6×线宽**、**半宽 ≈ 2.25×线宽**、
    /// **尖端在端点外 ≈ 1×线宽**（最后一条是因为 PDFKit 把三角「填充 + 描边」，
    /// 60° 尖角用 miter 接合会外扩 (线宽/2)/sin30° = 线宽）。
    ///
    /// 旧版用的是 `max(8, 线宽×4)` 和 25.7° 张角 —— 线宽 3 时只有 12 长、9.4 宽，
    /// 比 PDFKit 小一圈，看着就像"三角没到位"。这里直接用实测的三个数字建三角，
    /// 不引入描边那一套，可见轮廓和 PDFKit 一致。
    private static func arrowHead(at tip: CGPoint,
                                  from tail: CGPoint,
                                  style: PDFLineStyle,
                                  lineWidth: CGFloat) -> (CGPath?, Bool) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let path = CGMutablePath()

        // ⚠️ `.closedArrow` 已改由 `solidOutline` 一体化处理（线身与箭头是同一条轮廓，
        //    不再是从这里单独吐出的一个三角），不要再往这个 switch 里加回来。
        switch style {
        case .openArrow:
            let length = 4.6 * lineWidth
            let spread = CGFloat.pi / 6
            path.move(to: CGPoint(x: tip.x - length * cos(angle - spread),
                                  y: tip.y - length * sin(angle - spread)))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread),
                                     y: tip.y - length * sin(angle + spread)))
            return (path, false)

        case .circle:
            let r = lineWidth * 1.1
            path.addEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
            return (path, true)

        case .square:
            let s = lineWidth * 2.2
            path.addRect(CGRect(x: tip.x - s / 2, y: tip.y - s / 2, width: s, height: s))
            return (path, true)

        default:
            return (nil, false)
        }
    }

    // MARK: - 文本注释

    private static func drawFreeText(_ annotation: PDFAnnotation,
                                     in context: CGContext,
                                     bounds: CGRect) {
        // 背景：`annotation.color` 的 alpha 为 0 就是"透明无色"（调色板里的透明选项）
        let background = annotation.color
        if background.alphaComponent > 0.004 {
            context.setFillColor(background.cgColor)
            context.fill(bounds)
        }

        let text = annotation.contents ?? ""
        guard !text.isEmpty else { return }

        // 字号 / 字体族 / 粗斜体：全部从我们自己的键里读
        // （`annotation.font` 重载后恒为 Helvetica 12，见 FreeTextLayout）
        let font = FreeTextLayout.font(of: annotation)
        let textColor = annotation.fontColor ?? .black

        let inset = FreeTextLayout.horizontalInset
        let textRect = bounds.insetBy(dx: inset, dy: 0)

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    // MARK: - 便签

    /// PDFKit 原本画的是一张"折角便签"图标。这里自己画一个同形状的矢量版本。
    private static func drawStickyNote(_ annotation: PDFAnnotation,
                                       in context: CGContext,
                                       bounds: CGRect,
                                       color: NSColor) {
        let fold = bounds.width * 0.32
        let body = bounds

        context.setFillColor(color.cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(max(bounds.width * 0.04, 0.5))

        // 便签主体（右上角切一个折角）
        let p = CGMutablePath()
        p.move(to: CGPoint(x: body.minX, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - fold, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX, y: body.minY + fold))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX, y: body.maxY))
        p.closeSubpath()
        context.addPath(p)
        context.drawPath(using: .fillStroke)

        // 折角（用背景色盖出三角形，模拟翻折）
        let f = CGMutablePath()
        f.move(to: CGPoint(x: body.maxX - fold, y: body.minY))
        f.addLine(to: CGPoint(x: body.maxX - fold, y: body.minY + fold))
        f.addLine(to: CGPoint(x: body.maxX, y: body.minY + fold))
        f.closeSubpath()
        context.addPath(f)
        context.drawPath(using: .fillStroke)
    }

    // MARK: - 打印代理用的包围盒

    /// 一条批注自绘后**实际会占到**的矩形（含描边外扩）。
    ///
    /// 打印代理拿它当 `bounds` —— 否则 PDFKit 可能按原来那个（更小的）`bounds`
    /// 把画到外面的部分裁掉，箭头尖端首当其冲。
    static func renderedBounds(of annotation: PDFAnnotation) -> CGRect {
        let box = annotation.bounds
        guard let shape = paths(for: annotation) else { return box }

        var ink = CGRect.null
        if let stroke = shape.stroke { ink = ink.union(stroke.boundingBoxOfPath) }
        if let fill = shape.fill { ink = ink.union(fill.boundingBoxOfPath) }
        // ⚠️ 空路径的 `boundingBoxOfPath` 是 `CGRect.null`（origin 为无穷），必须挡掉
        guard !ink.isNull, !ink.isEmpty else { return box }

        // 描边向外扩半个线宽（round join 还要再多一点），留 2pt 余量
        let pad = strokeWidth(of: annotation) / 2 + 2
        return box.union(ink.insetBy(dx: -pad, dy: -pad))
    }
}

// MARK: - 打印：把批注交还给我们自己的渲染器

/// 一个**只为打印存在**的绘制代理。
///
/// ## 为什么需要它
///
/// 屏幕上批注由 `PDFView.drawPagePost` 自绘。但**打印走的是 PDFKit 的渲染**，
/// 它按 `/LE` 画出一个**平底三角**，和屏幕上的倒钩箭头对不上 ——
/// 用户看到的就是"预览一个样、打出来另一个样"。
///
/// 文件层面没有出路，两条标准路都实测堵死了：
/// - `/Polygon` + `/Vertices`：PDFKit 直接报 `Unhandled annotation subtype: /Polygon`，
///   而且 `/Vertices` 会被丢弃 —— 连写进文件都做不到；
/// - `/Ink` + `/IC`：`/IC` 能写盘，但 **PDFKit 只描边、不填充**（实测填充像素为 0）。
///
/// 于是走渲染侧：实测 **PDFKit 会调用 `PDFAnnotation` 子类 override 的
/// `draw(with:in:)`**（`page.draw(with:to:)` 与 `thumbnail` 两条路径都验证过）。
/// 打印前把自绘批注**换成这个代理**，PDFKit 就会用我们自己的渲染器画，两边自然一致。
///
/// ## 只在内存里替换
///
/// 改的是**打印用的副本页**，原文档和写盘内容都不动 ——
/// 文件里仍然是标准 `/Line` + `/LE`，别的阅读器照常打开、照常按规范画。
final class SelfRenderedAnnotation: PDFAnnotation {

    /// 几何与样式的来源（被替换掉的那个真实批注）
    private var source: PDFAnnotation?

    /// 把一个真实批注包装成绘制代理
    static func wrapping(_ annotation: PDFAnnotation) -> SelfRenderedAnnotation {
        // 保留原 subtype（PDFKit 内部会用它做一些判断；绘制则由我们接管）
        let subtype = PDFAnnotationSubtype(rawValue: "/" + (annotation.type ?? "Square"))
        let proxy = SelfRenderedAnnotation(bounds: AnnotationRenderer.renderedBounds(of: annotation),
                                           forType: subtype,
                                           withProperties: nil)
        proxy.source = annotation
        return proxy
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let source else { return }
        AnnotationRenderer.draw(source, in: context)
    }
}
