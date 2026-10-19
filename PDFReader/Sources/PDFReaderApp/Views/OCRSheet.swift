import SwiftUI
import PDFKit
import AppKit

/// OCR 文字识别弹窗：识别结果可复制、可导出为 txt，点击结果行可跳转到对应页。
@MainActor
struct OCRSheet: View {

    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel

    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case currentPage = "当前页"
        case allPages = "全部页"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .currentPage
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var results: [OCRService.PageResult] = []
    @State private var currentPageBeingProcessed: Int = -1
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
    }

    private var fullText: String {
        results
            .sorted { $0.pageIndex < $1.pageIndex }
            .map { "── 第 \($0.pageIndex + 1) 页 ──\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    private var progressLabel: String {
        let percent = "\(Int(progress * 100))%"
        guard currentPageBeingProcessed >= 0, scope == .allPages else { return percent }
        return "第 \(currentPageBeingProcessed + 1) 页 \(percent)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scopeBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onDisappear { task?.cancel() }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
            Text("OCR 文字识别")
                .font(.headline)
            Spacer()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding()
    }

    private var scopeBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(isRunning)

            Text("适用于扫描版 PDF（无文本层）")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text(progressLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(results.isEmpty ? "开始识别" : "重新识别") {
                    start()
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty && !isRunning {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("识别结果将显示在这里")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(results) { result in
                        pageSection(result)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pageSection(_ result: OCRService.PageResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("第 \(result.pageIndex + 1) 页")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Button("跳转") {
                    viewModel.goToPage(at: result.pageIndex)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))

                Spacer()

                Button("复制本页") {
                    copyToPasteboard(result.text)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            Text(result.text.isEmpty ? "（本页未识别到文字）" : result.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(result.text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footer: some View {
        HStack {
            if !results.isEmpty {
                let lineCount = results.reduce(0) { $0 + $1.lines.count }
                Text("\(results.count) 页 / \(lineCount) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("复制全部") {
                copyToPasteboard(fullText)
            }
            .disabled(results.isEmpty)

            Button("导出 txt…") {
                export()
            }
            .disabled(results.isEmpty)

            Button("关闭") {
                task?.cancel()
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }

    // MARK: - 识别流程

    private func start() {
        task?.cancel()
        results = []
        errorMessage = nil
        isRunning = true
        progress = 0

        let pageCount = tab.document.pageCount
        let pageIndices: [Int]
        switch scope {
        case .currentPage:
            pageIndices = [viewModel.currentPageIndex]
        case .allPages:
            pageIndices = Array(0..<pageCount)
        }

        // PDFDocument 非 Sendable；识别全程在主 actor 上串行，这里只是为了让闭包捕获合法
        let box = UnsafeSendableBox(value: tab.document)

        task = Task { @MainActor in
            let document = box.value
            var collected: [OCRService.PageResult] = []
            for (offset, pageIndex) in pageIndices.enumerated() {
                if Task.isCancelled { break }
                currentPageBeingProcessed = pageIndex
                guard let page = document.page(at: pageIndex) else { continue }
                do {
                    let result = try await OCRService.recognize(page: page, pageIndex: pageIndex)
                    collected.append(result)
                    results = collected
                } catch {
                    errorMessage = error.localizedDescription
                }
                progress = Double(offset + 1) / Double(max(pageIndices.count, 1))
            }
            isRunning = false
            currentPageBeingProcessed = -1
            if !collected.isEmpty, collected.allSatisfy({ $0.lines.isEmpty }) {
                errorMessage = "未识别到文字，该文档可能本身就是纯文本 PDF"
            }
        }
    }

    // MARK: - 输出

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stem = tab.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)-OCR.txt"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fullText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
