import AppKit
import PDFKit

/// 批注外观里**PDFKit 存不住的那几项**，用自定义键替它存。
///
/// ## 为什么需要这个（探针实测，不是猜的）
///
/// 用 `PDFDocument.dataRepresentation()` 写盘再读回来，逐项对比：
///
/// | 属性 | 写进去 | 读回来 | 结论 |
/// |------|--------|--------|------|
/// | `annotation.color` 的 **alpha** | 0.5 / 0.3 / 0.4 | **1.0** | ❌ 丢了（alpha=0 例外，会变成"无颜色"） |
/// | `annotation.fontColor` | systemBlue | 灰度黑 | ❌ 丢了 |
/// | `annotation.font` | Helvetica-Bold 20 / PingFangSC-Semibold 18 | **恒为 Helvetica 12** | ❌ 丢了 |
/// | `/DA`（DefaultAppearance） | — | **nil** | ❌ 指望不上 |
/// | **自定义键** `/PRFontFamily` 等 | "Helvetica" | "Helvetica" | ✅ **能往返** |
///
/// 所以：颜色的 RGB 和 `/C` 数组 PDFKit 自己会写，**但 alpha 不会**；
/// 文字颜色和字体更是整个丢掉。这些都改由下面的自定义键承载，
/// 加载时再 `restore` 回原生属性 —— 否则"存盘再打开，高亮变实心、
/// 文字变黑、字体变 Helvetica 12"。
enum AnnotationAppearance {

    /// 一条批注的外观快照（我们关心的全部可存项）
    struct Snapshot {
        /// 主颜色的 alpha（滑条值）
        var opacity: CGFloat
        /// 文字注释的**文字**颜色；非文字批注为 nil
        var textColor: NSColor?
        /// 字体族名；空串 = 系统默认
        var fontFamily: String
        /// 字号
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool

        static let `default` = Snapshot(opacity: 1, textColor: nil, fontFamily: "",
                                        fontSize: FreeTextLayout.defaultFontSize,
                                        isBold: false, isItalic: false)
    }

    /// 自定义键。
    ///
    /// 用 `/PR…` 前缀避免和别的应用撞车（PDF 里未知键会被忽略，不影响互操作）。
    enum Key {
        static let opacity = PDFAnnotationKey(rawValue: "PROpacity")
        static let textColor = PDFAnnotationKey(rawValue: "PRTextColor")
        static let fontFamily = PDFAnnotationKey(rawValue: "PRFontFamily")
        static let fontSize = PDFAnnotationKey(rawValue: "PRFontSize")
        static let fontBold = PDFAnnotationKey(rawValue: "PRFontBold")
        static let fontItalic = PDFAnnotationKey(rawValue: "PRFontItalic")
    }

    // MARK: - 写

    /// 把快照写进批注（自定义键 + 原生属性）。
    static func save(_ snapshot: Snapshot, to annotation: PDFAnnotation) {
        // 存成字符串：实测能稳定往返，也不用操心 PDF 对象类型
        annotation.setValue(String(Double(snapshot.opacity)), forAnnotationKey: Key.opacity)

        if let textColor = snapshot.textColor {
            // 原生属性也设一份，本次会话内 PDFKit 自己画的时候颜色是对的
            annotation.fontColor = textColor
            if let srgb = textColor.usingColorSpace(.sRGB) {
                annotation.setValue(encode(srgb), forAnnotationKey: Key.textColor)
            }
        }

        annotation.setValue(snapshot.fontFamily, forAnnotationKey: Key.fontFamily)
        annotation.setValue(String(Double(snapshot.fontSize)), forAnnotationKey: Key.fontSize)
        annotation.setValue(snapshot.isBold ? "1" : "0", forAnnotationKey: Key.fontBold)
        annotation.setValue(snapshot.isItalic ? "1" : "0", forAnnotationKey: Key.fontItalic)
    }

    // MARK: - 读

    /// 读出我们存过的那一份。**别的应用创建的批注返回 nil** —— 那时不能瞎猜，
    /// 交给原生属性（也就是它们的本来样子）。
    static func storedSnapshot(of annotation: PDFAnnotation) -> Snapshot? {
        guard let opacityText = annotation.value(forAnnotationKey: Key.opacity) as? String,
              let opacity = Double(opacityText) else { return nil }

        return Snapshot(
            opacity: CGFloat(opacity),
            textColor: decodeColor(annotation.value(forAnnotationKey: Key.textColor) as? String),
            fontFamily: (annotation.value(forAnnotationKey: Key.fontFamily) as? String) ?? "",
            fontSize: storedFontSize(of: annotation) ?? FreeTextLayout.defaultFontSize,
            isBold: (annotation.value(forAnnotationKey: Key.fontBold) as? String) == "1",
            isItalic: (annotation.value(forAnnotationKey: Key.fontItalic) as? String) == "1"
        )
    }

    /// 单独抽出来是为了避开 `Double.init` / `CGFloat.init` 的类型推断歧义
    private static func storedFontSize(of annotation: PDFAnnotation) -> CGFloat? {
        guard let text = annotation.value(forAnnotationKey: Key.fontSize) as? String,
              let size = Double(text), size > 0 else { return nil }
        return CGFloat(size)
    }

    // MARK: - 还原

    /// 把存下来的外观套回原生属性。**加载文档后调用一次**。
    ///
    /// 幂等：反复调用结果一样（因为它只做"把 A 复制到 B"）。
    static func restore(on annotation: PDFAnnotation) {
        guard let snapshot = storedSnapshot(of: annotation) else { return }

        // alpha：RGB 是 PDFKit 自己存住的，只差 alpha
        let base = annotation.color.usingColorSpace(.sRGB) ?? annotation.color
        annotation.color = base.withAlphaComponent(snapshot.opacity)

        if let textColor = snapshot.textColor {
            annotation.fontColor = textColor
        }

        // 字体：只在文字注释上有意义（`annotation.font` 读回来恒为 Helvetica 12）
        if AnnotationItem.Kind(subtype: annotation.type) == .freeText {
            annotation.font = FreeTextLayout.font(
                ofSize: snapshot.fontSize,
                family: snapshot.fontFamily,
                bold: snapshot.isBold,
                italic: snapshot.isItalic
            )
        }
    }

    // MARK: - 颜色编解码

    private static func encode(_ color: NSColor) -> String {
        "\(color.redComponent),\(color.greenComponent),\(color.blueComponent),\(color.alphaComponent)"
    }

    private static func decodeColor(_ text: String?) -> NSColor? {
        guard let text else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return NSColor(srgbRed: CGFloat(parts[0]), green: CGFloat(parts[1]),
                       blue: CGFloat(parts[2]), alpha: CGFloat(parts[3]))
    }
}
