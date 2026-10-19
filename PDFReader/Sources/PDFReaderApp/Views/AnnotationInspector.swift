import SwiftUI
import PDFKit

/// 右侧属性栏：选中一条标注后出现，用来改颜色 / 透明度 / 线宽 / 字体，以及删除。
///
/// 所有修改都是**即时生效**的（改一下立刻应用到批注上），不搞"确定/取消"，
/// 因为标注是页面上看得见的东西，改完马上能看出对不对；改坏了可以 Cmd+Z？——
/// 目前没有撤销，所以删除键旁边额外标了提示。
///
/// **文本注释有两套颜色**：背景色（`style.color`）和文字颜色（`style.textColor`），
/// 这里分成两栏，避免"改了颜色发现文字也跟着变"。
@MainActor
struct AnnotationInspector: View {

    @ObservedObject var viewModel: PDFViewModel
    /// 观察偏好：外框颜色改了要立刻生效
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject var style: AnnotationStyle
    let item: AnnotationItem

    init(viewModel: PDFViewModel, item: AnnotationItem) {
        self.viewModel = viewModel
        self.style = viewModel.style
        self.item = item
    }

    private var kind: AnnotationItem.Kind { item.kind }

    /// 线宽对形状/涂鸦/直线/签名有意义；文字标注靠字号
    private var supportsLineWidth: Bool {
        switch kind {
        case .ink, .square, .circle, .line: return true
        default: return false
        }
    }

    private var isFreeText: Bool { kind == .freeText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    colorSection
                    if isFreeText { textColorSection }
                    if kind != .note { opacitySection }
                    if supportsLineWidth { lineWidthSection }
                    if isFreeText { fontSection }
                    if !item.content.isEmpty { contentSection }
                }
                .padding(12)
            }

            Divider()
            footer
        }
        // 右栏和左栏一样属于"外框"（见 `AppChrome`）—— 只改一边会不对称
        .background(preferences.chromeColor)
    }

    // MARK: - 头部

    /// 头部：图标 + 类型 + 页码。
    ///
    /// ⚠️ 右边**不放"关闭属性栏"的 X**（v1.3.46 去掉）—— 顶栏右侧那个按钮就是这个作用，
    /// 两处各放一个只会让人犹豫该点哪个。注意"取消选中"这条行为没变：删掉标注之后
    /// 这一栏仍然**留白**（有意如此，栏位一收一放会让页面宽度抖一下）。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                Text("第 \(item.pageIndex + 1) 页")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 各属性

    /// 主颜色。对文本注释来说这是**背景色**。
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(isFreeText ? "背景色" : "颜色")
            // `wraps: true` —— 属性栏窄到 200 时这一排色点必须能折行，
            // 否则它会溢出、盖住分隔条，栏宽就拖不动了（见 `ColorSwatchRow.wraps`）
            ColorSwatchRow(selection: $style.color,
                           isTransparent: $style.isTransparent,
                           onChange: applyStyle,
                           diameter: 16,
                           showsTransparent: AnnotationStyle.supportsTransparent(kind),
                           wraps: true)
        }
    }

    /// 文字注释的**文字**颜色（和背景分开）
    private var textColorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("文字颜色")
            ColorSwatchRow(selection: $style.textColor,
                           isTransparent: .constant(false),
                           onChange: applyStyle,
                           diameter: 16,
                           allowsOpacityInPicker: true,
                           showsTransparent: false,
                           wraps: true)
        }
    }

    private var opacitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // sliderWidth: nil = 占满栏宽。属性栏宽度是用户可拖的，固定宽度会溢出
            OpacitySlider(value: $style.opacity, onChange: applyStyle, sliderWidth: nil)
            if kind == .highlight {
                Text("高亮在 100% 时也只有一半浓度 —— 实心会糊住正文")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if isFreeText && !style.isTransparent {
                Text("只影响背景，文字颜色在上面单独调")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var lineWidthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("线宽")
            LineWidthControl(lineWidth: $style.lineWidth,
                             previewColor: style.paint(for: kind),
                             onChange: applyStyle,
                             sliderWidth: nil)
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("字体")
            FontControls(style: style, onChange: applyStyle)
        }
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("内容")
            Text(item.displayContent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func applyStyle() {
        viewModel.applyStyleToSelection()
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 6) {
            if isFreeText {
                Button {
                    viewModel.fitFreeTextToContent(item)
                } label: {
                    Label("框适应内容大小", systemImage: "arrow.up.and.down.text.horizontal")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }

            Button(role: .destructive) {
                viewModel.deleteSelectedAnnotation()
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)

            Text("也可以直接按 Delete 键")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }
}
