import Foundation
import PDFKit

@MainActor
class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()

    private let key = "recentDocuments"
    private let maxCount = 10

    @Published var urls: [URL] = []

    private init() {
        load()
    }

    func add(_ url: URL) {
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > maxCount {
            urls = Array(urls.prefix(maxCount))
        }
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        save()
    }

    func clear() {
        urls.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - 持久化

    /// 生成书签。
    ///
    /// - 沙箱 `.app` 带 `com.apple.security.files.bookmarks.app-scope` 权限，能生成**带安全作用域**的书签。
    /// - 非沙箱构建（`swift build` 出来的可执行文件）没有该权限，`bookmarkData(options: .withSecurityScope)`
    ///   会直接抛 `Required entitlement ... is missing or false`。此时退化为普通书签 ——
    ///   至少「最近打开」还能记录路径并可打开，而不是静默存进一个空数组。
    ///
    /// 生成时持有作用域：沙箱下若在作用域外生成，书签会缺少访问权限
    /// （下次启动能解析出路径，却读不到内容）。
    private func makeBookmark(for url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        if let scoped = try? url.bookmarkData(options: .withSecurityScope) {
            return scoped
        }
        return try? url.bookmarkData()
    }

    /// 解析书签。先按带安全作用域解析（沙箱 `.app` 存的），失败再按普通书签解析。
    ///
    /// ⚠️ 两种解析方式**不能混用**：实测用 `.withSecurityScope` 去解析普通书签会直接失败。
    private func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url, isStale)
        }
        var plainStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &plainStale
        ) {
            return (url, plainStale)
        }
        return nil
    }

    private func save() {
        let stored = urls.compactMap { makeBookmark(for: $0) }
        UserDefaults.standard.set(stored, forKey: key)
    }

    private func load() {
        guard let stored = UserDefaults.standard.array(forKey: key) as? [Data] else { return }

        var loaded: [URL] = []
        // 与 loaded 一一对应；有过期项时用重建后的数据替换，保证两边下标对齐
        var refreshed: [Data] = []
        var hasStale = false

        for data in stored {
            guard let resolved = resolveBookmark(data) else { continue }

            if resolved.isStale, let rebuilt = makeBookmark(for: resolved.url) {
                loaded.append(resolved.url)
                refreshed.append(rebuilt)
                hasStale = true
                continue
            }

            loaded.append(resolved.url)
            refreshed.append(data)
        }

        urls = loaded
        if hasStale {
            UserDefaults.standard.set(refreshed, forKey: key)
        }
    }
}

// MARK: - 最近打开文件的首页缩略图（v1.3.48）

/// 「打开文件」那一页用的缩略图：每个最近文件取**第 1 页**渲染成小图。
///
/// ## 为什么必须异步 + 缓存
///
/// `PDFDocument(url:)` 要读整个文件、`thumbnail(of:for:)` 还要再渲染一页 ——
/// 一份几十页的 PDF 实测要几十到几百毫秒。放主线程就是"一打开 app 先卡一下"。
/// 所以：**后台渲染，主线程只查缓存**；还没好的那格先显示占位，
/// 渲染完发一次 `objectWillChange`，那一格自己就刷新了。
///
/// ## 为什么每张图要 `startAccessingSecurityScopedResource`
///
/// 沙箱里从"安全作用域书签"解析出来的 URL，**不 start 一下是读不到内容的** ——
/// 能拿到路径，但 `PDFDocument(url:)` 直接返回 nil。症状就是缩略图永远出不来。
///
/// ## 为什么后台单独开一份 `PDFDocument`
///
/// 不复用主线程那份（那份是当前打开的文档）。各线程各开各的，不共享 PDFKit 对象。
@MainActor
final class RecentThumbnailStore: ObservableObject {

    static let shared = RecentThumbnailStore()

    /// 请求尺寸给得比显示大一截，Retina 下不糊
    private static let requestSize = CGSize(width: 300, height: 420)

    private let cache = NSCache<NSString, NSImage>()
    /// 正在后台渲染的（同一张图别排队好几次 —— body 每次求值都会来这里问一遍）
    private var inFlight: Set<String> = []
    /// 渲染失败过的（文件被删了 / 没权限）—— 不反复重试，免得一直转圈
    private var failed: Set<String> = []

