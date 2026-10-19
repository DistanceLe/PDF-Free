import AppKit
import PDFKit

/// 文本注释（FreeText）批注框的尺寸计算 —— 让框自适应内容。
///
/// ## PDFKit 自己的排版规则（把页面渲染成位图实测出来的）
///
/// - **会自动换行**：长文本按框宽折行，中英文都会（英文按词、中文按字符）。
/// - **认 `\n`**：显式换行生效，空行也占一行。
/// - **框高不够就直接裁掉**：不会缩小字号、也不会溢出到框外。
///   所以"框多大"必须由我们自己算准。
/// - 左右内边距各 **3** 点；框顶到首行墨迹约 6 点（随字号略变）。
/// - **换行结果与 `NSAttributedString.boundingRect(options: [.usesLineFragmentOrigin, .usesFontLeading])`
///   完全一致** —— 这是本文件能算准的前提，也是下面那张标定表余量能稳定的原因。
///
/// ## 标定：最小不裁切框高 = 测量高度 + 余量
///
/// 用二分搜索实测"最小不裁切框高"（判据：墨迹高度是否等于框足够大时的完整墨迹高度）：
///
/// | 文本 | 字号 | 测量高 | 实测最小框高 | 所需余量 |
/// |------|------|--------|--------------|----------|
/// | 单行中文 | 12 | 15 | 18 | 3 |
/// | 长英文自动换行 | 12 | 30 | 34 | 4 |
/// | 三行显式换行 | 12 | 45 | 48 | 3 |
/// | 三行显式换行 | 15 | 54 | 59 | 5 |
/// | 长英文自动换行 | 15 | 36 | 42 | 6 |
/// | 三行显式换行 | 18 | 63 | 69 | 6 |
/// | 长英文自动换行 | 18 | 42 | 48 | 6 |
/// | 20 号字单行 | 20 | 23 | 25 | 2 |
///
/// 余量稳定在个位数，反过来证明两边的换行结果一致 —— 否则会差整整一行。
///
/// > v1.3.9 返工：上面这张表只在 8~20 号测过，早期拿 `max(6, ceil(字号 × 0.5))`
/// > 往大字号线性外推，结果 72 号时框里白白多出 39 点。现在余量是**常数**
/// > （`textPadding = 3`），8~72 号实测全部不裁切。详见 `textPadding` 的注释。
enum FreeTextLayout {

    /// 默认字号。
    ///
    /// 定 15 而不是 PDF 注释惯用的 12，是因为实测 12 号在"适合宽度"的显示倍率下太糊：
    /// 按真实栅格化倍率（1.4×）量，12 号文字的中间调像素占比 0.266，18 号只有 0.193 ——
    /// 字越小，笔画越容易被栅格化抹成灰边，观感就越糊。
    static let defaultFontSize: CGFloat = 15

    /// 可选字号（反推字号时的候选；界面上是连续滑条，不再受这几档限制）
    static let fontSizeChoices: [(label: String, size: CGFloat)] = [
        ("小", 12), ("中", 15), ("大", 18),
    ]

    /// 字号允许范围（界面的滑条 + 手动加减都限定在这里）
    static let fontSizeRange: ClosedRange<CGFloat> = 8...72

