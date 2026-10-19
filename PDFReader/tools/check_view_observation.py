#!/usr/bin/env python3
"""扫描 Views/ 下"读了模型状态却没订阅"的视图。

## 为什么需要这个检查

SwiftUI 里一个视图的 `body` 只在**它自己观察的对象**变化时重新求值。
如果在一个视图里读另一个对象的 `@Published` 属性（典型写法：父视图持有
`AppViewModel`，却去读 `tab.viewModel.isEditable`），值变了不会触发重绘 ——
界面看起来"点了没反应"，切换标签或窗口尺寸变化后才突然正常。

编译器完全不报错，只能靠人肉发现或静态扫描。本项目已经踩过两次：
批注列表不刷新、点「编辑」工具条不出现 + 搜索右侧栏不出现。

## 判据

对每个 `struct ... : View`，在它的 `body` 里搜两类"跨对象读状态"：

1. **链式**：`某tab.viewModel.someProperty` —— 从 `DocumentTab` 直达 `PDFViewModel`
   的属性。这是最容易犯的（父视图顺手写 `tab.viewModel.isEditable`），而且因为
   成员名恰好也叫 `viewModel`，肉眼看不出它没被订阅。
2. **别名**：声明成普通 `let x: PDFViewModel`，然后 `x.someProperty`。

两类都排除**方法调用**（`x.方法(`），所以 `tab.viewModel.bind(to:)` 这类命令式注入不会误报。

正确写法：父视图只决定"渲染哪个 tab"，把 tab 传下去，
由子视图 `@ObservedObject var pdfVM = tab.viewModel` 去读状态。

用法：
    python3 tools/check_view_observation.py [要扫描的目录]
    python3 tools/check_view_observation.py --selftest      # 先确认检查器本身没失灵
退出码 0 = 干净，1 = 有问题，2 = 用法错误。
"""

import re
import sys
from pathlib import Path

# 会被视图观察的模型类型（改动模型时记得同步这里）
MODEL_TYPES = {
    "PDFViewModel",
    "AppViewModel",
    "AnnotationStyle",
    "SpeechReader",
    "AutoScroller",
    "BookmarksStore",
}

DEFAULT_VIEWS_DIR = Path(__file__).resolve().parent.parent / "Sources" / "PDFReaderApp" / "Views"

STRUCT_RE = re.compile(
    r"^(?:@MainActor\s*\n)?"
    r"(?:private\s+|public\s+|internal\s+)?"
    r"struct\s+(\w+)\s*:\s*View\b",
    re.M,
)
DECL_RE = re.compile(
    r"^\s*(?:(@ObservedObject|@StateObject|@State|@EnvironmentObject)\s+)?"
    r"(?:private\s+)?(?:let|var)\s+(\w+)\s*:\s*([\w.]+)",
    re.M,
)


def strip_comments(text: str) -> str:
    """去掉行注释和块注释，避免注释里的示例代码被误判。"""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?<!\w)//.*?$", "", text, flags=re.M)
    return text


def find_structs(source: str):
    """按大括号配平切出每个 struct 的完整文本。

    注意 depth 从 0 起算：`match.end()` 停在 `View` 之后，struct 自己的 `{`
    还没数进去。若从 1 起算，那个 `{` 会被重复计数，范围一路吞到文件末尾 ——
    症状是后面每个 struct 都报同一批问题。（这个坑踩过一次。）
    """
    for match in STRUCT_RE.finditer(source):
        name = match.group(1)
        start = match.end()
        depth = 0
        end = len(source)
        i = start
        while i < len(source):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        yield name, source[start:end + 1]


def property_reads(body: str, var_name: str):
    """`var_name.成员` 中属于"读属性"的成员名（排除方法调用）。"""
    hits = set()
    for m in re.finditer(rf"\b{re.escape(var_name)}\.(\w+)", body):
        if body[m.end():m.end() + 1] == "(":
            continue  # 方法调用
        hits.add(m.group(1))
    return sorted(hits)


def chained_reads(body: str):
    """`xx.viewModel.成员` 形式的链式状态读取（排除方法调用）。"""
    hits = set()
    for m in re.finditer(r"\b(\w+)\.viewModel\.(\w+)", body):
        if body[m.end():m.end() + 1] == "(":
            continue
        hits.add((m.group(1), m.group(2)))
    return sorted(hits)


