import SwiftUI
import PDFKit

@MainActor
struct ToolbarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            // 只读 / 编辑 —— 放在最左边，因为它决定"这一屏能不能改东西"
            if let tab = viewModel.selectedTab {
                ReadOnlyToggle(tab: tab)
                Divider().frame(height: 18)
            }

            // 打开按钮
            Button(action: { viewModel.openDocument() }) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("打开文件 (⌘O)")

            Divider()
                .frame(height: 18)

            if let tab = viewModel.selectedTab {
                SidebarToggles(tab: tab)
                Divider().frame(height: 18)
                DocumentToolbarContent(tab: tab, appViewModel: viewModel)
            } else {
                Spacer()
            }

            Divider().frame(height: 18)

            // 搜索框常驻右上角，点一下就能用
            if let tab = viewModel.selectedTab {
                SearchField(viewModel: tab.viewModel)
            }
        }
    }
}

/// 只读 / 编辑 开关。默认只读 —— 打开文件先"只能看"，点了编辑才出标注工具。
@MainActor
private struct ReadOnlyToggle: View {
    let tab: DocumentTab
    @ObservedObject var pdfVM: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.pdfVM = tab.viewModel
    }

    var body: some View {
        Picker("", selection: $pdfVM.isEditable) {
            Label("只读", systemImage: "lock").tag(false)
            Label("编辑", systemImage: "pencil").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 132)
        .help(pdfVM.isEditable
              ? "编辑模式：可以添加/修改标注（点「只读」退出）"
              : "只读模式：不会改动文档。点「编辑」开始标注")
    }
}

/// 左右侧边栏的显示开关。
///
/// 拆成独立子视图是为了观察 `PDFViewModel` —— `ToolbarView` 观察的是 `AppViewModel`，
/// 直接读栏的可见性不会触发重绘。
///
/// 侧边栏也可以从它自己那一栏里关（右侧属性栏右上角的 ×），这里管的是"关掉之后
/// 怎么再打开" —— 否则关了就再也回不来了。
@MainActor
private struct SidebarToggles: View {
    let tab: DocumentTab
    @ObservedObject var pdfVM: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.pdfVM = tab.viewModel
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                // 栏位一收一放，PDFView 宽度会变 —— 先记下缩放，别让页面跟着缩放
                pdfVM.beginPreservingZoom()
                pdfVM.isLeftSidebarVisible.toggle()
            } label: {
                Image(systemName: pdfVM.isLeftSidebarVisible
                      ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 14))
                    .foregroundStyle(pdfVM.isLeftSidebarVisible ? Color.accentColor : .primary)
            }
            .buttonStyle(.borderless)
            .help(pdfVM.isLeftSidebarVisible ? "隐藏左侧栏" : "显示左侧栏")

            Button {
                pdfVM.beginPreservingZoom()
                pdfVM.isRightSidebarVisible.toggle()
            } label: {
                Image(systemName: pdfVM.isRightSidebarVisible
                      ? "sidebar.right" : "sidebar.trailing")
                    .font(.system(size: 14))
                    .foregroundStyle(pdfVM.isRightSidebarVisible ? Color.accentColor : .primary)
            }
            .buttonStyle(.borderless)
            .help(pdfVM.isRightSidebarVisible ? "隐藏右侧栏" : "显示右侧栏")
        }
    }
}

/// 顶栏右上角的搜索框。
///
/// 输入即搜（350ms 防抖），结果出现在右侧栏；
/// ⌘F 会把焦点送过来，⌘G / ⇧⌘G 上下跳结果。
@MainActor
private struct SearchField: View {
    @ObservedObject var viewModel: PDFViewModel
    @FocusState private var isFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("搜索", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($isFocused)
                .onSubmit { runSearchNow() }

            if !viewModel.searchQuery.isEmpty {
                if viewModel.isSearching {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("\(viewModel.searchResults.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Button { viewModel.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                              lineWidth: 1)
        )
        // ⌘F：焦点送过来并全选，直接输新词
        .onChange(of: viewModel.searchFocusToken) { _, _ in isFocused = true }
        // 输入即搜，但要防抖 —— 不然每敲一个字都跑一次全文搜索
        .onChange(of: viewModel.searchQuery) { _, newValue in
            debounceTask?.cancel()
            guard !newValue.isEmpty else {
                viewModel.performSearch()      // 清空时立刻收起结果
                return
            }
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                viewModel.performSearch()
            }
        }
    }

    private func runSearchNow() {
        debounceTask?.cancel()
        viewModel.performSearch()
    }
}

/// 选中文档时才出现的工具栏内容。
///
/// 单独拆成子视图是为了直接 `@ObservedObject` 观察 `PDFViewModel`：
/// 否则页码、书签状态、后退可用性等 `@Published` 变化不会触发工具栏重绘。
@MainActor
private struct DocumentToolbarContent: View {

    let tab: DocumentTab
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var pdfVM: PDFViewModel
    @ObservedObject var speech: SpeechReader
    @ObservedObject var autoScroller: AutoScroller

    init(tab: DocumentTab, appViewModel: AppViewModel) {
        self.tab = tab
        self.appViewModel = appViewModel
        self.pdfVM = tab.viewModel
        self.speech = tab.viewModel.speech
        self.autoScroller = tab.viewModel.autoScroller
    }

    var body: some View {
        HStack(spacing: 10) {
            historyControls
            divider
            pageControls

            Button(action: { pdfVM.toggleBookmark() }) {
                Image(systemName: pdfVM.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14))
                    .foregroundStyle(pdfVM.isCurrentPageBookmarked ? Color.accentColor : .primary)
            }
            .buttonStyle(.borderless)
            .help(pdfVM.isCurrentPageBookmarked ? "移除书签" : "添加书签")

            Spacer()

            zoomControls
            divider
            layoutMenu
            divider
            readingControls
            divider
            moreMenu
        }
    }

