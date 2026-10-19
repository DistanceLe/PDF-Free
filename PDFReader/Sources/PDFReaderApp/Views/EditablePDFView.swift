import AppKit
import PDFKit

/// 可编辑的 PDFView：负责标注的全部鼠标/键盘交互。
///
/// 一个视图承担四件事：
/// 1. **拖拽绘制** —— 矩形 / 圆 / 箭头 / 涂鸦，按住拖出形状
/// 2. **点选与拖动** —— 选择工具下点选已有标注，按住可拖到别处
/// 3. **点击放置** —— 文本 / 便签 / 签名，点一下决定落点再弹窗
/// 4. **Delete 删除、Esc 取消** —— 键盘快捷键
///
/// 只读模式下这些全部让开，事件交回 PDFView（保留它原生的文字选择、点便签弹内容等行为）。
///
/// ## 为什么不用 PDFKit 自带的 `isInMarkupMode`
/// 它在 macOS 26 已废弃，且会带来一整套自己的编辑手势，与「空格抓手」「⌥+滚轮缩放」
/// 两个全局事件监听抢事件；它也不区分标注类型，高亮会被一起拖走。
@MainActor
final class EditablePDFView: PDFView {

    /// 由 `PDFKitRepresentedView` 注入。视图直接拿 viewModel，
    /// 省掉一个十几个方法的 delegate 协议（这层在项目里本来也是视图持 viewModel 的写法）。
    weak var viewModel: PDFViewModel?

    /// 拖动结束（真的移动过）或绘制完成时回调，交给外部刷新列表
    var onAnnotationsChanged: (() -> Void)?

    /// 按下后移动超过这个距离才算拖动；否则当成普通单击
    private static let dragThreshold: CGFloat = 3

    private var keyMonitor: Any?

    // MARK: - 会话状态

    /// 拖动已有标注
    private final class MoveSession {
        let annotation: PDFAnnotation
        let page: PDFPage
        let grabOffset: CGPoint
        let mouseDownEvent: NSEvent
        var hasMoved = false

        init(annotation: PDFAnnotation, page: PDFPage, grabOffset: CGPoint, mouseDownEvent: NSEvent) {
            self.annotation = annotation
            self.page = page
            self.grabOffset = grabOffset
            self.mouseDownEvent = mouseDownEvent
        }
    }

    private var moveSession: MoveSession?

    /// 拖**文本注释的左右边框**改宽度（v1.3.73）。
    ///
    /// 改的是这条批注自己的"换行宽度上限"（`FreeTextLayout.setMaxWidth`），
    /// 不是硬写 `bounds.width` —— 这样之后改字号、重排内容时，折行宽度仍然是
    /// 用户定的那个值，而不是一重排就被内容"缩回去"。
    private final class ResizeSession {
        /// 抓的是哪条边：拖左边 → 右边缘不动；拖右边 → 左边缘不动。
        enum Edge { case left, right }

        let annotation: PDFAnnotation
        let page: PDFPage
        let edge: Edge
        /// **按下那一刻**的原始 bounds —— 拖拽全程都以它为基准算，
        /// 不逐帧累加，否则来回拖会一点点漂。
        let originalBounds: CGRect
        /// 宽度上限（略小于页宽，别让框长到页面外面）
        let widthLimit: CGFloat
        let mouseDownEvent: NSEvent
        var hasMoved = false

        init(annotation: PDFAnnotation, page: PDFPage, edge: Edge,
             originalBounds: CGRect, widthLimit: CGFloat, mouseDownEvent: NSEvent) {
            self.annotation = annotation
            self.page = page
            self.edge = edge
            self.originalBounds = originalBounds
            self.widthLimit = widthLimit
            self.mouseDownEvent = mouseDownEvent
        }
    }

    private var resizeSession: ResizeSession?

    /// 刚双击了文本注释、内容已经交给编辑框 —— **紧接着的那次抬起别再让 PDFView 处理**，
    /// 否则它会顺手做"双击选词"，把页面上的文字选蓝一片（v1.3.73）。
    private var swallowNextMouseUp = false

    /// 边框抓取带在**屏幕上**的宽度（点）。
    ///
    /// 按屏幕点算而不是按页坐标算：缩放拉到 400% 时页坐标里 6 点是 24 屏幕点、
    /// 拉到 25% 时只剩 1.5 点 —— 后者根本抓不住。手感必须跟缩放无关。
    private static let resizeHandleWidth: CGFloat = 6

    /// 拖拽绘制中记下的页
    private var drawingPage: PDFPage?

    /// 只读模式下展示便签内容的浮层（需要持有，否则会被立刻释放）
    private var notePopover: NSPopover?

