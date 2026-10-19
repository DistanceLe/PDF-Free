import SwiftUI
import AppKit

// MARK: - 颜色

/// 一排颜色圆点 + 「透明」按钮 + 系统取色器。
///
/// 三处复用：标注工具条、右侧属性栏、新建文本注释的弹窗。
@MainActor
struct ColorSwatchRow: View {

    @Binding var selection: NSColor
    /// 是否处于"完全不上色"状态
    @Binding var isTransparent: Bool
    /// 每调一次都要把新样式套到选中的标注上
    let onChange: () -> Void

    var diameter: CGFloat = 16
    /// 系统取色器里要不要带透明度那一栏。
    /// 主颜色有自己的"不透明度"滑条，这里就关掉，免得两处打架；
    /// 文字颜色没有独立滑条，就打开。
    var allowsOpacityInPicker: Bool = false
    /// 要不要显示「透明」按钮（文字颜色没有"透明"这个概念）
    var showsTransparent: Bool = true

    /// 窄容器（右侧属性栏，栏宽最小 200）里要不要**自动换行**。
    ///
    /// ⚠️ 这一排的最小宽度是 **266pt** —— 8 个色点各 `16+3×2 = 22`（178），
    /// 7 个间隔 4（28），「透明」22，取色器 28。再算上属性栏 12×2 的内边距
    /// 就是 **290**，而属性栏最小只有 **200**（可用 176）。
    ///
    /// 不换行的话 SwiftUI 会让内容**溢出**到 `.frame` 外面 —— 而**溢出的部分照样
    /// 接收点击**。它会盖住左边那条 6pt 宽的分隔条，表现就是
    /// **"栏宽拖不动了，得先取消选中标注"**（用户实测报的正是这个）。
    ///
    /// 工具条 / 弹窗那边宽度富余，保持一行（默认 `false`）。
    ///（同一个坑在 `FontControls` 上出现过一次 —— 那次是改成分两行。）
    var wraps: Bool = false

    var body: some View {
        if wraps {
            wrappedRow
        } else {
            singleRow
        }
    }

    private var singleRow: some View {
        HStack(spacing: 4) { entries }
    }

    /// 自适应换行：宽度够时还是一行，窄了才折到第二行
    private var wrappedRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: diameter + 8),
                                      spacing: 4,
                                      alignment: .leading)],
                  alignment: .leading,
                  spacing: 4) {
            entries
        }
    }

    @ViewBuilder
    private var entries: some View {
        ForEach(Array(AnnotationStyle.palette.enumerated()), id: \.offset) { _, color in
            swatch(color)
        }

        if showsTransparent {
            transparentSwatch
        }

        ColorPicker("", selection: customBinding, supportsOpacity: allowsOpacityInPicker)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: diameter + 12)
            .help("自定义颜色")
    }

    private func swatch(_ color: NSColor) -> some View {
        Button {
            selection = color
            isTransparent = false
            onChange()
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle().strokeBorder(
                        isCurrent(color) && !isTransparent ? Color.accentColor
                                                           : Color.primary.opacity(0.15),
                        lineWidth: isCurrent(color) && !isTransparent ? 2.5 : 1
                    )
                )
                // 点击区比圆本身大一圈 —— 只有圆本身能点的话很难点中
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(colorName(color))
    }

    /// 「透明」：一个被斜线划掉的圆点（图形界面的通用画法）
    private var transparentSwatch: some View {
        Button {
            isTransparent = true
            onChange()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .textBackgroundColor))
                Circle()
                    .strokeBorder(isTransparent ? Color.accentColor : Color.primary.opacity(0.25),
                                  lineWidth: isTransparent ? 2.5 : 1)
                Capsule()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: diameter * 0.95, height: 1.6)
                    .rotationEffect(.degrees(-45))
            }
            .frame(width: diameter, height: diameter)
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("透明无色（无背景 / 不上色）")
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: selection) },
            set: { newValue in
                // 统一转到 sRGB，否则和调色板里的颜色比对（isCurrent）会因为
                // 色彩空间不同而判不相等，出现"两个勾选态"
                selection = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                isTransparent = false
                onChange()
            }
        )
    }

    private func isCurrent(_ color: NSColor) -> Bool {
        guard let a = color.usingColorSpace(.sRGB),
              let b = selection.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    private func colorName(_ color: NSColor) -> String {
        switch color {
        case .systemRed: return "红"
        case .systemOrange: return "橙"
        case .systemYellow: return "黄"
        case .systemGreen: return "绿"
        case .systemTeal: return "青"
        case .systemBlue: return "蓝"
        case .systemPurple: return "紫"
        default: return "黑"
        }
    }
}

