import AppKit
import SwiftUI
import PDFKit

/// 批注列表面板：列出当前文档所有页的批注，可跳转、多选、批量删除，并可把批注写回 PDF 文件。
@MainActor
struct AnnotationSidebar: View {

    /// 必须用 @ObservedObject 而不是普通 let：
    /// SwiftUI 会对子视图的存储属性做记忆化比较，`PDFViewModel` 是类，
    /// 引用没变就认为视图无需更新，body 不会重新求值 ——
    /// 表现就是「新增批注后列表不刷新，切换一次面板才出现」。
    @ObservedObject var viewModel: PDFViewModel

    /// 待删除的批注 —— 单条或一批，等弹窗确认后才真正删
    @State private var pendingDeletions: [AnnotationItem] = []

    /// 列表里的多选。
    ///
    /// `AnnotationItem.id` 是 `ObjectIdentifier(annotation)`，而底层的 `PDFAnnotation`
    /// 实例在 `reloadAnnotations()` 前后是同一个，所以 tag 始终对得上 ——
    /// 不会出现"列表刷新一次、选中的东西就丢了"。
    @State private var selection = Set<ObjectIdentifier>()

    @State private var messageTitle = "已保存"
    @State private var saveMessage: String?
    /// 备份文件路径 —— 弹窗里「在访达中显示」要用
    @State private var backupURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.annotations.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            toolbar
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) {
                viewModel.removeAnnotations(pendingDeletions)
                // 删完把选择里那些已经不存在的 id 清掉，免得工具栏还挂着旧计数
                selection.subtract(pendingDeletions.map(\.id))
                pendingDeletions = []
                // ⚠️ 上面是直接改 `@State`，**绕过**了 `listSelection` 的 `set` ——
                // 不复位的话键盘监听会以为列表里还选着东西，再按 Delete 就落进空选集合、
                // 什么都不发生（静默失效）。这里是唯一一处绕过 Binding 的改动点。
                viewModel.annotationListSelectionCount = selection.count
            }
            Button("取消", role: .cancel) {
                pendingDeletions = []
            }
        } message: {
            Text(deleteAlertMessage)
        }
        // 侧边栏切到别的面板时这个视图会销毁，但 viewModel 上的计数**不会自己归零** ——
        // 留着的话，切到书签栏后按 Delete 会去打一个已经不存在的列表（事件被吞、什么都不发生）。
        .onDisappear {
            viewModel.annotationListSelectionCount = 0
        }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "highlighter")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("暂无批注")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("选中文本后可高亮/下划线，也可添加便签或签名")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            // 列表空的时候，用户可能是"刚把最后一条删完" —— 那种情况下还需要保存一次
            // 才能把删除写进文件（按钮现在允许这么做，见它上面的注释）。
            // 这里点一句，免得人以为"没批注就等于没什么可存的"。
            if viewModel.isEditable {
                Text("刚删掉最后一条？用下方「保存批注到 PDF」把改动写进文件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// 列表。
    ///
    /// 多选用 `List(selection:)` 而不是自己抓点击 —— **Cmd 点选、Shift 范围选**
    /// 系统都替我们做好了，自己写要处理锚点、修饰键、去重一堆事。
    ///
    /// 代价是**这一层不能再挂 `onTapGesture`**：它会吃掉点击、让 List 收不到选择事件，
    /// 多选就永远触发不了。「点了就跳转」改由 `listSelection` 这个 Binding 的 `set` 承担
    /// （写在 `set` 里而不是 `onChange`，是为了和"当前页"标记落在同一次更新 —— 见 `listSelection`）。
    private var list: some View {
        List(selection: listSelection) {
            ForEach(viewModel.annotations) { item in
                AnnotationRow(
                    item: item,
                    isSelected: isRowSelected(item),
                    isCurrentPage: viewModel.currentPageIndex == item.pageIndex
                )
                // 行的外观只由这三个值决定 —— 加上它，SwiftUI 会跳过没变的行。
                // 选中时列表整体重绘是"闪一下"的主要来源，这里是最省事的止血点。
                .equatable()
                .tag(item.id)
                // 这里传的是**常量**，作用是清掉系统默认的选中底色 ——
                // 否则它会和行内自绘的底色叠成两层蓝。
                //
                // ⚠️ 千万别改成"按行算出来的颜色"：那样 SwiftUI 会认为每一行的背景
                // 每次都可能变，选中任意一条都得把整列表的底色重算一遍 —— 就是那次"闪"。
                // 底色请画在 `AnnotationRow` 里面（那里有 `Equatable` 兜着，没变的行会跳过）。
                .listRowBackground(Color.clear)
                .contextMenu { contextMenu(for: item) }
            }
        }
        .listStyle(.plain)
        // Delete / 退格键删除。
        //
        // ⚠️ **主路径不是这里，而是键盘监听。** `onDeleteCommand` 要列表拿到焦点才会触发，
        // 而焦点一般在 PDF 视图那边 —— 实测在列表里选中后按 Delete 毫无反应。
        // 真正生效的是下面那条 `listDeleteRequestTick`：`EditablePDFView` 的全局键盘监听
        // 看到 Delete、且列表里有选中项时，把它 +1（那条路不依赖焦点）。
        //
        // 这里保留一份只是为了兜底：万一键盘监听没装上（或将来改动），
        // 事件若真走到列表，行为仍然正确。两处都走同一个确认弹窗，不会重复触发 ——
        // 键盘监听会吞掉事件，`.onDeleteCommand` 就不再有机会跑。
        .onDeleteCommand {
            guard viewModel.isEditable, !selectedItems.isEmpty else { return }
            pendingDeletions = selectedItems
        }
        .onChange(of: viewModel.listDeleteRequestTick) { _, _ in
            // 键盘监听那边按下了 Delete（列表里选中的那些）。
            // 这里才拿得到"选的是哪几条"，然后走统一的确认弹窗。
            guard viewModel.isEditable, !selectedItems.isEmpty else { return }
            pendingDeletions = selectedItems
        }
        .onChange(of: viewModel.selectedAnnotation?.id) { _, newID in
            // 在页面上点选了批注 → 列表跟着高亮。
            // 只在"列表没有多选"时同步，否则会把用户刚框好的一批冲掉。
            guard let newID, selection.count <= 1, selection != [newID] else { return }
            selection = [newID]
            // 这里也是直接改 `@State`，绕过了 `listSelection` 的 `set` ——
            // 计数要顺手补上，否则"列表选中 1 条"这件事对键盘监听不可见（同类静默失效，
            // 另一处在删除确认里）。
            viewModel.annotationListSelectionCount = selection.count
        }
    }

    /// 列表的选择绑定 —— **跳转写在这里，不写在 `onChange` 里**。
    ///
    /// `onChange` 的语义是"状态改完、视图更新**之后**"才回调，也就是**下一帧**。
    /// 于是点一行会看到两次更新：先列表刷新（选中配色变），下一帧才补上"当前页"标记 ——
    /// 用户的原话是「对应的批注并不会马上刷新出小蓝条，只会闪一下」。
    ///
    /// 放到 `set` 里，`selection` 和 `currentPageIndex` 就落在**同一次**更新里，
    /// 没有那个"先闪一下、再出现"的中间帧。
    private var listSelection: Binding<Set<ObjectIdentifier>> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue

                // 告诉 viewModel 现在选了几条 —— `EditablePDFView` 那个全局键盘监听
                // 靠它决定 Delete 键走哪条路（列表里选中了就交给列表，它能删一批）。
                //
                // ⚠️ 这里是**视图更新过程中**，`annotationListSelectionCount` 必须保持
                // 非 `@Published` 的普通属性：`@Published` 在这个时机赋值会触发 SwiftUI 的
                // "Publishing changes from within view updates" 警告，更新还有被丢的风险。
                viewModel.annotationListSelectionCount = newValue.count

                // 只有"恰好选中一条"才跳转 —— 多选是批量操作，别把页面拽来拽去
                guard newValue.count == 1, let id = newValue.first,
                      let item = viewModel.annotations.first(where: { $0.id == id }) else { return }
                viewModel.goToAnnotation(item)
            }
        )
    }

    /// 这一行算不算"选中"。
    ///
    /// ⚠️ **只看列表自己的 `selection`，不要再读 `viewModel.selectedAnnotation`。**
    ///
    /// 读两个来源会让"点一行"触发**两轮**重绘：先是 `selection` 变（List 自己更新一轮），
    /// 紧接着 `onChange` 里的 `goToAnnotation` 又把 `selectedAnnotation` 写掉（body 再算一轮）。
    /// 两轮连在一起看就是那次"闪一下"。
    ///
    /// 页面点选那条路径依然有效：`onChange(of: viewModel.selectedAnnotation?.id)`
    /// 会把它同步进 `selection`，只晚一帧 —— 肉眼看不出，但省掉整整一轮重绘。
    ///
    /// 行底色**只承载"选中"这一种语义**：早先「当前页的批注」也铺了一层更浅的蓝
    /// （`accentColor.opacity(0.07)`），可那是**跟着翻页自动变**的 ——
    /// 用户什么都没选，列表里却飘着一片浅蓝，和真正的选中态抢同一套视觉语言。
    /// 现在「当前页」改由行内的左侧竖条表示（见 `AnnotationRow`）。
    private func isRowSelected(_ item: AnnotationItem) -> Bool {
        selection.contains(item.id)
    }

    @ViewBuilder
    private func contextMenu(for item: AnnotationItem) -> some View {
        Button("跳转到该批注") {
            viewModel.goToAnnotation(item)
        }
        Button("复制批注内容") {
            copyToPasteboard(item.displayContent)
        }
        if item.kind == .freeText {
            Divider()
            Button("框适应内容大小") {
                viewModel.fitFreeTextToContent(item)
            }
            .disabled(!viewModel.isEditable)
        }
        Divider()
        Button("删除", role: .destructive) {
            pendingDeletions = [item]
        }
        .disabled(!viewModel.isEditable)

        // 右键点在多选范围内 → 顺手给一个批量删除
        if selection.count > 1, selection.contains(item.id) {
            Button("删除选中的 \(selection.count) 条", role: .destructive) {
                pendingDeletions = selectedItems
            }
            .disabled(!viewModel.isEditable)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            // 有选中才出现，而且放在最上面 —— 选完就想删，别让人往下找
            if !selection.isEmpty {
                Button(role: .destructive) {
                    pendingDeletions = selectedItems
                } label: {
                    Label("删除选中的 \(selection.count) 条", systemImage: "trash")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(!viewModel.isEditable)
            }

            Button {
                save()
            } label: {
                // 图片没有"PDF"可存 —— 它的出口是导出一张新图片（v1.3.66）
                Label(viewModel.isImageDocument ? "导出为图片…" : "保存批注到 PDF",
                      systemImage: "square.and.arrow.down")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            // ⚠️ 判据必须和 ⌘S 那条路一致（菜单 → `.pdfSaveAnnotations` → `saveAnnotationsToDisk()`），
            // 也就是**只要求可编辑**。
            //
            // 早先这里还挂着 `viewModel.annotations.isEmpty`，用意是"没批注就没什么可存"——
            // 但那恰恰搞反了最要紧的一种情形：**把最后一条批注删完之后，正是最需要保存的时候**
            // （要把"删除"写进文件）。那时列表是空的，按钮就点不动了，只能靠 ⌘S 兜着。
            //
            // 删掉这条之后，"空列表也能存"是预期行为：多存一次只是把同样的内容重写一遍
            // （写前照例自动备份），不会丢东西；而"该存时存不了"是实打实的坑。
            .disabled(!viewModel.isEditable)

            // 早期版本给文本注释写死了 48 点高，长内容会被裁；
            // 这个按钮把那些框加高到放得下（只加高，不动宽度）
            Button {
                fixClippedTextAnnotations()
            } label: {
                Label("修复被裁切的文本注释", systemImage: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(!hasFreeTextAnnotation || !viewModel.isEditable)

            if viewModel.isEditable {
                Text("写入前会自动备份原文件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("只读模式：点顶部「编辑」后可修改")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
    }

    // MARK: - 派生状态

    private var hasFreeTextAnnotation: Bool {
        viewModel.annotations.contains { $0.kind == .freeText }
    }

    /// 当前选中的批注（按列表顺序，不按点击顺序）
    private var selectedItems: [AnnotationItem] {
        viewModel.annotations.filter { selection.contains($0.id) }
    }

    private var deleteAlertTitle: String {
        pendingDeletions.count > 1
            ? "确认删除这 \(pendingDeletions.count) 条批注？"
            : "确认删除批注？"
    }

    private var deleteAlertMessage: String {
        guard let first = pendingDeletions.first else { return "" }
        if pendingDeletions.count == 1 {
            return first.displayContent
        }
        // 多条时列出前 8 条，剩下的用计数带过 —— 弹窗里塞几十行没法看
        let shown = pendingDeletions.prefix(8).map {
            "· \($0.kind.rawValue)（第 \($0.pageIndex + 1) 页）"
        }
        var text = shown.joined(separator: "\n")
        if pendingDeletions.count > 8 {
            text += "\n…共 \(pendingDeletions.count) 条"
        }
        return text
    }

    // MARK: - 行为

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeletions.isEmpty },
            set: { if !$0 { pendingDeletions = [] } }
        )
    }

    private func fixClippedTextAnnotations() {
        let count = viewModel.expandClippedFreeText()
        messageTitle = count > 0 ? "已修正" : "无需修正"
        saveMessage = count > 0
            ? "已加高 \(count) 条放不下内容的文本注释。\n改动要「保存批注到 PDF」后才写入文件。"
            : "没有被裁切的文本注释。\n（想让某一条贴合内容大小，在列表里右键它选「框适应内容大小」）"
        presentSaveMessage()
    }


    /// 弹出"保存结果"提示（v1.3.62）。
    ///
    /// ⚠️ 这里**必须用我们自己的 `AlertPresenter`，不能用 SwiftUI 的 `.alert`**：
    /// SwiftUI 的 alert 是它自己创建的窗口，我们够不着 —— 而那个窗口**自带标签页身份**，
    /// 系统会给它画一条"标签栏 + `+`"浮在弹框上面（用户报过两次）。
    /// 我们自己的弹框会在挂 sheet 前把标签页身份摘掉，所以干净。
    private func presentSaveMessage() {
        AlertPresenter.present(title: messageTitle,
                               message: saveMessage ?? "",
                               buttons: backupURL == nil ? ["好"] : ["在访达中显示备份", "好"],
                               on: viewModel.pdfView?.window) { index in
            // 第一个按钮是"显示备份"时才有这个动作
            if let backupURL, index == 0 {
                NSWorkspace.shared.activateFileViewerSelecting([backupURL])
            }
        }
    }

    private func save() {
        // 图片文档的出口是「导出为图片…」（v1.3.66）—— 它那份 PDF 是内存里造的、
        // 没有 `documentURL`，走 `saveAnnotationsToDisk` 只会得到一句"保存失败"。
        // 分路交给 `performSave`，这里只管把结果说清楚。
        if viewModel.isImageDocument {
            do {
                // 返回 nil ＝ 用户在保存面板里按了取消 → 什么都不用说
                guard let exported = try viewModel.performSave() else { return }
                messageTitle = "已导出"
                backupURL = nil
                saveMessage = "批注已合成进新图片：\n\(exported.path)\n\n原图没有被改动。"
            } catch {
                messageTitle = "导出失败"
                backupURL = nil
                saveMessage = error.localizedDescription
            }
            presentSaveMessage()
            return
        }

        messageTitle = "已保存"
        do {
            let backup = try viewModel.saveAnnotationsToDisk()
            backupURL = backup?.url
            if let backup {
                saveMessage = "批注已写入 PDF。\n原文件的备份\(backup.location.description)：\n\(backup.url.path)"
            } else {
                saveMessage = "批注已写入 PDF。"
            }
            // 目录是**另外**注入进去的（PDFKit 不写目录，见 PDFOutlineWriter）——
            // 它失败不算保存失败（批注确实进去了），但要如实说清楚
            if let notice = viewModel.outlineWriteNotice {
                messageTitle = "已保存（目录未写入）"
                saveMessage = (saveMessage ?? "") + "\n\n⚠️ " + notice
            }
            presentSaveMessage()
        } catch {
            backupURL = nil
            saveMessage = "保存失败：\(error.localizedDescription)"
            presentSaveMessage()
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - 单行

@MainActor
private struct AnnotationRow: View, Equatable {
    let item: AnnotationItem
    /// 是不是选中的那条（列表多选，或页面上点选的那条）—— 决定文字/图标用不用强调色
    let isSelected: Bool
    /// 是不是位于当前正在看的这一页 —— 由左侧竖条标示
    let isCurrentPage: Bool

    /// 只有这几样影响外观，相等就让 SwiftUI 跳过这一行的重绘。
    ///
    /// 不实现它的话，选中任意一条都会让**整列表每一行**重新求值 ——
    /// 几十行 × 每行一个 `contextMenu`（要建 NSMenu）在建，肉眼就是"闪一下"。
    ///
    /// ⚠️ 只比 `item.id` 是不够的：`id` 是 `ObjectIdentifier(annotation)`（对象身份），
    /// 批注**内容**被改时它纹丝不动 —— 那样列表就会停留在旧文字上。
    /// 所以内容、日期、页码都得一起比。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.content == rhs.item.content
            && lhs.item.date == rhs.item.date
            && lhs.item.pageIndex == rhs.item.pageIndex
            && lhs.isSelected == rhs.isSelected
            && lhs.isCurrentPage == rhs.isCurrentPage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 「当前页」标记：一根细竖条。
            //
            // 早先这里用的是**整行淡蓝底**，但那个颜色是跟着翻页自动变的，
            // 用户没做任何选择列表里却有一片蓝，和真正的选中态抢视觉 ——
            // 见 `AnnotationSidebar.rowBackground` 的说明。
            // 竖条只占 3pt，不打断阅读，翻页时也能一眼看出这页有哪些批注。
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isCurrentPage ? Color.accentColor.opacity(0.55) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 1)

            Image(systemName: item.kind.icon)
                .font(.system(size: 12))
                // 选中只由行底色表达 —— "强调色文字 + 强调色底"会糊在一起看不清
                .foregroundStyle(isCurrentPage ? Color.primary : .secondary)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.kind.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(item.pageIndex + 1) 页")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let date = item.date {
                        Text(date, style: .date)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(item.displayContent)
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        // 选中底色画在**行内**，不交给 `listRowBackground`。
        //
        // 原因：`listRowBackground` 是 List 层的 modifier，SwiftUI 判断不出
        // "只有这一行的背景变了"，一点选中就得把整列表的底色重算一遍 —— 那就是"闪"。
        // 画在这里则受 `Equatable` 保护：只有 `==` 判为不同的行才会重新求值。
        //
        // 系统那个默认的选中底色已在 List 一侧用 `.listRowBackground(Color.clear)` 清掉，
        // 所以这里画多少就是多少，不会叠成两层蓝。
        //
        // 浓淡：0.12 够看出"选中"，又不会把正文字压得发闷 ——
        // 早先用 0.22 时文字（尤其次要信息）明显发灰。目录面板同步改成同一个值。
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}