    /// 可选字体族。
    ///
    /// 只挑**确认能在 macOS 上建出来**的（实测 `NSFont(name:)` 全部成功）。
    /// 空串代表系统默认字体（中文环境下就是苹方）。
    ///
    /// 不全量列 `availableFontFamilies` 的原因：那是几百个名字、还混着一堆
    /// 装饰体和符号字体，做成菜单根本没法挑。
    static let fontFamilies: [(name: String, label: String)] = [
        ("", "系统默认"),
        ("PingFang SC", "苹方"),
        ("Songti SC", "宋体"),
        ("Heiti SC", "黑体"),
        ("Kaiti SC", "楷体"),
        ("STSong", "华文宋体"),
        ("STKaiti", "华文楷体"),
        ("Hiragino Sans GB", "冬青黑体"),
        ("Helvetica", "Helvetica"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Arial", "Arial"),
        ("Times New Roman", "Times New Roman"),
        ("Georgia", "Georgia"),
        ("Courier New", "Courier New"),
        ("Verdana", "Verdana"),
        ("Menlo", "Menlo"),
        ("Futura", "Futura"),
        ("Baskerville", "Baskerville"),
    ]

    /// 按族名 + 粗体 / 斜体取字体。
    ///
    /// 实测的坑：
    /// - `NSFont(name:)` 对族名和 PostScript 名都能用（"PingFang SC" → PingFangSC-Regular）。
    /// - `withSymbolicTraits` **返回的是非可选** `NSFontDescriptor`（这个 SDK 的签名），
    ///   但据此建 `NSFont` **可能失败、也可能返回同一个字面** —— 必须看字体名是否真的变了。
    ///
    /// ## ⚠️ 不做"合成斜体"（试过，反而更糟）
    ///
    /// 中文字体大多没有斜体面（苹方/宋体/黑体/楷体/冬青实测都没有）。试过两条合成路线，
    /// **都不行**：
    /// - `NSFontDescriptor.withMatrix(斜切矩阵)` + `NSFont(descriptor:size:)` ——
    ///   斜切矩阵下**一个像素都画不出来**（实测墨迹为空），而且 `descriptor.matrix` 读回来还是 nil；
    /// - CoreText 的 `.obliqueness` 属性 —— 在 `CTLineDraw` 路径上**完全没有效果**
    ///   （正体和"斜体"的像素倾斜量一模一样）。
    ///
    /// 所以这里**只做真实字面的切换**；某个族没有斜体时，界面上把「斜体」按钮置灰
    /// （见 `supportsItalic(family:)`），而不是给一个"按了没反应"的按钮。
    static func font(ofSize size: CGFloat,
                     family: String = "",
                     bold: Bool = false,
                     italic: Bool = false) -> NSFont {
        let base: NSFont = family.isEmpty
            ? .systemFont(ofSize: size)
            : (NSFont(name: family, size: size) ?? .systemFont(ofSize: size))

        guard bold || italic else { return base }

        // 1) 首选 symbolic traits —— 标准族（Helvetica / Times / Arial…）能换到真字面
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if let candidate = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size),
           candidate.fontName != base.fontName {
            return candidate
        }

        // 2) 字体管理器兜底（按 trait 找同族的对应字面）
        var converted = base
        if bold { converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask) }
        if italic { converted = NSFontManager.shared.convert(converted, toHaveTrait: .italicFontMask) }
        return converted
    }

    /// 这个字体族有没有**真的斜体面**。没有就别给用户一个"按了没反应"的按钮。
    static func supportsItalic(family: String) -> Bool {
        supports(family: family, trait: .italicFontMask)
    }

    /// 有没有粗体面（`STSong` / `STKaiti` 实测各只有一个成员，连粗体都没有）
    static func supportsBold(family: String) -> Bool {
        family.isEmpty || supports(family: family, trait: .boldFontMask)
    }

    private static func supports(family: String, trait: NSFontTraitMask) -> Bool {
        guard !family.isEmpty else { return true }   // 系统字体两种都有
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.contains { member in
            guard let raw = member[3] as? UInt else { return false }
            return raw & trait.rawValue != 0
        }
    }

    /// 默认字号的字体
    static var font: NSFont { font(ofSize: defaultFontSize) }

    /// 从批注读出实际使用的字体（族名 / 粗斜体 / 字号）。
    ///
    /// 族名和粗斜体存在自定义键里（见 `AnnotationAppearance`）—— 因为
    /// **`annotation.font` 写盘再读回来恒为 Helvetica 12**，原生属性指望不上。
    /// 别的应用建的批注没有那些键，就按系统默认字体处理（字号仍靠框高反推）。
    static func font(of annotation: PDFAnnotation) -> NSFont {
        let snapshot = AnnotationAppearance.storedSnapshot(of: annotation)
        return font(ofSize: effectiveFontSize(of: annotation),
                    family: snapshot?.fontFamily ?? "",
                    bold: snapshot?.isBold ?? false,
                    italic: snapshot?.isItalic ?? false)
    }

    /// PDFKit 绘制 FreeText 时的左右内边距（实测 3 点）
    static let horizontalInset: CGFloat = 3

    /// 文本四周的留白（点）。
    ///
    /// ## 为什么不再按字号线性外推（v1.3.9 返工）
    ///
    /// 旧版是 `max(6, ceil(字号 × 0.5))` —— 系数只在 8~18 号标定过，往后是线性外推。
    /// 实测底部留白**随字号一路涨**（框里白多出来的部分，肉眼看就是"背景比文字大一圈"）：
    ///
    /// | 字号 | 8 | 12 | 15 | 18 | 24 | 36 | 48 | 72 |
    /// |------|---|----|----|----|----|----|----|----|
    /// | 旧留白 | 7 | 7 | 9 | 10 | 13 | 20 | 26 | **39** |
    ///
    /// 72 号时框里白白多出 39 点，用户的原话是「背景的计算大小有些对不上，
    /// 特别是字体最大的时候就更明显了」。
    ///
    /// 实际上 CoreText 自己算的高度（`boundingRect(options: .usesFontLeading)`，
    /// 与 `CTFramesetterSuggestFrameSizeWithConstraints` 实测完全一致）**已经把行高、
    /// 上下伸部都算进去了** —— 再叠一个字号相关的余量纯属重复。
    /// 改成常数后实测 8~72 号全部不裁切，底部留白稳定在 3~6 点：
    ///
    /// | 字号 | 8 | 12 | 15 | 18 | 24 | 36 | 48 | 72 |
    /// |------|---|----|----|----|----|----|----|----|
    /// | 新留白 | 3 | 3 | 4 | 3 | 4 | 4 | 5 | 6 |
    static let textPadding: CGFloat = 3


    /// 框的最大宽度，超出就换行
    static let maximumWidth: CGFloat = 320

    /// 框的最小宽度，避免单字变成一个细条
    static let minimumWidth: CGFloat = 44

    /// 按内容算出自适应尺寸。
    ///
    /// **换行策略（v1.3.9 明确下来的）**：宽度由内容里**最长的一行**决定，
    /// 只有它超过 `maxWidth` 时才自动折行。也就是说 ——
    /// 用户自己敲的 `\n` 决定换行，我们不去替他折。
    ///
    /// - Parameters:
    ///   - text: 批注内容（可含 `\n`）
    ///   - font: 字号，需与写入批注的 `annotation.font` 一致
    ///   - maxWidth: 换行宽度上限，超出部分才自动换行
    static func fittedSize(for text: String,
                           font: NSFont = FreeTextLayout.font,
                           maxWidth: CGFloat = FreeTextLayout.maximumWidth) -> CGSize {
        let display = text.isEmpty ? " " : text

        // 1. 先量"不换行时的自然宽度" —— 无限宽下单行排出，`\n` 仍然生效，
        //    所以这里拿到的是**最长那一行**的宽度
        let natural = measure(display, font: font, maxWidth: .greatestFiniteMagnitude).width

        // +2 点是刻意留的：可用宽度若正好等于文本宽度，末字可能被挤到下一行，
        // 那样高度就少算一行 → 又被裁。宁可宽一点。
        let width = min(maxWidth, max(natural + horizontalInset * 2 + 2, minimumWidth))

        // 2. 用**最终的可用宽度**重新量高度 —— 换行结果取决于它，不能复用第一步的结果
        let available = max(width - horizontalInset * 2, 1)
        let textHeight = measure(display, font: font, maxWidth: available).height

        // 3. 上取整到整点，避免半像素导致的边缘裁切
        return CGSize(width: width.rounded(.up),
                      height: (textHeight + textPadding).rounded(.up))
    }

    /// 在**固定宽度**下，算出让内容放得下所需的高度。
    ///
    /// 与 `fittedSize` 的区别：这里不改宽度。用于"只加高"的批量修复 ——
    /// 批量操作可能碰到别的应用创建的批注，保持宽度不动最保守。
    static func requiredHeight(for text: String,
                               font: NSFont = FreeTextLayout.font,
                               width: CGFloat) -> CGFloat {
        let display = text.isEmpty ? " " : text
        let available = max(width - horizontalInset * 2, 1)
        return (measure(display, font: font, maxWidth: available).height
                + textPadding).rounded(.up)
    }

    /// 按内容算出自适应 bounds，左上角对齐到 `origin`。
    static func fittedBounds(for text: String,
                             at origin: CGPoint,
                             font: NSFont = FreeTextLayout.font,
                             maxWidth: CGFloat = FreeTextLayout.maximumWidth) -> CGRect {
        CGRect(origin: origin, size: fittedSize(for: text, font: font, maxWidth: maxWidth))
    }

    /// 把现有批注的框调整到恰好容纳内容，返回调整后的 bounds。
    /// 返回 nil 表示无需调整。
    ///
    /// ## ⚠️ 宽度**不能**拿"现有宽度"当上限（v1.3.9 修的）
    ///
    /// 旧版是 `maxWidth: max(bounds.width, minimumWidth)` —— 意思是"只收窄、不撑宽"。
    /// 听起来保守，实际有个致命问题：**改小字号会把宽度永久压小**。
    /// 15 号 → 20 号 → 15 号，第二次的宽度回不到第一次的值，
    /// 用户的原话是「变小之后再变大，就回不到原来的样式了」。
    ///
    /// 现在宽度**只由内容决定**（最长的那一行），上限是这条批注**记录下来的**
    /// `maxWidth`（见 `maxWidth(of:)`）：
    ///
    /// - 内容里没有换行符 → 不换行；
    /// - 最长的一行超过 `maxWidth` → 才自动换行；
    /// - 字号来回改，宽度就来回跟着内容走，**可逆**。
    static func fittedBounds(forExisting bounds: CGRect,
                             text: String,
                             font: NSFont? = nil,
                             maxWidth: CGFloat = FreeTextLayout.maximumWidth) -> CGRect? {
        guard !text.isEmpty else { return nil }

        let resolvedFont = font ?? FreeTextLayout.font
        let size = fittedSize(for: text, font: resolvedFont, maxWidth: maxWidth)

        if abs(size.width - bounds.width) < 0.5 && abs(size.height - bounds.height) < 0.5 {
            return nil
        }
        // 以中心为基准缩放，批注不会"跳"到别的地方
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - 每条批注自己的"最大宽度"

    /// 换行宽度的上限，存在批注自己的键里。
    ///
    /// 为什么要存：新建时上限取的是"可见区域宽的 90%，且不超过 `maximumWidth`"，
    /// 是**那一刻**的值。事后重排若拿不到它，就只能拿现有宽度凑合 ——
    /// 那正是"改小字号就再也长不回去"的根源。
    private static let maxWidthKey = PDFAnnotationKey(rawValue: "PRMaxWidth")

    /// 记下这条批注的换行宽度上限
    static func setMaxWidth(_ width: CGFloat, on annotation: PDFAnnotation) {
        annotation.setValue(String(Double(width)), forAnnotationKey: maxWidthKey)
    }

    /// 读这条批注的换行宽度上限。别的应用建的批注没有这个键 → 退回 `maximumWidth`。
    static func maxWidth(of annotation: PDFAnnotation) -> CGFloat {
        guard let text = annotation.value(forAnnotationKey: maxWidthKey) as? String,
              let value = Double(text), value >= minimumWidth else { return maximumWidth }
        return CGFloat(value)
    }

    /// 读出批注实际使用的字号。
    ///
    /// **不能只信 `annotation.font`。** 实测：从磁盘载入的批注，PDFKit 会把 `font`
    /// 报成默认的 Helvetica 12（15 号、18 号都被报成 12），`/DA` 也读不到了 ——
    /// 但**渲染尺寸其实是保留的**（存盘重载后墨迹高度不变）。
    /// 只看 `font` 会把框按 12 号算，比实际需要矮，一执行"适应内容"就把批注改坏。
    ///
    /// 所以依次尝试：
    /// 0. **我们自己存的 `/PRFontSize`**（见 `AnnotationAppearance`）—— 最准，优先
    /// 1. `/DA`（DefaultAppearance）里的 `N Tf`
    /// 2. **按现有框高反推**：我们建的批注，高度就是按公式算出来的，
    ///    取"算出来的高度 ≥ 现有高度"里最小的那个字号；都不满足则取最大的。
    ///    这个方向偏保守 —— 宁可把字号猜大（框偏大），也不猜小（框偏小会裁）
    /// 3. `annotation.font`
    /// 4. 默认字号
    static func effectiveFontSize(of annotation: PDFAnnotation) -> CGFloat {
        if let stored = storedFontSize(of: annotation) { return stored }
        if let size = defaultAppearanceFontSize(of: annotation), size > 0 {
            return size
        }

        let content = annotation.contents ?? ""
        let bounds = annotation.bounds
        if !content.isEmpty, bounds.width > 0, bounds.height > 0 {
            // 候选从"旧的三档"扩成整段可调范围 —— 字号现在是连续的，
            // 只试 12/15/18 会把 20 号猜成 18 号。
            let candidates = Array(stride(from: fontSizeRange.lowerBound,
                                          through: fontSizeRange.upperBound, by: 1))
            for size in candidates {
                let needed = requiredHeight(for: content, font: font(ofSize: size), width: bounds.width)
                if needed >= bounds.height - 0.5 { return size }
            }
            // 现有框比最大字号所需的还高（典型是旧版固定 48 高的框）→ 取最大字号，
            // 这样"适应内容"只会把框收到最大字号所需的高度，不会误伤内容
            if let largest = candidates.last { return largest }
        }

        if let size = annotation.font?.pointSize, size > 0 { return size }
        return defaultFontSize
    }

    /// 我们自己存下来的字号（`/PRFontSize`）
    private static func storedFontSize(of annotation: PDFAnnotation) -> CGFloat? {
        guard let text = annotation.value(forAnnotationKey: AnnotationAppearance.Key.fontSize) as? String,
              let size = Double(text), size > 0 else { return nil }
        return CGFloat(size)
    }

    /// 从 `/DA` 里取字号，形如 `/.AppleSystemUIFont 15 Tf 0 g`
    static func defaultAppearanceFontSize(of annotation: PDFAnnotation) -> CGFloat? {
        guard let da = annotation.value(forAnnotationKey: .defaultAppearance) as? String else {
            return nil
        }
        return fontSize(inDefaultAppearance: da)
    }

    /// 解析 `/Helvetica 15 Tf 0 g` 这类串里的字号（"Tf" 前一个 token）
    static func fontSize(inDefaultAppearance da: String) -> CGFloat? {
        let tokens = da.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        for (index, token) in tokens.enumerated() where token == "Tf" && index >= 1 {
            if let size = Double(tokens[index - 1]), size > 0 {
                return CGFloat(size)
            }
        }
        return nil
    }

    /// 把矩形钳在页面范围内（与拖动批注用的是同一套约束）
    static func clampToPage(_ rect: CGRect, pageBounds: CGRect) -> CGRect {
        let x = min(max(rect.minX, pageBounds.minX), max(pageBounds.minX, pageBounds.maxX - rect.width))
        let y = min(max(rect.minY, pageBounds.minY), max(pageBounds.minY, pageBounds.maxY - rect.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
    }

    private static func measure(_ text: String, font: NSFont, maxWidth: CGFloat) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let rect = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}
