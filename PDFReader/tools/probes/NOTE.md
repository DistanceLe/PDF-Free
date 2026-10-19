# 探针清单（曾用过的一次性验证工具）

⚠️ **这些探针本身已经没了** —— 它们原先放在 `/tmp`，被系统定期清理掉了
（2026-10-12 发现）。这份清单留在这里，是为了下次要验证同类逻辑时知道"该写什么、
当时验的是什么、结论是什么"，而不是从零想。

**以后新写的探针直接放这个目录**，别再放 `/tmp`。

## 怎么编译 / 运行

探针的套路统一是：`swiftc -parse-as-library` 把**产品源码**一起编进去，
再加一个 `main.swift` 驱动 —— 这样验的是"产品代码的同一份实现"，不是抄一份。

```sh
swiftc -O -o /tmp/xxxprobe \
  Sources/PDFReaderApp/Models/PDFViewModel.swift \
  Sources/PDFReaderApp/Utils/AnnotationRenderer.swift \
  … \
  tools/probes/xxxprobe.swift
```

⚠️ 源文件列表里**要排除带 `@main` 的 `PDFReaderApp.swift`**。
⚠️ 探针里的 viewModel **必须 bind 一个真 PDFView**，否则依赖它的操作会静默失败。

## 清单

| 探针 | 验的是什么 | 当时的结论 |
|------|-----------|-----------|
| `dirtyprobe` | 目录改动 → 脏标记；保存后清除 | 39/39 |
| `tocprobe` | 目录增删改 + 注入 PDF（用 pypdf 独立交叉验证） | 35/35 |
| `tocmoveprobe` | 目录拖动排序 / 层级移动 / 环检测 | 39/39 |
| `bookmarkprobe` | 书签多选、批量删、持久化 | 20/20 |
| `undoprobe` | ⌘Z 的整页快照撤销栈（含跨页） | 38/38 |
| `pageprobe` | `currentPage` 不跟 `clipView` 滚动更新 | 6/6 —— **改判据用"视口中心页"** |
| `arrowprobe` / `polyprobe` | 一体化箭头的轮廓绕向、多子路径填充 | 定位到"双头箭头线身消失" |
| `autosaveprobe` | 写盘：临时文件 → 自检 → 原子替换 | 21/21 |
| `closeguardprobe` | 窗口关闭代理：`windowShouldClose` 时机、返回 false 留窗口、`windowWillClose` 转发 | 10/10 |
| `tocdeleteprobe` | **`document.outlineRoot = nil` 会从文件重新解析目录** | 复现"删掉的目录又回来" |
| `tabprobe` | 窗口分页：`tabbingIdentifier` 相同会不会自动合并、`addTabbedWindow` 的方向 | 必须手动并；`ordered: .above` 才是"往后排" |
| `windowdelegateprobe` | **换掉 `NSWindow.delegate` 的代理写法会不会崩**：delegate 是不是窗口通知的观察者、原 delegate 消失后转发链断在哪、动态兜底(`resolveInstanceMethod`+`class_addMethod`)行不行 | ① delegate 确实是通知观察者（投 `didBecomeKey` 就能收到）；② 旧写法 + 原 delegate 没了 → **崩**（复现 v1.3.51 的崩溃）；③ 动态兜底能挡住任意窗口回调，且原 delegate 活着时不误吞。⚠️ 最后一段故意崩，非 0 退出是预期的 |
| `tabmodeeprobe` | **标签栏怎么默认显示**：`tabbingMode` 上线后设没用、`toggleTabBar` 有效、`tabbedWindows` 的语义、并组顺序 | ① 上屏后设 `preferred` 不生效；② `toggleTabBar(nil)` 显示且关到剩一个也不缩回；③ ⚠️ 开过之后单窗口 `tabbedWindows` = `[自己]`；④ 顺序只能按"打开顺序"排 |
| `pdfcatcheck.py` | 字节级解析 catalog 里有没有 `/Outlines`（不依赖 PDFKit） | 验证"删除真的进了文件" |
| `tabprobe.swift` | **窗口分页**：同 identifier 会不会自动并成标签 | 同 identifier **不会**并；只有显式 `addTabbedWindow` 才行 |
| `tabdetachprobe.swift` | **标签拖出去能不能留住独立窗口 / 最小化窗口还原时会不会被并**（杰哥 2026-10-13 报的两个问题）。旧逻辑 vs 新逻辑并排跑 | ① 旧逻辑下"拖出去的标签"和"还原的最小化窗口"都会被 `prepareWhenReady` **又并回去** —— 根因是它每次都重跑并组、而 `tabbedWindows > 1` 那道判断接不住这两种现场；② 加"入境手续只办一次"后两条都守住，13/13；③ ⚠️ 最小化窗口的 `isVisible` **就是 false**（不是 true），所以"新窗口被并进最小化窗口的组"这条**不会**发生 —— 真正的现场是**还原那一下**；④ `.preferred` 在**上屏前**设，系统自己就会合并同 identifier 的窗口（产品只能上屏后设）；⑤ ⚠️ 从终端裸跑的 app 拿不到键盘焦点，`deminiaturize`/`makeKeyAndOrderFront` **一条 `didBecomeKey` 都不发** —— 用它验证"成为 key 之后"的行为时必须手动把那个回调干的事做一遍 |

## 现在优先用 `AutomationHooks`

从 v1.3.37 起，验证入口集中在
`Sources/PDFReaderApp/Utils/AutomationHooks.swift`（环境变量驱动，正常使用零影响）。
它比 `/tmp` 探针可靠得多（在版本控制里、不会丢），能用它就先用它：

```sh
PDFREADER_AUTOTEST_OPEN="a.pdf,b.pdf" PDFREADER_AUTOTEST_SWITCH_TABS=1 \
    .build/debug/PDFReader --autoquit-after 11

PDFREADER_AUTOTEST_UNSAVED="x.pdf" .build/debug/PDFReader --autoquit-after 5   # 关闭确认
PDFREADER_AUTOTEST_OPEN="x.pdf" PDFREADER_AUTOTEST_REPORT_PROGRESS="x.pdf" …   # 位置/缩放往返
PDFREADER_AUTOTEST_OPEN="x.pdf" PDFREADER_AUTOTEST_CLOSE_TAB=1 …               # ⌘W 分流
```

## 什么时候还是得写探针

`AutomationHooks` 覆盖不到的，主要是**纯数据层**的东西（目录树操作、注入 PDF、
撤销栈、书签持久化）—— 那些用探针一次跑几十条断言最省事。