    // MARK: - 拖动预览层
    //
    // 拖拽绘制时，草稿**不画在 PDFView 上**，而是画在一条独立的 CAShapeLayer 上。
    //
    // 为什么：拖动画布时若走 `pdfView.needsDisplay = true`，每次都要等 PDFKit
    // 把整页重新合成一遍才能看到结果 —— 实测「事件 → 重绘」要 **38 ms**
    // （连 P90 都到 78 ms）。快速拖动时这 38 ms 就累积成肉眼可见的"图形落后于鼠标"，
    // 也就是用户说的"不跟手、慢一拍"。
    //
    // 而 `CAShapeLayer.path` 的更新由 Core Animation 在渲染服务器上处理，
    // **完全不经过 PDFKit 的重绘**，实测同一次拖动后 20 ms 截屏，图层方案已经画出，
    // 而视图重绘方案连 60 ms 都还没出现。
    //
    // ⚠️ **必须用 `zPosition` 而不是"加进去的顺序"来定序。**
    //
    // 实测（连画两笔）：第一笔时 `pdfView.layer.sublayers` 是
    // `[页面内容层, 填充层, 描边层]` —— 我们在最上面，预览看得到。
    // 但第一笔画完会弹右侧属性栏 → PDFView 变窄 → `autoScales` 重新适配页面
    // → **PDFKit 重排自己的层，把页面内容层放到了我们后面**，变成
    // `[填充层, 描边层, 页面内容层]`。这时的表现就是**第二笔画的过程中屏幕上什么都没有，
    // 只有松手后整页重绘才把结果画出来**。
    //
    // 用 `zPosition` 定序就与数组顺序无关，PDFKit 怎么重排都盖不住预览。

    /// 预览层的 z 序。页面内容层的 zPosition 是 0，所以只要比它大就能压在上面。
    private static let draftFillZ: CGFloat = 1000
    private static let draftStrokeZ: CGFloat = 1001