def check_source(raw: str, filename: str):
    """返回 [(struct 名, 表达式, 成员列表, 是否链式)]。"""
    source = strip_comments(raw)
    problems = []

    for struct_name, body in find_structs(source):
        observed, not_observed = set(), {}
        for decl in DECL_RE.finditer(body):
            wrapper, var_name, var_type = decl.group(1), decl.group(2), decl.group(3)
            base_type = var_type.split(".")[-1]
            if base_type not in MODEL_TYPES:
                continue
            if wrapper in ("@ObservedObject", "@StateObject", "@State", "@EnvironmentObject"):
                observed.add(var_name)
            else:
                not_observed[var_name] = base_type

        # 只看 body：init 里的 `self.x = tab.viewModel.y` 是有意的注入，不算问题
        body_index = body.find("var body")
        view_body = body[body_index:] if body_index >= 0 else body

        for owner, member in chained_reads(view_body):
            problems.append((struct_name, f"{owner}.viewModel", [member], True))

        for var_name, var_type in not_observed.items():
            if var_name in observed:
                continue
            members = property_reads(view_body, var_name)
            if members:
                problems.append((struct_name, f"{var_name}: {var_type}", members, False))

    return problems


# --- 自检样本：改检查逻辑后用它确认没失灵 -----------------------------------

SELFTEST_BAD = """
import SwiftUI

@MainActor
struct BadView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        VStack {
            if let tab = viewModel.selectedTab, tab.viewModel.isEditable {
                Text("工具条")
            }
        }
    }
}
"""

SELFTEST_GOOD = """
import SwiftUI

@MainActor
struct GoodView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        if let tab = viewModel.selectedTab {
            PaletteHost(tab: tab)
        }
    }
}

@MainActor
private struct PaletteHost: View {
    let tab: DocumentTab
    @ObservedObject var pdfVM: PDFViewModel

    init(tab: DocumentTab) {
        self.tab = tab
        self.pdfVM = tab.viewModel
    }

    var body: some View {
        if pdfVM.isEditable { Text("\\(pdfVM.activeTool)") }
    }
}
"""

SELFTEST_NOISE = """
import SwiftUI

// 注释里写 tab.viewModel.someProperty 不应被算进来
@MainActor
struct NoiseView: View {
    let viewModel: PDFViewModel

    var body: some View {
        Button("跳转") {
            viewModel.goToPage(at: 0)
            tab.viewModel.bind(to: pdfView)     // 方法调用，不该报
        }
    }
}
"""


def selftest() -> bool:
    print("=== 检查器自检 ===")
    ok = True

    bad = check_source(SELFTEST_BAD, "bad")
    if any("isEditable" in members for _, _, members, _ in bad):
        print("  ✅ 能抓到「父视图读 tab.viewModel 属性」")
    else:
        print("  ❌ 漏报：抓不到链式读取 —— 检查器失灵了")
        ok = False

    good = check_source(SELFTEST_GOOD, "good")
    if good:
        print(f"  ❌ 误报：正确写法被算成问题 —— {good}")
        ok = False
    else:
        print("  ✅ 正确写法不误报")

    noise = check_source(SELFTEST_NOISE, "noise")
    if not noise:
        print("  ✅ 方法调用与注释不误报")
    else:
        print(f"  ❌ 误报：{noise}")
        ok = False

    print(f"  → {'自检通过' if ok else '自检失败'}")
    return ok


def main():
    args = sys.argv[1:]

    if "--selftest" in args:
        return 0 if selftest() else 1

    views_dir = Path(args[0]).resolve() if args else DEFAULT_VIEWS_DIR
    if not views_dir.is_dir():
        print(f"找不到目录：{views_dir}", file=sys.stderr)
        return 2

    total_files, total_problems = 0, 0
    for path in sorted(views_dir.glob("*.swift")):
        total_files += 1
        for struct_name, expr, members, chained in check_source(
            path.read_text(encoding="utf-8"), path.name
        ):
            total_problems += 1
            print(f"❌ {path.name} → struct {struct_name}")
            print(f"   `{expr}` 没有被订阅，但 body 里读了它的属性：{', '.join(members)}")
            if chained:
                print("   → 值变化不会触发重绘。把用到这些状态的部分拆成独立子视图，")
                print("     在子视图里写 `@ObservedObject var pdfVM = tab.viewModel`，")
                print("     父视图只决定「渲染哪个 tab」。")
            else:
                print("   → 值变化不会触发重绘。把它改成 @ObservedObject 声明。")
            print()

    print(f"扫描了 {total_files} 个视图文件。")
    if total_problems == 0:
        print("✅ 未发现「读了状态却没订阅」的视图。")
        return 0
    print(f"⚠️ 发现 {total_problems} 处问题。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
