import CoreGraphics
import Foundation

/// 标注绘制的几何换算。
///
/// 单独成文件是为了**能单独编进探针实测** —— 这几处坐标系换算光看代码看不出对错，
/// 尤其 Line（箭头）批注的 start/end 是「批注空间」而不是页坐标，
/// 用错坐标系的表现是"拖了半天什么都没画出来"。
enum AnnotationGeometry {

    /// 两个点构成的正规矩形 —— 拖动方向任意（可能从右下往左上拖）
    static func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 一组点的包围盒
    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 箭头（Line 批注）的起终点，换算到**批注空间**（相对 bounds 原点）。
    ///
    /// 实测：`startPoint` / `endPoint` 按批注空间解释，直接用页坐标会什么都画不出来
    /// （`PDFAnnotation.h` 的注释也写了 "Points are specified in annotation space"）。
    static func linePointsInAnnotationSpace(anchor: CGPoint,
                                           current: CGPoint,
                                           bounds: CGRect) -> (start: CGPoint, end: CGPoint) {
        (start: CGPoint(x: anchor.x - bounds.minX, y: anchor.y - bounds.minY),
         end: CGPoint(x: current.x - bounds.minX, y: current.y - bounds.minY))
    }

    /// 涂鸦点 → 批注空间（ink 笔迹坐标同样相对 bounds 原点）
    static func inkPointsInAnnotationSpace(_ points: [CGPoint], bounds: CGRect) -> [CGPoint] {
        points.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
    }

    /// 把「每行一个矩形」的文字选区切成 quad 点。
    ///
    /// 用于高亮 / 下划线 / 删除线这类**文字批注**：跨行选择在 PDF 里是**一组** quad
    /// （每行一段），不是一个大矩形。
    ///
    /// ## 两个实测踩出来的坑（别再踩）
    ///
    /// 1. **坐标必须是批注空间**（相对 `bounds` 原点）。直接塞页坐标进去，
    ///    PDFKit 会把整组 quad 平移出选区 —— 实测"画到选区外 17 行"，
    ///    屏幕上就是标注跑到别的地方去了。
    /// 2. **每个 quad 的四点顺序是「左上、右上、左下、右下」**
    ///    （PDF 32000-1 Table 8.47；PDFKit 自己产出的批注回读也是这个顺序）。
    ///    顺序写错会画成"蝴蝶结"：同一行里上下两段、中间空一条。
    ///
    /// - Parameters:
    ///   - lines: 每行的选区矩形（**页坐标**），空矩形会被跳过
    ///   - bounds: 整条批注的 bounds（页坐标），quad 点是相对它原点算的
    static func quadPoints(forLines lines: [CGRect], bounds: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        for rect in lines where rect.width > 0 && rect.height > 0 {
            let x0 = rect.minX - bounds.minX
            let x1 = rect.maxX - bounds.minX
            let y0 = rect.minY - bounds.minY
            let y1 = rect.maxY - bounds.minY
            points.append(CGPoint(x: x0, y: y1))   // 左上
            points.append(CGPoint(x: x1, y: y1))   // 右上
            points.append(CGPoint(x: x0, y: y0))   // 左下
            points.append(CGPoint(x: x1, y: y0))   // 右下
        }
        return points
    }

    /// 把页面上的一块区域滚到视口正中所需的 clipView 原点。
    ///
    /// 换算关系与锚点缩放/抓手平移同源：`clipView.bounds` 处于 documentView 坐标系，
    /// **1 个单位 = scaleFactor 个屏幕点**，且 y 方向与视图坐标相反。
    ///
    /// - Parameters:
    ///   - current: 当前 `clipView.bounds`
    ///   - targetInView: 目标区域在**视图坐标**下的矩形
    ///   - viewportCenter: 视口中心（视图坐标）
    ///   - scale: `pdfView.scaleFactor`
    static func scrollOriginToCenter(current: CGRect,
                                    targetInView: CGRect,
                                    viewportCenter: CGPoint,
                                    scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return current.origin }
        // 内容需要移动多少屏幕点，目标才会落到视口中心
        let dx = viewportCenter.x - targetInView.midX
        let dy = viewportCenter.y - targetInView.midY

        var origin = current.origin
        origin.x -= dx / scale
        origin.y += dy / scale       // y 相反
        return origin
    }
}