// MARK: - 不透明度

/// 不透明度滑条（0~100%）。
///
/// 注意：高亮和文本注释背景在这个值之上还有**各自的基础半透明**（见 `AnnotationStyle`），
/// 所以滑条拉到 100% 时高亮是 50% 的淡色 —— 这是有意的，实心高亮会糊住正文。
@MainActor
struct OpacitySlider: View {

    @Binding var value: CGFloat
    let onChange: () -> Void

    var label: String = "不透明度"
    /// nil = 占满可用宽度（属性栏里用，栏宽可变，固定宽度会被挤爆）
    var sliderWidth: CGFloat? = 90

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
            slider
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
        .help("颜色/背景的不透明度")
    }

    @ViewBuilder
    private var slider: some View {
        if let sliderWidth {
            base.frame(width: sliderWidth)
        } else {
            base.frame(maxWidth: .infinity)
        }
    }

    private var base: some View {
        Slider(value: Binding(get: { Double(value) },
                              set: { value = CGFloat($0); onChange() }),
               in: 0...1)
            .controlSize(.small)
    }
}

// MARK: - 线宽

/// 线宽：连续滑条 + 手动加减。
///
/// 以前是 1/2/3/5/8 五档菜单 —— 用户要的是"无极调节 + 也能手动加减"。
@MainActor
struct LineWidthControl: View {

    @Binding var lineWidth: CGFloat
    /// 预览线的颜色（跟着当前颜色走）
    let previewColor: NSColor
    let onChange: () -> Void

    /// nil = 滑条占满剩余宽度（属性栏里用；栏宽是用户可拖的，固定宽度会溢出）
    var sliderWidth: CGFloat? = 110

    private var range: ClosedRange<CGFloat> { AnnotationStyle.lineWidthRange }

    var body: some View {
        HStack(spacing: 6) {
            Text("线宽")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()

            stepButton("minus") { set(lineWidth - 0.5) }

            slider

            stepButton("plus") { set(lineWidth + 0.5) }

            // 数值 + 一条粗细可变的预览线，比纯数字直观
            HStack(spacing: 4) {
                Capsule()
                    .fill(Color(nsColor: previewColor))
                    .frame(width: 20, height: max(min(lineWidth, 14), 1))
                Text(Format.trimmed(lineWidth))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            .frame(height: 16)
            .fixedSize()
        }
        .help("线宽（拖滑条连续调，或用 ± 以 0.5 为步长）")
    }

    @ViewBuilder
    private var slider: some View {
        if let sliderWidth {
            base.frame(width: sliderWidth)
        } else {
            base.frame(maxWidth: .infinity)
        }
    }

    private var base: some View {
        Slider(value: Binding(get: { Double(lineWidth) },
                              set: { set(CGFloat($0)) }),
               in: Double(range.lowerBound)...Double(range.upperBound))
            .controlSize(.small)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 夹在合法范围内再落值（滑条和 ± 都走这里）
    private func set(_ value: CGFloat) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        // 归到 0.5 的整数倍，免得 ± 累加出 3.5000001 这种数
        lineWidth = (clamped * 2).rounded() / 2
        onChange()
    }
}

// MARK: - 字体

/// 字体设置：族 / 字号 / 加粗 / 斜体。
///
/// 两种排布：
/// - **紧凑**（工具条）：一行横排，滑条固定宽度 —— 那里宽度富余，横排更省地方
/// - **非紧凑**（右侧属性栏）：**分两行**。属性栏的宽度是用户可拖的（最小 200），
///   一行横排塞不下（族菜单 96 + 滑条 120 + 步进 + 数值 + 两个开关 ≈ 300），
///   溢出后 SwiftUI 会把整栏撑宽，表现就是「栏宽拖不动了，内容还显示不全」。
@MainActor
struct FontControls: View {