    private lazy var draftStrokeLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.isHidden = true
        layer.zPosition = Self.draftStrokeZ
        return layer
    }()

    private lazy var draftFillLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.strokeColor = nil
        layer.isHidden = true
        layer.zPosition = Self.draftFillZ
        return layer
    }()

    // MARK: - 宽度变化时保持缩放（v1.3.9）
    //
    // 需求：显示 / 隐藏左右侧边栏、拖分隔条、弹属性栏的时候，**页面不要跟着缩放**。
    //
    // ⚠️ 不能在 `layout()` 里跟"上一帧的 scaleFactor"比 —— 实测 PDFKit
    // **在宽度变化的过程中**就已经按"适合宽度"把 scaleFactor 重算好了，
    // 等 `layout()` 被调到，读到的已经是新值，那会儿再"还原"就等于还原成新值（白搭）。
    //
    // 所以这里存的是**外部在宽度变化之前**记下的目标值
    // （`PDFViewModel.beginPreservingZoom()`），`layout()` 只负责把它还回去。
    //
    // 另外：给 `scaleFactor` 赋值会顺带把 `autoScales` 关掉（实测确认），
    // 这正好也挡住了 PDFKit 之后的"适合宽度" —— 之后再怎么改宽度都不会动缩放。
    // 用户点「适合宽度」或换文档时会被清掉（`resetPreservedZoom()`）。

    /// 宽度变化后要还原到的缩放。nil = 不干预（让 `autoScales` 照常工作）。
    var zoomToPreserve: CGFloat?

    /// 上一次布局时的宽度，用来判断"这次布局宽度到底变没变"
    private var widthAtLastLayout: CGFloat = 0

    /// 上一次布局时的缩放，用来判断"要不要重算光标矩形"
    private var scaleAtLastLayout: CGFloat = 0

    /// 文档换了（或用户明确点了「适合宽度」）就别再钉住缩放了
    func resetPreservedZoom() {
        zoomToPreserve = nil
    }

    override func layout() {
        let incomingWidth = bounds.width
        let widthChanged = widthAtLastLayout > 0 && abs(incomingWidth - widthAtLastLayout) > 0.5
        super.layout()
        widthAtLastLayout = incomingWidth

        // 缩放一变，文本注释边框在**屏幕上的位置**也跟着变 —— 得重算光标矩形，
        // 否则缩放之后鼠标停在边框上不会变成「左右拉伸」光标（v1.3.73）。
        //
        // ⚠️ 只在缩放真的变了时才做：`layout()` 每帧都可能被调到，
        // 每次都重算的话，大文档要白白扫一遍可见页的批注。
        if abs(scaleFactor - scaleAtLastLayout) > 0.0001 {
            scaleAtLastLayout = scaleFactor
            window?.invalidateCursorRects(for: self)
        }

        guard widthChanged, let target = zoomToPreserve, document != nil else { return }
        if abs(scaleFactor - target) > 0.0001 {
            scaleFactor = target
        }
    }

    // MARK: - 生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installKeyMonitorIfNeeded()
    }

    /// 宿主视图销毁时调用，撤掉键盘监听
    func detach() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        moveSession = nil
        resizeSession = nil
        drawingPage = nil
        hideDraftPreview()
        draftStrokeLayer.removeFromSuperlayer()
        draftFillLayer.removeFromSuperlayer()
        notePopover?.close()
        notePopover = nil
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    /// 返回 true 表示吞掉该事件
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // ⚠️ 注意这里**没有** `viewModel.isEditable` —— 书签栏的删除与编辑模式无关
        // （书签是应用自己的数据，不是文档里的批注；只读模式正是读书签的时候）。
        // 编辑相关的分支各自单独判断，见下面。
        guard let viewModel, let window, event.window === window else { return false }
        // 正在输入文字（批注弹窗、搜索框）时一切都别抢
        guard !(window.firstResponder is NSTextView) else { return false }
        // ⚠️ 「页面管理」盖在主窗口上时，Delete 是它的（删选中那些页），不是我们的。
        //
        // 以前页面管理是 sheet，`event.window` 是那个 sheet，这条自然不成立；
        // v1.3.43 改成**同一个窗口里的浮层**之后就会撞上 —— 不挡的话
        // 在页面管理里按 ⌫ 会顺手把 PDF 上选中的批注也删掉。
        guard !viewModel.isPageManagerVisible else { return false }

        switch event.keyCode {
        case 51, 117:                       // Delete / Forward Delete
            // 目录栏里有选中 → 交给目录栏删。
            // ⚠️ 目录要被**写进 PDF 文件**，那是编辑行为，所以这一支要求可编辑
            // （和书签不同 —— 书签是应用自己的数据，只读时也允许删）。
            if viewModel.isEditable, viewModel.tocSelectedID != nil {
                viewModel.requestDeleteOfTOCSelection()
                return true
            }

            // 书签栏里有选中 → 交给书签栏删（它在侧边栏里，不依赖焦点）。
            // 这一支排在 `isEditable` 判断**之前**：书签是应用自己的数据，只读模式正是看书签的时候。
            if !viewModel.bookmarkListSelectionIDs.isEmpty {
                viewModel.requestDeleteOfBookmarkSelection()
                return true
            }

            guard viewModel.isEditable else { return false }

            // 批注列表里选中了（尤其**多条**）时，交给列表去删 —— 它能弹确认框、
            // 一次删掉一批，也知道选的是哪几条。
            //
            // 这里是 `addLocalMonitorForEvents` 挂的**全局**监听，跑在所有键盘事件最前面，
            // 而且完全不在 SwiftUI 的渲染路径上。所以**不要指望列表自己的 `.onDeleteCommand`**：
            // 那个 command 要列表拿到焦点才会触发，而焦点一般在 PDF 视图这边 ——
            // 实测在列表里选中几条后按 Delete 毫无反应（事件被这里吞掉或无人接手）。
            // 改由我们主动通知列表（计数器），这条路不依赖焦点。
            //
            // 只有一个例外仍走下面那条老路：列表只选中一条、且页面上也正选着它 ——
            // 那种情况直接删更顺手，不必多弹一次确认框。
            let listCount = viewModel.annotationListSelectionCount
            if listCount > 1 || (listCount == 1 && !viewModel.hasSelection) {
                viewModel.requestDeleteOfListSelection()
                return true
            }
            guard viewModel.hasSelection else { return false }
            viewModel.deleteSelectedAnnotation()
            return true

        case 53:                            // Esc
            guard viewModel.isEditable else { return false }
            if viewModel.isDrawing {
                viewModel.cancelDrawing()
                return true
            }
            if viewModel.hasSelection {
                viewModel.clearSelection()
                return true
            }
            if viewModel.activeTool != .select {
                viewModel.activeTool = .select
                return true
            }
            return false

        default:
            return false
        }
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        guard let viewModel else {
            super.mouseDown(with: event)
            return
        }

        // 只读模式：不碰文档，但要把「点便签看内容」补回来。
        //
        // 批注现在由我们自绘（`shouldDisplay = false`，见 `AnnotationRenderer`），
        // 而 PDFKit 对"不显示"的批注不再处理任何交互 —— 原生那个"点便签弹出内容"
        // 因此失效。这里自己实现一份，其余点击照旧交回 PDFKit 保留文字选择。
        if !viewModel.isEditable {
            if let page = pageFor(event), let pageIndex = document?.index(for: page) {
                let point = convert(convert(event.locationInWindow, from: nil), to: page)
                if let hit = viewModel.annotation(at: pageIndex, point: point),
                   AnnotationItem.Kind(subtype: hit.type) == .note {
                    presentNoteContents(hit, from: event)
                    return
                }
            }
            super.mouseDown(with: event)
            return
        }

        guard let page = pageFor(event), let pageIndex = document?.index(for: page) else {
            super.mouseDown(with: event)
            return
        }

        let pagePoint = convert(convert(event.locationInWindow, from: nil), to: page)

        switch viewModel.activeTool {
        case .select:
            // 命中已有标注 → 选中并准备拖动；否则清掉选中，把事件交回（保留文字选择）
            if let hit = viewModel.annotation(at: pageIndex, point: pagePoint) {
                // ⚠️ 双击**文本注释** → 直接改里面的文字（v1.3.73）。
                // 必须排在"准备拖动 / 拖边框"**前面**，而且要把第一次按下建的那两个
                // 会话作废 —— 否则双击之后还留在拖动状态里，鼠标一动就把批注搬走了。
                if event.clickCount == 2,
                   AnnotationItem.Kind(subtype: hit.type) == .freeText {
                    moveSession = nil
                    resizeSession = nil
                    viewModel.endMoveUndo(committed: false)   // 丢掉第一次按下拍的快照
                    swallowNextMouseUp = true
                    viewModel.beginEditingFreeText(hit, pageIndex: pageIndex)
                    return
                }

                viewModel.select(hit, pageIndex: pageIndex)

                // ⚠️ 先看是不是**抓在文本注释的左右边框**上 —— 那是"改宽度"，不是"搬家"。
                // 顺序要紧：边框判定必须排在普通拖动之前，否则永远轮不到它。
                if let edge = resizeEdge(of: hit, on: page, event: event) {
                    viewModel.beginMoveUndo(pageIndex: pageIndex)
                    let pageBounds = page.bounds(for: .cropBox)
                    resizeSession = ResizeSession(
                        annotation: hit,
                        page: page,
                        edge: edge,
                        originalBounds: hit.bounds,
                        // 上限给到"页宽再收一点"，别让框拖出页面
                        widthLimit: max(pageBounds.width - 8, FreeTextLayout.minimumWidth),
                        mouseDownEvent: event
                    )
                    // 先吞掉：等看清是"拖边框"还是"单击选中"
                    return
                }

                let bounds = hit.bounds
                // 拖动要记的是**拖动前**的样子，所以快照现在就拍（抬起时再决定入不入栈）
                viewModel.beginMoveUndo(pageIndex: pageIndex)
                moveSession = MoveSession(
                    annotation: hit,
                    page: page,
                    grabOffset: CGPoint(x: pagePoint.x - bounds.minX, y: pagePoint.y - bounds.minY),
                    mouseDownEvent: event
                )
                // 先吞掉：等看清是"拖动"还是"单击"
                return
            }
            viewModel.clearSelection()
            super.mouseDown(with: event)

        case let tool where tool.isDragDraw:
            if viewModel.beginDrawing(tool: tool, pageIndex: pageIndex, at: pagePoint) {
                drawingPage = page
                syncDraftPreview()
            }

        case let tool where tool.isClickToPlace:
            // 点一下决定落点，随后弹窗输入
            viewModel.requestPlacement(tool: tool, pageIndex: pageIndex, at: pagePoint)

        case let tool where tool.appliesToTextSelection:
            // 让它先做文字选择，mouseUp 时再套用标注
            super.mouseDown(with: event)

        default:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewModel, viewModel.isEditable else {
            super.mouseDragged(with: event)
            return
        }

        // 拖拽绘制
        if viewModel.isDrawing, let page = drawingPage {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            viewModel.continueDrawing(to: point)
            // 只更新预览层（一条 CAShapeLayer 的 path），不触发 PDFView 重绘 ——
            // 这是"跟手"的关键，见 draftStrokeLayer 的注释
            syncDraftPreview()
            return
        }

        // 拖边框改宽度（文本注释）
        if let session = resizeSession {
            if !session.hasMoved {
                guard movedDistance(from: session.mouseDownEvent, to: event) >= Self.dragThreshold else {
                    return
                }
                session.hasMoved = true
                NSCursor.resizeLeftRight.set()
            }
            resize(session, to: event)
            return
        }

        // 拖动已有标注
        guard let session = moveSession else {
            super.mouseDragged(with: event)
            return
        }
        if !session.hasMoved {
            guard movedDistance(from: session.mouseDownEvent, to: event) >= Self.dragThreshold else {
                return
            }
            session.hasMoved = true
            NSCursor.closedHand.set()
        }
        move(session, to: event)
    }

    override func mouseUp(with event: NSEvent) {
        // 这次抬起是"双击文本注释"的第二下 —— 内容已经交给编辑框了，
        // 别再惊动 PDFView（它会顺手做"双击选词"，把页面上的文字选蓝一片）
        if swallowNextMouseUp {
            swallowNextMouseUp = false
            return
        }

        guard let viewModel, viewModel.isEditable else {
            super.mouseUp(with: event)
            return
        }

        // 绘制收尾
        if viewModel.isDrawing {
            viewModel.finishDrawing()
            drawingPage = nil
            // 预览层不在这里收起 —— 交给下一次 drawPagePost（那时真批注已经画好了），
            // 否则中间会露出一帧空白，看起来闪一下
            onAnnotationsChanged?()
            return
        }

        // 拖边框收尾
        if let session = resizeSession {
            resizeSession = nil
            if session.hasMoved {
                viewModel.endMoveUndo(committed: true, name: "调整文本宽度")
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
                onAnnotationsChanged?()
            } else {
                // 没拖动 → 就是单击选中，丢掉那份快照，别让列表里凭空多一步撤销
                viewModel.endMoveUndo(committed: false)
            }
            return
        }

        // 拖动收尾
        if let session = moveSession {
            moveSession = nil
            if session.hasMoved {
                // 真的移动过 → 把按下时拍的那份快照入栈（撤销能回到原位）
                viewModel.endMoveUndo(committed: true)
                // 超长笔迹在拖动时跳过了"每帧重建墨迹"（见 reanchorInkIfNeeded），
                // 松手这里补一次 —— 拖完墨迹必须落在框里，否则文件又是坏的
                viewModel.finishMovingAnnotation(session.annotation)
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
                onAnnotationsChanged?()
                return
            }
            // 没移动过 → 就是单击选中：把暂存的快照丢掉，
            // 免得列表里凭空多出一个"移动批注"的撤销步骤
            viewModel.endMoveUndo(committed: false)
            return
        }

        // 文字选区类工具：选完就把标注加上
        if viewModel.activeTool.appliesToTextSelection {
            viewModel.applyToolToSelection(viewModel.activeTool)
            onAnnotationsChanged?()
            return
        }

        super.mouseUp(with: event)
    }

    // MARK: - 拖动已有标注

    private func movedDistance(from startEvent: NSEvent, to currentEvent: NSEvent) -> CGFloat {
        let start = convert(startEvent.locationInWindow, from: nil)
        let current = convert(currentEvent.locationInWindow, from: nil)
        return hypot(current.x - start.x, current.y - start.y)
    }

    private func move(_ session: MoveSession, to event: NSEvent) {
        let point = convert(convert(event.locationInWindow, from: nil), to: session.page)
        let size = session.annotation.bounds.size
        var origin = CGPoint(x: point.x - session.grabOffset.x, y: point.y - session.grabOffset.y)

        // 限制在所在页内（批注挂在某一页上，拖出页面既看不见也找不回来）
        let pageBounds = session.page.bounds(for: .cropBox)
        origin.x = min(max(origin.x, pageBounds.minX), max(pageBounds.minX, pageBounds.maxX - size.width))
        origin.y = min(max(origin.y, pageBounds.minY), max(pageBounds.minY, pageBounds.maxY - size.height))

        let proposed = CGRect(origin: origin, size: size)
        guard proposed != session.annotation.bounds else { return }

        session.annotation.bounds = proposed
        session.annotation.modificationDate = Date()

        // ⚠️ Line（箭头）的 startPoint/endPoint **不要**跟着平移。
        //
        // 它们是**相对 bounds 原点**的坐标，语义上"线在框里的位置"。
        // 平移 bounds 时 PDFKit 会保持这个相对关系不变（实测：只改 bounds，
        // start/end 原样不动），所以线会跟着框一起走。
        //
        // 之前这里额外加了一次 delta，等于平移了两次 —— 表现就是拖动时
        // **箭头飘出虚线框、被裁剪成只剩一部分**（框走了 50，线走了 100）。
        //
        // 但**涂鸦（ink）正相反**：它的墨迹在文件里是**绝对坐标**，改 bounds
        // 它一动不动 —— 于是 `/Rect` 走了、墨迹没走，别的阅读器按 `/Rect`
        // 一裁就是"涂鸦少了一块"。所以 ink 需要重建笔迹让它跟上（见
        // `PDFViewModel.reanchorInkIfNeeded`，里面有两个坑的实测表）。
        viewModel?.reanchorInkIfNeeded(session.annotation)

        annotationsChanged(on: session.page)
        needsDisplay = true
    }

    // MARK: - 拖边框改宽度（文本注释，v1.3.73）

    /// 鼠标是不是抓在某条**文本注释**的左右边框上。是就返回抓的是哪条边。
    ///
    /// ⚠️ 抓取带按**屏幕点**算（先把批注的框换算到视图坐标再比）——
    /// 直接拿页坐标比的话，缩放一变手感就跟着变了。
    private func resizeEdge(of annotation: PDFAnnotation,
                            on page: PDFPage,
                            event: NSEvent) -> ResizeSession.Edge? {
        guard AnnotationItem.Kind(subtype: annotation.type) == .freeText else { return nil }
        // `.standardized` 兜一下：转换回来的矩形原点/宽高方向不保证规范，
        // 不归一化的话下面的 minX/maxX 比大小会翻车
        let viewRect = convert(annotation.bounds, from: page).standardized
        guard viewRect.height > 1, viewRect.width > 1 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        // 纵向也必须落在框内 —— 否则框外老远的地方也会被判成"抓到了边框"
        guard p.y >= viewRect.minY, p.y <= viewRect.maxY else { return nil }
        if abs(p.x - viewRect.minX) <= Self.resizeHandleWidth { return .left }
        if abs(p.x - viewRect.maxX) <= Self.resizeHandleWidth { return .right }
        return nil
    }

    /// 拖边框：改这条文本注释的**换行宽度上限**，高度按新宽度重排内容算出来。
    ///
    /// 三条约束（为了和别的编辑器手感一致）：
    /// - **对侧边缘不动**：拖左边就钉住右边，反之亦然；
    /// - **顶部不动**：宽度变小 → 内容多折几行 → 框往下长
    ///   （PDF 坐标 y 向上，"顶"是 `maxY`）；
    /// - 全程以 `originalBounds` 为基准算，不逐帧累加 —— 来回拖不会漂。
    private func resize(_ session: ResizeSession, to event: NSEvent) {
        let annotation = session.annotation
        let original = session.originalBounds
        let point = convert(convert(event.locationInWindow, from: nil), to: session.page)

        // 鼠标位置 → 框该有多宽
        let rawWidth: CGFloat
        switch session.edge {
        case .left:  rawWidth = original.maxX - point.x
        case .right: rawWidth = point.x - original.minX
        }
        let width = min(max(rawWidth, FreeTextLayout.minimumWidth), session.widthLimit)

        // 高度：按新宽度把内容重排一遍量出来（`requiredHeight` 收的就是框宽）
        let text = annotation.contents ?? ""
        let font = FreeTextLayout.font(of: annotation)
        let height = FreeTextLayout.requiredHeight(for: text, font: font, width: width)

        let originX = session.edge == .left ? original.maxX - width : original.minX
        let originY = original.maxY - height            // 顶部固定

        let proposed = FreeTextLayout.clampToPage(
            CGRect(x: originX, y: originY, width: width, height: height),
            pageBounds: session.page.bounds(for: .cropBox)
        )
        guard proposed != annotation.bounds else { return }

        annotation.bounds = proposed
        // 把用户定的宽度记进批注自己的键里 —— 之后改字号重排时按它折行。
        // 不记的话宽度会跟着内容跑，等于拖了个寂寞（见 `FreeTextLayout.maxWidth(of:)`）。
        FreeTextLayout.setMaxWidth(width, on: annotation)
        annotation.modificationDate = Date()

        annotationsChanged(on: session.page)
        needsDisplay = true
    }

    /// 鼠标停在文本注释的左右边框上时，换成「左右拉伸」光标。
    ///
    /// 没有这个，用户根本不知道边框能拖 —— 功能的可见性全靠它。
    ///
    /// ⚠️ 只扫 `visiblePages`：84 页的文档全扫一遍太浪费，而光标矩形本来
    /// 也只在看得见的页上才有意义。
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let viewModel, viewModel.isEditable else { return }
        for page in visiblePages {
            for annotation in page.annotations
            where AnnotationItem.Kind(subtype: annotation.type) == .freeText {
                let r = convert(annotation.bounds, from: page)
                guard r.height > 1, r.width > 1 else { continue }
                let band = Self.resizeHandleWidth
                addCursorRect(NSRect(x: r.minX - band, y: r.minY, width: band * 2, height: r.height),
                              cursor: .resizeLeftRight)
                addCursorRect(NSRect(x: r.maxX - band, y: r.minY, width: band * 2, height: r.height),
                              cursor: .resizeLeftRight)
            }
        }
    }

    // MARK: - 页面底色（v1.3.67）

    /// 页面**背后**那一层，用户可在 设置 → 外观 → 页面背景色 里改。
    ///
    /// ## 为什么光有 `PDFView.backgroundColor` 不够
    ///
    /// 那个只管**页面外**的留白。页面**内部**的透明区域（透明 PNG 挖空的地方）
    /// 是 PDFView 自己铺的白，`backgroundColor` 够不着 —— 实测把底色设成 `#808080`：
    /// 页面外的留白确实变灰了，而图片里那个透明洞**还是白的**。
    /// 对用户报的那件事（"透明图片看不出哪儿是透明的"）等于没帮上忙。
    ///
    /// ⚠️ **改不了 PDFKit 那层白**（v1.3.67 实测）。
    ///
    /// 头文件 `PDFView.h:263` 写着 `drawPage:toContext:` 的默认实现是
    /// "**erases page to white**" —— 页面内那片白就是它擦的。
    /// 文档说这个方法是给子类 override 的，但**Swift 里够不着**：
    /// `override func drawPage(_:toContext:)` 直接报
    /// `'drawPage(_:toContext:)' was obsoleted in Swift 3`。
    ///
    /// 所以底色改成**烘焙进页面内容**（见 `ImageDocument.makePage`）——
    /// 页面内容先铺一层底色矩形，图片的透明区域就露出它，也盖住了 PDFKit 擦的白。
    ///
    /// 这里只留页面**外**那一层（`PDFView.backgroundColor` 管得着）。

    /// 换深浅模式要重画：默认底色的 `textBackgroundColor` 是**动态色**，
    /// 上面那句 `pageBackground.cgColor` 早就把它解析成固定值了。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 选中框

    /// PDFKit 的绘制钩子：在页面画完后补画选中框。
    /// 用 CGContext 画在**页坐标**里，所以缩放时跟页面一起缩放（矢量，不糊）。
    override func drawPagePost(_ page: PDFPage, to context: CGContext) {
        super.drawPagePost(page, to: context)

        // 1. 自绘页面上已有的批注。
        //
        // 这些批注的 `shouldDisplay` 已被置为 false（PDFKit 不再画它们），
        // 改由这里用 CGContext 画 —— 两个原因（都实测过）：
        //   · PDFKit 的页面层 contentsScale 是 1.0 而屏幕是 2.0，画出来是 1x 放大、边缘发虚；
        //   · PDFKit 的批注层在鼠标拖拽期间根本不刷新。
        // 而 drawPagePost 属于 PDFView 自己的层：原生分辨率 + 实时。
        for annotation in page.annotations where AnnotationRenderer.isSelfRendered(annotation) {
            AnnotationRenderer.draw(annotation, in: context)
        }

        // 2. 正在绘制中的草稿**不在这里画**。
        //
        // ⚠️ 曾经这里有一段"兜底"：预览图层没法用时就把草稿画进页面画布。
        // **实测证明这段兜底是有害的，已删除。**
        //
        // PDFKit 会在布局变化时重建 `pdfView.layer` 的 sublayers，我们的预览层会被挤掉
        // （`superlayer` 变 nil，下一次 `syncDraftPreview` 才重新挂上）。就在这个空档里，
        // 兜底会把草稿画进页面画布 —— 而页面画布**只在真正重绘时才更新**。
        // 于是：图层重新挂上后显示当前形状，画布上却留着那一刻的旧形状，
        // 两个形状同时挂在屏幕上。用户的原话是
        // **「先向右下拖再向左上拖，两个对称的矩形看得出不是连着的，中间有缝隙」** ——
        // 缝隙就是"旧形状"和"新形状"之间的差。松手重绘一次残影才消失。
        //
        // 所以：草稿**只**由独立图层显示，一处都不能多画。

        // 3. 预览层的收尾与纠正：
        //    · 还在画 → 同步一次位置（应对滚动/缩放导致的重绘）
        //    · 已经不在画（含松手后）→ 收起。真批注已经在上面画好了，
        //      这样"草稿 → 正式批注"的切换没有中间态，不会闪出空白。
        if viewModel?.isDrawing == true {
            syncDraftPreview()
        } else {
            hideDraftPreview()
        }

        // 4. 选中框
        guard let viewModel, viewModel.isEditable,
              let item = viewModel.selectedAnnotation,
              let document, document.index(for: page) == item.pageIndex else { return }

        // 线宽/虚线按缩放倒数换算，让屏幕上的粗细保持恒定
        let inverseScale = 1 / max(scaleFactor, 0.05)
        let rect = item.annotation.bounds.insetBy(dx: -3 * inverseScale, dy: -3 * inverseScale)

        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 * inverseScale)
        context.setLineDash(phase: 0, lengths: [5 * inverseScale, 3 * inverseScale])
        context.stroke(rect)
        context.restoreGState()
    }

    // MARK: - 拖动预览层（实现）

    private func installPreviewLayersIfNeeded() {
        wantsLayer = true
        guard let host = layer else { return }
        // 每笔开始都对一次 zPosition：万一图层被拆过再挂回来，顺序也要重新压住页面内容
        draftFillLayer.zPosition = Self.draftFillZ
        draftStrokeLayer.zPosition = Self.draftStrokeZ
        guard draftStrokeLayer.superlayer !== host else { return }
        host.addSublayer(draftFillLayer)      // 填充在下
        host.addSublayer(draftStrokeLayer)    // 描边在上
    }

    /// 把当前草稿同步到预览层。坐标用**视图坐标**。
    private func syncDraftPreview() {
        installPreviewLayersIfNeeded()

        guard let viewModel,
              let page = drawingPage,
              let preview = viewModel.draftPreview(for: page) else {
            hideDraftPreview()
            return
        }

        // 「透明」= 不上色 → 预览层也什么都不显示。
        // CALayer 对 alpha 0 的颜色是安全的（不像 CGContext 会拿黑色兜底），
        // 但显式收掉更省事，也避免万一以后换了实现又踩坑。
        guard preview.color.alphaComponent > AnnotationRenderer.transparentThreshold else {
            hideDraftPreview()
            return
        }

        var transform = pageToViewTransform(for: page)
        let color = preview.color
        // path 用的是页坐标，转到视图坐标后被缩放了 scaleFactor 倍，
        // 所以线宽也要跟着乘，否则缩放后粗细和最终批注对不上
        let lineWidth = preview.lineWidth * scaleFactor

        // ⚠️ 必须关掉隐式动画。否则每次改 path 都会走 0.25 秒的补间动画，
        // 看起来正是"图形慢慢追鼠标"——那正是要修的毛病。
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // frame 跟视图对齐 —— 让 layer 的坐标空间与视图一致，省掉每次换算
        draftStrokeLayer.frame = bounds
        draftFillLayer.frame = bounds

        if let strokePath = preview.shape.stroke, let moved = strokePath.copy(using: &transform) {
            draftStrokeLayer.path = moved
            draftStrokeLayer.strokeColor = color.cgColor
            draftStrokeLayer.lineWidth = lineWidth
            draftStrokeLayer.isHidden = false
        } else {
            draftStrokeLayer.isHidden = true
        }

        if let fillPath = preview.shape.fill, let moved = fillPath.copy(using: &transform) {
            draftFillLayer.path = moved
            draftFillLayer.fillColor = color.cgColor
            draftFillLayer.isHidden = false
        } else {
            draftFillLayer.isHidden = true
        }

        CATransaction.commit()
    }

    private func hideDraftPreview() {
        guard !draftStrokeLayer.isHidden || !draftFillLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draftStrokeLayer.isHidden = true
        draftFillLayer.isHidden = true
        CATransaction.commit()
    }

    /// 页坐标 → 视图坐标的仿射变换。
    ///
    /// 用三个采样点推导，能正确处理缩放、y 翻转和页面旋转 ——
    /// 比手写"乘 scaleFactor"稳（PDFView 的变换受 displayBox / 旋转影响）。
    private func pageToViewTransform(for page: PDFPage) -> CGAffineTransform {
        let origin = convert(CGPoint.zero, from: page)
        let unitX = convert(CGPoint(x: 1, y: 0), from: page)
        let unitY = convert(CGPoint(x: 0, y: 1), from: page)
        return CGAffineTransform(a: unitX.x - origin.x, b: unitX.y - origin.y,
                                 c: unitY.x - origin.x, d: unitY.y - origin.y,
                                 tx: origin.x, ty: origin.y)
    }

    // MARK: - 辅助

    /// 只读模式下点便签 → 弹出内容（补回被自绘方案"接管"掉的 PDFKit 原生行为）
    private func presentNoteContents(_ annotation: PDFAnnotation, from event: NSEvent) {
        notePopover?.close()

        let text = (annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "（空便签）"

        let width: CGFloat = 280
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true          // 方便复制内容
        label.frame = NSRect(x: 10, y: 10, width: width, height: 0)
        label.sizeToFit()

        let height = max(label.frame.height + 20, 36)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 20, height: height))
        label.frame = NSRect(x: 10, y: 10, width: width, height: label.frame.height)
        container.addSubview(label)

        let controller = NSViewController()
        controller.view = container

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        notePopover = popover

        let viewPoint = convert(event.locationInWindow, from: nil)
        popover.show(
            relativeTo: NSRect(x: viewPoint.x - 1, y: viewPoint.y - 1, width: 2, height: 2),
            of: self,
            preferredEdge: .maxY
        )
    }

    private func pageFor(_ event: NSEvent) -> PDFPage? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        // nearest: false —— 点在页间留白里不该触发任何绘制
        return page(for: viewPoint, nearest: false)
    }
}
