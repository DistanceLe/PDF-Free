import Foundation

/// 打印设置。
///
/// 这里只放**系统打印面板没有、或者必须在调起面板之前定好**的选项；
/// 打印机选择、纸张大小、方向、双面、预览交给系统面板，分工不重复。
///
/// `Equatable`：用于驱动打印预览的防抖重建（`.task(id: options)`）。
struct PDFPrintOptions: Equatable {

    // MARK: - 页面范围

    enum RangeMode: String, CaseIterable, Identifiable {
        case all
        case currentPage
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "全部页面"
            case .currentPage: return "当前页"
            case .custom: return "自定义范围"
            }
        }
    }

    // MARK: - 缩放

    enum ScaleMode: String, CaseIterable, Identifiable {
        case fitPage
        case actualSize
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fitPage: return "适合页面"
            case .actualSize: return "实际大小"
            case .custom: return "自定义缩放"
            }
        }
    }

    /// 每张纸可选的页数（1 = 不拼版）
    static let pagesPerSheetChoices = [1, 2, 4, 6, 9]

    // MARK: - 纸张

    enum PaperSize: String, CaseIterable, Identifiable {
        case systemDefault
        case a3
        case a4
        case a5
        case b5
        case letter
        case legal
        case tabloid

        var id: String { rawValue }

        var label: String {
            switch self {
            case .systemDefault: return "跟随系统"
            case .a3: return "A3  297 × 420 mm"
            case .a4: return "A4  210 × 297 mm"
            case .a5: return "A5  148 × 210 mm"
            case .b5: return "B5  176 × 250 mm"
            case .letter: return "Letter  8.5 × 11 in"
            case .legal: return "Legal  8.5 × 14 in"
            case .tabloid: return "Tabloid  11 × 17 in"
            }
        }

        /// 纵向尺寸（点，1pt = 1/72 英寸）。`systemDefault` 返回 nil，表示沿用系统设置。
        var portraitSize: CGSize? {
            switch self {
            case .systemDefault: return nil
            case .a3: return CGSize(width: 841.89, height: 1190.55)
            case .a4: return CGSize(width: 595.28, height: 841.89)
            case .a5: return CGSize(width: 419.53, height: 595.28)
            case .b5: return CGSize(width: 498.90, height: 708.66)
            case .letter: return CGSize(width: 612, height: 792)
            case .legal: return CGSize(width: 612, height: 1008)
            case .tabloid: return CGSize(width: 792, height: 1224)
            }
        }
    }

    enum PaperOrientation: String, CaseIterable, Identifiable {
        case portrait
        case landscape

        var id: String { rawValue }
        var label: String { self == .portrait ? "纵向" : "横向" }
    }

    var rangeMode: RangeMode = .all
    /// 自定义范围输入，例如 "1-3, 5, 8-10"
    var customRange: String = ""
    var scaleMode: ScaleMode = .fitPage
    /// 自定义缩放百分比，100 表示原始大小
    var customScalePercent: Double = 100
    var autoRotate: Bool = true
    var pagesPerSheet: Int = 1
    /// 关闭后打印输出里不含高亮、便签、签名等批注
    var includeAnnotations: Bool = true
    var paperSize: PaperSize = .systemDefault
    var orientation: PaperOrientation = .portrait
}
