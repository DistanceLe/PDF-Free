import Foundation

@MainActor
class BookmarksStore: ObservableObject {
    static let shared = BookmarksStore()

    private let bookmarksKey = "pdfreader.bookmarks"
    private let progressKey = "pdfreader.progress"
    /// 阅读位置：页号 + 页内纵向比例（存成 `"3:0.42"`，见 `saveReadingPosition`）
    private let positionKey = "pdfreader.readingPosition"
    /// 缩放比例（同一个文件下次打开时接着用）
    private let zoomKey = "pdfreader.zoom"

    @Published var bookmarks: [Bookmark] = []

    struct Bookmark: Codable, Identifiable, Equatable {
        let id: UUID
        let documentURL: URL
        let pageIndex: Int
        let title: String
        let createdAt: Date
    }

    private init() {
        load()
    }

    // MARK: - 书签

    func add(documentURL: URL, pageIndex: Int, title: String) {
        // 避免重复
        if bookmarks.contains(where: { $0.documentURL == documentURL && $0.pageIndex == pageIndex }) {
            return
        }
        let bookmark = Bookmark(
            id: UUID(),
            documentURL: documentURL,
            pageIndex: pageIndex,
            title: title,
            createdAt: Date()
        )
        bookmarks.append(bookmark)
        save()
    }

    func remove(id: UUID) {
        remove(ids: [id])
    }

    /// 批量删除（列表多选后用）。
    ///
    /// 只在最后写一次盘 —— 逐条调 `remove(id:)` 会存 N 次，删几十条时没必要。
    func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let doomed = Set(ids)
        bookmarks.removeAll { doomed.contains($0.id) }
        save()
    }

    func remove(documentURL: URL, pageIndex: Int) {
        bookmarks.removeAll { $0.documentURL == documentURL && $0.pageIndex == pageIndex }
        save()
    }

    /// 页面顺序 / 数量变了之后，把书签重新指认到新页号上（v1.3.42）。
    ///
    /// - Parameter updates: 书签 id → 新页号。**没在里面的**表示它原来指着的那一页
    ///   已经不在文档里了 → 这条书签一并去掉（留着只会指向一个不存在的位置）。
    ///
    /// 为什么要重指而不是不管：删掉第 2 页之后，原本指向第 5 页的书签如果不动，
    /// 就会跑到"现在的第 5 页"（＝原来的第 6 页内容）—— 静悄悄指错比丢掉更糟。
    func reassignPages(documentURL: URL, updates: [UUID: Int]) {
        var result: [Bookmark] = []
        for bookmark in bookmarks {
            guard bookmark.documentURL == documentURL else {
                result.append(bookmark)          // 别的文件的，原样留着
                continue
            }
            guard let newIndex = updates[bookmark.id] else {
                continue                          // 它指着的那一页没了 → 书签一并去掉
            }
            result.append(Bookmark(id: bookmark.id,
                                   documentURL: bookmark.documentURL,
                                   pageIndex: newIndex,
                                   title: bookmark.title,
                                   createdAt: bookmark.createdAt))
        }
        guard result != bookmarks else { return }
        bookmarks = result
        save()
    }

    func isBookmarked(documentURL: URL, pageIndex: Int) -> Bool {
        bookmarks.contains(where: { $0.documentURL == documentURL && $0.pageIndex == pageIndex })
    }

    func bookmarks(for documentURL: URL) -> [Bookmark] {
        bookmarks.filter { $0.documentURL == documentURL }
    }

    // MARK: - 阅读进度

    func saveProgress(documentURL: URL, pageIndex: Int) {
        var allProgress = UserDefaults.standard.dictionary(forKey: progressKey) as? [String: Int] ?? [:]
        allProgress[documentURL.absoluteString] = pageIndex
        UserDefaults.standard.set(allProgress, forKey: progressKey)
    }

    func loadProgress(documentURL: URL) -> Int? {
        let allProgress = UserDefaults.standard.dictionary(forKey: progressKey) as? [String: Int] ?? [:]
        return allProgress[documentURL.absoluteString]
    }

    // MARK: - 阅读位置与缩放（v1.3.37）

    /// 记住"看到哪儿了"：页号 + **视口中心在页面里的纵向比例**（0 = 页底、1 = 页顶）。
    ///
    /// ⚠️ 为什么存**比例**而不是绝对坐标：别的工具重新导出过 PDF 之后页面尺寸可能会变，
    /// 存绝对点就漂到别处去了；比例始终落在同一处内容上。
    ///
    /// 和老的 `progress` 分开两个 key —— 老数据（只有页号）已经在用户机器上了，
    /// 分开存就不用做迁移，读的时候先看新 key、没有再看老的。
    func saveReadingPosition(documentURL: URL, pageIndex: Int, offsetRatio: Double) {
        var all = UserDefaults.standard.dictionary(forKey: positionKey) as? [String: String] ?? [:]
        all[documentURL.absoluteString] = "\(pageIndex):\(offsetRatio)"
        UserDefaults.standard.set(all, forKey: positionKey)
        // 老 key 也顺手更新：别的地方（比如"最近打开"列表）读它时不该拿到过期页号
        saveProgress(documentURL: documentURL, pageIndex: pageIndex)
    }

    func loadReadingPosition(documentURL: URL) -> (pageIndex: Int, offsetRatio: Double)? {
        let all = UserDefaults.standard.dictionary(forKey: positionKey) as? [String: String] ?? [:]
        guard let raw = all[documentURL.absoluteString] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let page = Int(parts[0]),
              let ratio = Double(parts[1]) else { return nil }
        return (page, ratio)
    }

    /// 缩放比例。存 `Double`（不是百分比字符串），读回来直接能用。
    func saveZoom(documentURL: URL, scaleFactor: Double) {
        var all = UserDefaults.standard.dictionary(forKey: zoomKey) as? [String: Double] ?? [:]
        all[documentURL.absoluteString] = scaleFactor
        UserDefaults.standard.set(all, forKey: zoomKey)
    }

    func loadZoom(documentURL: URL) -> Double? {
        let all = UserDefaults.standard.dictionary(forKey: zoomKey) as? [String: Double] ?? [:]
        return all[documentURL.absoluteString]
    }

    // MARK: - 持久化

    /// 写盘，并广播"书签已经改了"。
    ///
    /// ⚠️ 为什么要有这个广播，而不是让观察者盯 `@Published var bookmarks`：
    /// **`@Published` 是在 willSet 里发通知的** —— 收到那一刻数组还是旧的，
    /// 拿它去算"当前页有没有书签"只会算到改动**前**的状态（等于没刷新）。
    /// 这个广播是"改完、存完"之后发的，观察者同步去读就是新值。
    ///
    /// 另一个好处：`NotificationCenter` 天然支持多个观察者（每个标签页一个 viewModel）。
    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
        NotificationCenter.default.post(name: .pdfBookmarksDidChange, object: nil)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }
}