    private init() {
        cache.countLimit = 60
    }

    /// 拿缩略图：有就立刻返回；没有就返回 nil 并**开始后台渲染**。
    func image(for url: URL) -> NSImage? {
        let path = url.path
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard !inFlight.contains(path), !failed.contains(path) else { return nil }
        startRender(url: url, path: path)
        return nil
    }

    /// 这一格是不是正在加载（失败的不算，免得一直显示"加载中"）
    func isLoading(_ url: URL) -> Bool {
        inFlight.contains(url.path)
    }

    /// 某个文件被移出"最近"时，单独清掉它那张
    func forget(_ url: URL) {
        let path = url.path
        cache.removeObject(forKey: path as NSString)
        failed.remove(path)
    }

    /// 「清除最近」时整片清掉
    func removeAll() {
        cache.removeAllObjects()
        failed.removeAll()
        objectWillChange.send()
    }

    // MARK: - 后台渲染

    /// 渲染用的**串行**队列。
    ///
    /// ⚠️ **不能并发。** PDFKit 内部是有锁的，多张图同时渲染会互相抢；更要命的是
    /// **主线程那边也用 PDFKit**（打开文件、`reloadTOC`、PDFView 绘制）。
    /// 实测 v1.3.48：首次打开文件时出现 **2.2~2.5 秒**的主线程慢轮次
    ///（活动 = "重载目录列表"），时间点正好和十来张缩略图并发渲染重合。
    ///
    /// 串行 + 每张之间让一下，主线程就不会被饿住。
    private static let renderQueue = DispatchQueue(label: "pdfreader.recent-thumbnails",
                                                   qos: .utility)

    private func startRender(url: URL, path: String) {
        inFlight.insert(path)
        let size = Self.requestSize
        // 页面底色**在这里（主线程）读好**再传给后台 —— 后台那条线程不能碰
        // `AppPreferences`（`@MainActor`）。传 hex 字符串而不是 `NSColor`，
        // 纯粹是为了好穿过并发检查（值类型，天经地义地 Sendable）。
        let backgroundHex = AppPreferences.shared.pageBackgroundHex
        Self.renderQueue.async {
            let rendered = Self.render(url: url, size: size, backgroundHex: backgroundHex)
            // 让出一点时间：PDFKit 的锁刚释放，主线程可能正等着它
            Thread.sleep(forTimeInterval: 0.06)
            Task { @MainActor in
                let store = RecentThumbnailStore.shared
                store.inFlight.remove(path)
                if let image = rendered.image {
                    store.cache.setObject(image, forKey: path as NSString)
                    Diagnostics.shared.record("最近缩略图：渲染完成 \(Int(image.size.width))×"
                                              + "\(Int(image.size.height))「\(url.lastPathComponent)」")
                } else {
                    store.failed.insert(path)
                    Diagnostics.shared.record("最近缩略图：拿不到「\(url.lastPathComponent)」"
                                              + "（文件被删了，或者书签权限失效）")
                }
                store.objectWillChange.send()
            }
        }
    }

    /// 仅供自动化验证：串行队列里现在还有多少张排着
    var pendingCount: Int { inFlight.count }

    /// 在后台线程跑：**自己开一份 `PDFDocument`**，不碰主线程那一份。
    private nonisolated static func render(url: URL, size: CGSize, backgroundHex: String) -> RenderedThumbnail {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        // 图片没有 PDF 骨架，得先包成单页 PDF 才渲染得出缩略图（v1.3.66）。
        // 底色跟内容区用同一个（v1.3.67）—— 不然缩略图里透明处是白的、
        // 内容区里是灰的，两处对不上，用户会以为哪儿坏了。
        let background = ImageDocument.color(hex: backgroundHex) ?? .white
        guard let document = PDFDocument(url: url) ?? ImageDocument.makeDocument(from: url, background: background),
              let page = document.page(at: 0) else { return RenderedThumbnail(image: nil) }
        return RenderedThumbnail(image: page.thumbnail(of: size, for: .cropBox))
    }
}

/// 把 `NSImage` 带过 `Sendable` 检查：它只在后台**造**、到主线程**用**，中间不共享。
private struct RenderedThumbnail: @unchecked Sendable {
    let image: NSImage?
}
