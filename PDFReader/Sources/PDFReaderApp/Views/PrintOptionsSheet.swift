import SwiftUI
import PDFKit

/// 打印设置面板：左侧设置，右侧实时预览。
///
/// 预览和实际打印都走 `PDFPrintService.makePrintableDocument`，
/// 所以看到的就是将要打出来的（拼版、页面范围、批注开关的效果都能直接看到）。
///
/// 只放系统打印面板没有的选项；打印机、份数、纸张、方向、双面、预览交给下一步的系统面板，
/// 面板底部会明确提示这一点，避免用户以为漏了。
@MainActor
struct PrintOptionsSheet: View {

    let tab: DocumentTab
    @ObservedObject var viewModel: PDFViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var options = PDFPrintOptions()
    @State private var errorMessage: String?

    // 预览状态
    @State private var previewDocument: PDFDocument?
    @State private var previewError: String?
    @State private var isBuildingPreview = false

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
    }

    private var pageCount: Int { tab.document.pageCount }

    /// 自定义范围解析出的页数，用于实时反馈
    private var customRangeCount: Int? {
        guard options.rangeMode == .custom else { return nil }
        return PDFPrintService.parsePageRange(options.customRange, pageCount: pageCount).count
    }

    private var effectivePageCount: Int {
        switch options.rangeMode {
        case .all: return pageCount
        case .currentPage: return 1
        case .custom: return customRangeCount ?? 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                formPane
                Divider()
                previewPane
            }
            Divider()
            footer
        }
        .frame(width: 880, height: 600)
        // options 一变就重建预览。带防抖，避免拖动缩放滑块时疯狂重算（拼版可能较慢）。
        .task(id: options) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rebuildPreview()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "printer")
            Text("打印设置")
                .font(.headline)
            Spacer()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding()
    }

    // MARK: - 左侧：设置

    private var formPane: some View {
        ScrollView {
            Form {
                Section("页面范围") {
                    Picker("范围", selection: $options.rangeMode) {
                        ForEach(PDFPrintOptions.RangeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if options.rangeMode == .custom {
                        TextField("例如 1-3, 5, 8-10", text: $options.customRange)
                            .textFieldStyle(.roundedBorder)

                        Text(rangeHint)
                            .font(.caption)
                            .foregroundStyle(customRangeCount == nil ? .secondary : .primary)
                    }
                }

                Section("缩放") {
                    Picker("缩放", selection: $options.scaleMode) {
                        ForEach(PDFPrintOptions.ScaleMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if options.scaleMode == .custom {
                        HStack(spacing: 10) {
                            Slider(value: $options.customScalePercent, in: 25...400, step: 5)
                            Text("\(Int(options.customScalePercent))%")
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 46, alignment: .trailing)
                        }
                    }

                    Toggle("自动旋转以适配纸张方向", isOn: $options.autoRotate)
                }

                Section("排版") {
                    Picker("每张纸页数", selection: $options.pagesPerSheet) {
                        ForEach(PDFPrintOptions.pagesPerSheetChoices, id: \.self) { count in
                            Text(count == 1 ? "1 页（不拼版）" : "\(count) 页").tag(count)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("拼版按当前纸张大小计算，可在下一步的系统面板里调整纸张。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("纸张") {
                    Picker("纸张大小", selection: $options.paperSize) {
                        ForEach(PDFPrintOptions.PaperSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("方向", selection: $options.orientation) {
                        ForEach(PDFPrintOptions.PaperOrientation.allCases) { orientation in
                            Text(orientation.label).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(options.paperSize == .systemDefault)

                    Text(paperHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("内容") {
                    Toggle("打印批注（高亮 / 便签 / 签名）", isOn: $options.includeAnnotations)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400)
    }

    private var paperHint: String {
        if options.paperSize == .systemDefault {
            return "沿用系统纸张设置，可在下一步的系统面板里调整。"
        }
        let size = PDFPrintService.resolvedPaperSize(for: options)
        return String(format: "拼版按 %.0f × %.0f 点（约 %.0f × %.0f mm）计算。",
                      size.width, size.height,
                      size.width / 72 * 25.4, size.height / 72 * 25.4)
    }

    private var rangeHint: String {
        if options.customRange.trimmingCharacters(in: .whitespaces).isEmpty {
            return "留空则打印全部 \(pageCount) 页"
        }
        guard let count = customRangeCount else { return "" }
        return count == 0
            ? "没有匹配的页码，将回退为打印全部"
            : "将打印 \(count) 页（共 \(pageCount) 页）"
    }

    // MARK: - 右侧：预览

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("预览")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isBuildingPreview {
                    ProgressView()
                        .controlSize(.small)
                    Text("生成中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let previewDocument {
                    Text("共 \(previewDocument.pageCount) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let previewError {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(previewError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let previewDocument {
                PrintPreviewView(document: previewDocument)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text("正在生成预览…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("打印机、份数、纸张大小、方向、双面在下一步的系统打印面板里设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text("共打印 \(effectivePageCount) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Button("打印…") { performPrint() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(effectivePageCount == 0)
            }
        }
        .padding()
    }

    // MARK: - 行为

    private func rebuildPreview() {
        isBuildingPreview = true
        defer { isBuildingPreview = false }
        do {
            previewDocument = try PDFPrintService.makePrintableDocument(
                document: tab.document,
                options: options,
                currentPageIndex: viewModel.currentPageIndex
            )
            previewError = nil
        } catch {
            previewDocument = nil
            previewError = error.localizedDescription
        }
    }

    private func performPrint() {
        do {
            let didPrint = try PDFPrintService.print(
                document: tab.document,
                options: options,
                currentPageIndex: viewModel.currentPageIndex
            )
            // 打印成功才关闭；用户在系统面板里取消则留在本面板，方便改设置重试
            if didPrint {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct PrintPreviewView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PageFittingPDFView()
        pdfView.autoScales = true          // 首次进入先让它摆好位置，随后 layout 里接管
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        pdfView.backgroundColor = .controlBackgroundColor
        pdfView.document = document
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        guard pdfView.document !== document else { return }
        pdfView.document = document
        // 换了文档要重新整页适配（视口尺寸没变，靠 resetFitting 强制重算）
        (pdfView as? PageFittingPDFView)?.resetFitting()
    }
}
