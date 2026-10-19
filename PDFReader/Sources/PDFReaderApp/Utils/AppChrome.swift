import AppKit
import SwiftUI

/// 界面「外框」的配色（v1.3.59）。
///
/// ## 为什么要有这个
///
/// 用户的原话："这个整个头部能换一种背景色，因为和内容页都是白色的，看着很杂又不清晰。"
///
/// 实测采样（浅色模式，屏幕取色）：
///
/// | 位置 | 颜色 | 灰阶 |
/// |---|---|---|
/// | 工具栏 | `#E4E4E4` | 228 |
/// | 侧边栏顶部标签栏 | `#EFEFEF` | 239 |
/// | PDF 内容页 | `#FFFFFF` | 255 |
///
/// 三个都挤在"接近白"的那一小段里，**差了二十来阶** —— 控件区和页面糊在一起，
/// 一眼分不出哪儿是"能点的界面"、哪儿是"文档本身"。
///
/// ## 怎么办
///
/// 把**工具栏 + 侧边栏**（也就是"外框"那一圈）统一压到同一个更深的灰上，
/// 内容页保持纯白。这样三层就分开了：外框（深灰）→ 侧边栏内容（中灰）→ 页面（白）。
///
/// ⚠️ 之前两处用的是 `windowBackgroundColor`（系统窗口底，浅色下就是 228 那一档）——
/// 系统用它没问题，问题在**我们的内容页也是白的**，两者挨在一起就没有层次了。
/// 这里换成比它明确深一档的值，并且**深浅两种外观各给一套**（不靠系统默认）。
extension Color {

    /// 内置的默认外框色：浅色 #CCCCCC / 深色 #2E2E2E。
    static let defaultChrome = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // ⚠️ 用 **sRGB 明确值**，不用 `calibratedWhite`：后者是"通用灰"色彩空间，
        //    到显示器上怎么映射说不准，值不好对（注释里写的和屏幕上看到的对不上）。
        //
        // 浅色 #CCCCCC（204）：和页面的白拉开 **51 阶**，隔着半米也分得清
        //（原来用的是系统窗口底 #E4E4E4/228，只差 27 阶 —— 用户说"看着很杂又不清晰"就是它）。
        // 深色 #2E2E2E（46）：比窗口底亮一点，正好把外框"托"起来。
        return isDark ? NSColor(srgbRed: 46.0 / 255, green: 46.0 / 255, blue: 46.0 / 255, alpha: 1)
                      : NSColor(srgbRed: 204.0 / 255, green: 204.0 / 255, blue: 204.0 / 255, alpha: 1)
    })

    /// 当前该用的外框色 —— **用户在设置里改过就用他的**，没改过用内置的（v1.3.61）。
    ///
    /// ⚠️ 视图要用它得先观察 `AppPreferences.shared`（`@ObservedObject`），
    /// 否则改完颜色界面不会立刻刷新。
    @MainActor
    static var appChrome: Color { AppPreferences.shared.chromeColor }

    /// 内置的**页面底色**：跟随系统（浅色白 / 深色近黑）。
    ///
    /// 刻意不写死一个色值 —— 加这个开关之前它就是 `textBackgroundColor`，
    /// 用户不动它就还是原样（深色模式下不该突然变成一张白纸）。
    /// `.textBackgroundColor` 是**动态色**，深浅模式切换时自己会跟着变。
    static let defaultPageBackground = Color(nsColor: .textBackgroundColor)

    /// 从 `#RRGGBB` / `#RRGGBBAA` 建颜色；空串或格式不对返回 nil。
    ///
    /// 自己解析而不用 `NSColor(hex:)` 之类的第三方写法：格式就那么两种，
    /// 而且**必须容错** —— 用户在设置里手敲的时候中间态是不合法的。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// 转成 `#RRGGBB`，用来存进 `UserDefaults`。
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// 「外框」上那条分界线 —— 比 `Divider()` 的存在感稍强一点。
    ///
    /// 外框压深之后其实已经分得开了，但侧边栏和内容都是"一整块"，
    /// 中间那条线还是要看得见，不然拖分割条时没有落点感。
    static let appChromeEdge = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(srgbRed: 26.0 / 255, green: 26.0 / 255, blue: 26.0 / 255, alpha: 1)
                      : NSColor(srgbRed: 184.0 / 255, green: 184.0 / 255, blue: 184.0 / 255, alpha: 1)
    })
}

extension AppPreferences {
    /// 界面上真正该用的外框色：**用户设过就用他的**，没设过用内置的。
    ///
    /// 放在这里而不是 `AppPreferences.swift`：那边只 import AppKit（模型层不引 SwiftUI），
    /// `Color` 和 hex 解析都归这个文件管。
    var chromeColor: Color {
        Color(hex: chromeColorHex) ?? Color.defaultChrome
    }

    /// 文档**页面底色** —— 用户设过就用他的（v1.3.67），没设过跟随系统。
    ///
    /// 它管的是「PDF 页面背后那一层」，也是**透明图片的透明区域**透出来的东西。
    var pageBackgroundColor: Color {
        Color(hex: pageBackgroundHex) ?? Color.defaultPageBackground
    }

    /// 同上，给 `PDFView.backgroundColor` 用的 AppKit 版本。
    ///
    /// ⚠️ 默认那条路直接回 `.textBackgroundColor`，**不要**先把
    /// `Color.defaultPageBackground` 转成 `NSColor` —— 虽然结果看着一样，
    /// 但多绕一道容易在以后被改坏；这里语义也更直白：
    /// "用户没设过 ⇒ 就是系统原本该用的那个动态色"。
    var pageBackgroundNSColor: NSColor {
        ImageDocument.color(hex: pageBackgroundHex) ?? .textBackgroundColor
    }
}
