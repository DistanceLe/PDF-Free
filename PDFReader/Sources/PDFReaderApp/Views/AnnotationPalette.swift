import SwiftUI
import PDFKit

/// 标注工具条 —— 只在编辑模式出现。
///
/// 左边是工具本身（固定），右边是"画笔属性"（颜色 / 不透明度 / 线宽 / 字体，可横向滚动）——
/// 属性项比以前多了一倍多（多了不透明度、字体、直线），窄窗口下不滚动会被挤爆。
/// 工具分组与 `AnnotationTool` 的三类交互一一对应，加工具只需要改那个枚举。
@MainActor
struct AnnotationPalette: View {

    @ObservedObject var viewModel: PDFViewModel
    @ObservedObject var style: AnnotationStyle

    init(viewModel: PDFViewModel) {
        self.viewModel = viewModel
        self.style = viewModel.style
    }

    private var tools: [AnnotationTool] {
        [.select, .highlight, .underline, .strikeOut,
         .text, .ink, .line, .rectangle, .ellipse, .arrow, .note, .signature]
    }

    /// 哪些工具用得上字体设置（文本注释）
    private var usesFont: Bool { viewModel.activeTool == .text }

    /// 「透明」只对**带背景/填充**的批注有意义（高亮、文本注释背景）。
    /// 描边类的（形状 / 涂鸦 / 直线 / 下划线…）没有颜色就是看不见，不给这个选项。
    private var allowsTransparent: Bool {
        let kind = viewModel.activeTool.producedKind ?? viewModel.selectedAnnotation?.kind
        guard let kind else { return false }
        return AnnotationStyle.supportsTransparent(kind)
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tools) { tool in
                toolButton(tool)
            }

            divider

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ColorSwatchRow(selection: $style.color,
                                   isTransparent: $style.isTransparent,
                                   onChange: applyToSelection,
                                   diameter: 14,
                                   showsTransparent: allowsTransparent)

                    OpacitySlider(value: $style.opacity, onChange: applyToSelection, sliderWidth: 80)

                    if usesFont {
                        FontControls(style: style, onChange: applyToSelection, compact: true)
                    } else {
                        LineWidthControl(lineWidth: $style.lineWidth,
                                         previewColor: style.paint(for: .square),
                                         onChange: applyToSelection,
                                         sliderWidth: 100)
                    }
                }
                .padding(.vertical, 1)
            }

            Spacer(minLength: 0)

            if viewModel.hasSelection {
                Label("已选中 1 项 · 按 Delete 删除", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var divider: some View {
        Divider().frame(height: 18)
    }

    /// 改完样式立刻套到选中的标注上（没选中就只改"下次用的样式"）
    private func applyToSelection() {
        viewModel.applyStyleToSelection()
    }

    // MARK: - 工具按钮

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isActive = viewModel.activeTool == tool
        return Button {
            select(tool)
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 14))
                .frame(width: 28, height: 24)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
                // ⚠️⚠️ **这一行不能省。**
                //
                // `Button` 的命中区默认只认 label 里**不透明**的内容 —— 未激活时底色是
                // `Color.clear`（完全透明），于是命中区**只剩图标的笔画**。
                // 而 `line.diagonal.arrow`（就是用户说的"线条箭头"）在 14pt 下
                // 那根斜线只有一两个点宽，按偏一点就落空 ——
                // 「经常点了没反应，要再点一次才行」就是这么来的。
                //
                // 激活之后底色变成不透明的强调色，命中区**突然**覆盖整块 28×24，
                // 所以"再点一次"往往就中了，看起来特别随机。
                // `frame` 只是撑开布局，**不扩大命中区**；`contentShape` 才是。
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.hint)
    }

    private func select(_ tool: AnnotationTool) {
        // 再点一次已激活的工具 = 退出，回到选择工具
        viewModel.activeTool = (viewModel.activeTool == tool) ? .select : tool
    }
}
