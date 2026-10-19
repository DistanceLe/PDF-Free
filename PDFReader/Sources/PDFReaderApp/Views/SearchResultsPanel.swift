import SwiftUI
import PDFKit

/// 右侧搜索结果面板。
///
/// 搜索框在顶栏右上角，结果放这里 —— 这样结果列表和页面并列，
/// 点一条就能把命中处滚到页面正中，不用来回切面板。
@MainActor
struct SearchResultsPanel: View {

    @ObservedObject var viewModel: PDFViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.isSearching {
                centered {
                    ProgressView().controlSize(.small)
                    Text("搜索中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if viewModel.searchResults.isEmpty {
                centered {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(viewModel.searchQuery.isEmpty ? "输入关键词开始搜索" : "没有匹配结果")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                list
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("搜索结果")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if !viewModel.searchResults.isEmpty {
                Text("\(max(viewModel.selectedSearchResult + 1, 0)) / \(viewModel.searchResults.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                // ⚠️ 这两个翻页按钮同样要"撑开热区"：11pt 的 chevron 是一根细线，
                // 底下又是透明背景 —— 不给 frame + contentShape 的话，
                // 命中区就只有那一条线，基本点不中。
                Button { viewModel.goToPreviousSearchResult() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("上一个 (⇧⌘G)")
                Button { viewModel.goToNextSearchResult() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("下一个 (⌘G)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { index, selection in
                    Button {
                        viewModel.goToSearchResult(at: index)
                    } label: {
                        row(index: index, selection: selection)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == viewModel.selectedSearchResult
                                  ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .id(index)
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.selectedSearchResult) { _, newValue in
                guard newValue >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// 命中处前后各取多少个字符的上下文。
    ///
    /// 30 是折中：列表这个宽度下大约一两行，既有语境、又不至于把列表撑成长文。
    private let contextRadius = 30

    private func row(index: Int, selection: PDFSelection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let page = selection.pages.first,
                   let document = viewModel.pdfView?.document {
                    Text("第 \(document.index(for: page) + 1) 页")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // 上下文 + 命中词（命中词加底色，和页面上那片搜索高亮是同一个视觉语言）
            Text(highlightedSnippet(for: selection))
                .font(.system(size: 11))
                .lineLimit(3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// 把「前文 + 命中词 + 后文」拼成一段带样式的文本。
    private func highlightedSnippet(for selection: PDFSelection) -> AttributedString {
        let parts = snippetParts(for: selection)

        var leading = AttributedString(parts.leading)
        leading.foregroundColor = .secondary

        var match = AttributedString(parts.match)
        match.backgroundColor = Color.yellow.opacity(0.45)
        match.font = .system(size: 11, weight: .semibold)

        var trailing = AttributedString(parts.trailing)
        trailing.foregroundColor = .secondary

        return leading + match + trailing
    }

    /// 取「命中处附近的一段话」：命中前后的原文 + 命中词本身。
    ///
    /// 关键在 `range(at:on:)` —— 它给出这段 selection 在**该页文本**里的字符范围。
    /// 只拿 `selection.string` 的话只有命中的那几个字（改之前就是这个样子），
    /// 有范围才能精准地往前/往后扩。
    private func snippetParts(for selection: PDFSelection)
    -> (leading: String, match: String, trailing: String) {
        let match = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ("", match.isEmpty ? "（无文本）" : match, "")

        guard let page = selection.pages.first,
              let pageText = page.string, !pageText.isEmpty else { return fallback }

        let ns = pageText as NSString
        let range = selection.range(at: 0, on: page)
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return fallback }

        let start = max(0, range.location - contextRadius)
        let end = min(ns.length, NSMaxRange(range) + contextRadius)

        var leading = collapseWhitespace(
            ns.substring(with: NSRange(location: start, length: range.location - start))
        ).trimmingCharacters(in: .whitespaces)
        var trailing = collapseWhitespace(
            ns.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        ).trimmingCharacters(in: .whitespaces)

        // 两头被截断了就加省略号 —— 让用户一眼知道"这儿还有上下文"
        if start > 0 { leading = "…" + leading }
        if end < ns.length { trailing += "…" }

        return (leading, match, trailing)
    }

    /// PDF 里的硬换行在窄列表里塞不下，统一压成单个空格
    private func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
