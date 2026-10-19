import AppKit

/// 屏幕度量：把 PDF 的「1 点 = 1/72 英寸」换算成屏幕上的**界面点**。
///
/// ## 为什么需要它
///
/// PDFKit 的 `scaleFactor` 语义是「**1 个 PDF 点占几个界面点**」——
/// `scaleFactor = 1.0` 时 1 PDF 点 = 1 界面点。
///
/// 可 1 个界面点在物理上**并不等于** 1/72 英寸（PDF 规范里 1 点 = 1/72 英寸），
/// 那要看你屏幕多大：这台 27" 4K 屏上 2560 界面点对应 599mm，
/// 也就是 1 界面点 ≈ 1/108.5 英寸。
///
/// 于是"实际大小"（＝拿尺子量屏幕，跟纸一样大）在这块屏上是
/// `108.5 / 72 ≈ 1.507`，**不是 1.0**。
///
/// 预览.app / Adobe 的「100% / 实际大小」用的就是这个口径。我们原来把它写死成
/// `1.0`，于是标着 100% 的页面其实只有真实尺寸的 **66%** ——
/// 用户看到的就是"同一个 100%，你们这边明显小一截"。
///
/// ## 这个值拿得准吗
///
/// 实测这台机器：`CGDisplayScreenSize` 报 599.3×340.2mm，LG 27" 4K 面板真实可视区
/// 约 597×336mm，吻合到 0.5% 以内。所以 108.5 这个逻辑 DPI 是**可信**的。
///
/// ⚠️ 但虚拟显示器 / 老显示器上这个接口会返回 0 或者胡编的数（曾经在 5K 屏上算出
/// 过 54dpi）—— 与其给个错的，不如老实退回 `1.0`（＝改之前的行为），见 `compute`。
@MainActor
enum ScreenMetrics {

    /// 每块屏算一次就够（DPI 不会变）。键是 `CGDirectDisplayID`。
    private static var cache: [CGDirectDisplayID: CGFloat] = [:]

    /// 「实际大小」对应多少 `scaleFactor` —— 也就是"1 个 PDF 点该占几个界面点"。
    ///
    /// 传 `nil` 时用主屏。窗口还没建出来的时候只能这样。
    static func actualSizeScale(for screen: NSScreen?) -> CGFloat {
        guard let screen = screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 1 }
        let id = CGDirectDisplayID(number.uint32Value)
        if let cached = cache[id] { return cached }
        let value = compute(for: screen, displayID: id)
        cache[id] = value
        return value
    }

    private static func compute(for screen: NSScreen, displayID: CGDirectDisplayID) -> CGFloat {
        // ⚠️ 用 `NSDeviceSize` 而不是 `screen.frame.size`：`frame` 是**整块虚拟桌面**
        // 坐标系里的矩形，多屏时非主屏会带上偏移。`NSDeviceSize` 才是这块屏自己的尺寸。
        let points = (screen.deviceDescription[NSDeviceDescriptionKey("NSDeviceSize")] as? NSValue)?.sizeValue
            ?? screen.frame.size

        let millimeters = CGDisplayScreenSize(displayID)
        guard millimeters.width > 1, points.width > 1 else {
            Diagnostics.shared.record("屏幕度量：拿不到物理尺寸（\(millimeters.width)mm），实际大小退回 1.0")
            return 1
        }

        let logicalDPI = points.width / (millimeters.width / 25.4)
        let scale = logicalDPI / 72.0

        // 合理的逻辑 DPI 在 60（超大屏/投影）到 290（手机级 PPI）之间。
        // 出了这个范围说明接口给的数不靠谱 —— 退回 1.0，宁可"不是真的实际大小"，
        // 也不能把一个错几倍的值塞给 `scaleFactor`。
        guard scale.isFinite, (0.8...4.0).contains(scale) else {
            Diagnostics.shared.record(String(format: "屏幕度量：算出的比例 %.3f 不合理，实际大小退回 1.0", scale))
            return 1
        }

        Diagnostics.shared.record(String(format: "屏幕度量：%.0f×%.0f 点 / %.1fmm 宽 → 逻辑DPI=%.1f → "
                                         + "实际大小 scaleFactor=%.4f",
                                         points.width, points.height, millimeters.width, logicalDPI, scale))
        return scale
    }
}