    private var divider: some View {
        Divider().frame(height: 18)
    }

    // MARK: - 历史导航

    private var historyControls: some View {
        HStack(spacing: 6) {
            Button(action: { pdfVM.goBack() }) {
                Image(systemName: "arrow.backward")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!pdfVM.canGoBack)
            .help("后退")

            Button(action: { pdfVM.goForward() }) {
                Image(systemName: "arrow.forward")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!pdfVM.canGoForward)
            .help("前进")
        }
    }

    // MARK: - 页面导航

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button(action: { pdfVM.goToPreviousPage() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(pdfVM.currentPageIndex <= 0)

            Text("\(pdfVM.currentPageIndex + 1) / \(pdfVM.pageCount)")
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 70)

            Button(action: { pdfVM.goToNextPage() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(pdfVM.currentPageIndex >= pdfVM.pageCount - 1)
        }
    }

    // MARK: - 缩放

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button(action: { pdfVM.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("缩小")

            // 百分比本身是个按钮：点一下切到「实际大小」，再点一下回到原来的比例（v1.3.37）。
            // 写成 `Button` + `.plain` 就必须自己管命中区 —— 文字是细笔画，
            // 底下又是透明底，不加 `contentShape` 只有字形能点中（见 AnnotationPalette 那条注释）。
            Button {
                pdfVM.toggleActualSizeAndBack()
            } label: {
                // ⚠️ 用 `zoomPercent` 而不是 `scaleFactor * 100`（v1.3.64）——
                // 后者是"1 PDF 点占几个界面点"的**名义值**，标着 100% 时页面其实
                // 只有真实尺寸的 66%（见 `ScreenMetrics`），跟预览.app 一比就短一截。
                Text(String(format: "%.0f%%", pdfVM.zoomPercent))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pdfVM.isShowingTemporaryActualSize
                  ? "再点一下回到原来的缩放比例"
                  : "点一下切到实际大小（100%）")

            Button(action: { pdfVM.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("放大")

            Menu {
                Button("实际大小") { pdfVM.zoomToActualSize() }
                Button("适合宽度") { pdfVM.zoomToFitWidth() }
                Button("适合页面") { pdfVM.zoomToFitPage() }
            } label: {
                Image(systemName: "aspectratio")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("缩放方式")
        }
    }

    // MARK: - 页面布局

    private var layoutMenu: some View {
        Menu {
            Button("单页连续") { pdfVM.setDisplayMode(.singlePageContinuous) }
            Button("单页") { pdfVM.setDisplayMode(.singlePage) }
            Button("双页") { pdfVM.setDisplayMode(.twoUp) }
            Button("双页连续") { pdfVM.setDisplayMode(.twoUpContinuous) }
        } label: {
            Image(systemName: "doc.text")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("页面布局")
    }

    // MARK: - 朗读与自动滚动

    private var readingControls: some View {
        HStack(spacing: 6) {
            Menu {
                if speech.isSpeaking {
                    Button(speech.isPaused ? "继续朗读" : "暂停朗读") {
                        speech.togglePause()
                    }
                    Button("停止朗读") { pdfVM.stopSpeaking() }
                    Divider()
                    Button("从当前页重新开始") { pdfVM.restartSpeechFromCurrentPosition() }
                } else {
                    Button("朗读选中文本 / 当前页") { pdfVM.speakSelectionOrCurrentPage() }
                    Button("从当前页开始朗读") { pdfVM.speakCurrentPage() }
                }
                Divider()
                Toggle("读完整页自动翻页", isOn: $speech.autoAdvance)
                Picker("语速", selection: $speech.rate) {
                    Text("慢").tag(0.4)
                    Text("正常").tag(0.5)
                    Text("快").tag(0.6)
                    Text("很快").tag(0.7)
                }
            } label: {
                Image(systemName: speechIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(speech.isSpeaking ? Color.accentColor : .primary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("文本朗读")

            Menu {
                Button(autoScroller.isRunning ? "停止自动滚动" : "开始自动滚动") {
                    pdfVM.toggleAutoScroll()
                }
                Divider()
                Picker("速度", selection: $autoScroller.speed) {
                    Text("慢").tag(20.0)
                    Text("正常").tag(40.0)
                    Text("快").tag(80.0)
                    Text("很快").tag(140.0)
                }
            } label: {
                Image(systemName: autoScroller.isRunning ? "pause.rectangle.fill" : "arrow.down.to.line")
                    .font(.system(size: 14))
                    .foregroundStyle(autoScroller.isRunning ? Color.accentColor : .primary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("自动滚动（连续页模式下生效）")

            Button(action: { pdfVM.activeSheet = .ocr }) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("OCR 文字识别")
        }
    }

    private var speechIcon: String {
        guard speech.isSpeaking else { return "speaker.wave.2" }
        return speech.isPaused ? "pause.circle.fill" : "speaker.wave.2.fill"
    }

    // MARK: - 更多

    private var moreMenu: some View {
        Menu {
            Button("打印…") { pdfVM.presentPrintOptions() }
            Button("文档信息…") { pdfVM.showDocumentInfo = true }
            Divider()
            Button("逆时针旋转") { pdfVM.rotateCurrentPageCounterClockwise() }
            Button("顺时针旋转") { pdfVM.rotateCurrentPageClockwise() }
            Divider()
            Button("全屏") { appViewModel.toggleFullScreen() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("更多")
    }
}
