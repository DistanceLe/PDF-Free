import Foundation
import PDFKit

/// 批注在列表面板中的展示模型。
struct AnnotationItem: Identifiable {

    enum Kind: String, CaseIterable {
        case highlight = "高亮"
        case underline = "下划线"
        case strikeOut = "删除线"
        case note = "便签"
        case freeText = "文本注释"
        case ink = "涂鸦"
        case square = "矩形"
        case circle = "圆形"
        // 「直线」和「箭头」在 PDF 里是**同一个子类型**（Line），靠端点线型区分，
        // 所以这里用一个名字把两种都涵盖
        case line = "直线 / 箭头"
        /// 「图章」—— 系统预览、Adobe 里那个盖章工具就是它（`/Stamp`）。
        /// ⚠️ 加它的直接原因：用户用预览盖了两个章，我们的列表里**一条都没有**
        ///（页面照常画得出来，因为 PDFKit 认它），见 `isUserAnnotation` 的说明。
        case stamp = "图章"
        case other = "其他"

        // 下面三个**不是用户批注**，是 PDF 的结构性噪音（便签的附属弹窗、链接、表单字段）。
        // 它们只用来"被过滤掉"，不会出现在批注列表里。
        case popup = "弹出注释"
        case link = "链接"
        case widget = "表单字段"

        var icon: String {
            switch self {
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strikeOut: return "strikethrough"
            case .note: return "note.text"
            case .freeText: return "text.bubble"
            case .ink: return "scribble"
            case .square: return "rectangle"
            case .circle: return "circle"
            case .line: return "line.diagonal.arrow"
            case .stamp: return "seal"
            case .other: return "questionmark.square.dashed"
            case .popup: return "bubble.left"
            case .link: return "link"
            case .widget: return "rectangle.and.pencil.and.ellipsis"
            }
        }

        /// 能否用鼠标拖动改变位置。
        ///
        /// 只有「自带矩形框、框内就是全部内容」的批注才适合拖动：
        /// 便签（图标框）、文本注释（文本框）、涂鸦/签名（笔迹外框）、矩形、圆、箭头。
        ///
        /// 高亮 / 下划线 / 删除线**故意排除** —— 它们是锚定在正文文字上的，
        /// 直接搬走矩形框会让标注和文字脱节，看起来像是标错了地方。
        var isDraggable: Bool {
            switch self {
            case .note, .freeText, .ink, .square, .circle, .line, .stamp: return true
            // 高亮那三种锚在正文文字上，不能直接搬框；`.other` 和结构性噪音
            //（popup / link / widget）也都不给拖
            default: return false
            }
        }

        /// 能否在页面上直接点选。
        ///
        /// 高亮/下划线/删除线**不在此列**：它们在正文上，点一下应该优先做文字选择
        /// （不然高亮区域里的文字就没法选中复制了）。要改它们请在批注列表里选。
        var isSelectableOnPage: Bool { isDraggable }

        /// 外观可调的种类（颜色 / 线宽 / 字号）
        var hasEditableStyle: Bool {
            switch self {
            case .note, .freeText, .ink, .square, .circle, .line,
                 .highlight, .underline, .strikeOut:
                return true
            default:
                return false
            }
        }
    }

    let pageIndex: Int
    let kind: Kind
    let content: String
    let date: Date?
    let annotation: PDFAnnotation

    var id: ObjectIdentifier { ObjectIdentifier(annotation) }

    /// 便签类批注没有直接内容时，回退显示占位文案
    var displayContent: String {
        content.isEmpty ? kind.rawValue : content
    }

    /// 是否为用户在阅读器里添加的批注。
    ///
    /// ## 为什么是**黑名单**（v1.3.63 改过来的）
    ///
    /// 原来是白名单：只认我们自己支持的那 9 种，其余归成 `.other` 然后**扔掉**。
    /// 后果是**别人加的批注看不见** —— 用户报"用系统预览盖的两个图章，
    /// 我们这个 app 的列表里没有"，那两条是 `/Stamp`，正好在白名单外。
    /// （页面上还能看到它们，因为那就是标准 PDF 批注，PDFKit 自己会画。）
    ///
    /// 现在只排除**确实不是批注**的结构性噪音：便签的附属弹窗、链接、表单字段。
    /// 其余一律当用户批注收下 —— 不认识的类型归 `.other` 展示，
    /// **总比"用户明明看得见却列不出来"强**。
    var isUserAnnotation: Bool {
        switch kind {
        case .popup, .link, .widget:
            return false
        default:
            return true
        }
    }

    init(pageIndex: Int, annotation: PDFAnnotation) {
        self.pageIndex = pageIndex
        self.annotation = annotation
        self.kind = Kind(subtype: annotation.type)
        self.content = Self.textContent(of: annotation)
        self.date = annotation.modificationDate
    }

    private static func textContent(of annotation: PDFAnnotation) -> String {
        if let contents = annotation.contents, !contents.isEmpty {
            return contents
        }
        return annotation.widgetStringValue ?? ""
    }
}

extension AnnotationItem.Kind {
    /// 注意：`PDFAnnotationSubtype.xxx.rawValue` 形如 `"/Highlight"`（PDF 名称对象带前导斜杠），
    /// 而 `PDFAnnotation.type` 返回的是 `"Highlight"`（无斜杠）。两者直接比较**永远不相等**，
    /// 所以这里必须先剥掉斜杠再匹配，否则所有批注都会被归到 `.other`。
    init(subtype: String?) {
        let name = (subtype ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch name {
        case "Highlight": self = .highlight
        case "Underline": self = .underline
        case "StrikeOut": self = .strikeOut
        case "Text": self = .note
        case "FreeText": self = .freeText
        case "Ink": self = .ink
        case "Square": self = .square
        case "Circle": self = .circle
        case "Line": self = .line
        case "Stamp": self = .stamp
        case "Popup": self = .popup
        case "Link": self = .link
        case "Widget": self = .widget
        default: self = .other
        }
    }
}