    @ObservedObject var style: AnnotationStyle
    let onChange: () -> Void

    /// 紧凑模式（工具条里用）：族菜单 + 字号 + B/I 挤在一行
    var compact: Bool = false

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                familyMenu
                sizeControl
                boldToggle
                italicToggle
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                familyMenu
                sizeControl
                HStack(spacing: 6) {
                    boldToggle
                    italicToggle
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 这个族有没有粗体面（STSong / STKaiti 实测连粗体都没有）
    private var canBold: Bool { FreeTextLayout.supportsBold(family: style.fontFamily) }
    /// 有没有斜体面（**中文字体基本都没有**，实测苹方/宋体/黑体/楷体/冬青全都没有）
    private var canItalic: Bool { FreeTextLayout.supportsItalic(family: style.fontFamily) }

    private var boldHelp: String { canBold ? "加粗" : "「\(style.fontFamilyLabel)」没有粗体字面" }
    private var italicHelp: String { canItalic ? "斜体" : "「\(style.fontFamilyLabel)」没有斜体字面" }

    private var boldToggle: some View {
        styleToggle("bold", isOn: style.isBold, enabled: canBold, help: boldHelp) { style.isBold = $0 }
    }

    private var italicToggle: some View {
        styleToggle("italic", isOn: style.isItalic, enabled: canItalic, help: italicHelp) { style.isItalic = $0 }
    }

    private var familyMenu: some View {
        Menu {
            ForEach(FreeTextLayout.fontFamilies, id: \.name) { family in
                Button {
                    style.fontFamily = family.name
                    // 换到没有粗/斜体面的字体时，把开关一起关掉 ——
                    // 留着"开着但没效果"的按钮只会让人以为坏了
                    if !FreeTextLayout.supportsBold(family: family.name) { style.isBold = false }
                    if !FreeTextLayout.supportsItalic(family: family.name) { style.isItalic = false }
                    onChange()
                } label: {
                    // 用该字体本身渲染菜单项，"选字体"这件事所见即所得
                    Text(family.label).font(familyPreview(family.name))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "textformat")
                    .font(.system(size: 10))
                Text(style.fontFamilyLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .frame(minWidth: compact ? 70 : 0, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: compact, vertical: false)
        .help("字体")
    }

    private func familyPreview(_ name: String) -> Font {
        Font(FreeTextLayout.font(ofSize: 13, family: name))
    }

    private var sizeControl: some View {
        HStack(spacing: 4) {
            Text("字号")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
            stepButton("minus") { setSize(style.fontSize - 1) }
            slider
            stepButton("plus") { setSize(style.fontSize + 1) }
            Text(Format.trimmed(style.fontSize))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
        }
    }

    @ViewBuilder
    private var slider: some View {
        if compact {
            base.frame(width: 80)
        } else {
            base.frame(maxWidth: .infinity)
        }
    }

    private var base: some View {
        Slider(value: Binding(get: { Double(style.fontSize) },
                              set: { setSize(CGFloat($0)) }),
               in: Double(FreeTextLayout.fontSizeRange.lowerBound)...Double(FreeTextLayout.fontSizeRange.upperBound))
            .controlSize(.small)
    }

    private func styleToggle(_ symbol: String, isOn: Bool, enabled: Bool, help: String,
                             set: @escaping (Bool) -> Void) -> some View {
        Button {
            set(!isOn)
            onChange()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: isOn ? .bold : .regular))
                .frame(width: 20, height: 18)
                .foregroundStyle(isOn ? Color.white : (enabled ? Color.primary : Color.secondary))
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Color.accentColor : Color.clear)
                )
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setSize(_ value: CGFloat) {
        let range = FreeTextLayout.fontSizeRange
        style.fontSize = min(max(value.rounded(), range.lowerBound), range.upperBound)
        onChange()
    }
}

// MARK: - 小工具

enum Format {
    /// 整数就不显示小数点（"3" 而不是 "3.0"）
    static func trimmed(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(Int(rounded.rounded()))
        }
        return String(format: "%.1f", rounded)
    }
}
