import SwiftUI

@MainActor
struct PDFContentView: View {
    let tab: DocumentTab

    @ObservedObject var viewModel: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.viewModel = tab.viewModel
    }

    var body: some View {
        // ⚠️ 这一条 `.onReceive` 链非常长（十几个菜单指令），**不能再往同一个表达式里加**：
        // 加第 15 个时编译器会直接报 "unable to type-check this expression in reasonable
        // time"。所以拆成两段（各自 ~8 个），`editingCommands` 就只是"前半段 + 后半段"。
        editingCommands
    }

    /// 视图本体 + 两个 sheet
    ///
    /// ⚠️ **「页面管理」的浮层不在这里了（v1.3.44）** —— 它挪到了 `ContentView` 那一层，
    /// 因为要连顶栏和左右侧边栏一起盖住（只留系统窗口标签栏）。这里再放一个就是叠两层。
    private var sheetHost: some View {
        PDFKitRepresentedView(tab: tab)
            .background(Color(nsColor: .textBackgroundColor))
            .sheet(isPresented: $viewModel.showDocumentInfo) {
                if let info = viewModel.documentInfo {
                    DocumentInfoView(info: info)
                }
            }
            .sheet(item: $viewModel.activeSheet) { sheet in
                switch sheet {
                case .note:
                    NoteInputSheet(kind: .note, style: viewModel.style) { text in
                        viewModel.addStickyNote(text: text)
                    }
                case .freeText:
                    NoteInputSheet(kind: .freeText, style: viewModel.style) { text in
                        viewModel.addFreeText(text: text)
                    }
                case .editFreeText:
                    // 双击文本注释进来的。目标拿不到就什么都不弹
                    //（比如双击之后那个文件已经被关掉了）
                    if let target = viewModel.editingFreeText {
                        NoteInputSheet(kind: .editFreeText,
                                       style: viewModel.style,
                                       initialText: target.originalText) { text in
                            viewModel.updateFreeText(to: text)
                        }
                    }
                case .signature:
                    SignatureSheet { payload in
                        viewModel.insertSignature(payload)
                    }
                case .ocr:
                    OCRSheet(tab: tab)
                case .print:
                    PrintOptionsSheet(tab: tab)
                }
            }
    }


    /// 前半段菜单指令：朗读 / 自动滚动 / 打开各种面板 / 打印 / 页面管理
    ///
    /// 菜单指令（⌘ 快捷键）统一在这里派发到当前标签的 viewModel。
    ///
    /// ⚠️ **每一条都要先过 `viewModel.isInActiveWindow`。**
    /// 这些指令是 `NotificationCenter` 广播，多窗口下每个窗口都会收到一遍 ——
    /// 不过滤的话 ⌘Z 会在所有文件上各撤销一步、⌘S 把所有文件存一遍。
    /// 详见 `PDFViewModel.isInActiveWindow` 的说明。
    private var readCommands: some View {
        sheetHost
            .onReceive(NotificationCenter.default.publisher(for: .pdfSpeakToggle)) { _ in
                guard viewModel.isInActiveWindow else { return }
                if viewModel.speech.isSpeaking {
                    viewModel.speech.togglePause()
                } else {
                    viewModel.speakSelectionOrCurrentPage()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfSpeakStop)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.stopSpeaking()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfToggleAutoScroll)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.toggleAutoScroll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfAddNote)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.requestAnnotationSheet(.note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfAddTextAnnotation)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.requestAnnotationSheet(.freeText)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfAddSignature)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.requestAnnotationSheet(.signature)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfRunOCR)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.activeSheet = .ocr
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfPrint)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.presentPrintOptions()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfManagePages)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.beginPageEditing()
            }
    }

    /// 后半段菜单指令：查找 / 保存 / 撤销重做 / 只读提示
    private var editingCommands: some View {
        readCommands
            // ⌘F / ⌘G / ⇧⌘G
            .onReceive(NotificationCenter.default.publisher(for: .pdfFind)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.revealSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfFindNext)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.goToNextSearchResult()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfFindPrevious)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.goToPreviousSearchResult()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfSaveAnnotations)) { _ in
                guard viewModel.isInActiveWindow else { return }
                do {
                    // `performSave` 自己按文档类型选路（v1.3.66）：
                    // PDF 写回原文件，图片弹「导出为图片…」——图片那份文档没有
                    // `documentURL`，走 `saveAnnotationsToDisk` 只会报"保存失败"。
                    try viewModel.performSave()
                    // 目录是保存之后**另外**注入进文件的（PDFKit 不写目录）——
                    // 它失败时批注已经存好了，不能报成"保存失败"，但也不能不说
                    if let notice = viewModel.outlineWriteNotice {
                        let alert = NSAlert()
                        alert.messageText = "批注已保存，但目录没写进文件"
                        alert.informativeText = notice
                        // 同样挂到窗口上 —— 独立弹窗会被系统标签栏压住。
                        // 这里只是"告知"，答案用不上。
                        AlertPresenter.present(alert, near: viewModel.pdfView) { _ in }
                    }
                } catch {
                    AlertPresenter.present(NSAlert(error: error), near: viewModel.pdfView) { _ in }
                }
            }
            // ⌘Z / ⇧⌘Z（菜单项在 PDFReaderApp 里，焦点在文本框时会先交回给文本系统）
            .onReceive(NotificationCenter.default.publisher(for: .pdfUndo)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.undo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pdfRedo)) { _ in
                guard viewModel.isInActiveWindow else { return }
                viewModel.redo()
            }
            // 只读模式下点"添加标注"时给一句话，而不是静默失败
            .alert(
                "无法添加标注",
                isPresented: Binding(
                    get: { viewModel.readOnlyNotice != nil },
                    set: { if !$0 { viewModel.readOnlyNotice = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.readOnlyNotice ?? "")
            }
    }
}
