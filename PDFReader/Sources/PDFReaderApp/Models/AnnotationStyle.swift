import AppKit
import PDFKit

/// 标注的外观设置（颜色 / 透明度 / 线宽 / 字体），跟着工具条走。
///
/// 每个标签页一份（放在 `PDFViewModel` 上），但会写进 `UserDefaults`，
/// 所以下次打开还是上次选的颜色和线宽。
///
/// ## 颜色的两个"透明"概念，别搞混
///
/// - **`opacity`（不透明度滑条）**：给主颜色加 alpha。0 = 全透明，1 = 实色。
/// - **`isTransparent`（调色板里的「透明」按钮）**：**完全不上色**。
///   对文本注释就是"无背景色"，对形状就是"看不见"。
///
/// 另外：高亮和文本注释的背景**有各自的基础半透明系数**（`highlightBaseAlpha` /
/// `backgroundBaseAlpha`），滑条是在这个基础上再乘 —— 因为"实心高亮糊住正文"
/// 不是用户想要的默认值。所以高亮的滑条范围实际是 0~50%。
@MainActor
final class AnnotationStyle: ObservableObject {

    /// 预设颜色（微信图片编辑那套基础上加了红/绿/蓝之外的常用色）
    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemPurple, .labelColor,
    ]

    /// 高亮的**基础**透明度（实测 PDFKit 的高亮观感也在 0.4~0.5 这一带）
    static let highlightBaseAlpha: CGFloat = 0.5

    /// 文本注释背景的**基础**透明度
    static let backgroundBaseAlpha: CGFloat = 0.22

    // MARK: - 颜色

    @Published var color: NSColor {
        didSet {
            // 选了具体颜色就不该还是"透明"状态
            if isTransparent { isTransparent = false }
            save()
        }
    }

    /// 主颜色的不透明度（0…1）
    @Published var opacity: CGFloat = 1 {
        didSet { save() }
    }

    /// 完全不上色（无背景 / 无描边）
    @Published var isTransparent: Bool = false {
        didSet { save() }
    }

    /// 文本注释的**文字**颜色，和背景色分开（背景色用的是 `color`）
    @Published var textColor: NSColor = .textColor {
        didSet { save() }
    }

    // MARK: - 线宽

    /// 线宽不再是固定档位，滑条连续可调
    @Published var lineWidth: CGFloat = 3 {
        didSet { save() }
    }

    static let lineWidthRange: ClosedRange<CGFloat> = 0.5...24

    /// 形状是否填充（描边始终画）
    @Published var isFilled: Bool = false {
        didSet { save() }
    }

    // MARK: - 字体

    /// 字体族名；空串 = 系统默认
    @Published var fontFamily: String = "" {
        didSet { save() }
    }

    @Published var fontSize: CGFloat = FreeTextLayout.defaultFontSize {
        didSet { save() }
    }

    @Published var isBold: Bool = false {
        didSet { save() }
    }

    @Published var isItalic: Bool = false {
        didSet { save() }
    }

    /// 当前设置下的字体
    var font: NSFont {
        FreeTextLayout.font(ofSize: fontSize, family: fontFamily,
                            bold: isBold, italic: isItalic)
    }

    /// 字体菜单里显示的名字
    var fontFamilyLabel: String {
        FreeTextLayout.fontFamilies.first { $0.name == fontFamily }?.label ?? "系统默认"
    }

    // MARK: - 取色

    /// 某个批注种类实际用的颜色（含透明判断与基础半透明）。
    ///
    /// - 高亮：`opacity × highlightBaseAlpha`（实心高亮会糊住正文）
    /// - 文本注释：这是**背景**色，`opacity × backgroundBaseAlpha`
    /// - 其余（形状 / 涂鸦 / 直线 / 便签）：就是 `opacity`
    ///
    /// 「透明」时返回**带 alpha 0 的正常 sRGB 颜色**，而不是 `NSColor.clear` ——
    /// `clear` 是**单色（Monochrome）**色彩空间，交给 PDFKit 会变成空色，
    /// 自绘时 CGContext 还会拿黑色兜底（详见 `AnnotationRenderer.transparentThreshold`）。
    func paint(for kind: AnnotationItem.Kind) -> NSColor {
        guard !isTransparent else { return color.withAlphaComponent(0) }
        let base: CGFloat
        switch kind {
        case .highlight: base = Self.highlightBaseAlpha
        case .freeText: base = Self.backgroundBaseAlpha
        default: base = 1
        }
        return color.withAlphaComponent(opacity * base)
    }

    /// 这个种类有没有"透明"这回事（描边类的没有颜色就是看不见）
    static func supportsTransparent(_ kind: AnnotationItem.Kind) -> Bool {
        AnnotationRenderer.supportsTransparent(kind)
    }

    /// 文本注释用的文字颜色（自带 alpha，走系统取色器就能调）
    var textPaint: NSColor { textColor }

    // MARK: - 持久化

    private enum Key {
        static let color = "pdfreader.style.color"
        static let opacity = "pdfreader.style.opacity"
        static let transparent = "pdfreader.style.transparent"
        static let textColor = "pdfreader.style.textColor"
        static let lineWidth = "pdfreader.style.lineWidth"
        static let fontSize = "pdfreader.style.fontSize"
        static let fontFamily = "pdfreader.style.fontFamily"
        static let bold = "pdfreader.style.bold"
        static let italic = "pdfreader.style.italic"
        static let filled = "pdfreader.style.filled"
    }

    init() {
        let defaults = UserDefaults.standard

        color = Self.color(from: defaults, key: Key.color) ?? .systemRed
        textColor = Self.color(from: defaults, key: Key.textColor) ?? .textColor

        // 老版本没存过 opacity → 读出来是 0，要按"没有"处理（否则一打开就全透明）
        let storedOpacity = defaults.double(forKey: Key.opacity)
        opacity = defaults.object(forKey: Key.opacity) == nil ? 1 : CGFloat(storedOpacity)
        isTransparent = defaults.bool(forKey: Key.transparent)

        let storedWidth = defaults.double(forKey: Key.lineWidth)
        lineWidth = storedWidth > 0 ? CGFloat(storedWidth) : 3

        let storedFont = defaults.double(forKey: Key.fontSize)
        fontSize = storedFont > 0 ? CGFloat(storedFont) : FreeTextLayout.defaultFontSize
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? ""
        isBold = defaults.bool(forKey: Key.bold)
        isItalic = defaults.bool(forKey: Key.italic)

        isFilled = defaults.bool(forKey: Key.filled)
    }

    private static func color(from defaults: UserDefaults, key: String) -> NSColor? {
        guard let data = defaults.data(forKey: key),
              let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return nil }
        return stored
    }

    private func save() {
        let defaults = UserDefaults.standard
        for (key, value) in [(Key.color, color), (Key.textColor, textColor)] {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false) {
                defaults.set(data, forKey: key)
            }
        }
        defaults.set(Double(opacity), forKey: Key.opacity)
        defaults.set(isTransparent, forKey: Key.transparent)
        defaults.set(Double(lineWidth), forKey: Key.lineWidth)
        defaults.set(Double(fontSize), forKey: Key.fontSize)
        defaults.set(fontFamily, forKey: Key.fontFamily)
        defaults.set(isBold, forKey: Key.bold)
        defaults.set(isItalic, forKey: Key.italic)
        defaults.set(isFilled, forKey: Key.filled)
    }

    // MARK: - 套用

    /// 当前设置对应的外观快照（写进批注、也用于存盘）。
    ///
    /// ⚠️ 存的是**落到批注上的最终 alpha**（已经乘过高亮/背景的基础系数），
    /// 不是滑条上的原始值 —— 因为自绘和 PDFKit 都直接读 `annotation.color`。
    /// 反过来的换算在 `adopt(from:kind:)` 里做。
    func snapshot(for kind: AnnotationItem.Kind) -> AnnotationAppearance.Snapshot {
        AnnotationAppearance.Snapshot(opacity: paint(for: kind).alphaComponent,
                                      textColor: textPaint,
                                      fontFamily: fontFamily,
                                      fontSize: fontSize,
                                      isBold: isBold,
                                      isItalic: isItalic)
    }

    /// 选中已有标注时，把它的外观读进设置里，免得"改颜色"要先猜当前值
    func adopt(from annotation: PDFAnnotation, kind: AnnotationItem.Kind) {
        // 注意：annotation.color 在 Swift 里是**非可选**的 NSColor
        // （PDFAnnotation.h 的 color 属性没有 nullable 标注）
        let stored = AnnotationAppearance.storedSnapshot(of: annotation)
        let alpha = stored?.opacity ?? annotation.color.alphaComponent

        color = annotation.color.withAlphaComponent(1)
        switch kind {
        case .highlight: opacity = min(1, alpha / Self.highlightBaseAlpha)
        case .freeText:  opacity = min(1, alpha / Self.backgroundBaseAlpha)
        default:         opacity = alpha
        }
        isTransparent = alpha <= 0.001

        // 文字颜色只对文本注释有意义（形状的 fontColor 是噪音）
        if kind == .freeText, let text = stored?.textColor ?? annotation.fontColor {
            textColor = text
        }

        if let width = annotation.border?.lineWidth, width > 0 {
            lineWidth = width
        }

        if kind == .freeText {
            let snapshot = stored ?? .default
            fontSize = FreeTextLayout.effectiveFontSize(of: annotation)
            fontFamily = snapshot.fontFamily
            isBold = snapshot.isBold
            isItalic = snapshot.isItalic
        }
    }
}
