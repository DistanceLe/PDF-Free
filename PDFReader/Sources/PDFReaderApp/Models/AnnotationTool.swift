import Foundation
import PDFKit

/// 标注工具。
///
/// 整条标注工具条由这个枚举驱动 —— 加工具只需要在这里加一个 case，
/// 图标、提示、交互方式都从它的属性来。
///
/// 三类交互：
/// - `isDragDraw`：在页面上按住拖动来画（涂鸦 / 直线 / 矩形 / 圆 / 箭头）
/// - `appliesToTextSelection`：作用于当前文字选区（高亮 / 下划线 / 删除线）
/// - `isClickToPlace`：在页面上点一下决定落点，再弹窗输入（文本注释 / 便签 / 签名）
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case strikeOut
    case text
    case ink
    case line
    case rectangle
    case ellipse
    case arrow
    case note
    case signature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "选择"
        case .highlight: return "高亮"
        case .underline: return "下划线"
        case .strikeOut: return "删除线"
        case .text: return "文本注释"
        case .ink: return "画笔涂鸦"
        case .line: return "直线"
        case .rectangle: return "矩形"
        case .ellipse: return "圆形"
        case .arrow: return "箭头"
        case .note: return "便签"
        case .signature: return "手写签名"
        }
    }

    /// 按钮提示。把"怎么用"一起写出来，省得挨个试。
    var hint: String {
        switch self {
        case .select: return "选择：点选已有标注并拖动"
        case .highlight, .underline, .strikeOut: return "\(title)：先选中文字"
        case .text, .note, .signature: return "\(title)：在页面上点一下决定位置"
        case .ink, .line, .rectangle, .ellipse, .arrow: return "\(title)：在页面上按住拖动"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        // 用 character.textbox（带框的字母）而不是 textformat ——
        // 后者是"文字格式/排版"的意思，语义上不是"插入一条文本注释"
        case .text: return "character.textbox"
        case .ink: return "scribble"
        // 直线用「斜线」，箭头用「带箭头的斜线」—— 两个图标本身就能区分
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "line.diagonal.arrow"
        case .note: return "note.text"
        case .signature: return "signature"
        }
    }

    /// 在页面上按住拖动来绘制
    var isDragDraw: Bool {
        switch self {
        case .ink, .line, .rectangle, .ellipse, .arrow: return true
        default: return false
        }
    }

    /// 作用于"当前文字选区"（选好文字后自动套用）
    var appliesToTextSelection: Bool {
        switch self {
        case .highlight, .underline, .strikeOut: return true
        default: return false
        }
    }

    /// 点一下决定落点，再弹窗输入
    var isClickToPlace: Bool {
        switch self {
        case .text, .note, .signature: return true
        default: return false
        }
    }

    /// 对应的 PDF 批注子类型；作用于文字选区的三种没有独立类型（跟着选区走）
    var subtype: PDFAnnotationSubtype? {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        case .ink: return .ink
        case .line: return .line
        case .rectangle: return .square
        case .ellipse: return .circle
        case .arrow: return .line
        default: return nil
        }
    }

    /// 画线类工具（只有箭头的**末端**带三角）
    var hasArrowHead: Bool { self == .arrow }

    /// 这个工具会产出哪种批注。
    ///
    /// 用来决定"某个样式选项对这个工具有没有意义" —— 比如「透明」只对带背景的
    /// （高亮 / 文本注释）有意义，对描边类的没有颜色就是看不见。
    var producedKind: AnnotationItem.Kind? {
        switch self {
        case .select: return nil
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        case .text: return .freeText
        case .note: return .note
        case .ink, .signature: return .ink
        case .line, .arrow: return .line
        case .rectangle: return .square
        case .ellipse: return .circle
        }
    }
}
