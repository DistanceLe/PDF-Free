import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 没打开任何文件时显示的那一页（v1.3.48 按参考图重做）。
///
/// 三块，从上到下：
///
/// 1. **标题**「打开文件」；
/// 2. **虚线框** —— 拖文件到这里，或者点里面那个「选择文件」；整页也是拖放目标
///   （鼠标在页面上任何地方松手都算），拖进来时虚线框会高亮 + 变色；
/// 3. **最近打开** —— 每个文件一张**首页缩略图** + 文件名，右上角「清除最近」。
///
/// ## 缩略图是异步来的
///
/// 见 `RecentThumbnailStore`：后台渲染、主线程查缓存。所以最近列表里有大 PDF 时，
/// 这一页也**不会**卡 —— 先显示占位，图好了那一格自己刷新。
///
/// ## 为什么"最近"用的是真实缩略图而不是图标
///
/// 参考图就是这个意思：文件名（尤其英文长名）长得都差不多，
/// 一眼能认出来的是**页面的样子**。
@MainActor
struct EmptyStateView: View {
    @ObservedObject var viewModel: AppViewModel
    /// 最近列表本身（清空 / 移除某一项之后要立刻反映到界面上）
    @ObservedObject private var recents = RecentDocuments.shared
    /// 缩略图（后台渲染完会 `objectWillChange`，那一格据此刷新）
    @ObservedObject private var thumbnails = RecentThumbnailStore.shared

    /// 有文件正拖在页面上 —— 虚线框高亮用
    @State private var isDropTargeted = false

    /// 自适应列宽：窗口窄就少放几列，宽了每格大一点
    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("打开文件")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 12)

                dropZone

                if !recents.urls.isEmpty {
                    recentSection
                        .padding(.top, 24)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 整页都能接住拖进来的文件（虚线框只是"看得见"的那部分）
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - 拖拽 / 选择文件

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26))
                // ⚠️ 三元里两边都得是**同一个类型**：`Color.accentColor` 是 Color，
                //    而 `.tertiary` 在 Color 上是 `HierarchicalShapeStyle`，混着写编译不过。
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

            Text("将文件拖拽至此")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("或")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            // ⚠️ `contentShape` 不能省：`.plain` 样式的按钮命中区只认 label 里
            //    **不透明**的内容，漏掉它的话点两侧的留白不算点中（v1.3.36 的教训）。
            Button {
                viewModel.openDocument()
            } label: {
                Text("选择文件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("选一个或多个 PDF 或图片（也可以直接把文件拖到这一页上）")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    // 走 `DocumentOpener` 而不是直接 `addDocument` ——
                    // 它认得"这个文件已经开在别的窗口里了"这种情况
                    DocumentOpener.open([url])
                }
            }
        }
    }

    // MARK: - 最近打开

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                // ⚠️ 同样要 `contentShape`（按钮底色是半透明，命中区会缩水）
                Button {
                    clearRecents()
                } label: {
                    Text("清除最近")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.16))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清空这个列表（只清记录，不会删掉文件）")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(recents.urls, id: \.self) { url in
                    recentCell(url)
                }
            }
        }
    }

    /// 一格：首页缩略图 + 文件名（**不带扩展名**）。
    ///
    /// 名字里那 `.pdf` 纯属占地方，参考图也是不带后缀的。
    private func recentCell(_ url: URL) -> some View {
        Button {
            DocumentOpener.open([url])
        } label: {
            VStack(spacing: 7) {
                thumbnail(for: url)

                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            // 「打开文件夹」——`activateFileViewerSelecting` 是 macOS 干这事的标准姿势：
            // 它会把**所在目录**开出来，同时**把这一项选中**，一眼就能看到人。
            // （项目里"诊断日志 → 在访达中显示"用的也是它，文案保持一致。）
            //
            // ⚠️ 别拿 `NSWorkspace.shared.open(url.deletingLastPathComponent())` 代替 ——
            // 那样打开目录是打开了，但不会帮你选中，文件一多还得自己找。
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

            Divider()

            Button("移除这一项") {
                RecentDocuments.shared.remove(url)
                RecentThumbnailStore.shared.forget(url)
                Diagnostics.shared.record("从「最近」里移除了「\(url.lastPathComponent)」")
            }
        }
    }

    /// 缩略图那一块。还没渲染好 / 渲染不出来时给个占位，别让格子忽大忽小。
    @ViewBuilder
    private func thumbnail(for url: URL) -> some View {
        ZStack {
            Color.white
            if let image = thumbnails.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(5)
            } else if thumbnails.isLoading(url) {
                ProgressView()
                    .controlSize(.small)
            } else {
                // 文件被删了 / 书签权限失效 —— 给个明确的"这不是 PDF 预览"
                Image(systemName: "doc.text")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
            }
        }
        // 和页面管理那边用同一个比例，看着是一叠纸
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.14))
        )
        .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
    }

    private func clearRecents() {
        let count = recents.urls.count
        RecentDocuments.shared.clear()
        // 缩略图缓存也一起清 —— 不然"清空后再打开几个"会看到旧图
        RecentThumbnailStore.shared.removeAll()
        Diagnostics.shared.record("已清除「最近打开」（原来有 \(count) 项）")
    }
}
