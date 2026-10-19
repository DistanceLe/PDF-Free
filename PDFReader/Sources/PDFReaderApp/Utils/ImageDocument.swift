import AppKit
import PDFKit
import UniformTypeIdentifiers

/// 让 app 能**看图**（v1.3.66）。
///
/// ## 做法：把图片包成一份"内存里的单页 PDF"
///
/// 没有另写一套图片查看器 —— 那样 ⌥滚轮缩放、空格拖拽、批注、缩略图、最近打开
/// 全部得重来一遍。改成把图片塞进 `PDFPage(image:)`、拼成一份**单页 `PDFDocument`**，
/// 后面那条路（`EditablePDFView` / `PDFViewModel` / `ScrollZoomMonitor` /
/// `SpaceDragPanMonitor` / 批注工具）**一行都不用改**，白拿。
///
/// 实测（4000×3000 的图）：`PDFPage(image:)` 只要 **51ms**，转完渲染一屏 40ms ——
/// 顺手就做完了，不需要异步、不需要进度条。
///
/// ## ⚠️ 两条必须守住的底线
///
/// **1. 图片文档的 `documentURL` 永远是 `nil`。**
///
/// `PDFViewModel.saveAnnotationsToDisk()` 是拿 `document.documentURL` 当落点的 ——
/// 一旦让它指回那张 `.jpg`，用户点一次「保存」就会**把照片覆盖成一个 PDF 文件**。
/// 不设 URL 就是**物理上写不回去**（走 `throw .noFileURL`），
/// 比"记得在某处加个 if"可靠得多。图片的出口只有一个：`PDFViewModel.exportImage()`
/// 里的「导出为图片…」，由用户自己挑新位置。
///
/// **2. 绝不自己维护后缀白名单。**
///
/// 认不认这个文件交给系统的 `UTType`（`conforms(to: .image)`）判断 ——
/// 苹果以后新增什么格式，我们自动就跟上了。
enum ImageDocument {

    /// 系统认得、而且算图片吗。
    ///
    /// 实测（本机 macOS 26）：`png` / `jpg` / `jpeg` / `gif` / `bmp` / `tiff` /
    /// `heic` / `heif` / `webp` / `avif` / `ico` / `psd` / `svg`
    /// **全部** `conforms(to: .image) == true`，主流格式一网打尽。
    ///
    /// ⚠️ `com.adobe.pdf` 实测是 **false**（PDF 不算图片），但这里仍然显式排掉 `pdf`：
    /// 哪天系统改了归类，也不至于把 PDF 当成图片走这条路。
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        guard type != .pdf else { return false }
        return type.conforms(to: .image)
    }

    /// 「打开文件」面板允许选什么 —— `.image` 是个抽象类型，
    /// 面板会自动放行所有 conform 到它的具体格式，不用一个个列。
    static let openableTypes: [UTType] = [.pdf, .image]

    /// 读成一份**单页** PDF 文档。读不出来返回 nil（上层按"打不开"处理）。
    ///
    /// 页面尺寸 = 图片自己的尺寸（没有 DPI 元数据时就是像素数），
    /// 也就是"1 图片像素 = 1 PDF 点"。这样「适合宽度」正好把整张图铺满视口，
    /// 放大时 PDFKit 会重采样，不是一格一格的马赛克。
    ///
    /// - Parameter background: 垫在图片**下面**那层底色（见 `makePage` 里为什么必须垫）。
    static func makeDocument(from url: URL, background: NSColor?) -> PDFDocument? {
        guard let page = makePage(from: url, background: background) else { return nil }
        let document = PDFDocument()
        document.insert(page, at: 0)
        // ⚠️ 千万别在这里 `document.documentURL = url` —— 见类型注释的底线 1
        return document
    }

    /// 生成一页：**先铺底色，再把图片画上去**。
    ///
    /// ## 为什么非得垫这一层
    ///
    /// `PDFView` 在画每一页之前会**把页面擦成白色** —— 头文件 `PDFView.h:263` 原话：
    ///
    /// > Default implementation **erases page to white** and calls:
    /// > `[page drawWithBox:[self displayBox] toContext:context]`.
    ///
    /// 于是图片自己的透明区域到了屏幕上就是白的，跟"图片本来就是白底"**一模一样** ——
    /// 这正是用户报的那件事。那片白**改不掉**（那个方法是给子类 override 的，
    /// 但 Swift 里够不着：`drawPage(_:toContext:)` 报 `obsoleted in Swift 3`）。
    ///
    /// 那就**把底色画进页面内容**：内容先铺一个整页的底色矩形，图片盖在上面 ——
    /// 不透明的地方遮住底色，透明的地方露出来，同时也盖住了 PDFKit 擦的那层白。
    ///
    /// ## 刻意不走 `PDFPage(image:)`
    ///
    /// 那个也写不出底色（它只把图片塞进页面）。这里改用手写 PDF：
    /// `CGContext(consumer:mediaBox:)` → 铺底 → 画图 → 收尾，再让 `PDFDocument(data:)` 读回来。
    /// 实测 4000×3000 的图 51ms 左右，同步做就行。
    ///
    /// - Parameter background: 垫在图片下面那层底色。**传 `nil` = 不铺**（图片自己的透明保留）——
    ///   导出时就这么用：那层是给**屏幕**看的（为了盖住 PDFKit 擦的白），
    ///   烧进用户导出的文件就成了"我明明是张透明图，导出怎么带底色了"。
    static func makePage(from url: URL, background: NSColor?) -> PDFPage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        if let background {
            // 动态色（默认那个 `textBackgroundColor`）要先解析到具体色彩空间，
            // `cgColor` 在脱离绘制环境时不一定给得出值 —— 兜底白，至少不会画出黑的。
            let fill = background.usingColorSpace(.sRGB)?.cgColor ?? NSColor.white.cgColor
            context.setFillColor(fill)
            context.fill(mediaBox)
        }
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()

        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// `#RRGGBB` → `NSColor`。空串或格式不对返回 nil。
    ///
    /// 单写一份不引 SwiftUI（`AppChrome` 里那个 `Color(hex:)` 会）——
    /// 缩略图是在**后台线程**渲染的，那边不该碰 SwiftUI 的类型。
    static func color(hex: String) -> NSColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt64(text, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    /// 原图的**像素**尺寸。
    ///
    /// 导出时拿它定输出分辨率：一张 4000px 的照片加了批注再导出，
    /// 不该缩成 595px 的一页 A4。取不到就返回 nil，由调用方给个保守的倍数。
    static func pixelSize(of url: URL) -> CGSize? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        // `representations` 里可能有好几档（Retina 的 1x/2x），取像素数最大的那档
        let candidates = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        guard let largest = candidates.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        else { return nil }
        return CGSize(width: largest.pixelsWide, height: largest.pixelsHigh)
    }
}
