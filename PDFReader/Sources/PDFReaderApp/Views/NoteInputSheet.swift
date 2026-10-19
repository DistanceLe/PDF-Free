import SwiftUI

/// 便签 / 文本注释的输入弹窗。
///
/// 文本注释在这里就能把**字体、字号、加粗/斜体、文字颜色**定好 ——
/// 这些设置直接写在 `AnnotationStyle` 上（工具条和右侧属性栏读的是同一份），
/// 所以弹窗里调完，后续新建的注释也沿用。
@MainActor
struct NoteInputSheet: View {

    enum Kind {
        case note
        case freeText
        /// 双击**已有**的文本注释 → 改里面的文字（v1.3.73）
        case editFreeText

        var title: String {
            switch self {
            case .note: return "添加便签"
            case .freeText: return "添加文本注释"
            case .editFreeText: return "编辑文本注释"
            }
        }

        var placeholder: String {
            switch self {
            case .note: return "输入批注内容…"
            case .freeText: return "输入要在页面上显示的文本…"
            case .editFreeText: return "修改这段文字…"
            }
        }

        var hint: String {
            switch self {
            case .note: return "便签以图标形式贴在页面上，鼠标悬停或双击可查看内容。"
            case .freeText: return "文本注释直接显示在页面可见区域内，可事后拖动调整位置。"
            case .editFreeText:
                return "改完点「保存」。宽度不会变（要改宽度直接拖注释的左右边框），高度会跟着内容自动调整。"
            }
        }

        var icon: String {
            switch self {
            case .note: return "note.text"
            case .freeText: return "text.bubble"
            case .editFreeText: return "pencil.and.outline"
            }
        }

        /// 编辑已有内容（按钮显示「保存」而不是「添加」）
        var isEditing: Bool { self == .editFreeText }
    }

    let kind: Kind
    @ObservedObject var style: AnnotationStyle
    /// 打开时预填的文字 —— 编辑已有注释用。空串 = 新建。
    let initialText: String
    let onConfirm: (String) -> Void

    /// ⚠️ 得**手写**这个 init。Swift 自动生成的那个 memberwise init 会把
    /// "有默认值的 `let` 属性"排除在外（`let` 一旦赋值就不能改，编译器干脆不给参数）——
    /// 那样 `initialText` 就传不进来了。
    init(kind: Kind,
         style: AnnotationStyle,
         initialText: String = "",
         onConfirm: @escaping (String) -> Void) {
        self.kind = kind
        self.style = style
        self.initialText = initialText
        self.onConfirm = onConfirm
    }

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: kind.icon)
                Text(kind.title)
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .focused($isFocused)

                if kind == .freeText {
                    fontSection
                    textColorRow
                    preview
                }

                Text(kind.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(kind.isEditing ? "保存" : "添加") {
                    onConfirm(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear {
            // 编辑已有注释时预填内容。`text` 是 @State，每次弹 sheet 都是新实例，
            // 所以这里实际上就是"打开即填"。
            if text.isEmpty { text = initialText }
            isFocused = true
        }
    }

    // MARK: - 文本注释的字体设置

    private var fontSection: some View {
        HStack(spacing: 10) {
            Text("字体")
                .font(.caption)
                .foregroundStyle(.secondary)
            FontControls(style: style, onChange: {})
            Spacer()
        }
    }

    private var textColorRow: some View {
        HStack(spacing: 10) {
            Text("文字颜色")
                .font(.caption)
                .foregroundStyle(.secondary)
            ColorSwatchRow(selection: $style.textColor,
                           isTransparent: .constant(false),
                           onChange: {},
                           diameter: 16,
                           allowsOpacityInPicker: true,
                           showsTransparent: false)
            Spacer()
        }
    }

    /// 用当前字体渲染一行预览，"选了什么"一眼可见
    private var preview: some View {
        HStack(spacing: 8) {
            Text("预览")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "示例文字 Aa 123" : String(text.prefix(28)))
                .font(Font(style.font))
                .foregroundStyle(Color(nsColor: style.textPaint))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: style.paint(for: .freeText)))
                )
                .lineLimit(1)
            Spacer()
        }
    }
}
