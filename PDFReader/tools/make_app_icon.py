#!/usr/bin/env python3
"""生成 PDF Free 的 app 图标（macOS 规范）。

为什么用代码画而不是找一张图：
  macOS 的图标有硬性规范 —— 1024×1024 画布、内容为 **824×824 居中圆角矩形**
  （圆角半径 185），四周留 100 透明边距。找来的图很难正好符合，
  而且缩放时圆角会糊。代码画一次，之后想换配色/加元素都是改几行。

输出：
  Resources/AppIcon.icns        —— 给 app 用（Info.plist 的 CFBundleIconFile）
  Resources/AppIcon-1024.png    —— 原图，留档 + 看效果

用法：
  <venv>/bin/python tools/make_app_icon.py
"""

import math
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
MARGIN = 100                      # Big Sur 起的规范：内容 824×824
RADIUS = 185                      # 圆角半径（相对 824 约 22.5%）
CONTENT = SIZE - 2 * MARGIN

# 背景渐变：上浅下深。挑蓝色 —— Preview 是灰白、Acrobat 是红，
# 蓝色既是"文档/阅读"的常规色，又能在 Dock 里一眼和它们区分开。
BG_TOP = (0x4E, 0x90, 0xFF)
BG_BOTTOM = (0x1E, 0x46, 0xC8)

PAPER = (255, 255, 255)
FOLD = (0xCB, 0xDA, 0xF7)         # 折角：比纸暗一档的冷白
LINE = (0xB6, 0xC7, 0xE8)         # 正文线条
LINE_ACCENT = (0xFF, 0xC5, 0x3D)  # 一条琥珀高亮 —— 呼应"能标注/高亮"这件事

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Resources")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def arc_points(cx, cy, r, a0, a1, seg=28):
    return [
        (cx + r * math.cos(a0 + (a1 - a0) * i / seg),
         cy + r * math.sin(a0 + (a1 - a0) * i / seg))
        for i in range(seg + 1)
    ]


def build() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # ── 背景：垂直渐变，裁进圆角矩形 ──
    gradient = Image.new("RGBA", (SIZE, SIZE))
    draw = ImageDraw.Draw(gradient)
    for y in range(MARGIN, SIZE - MARGIN):
        t = (y - MARGIN) / (CONTENT - 1)
        draw.line([(MARGIN, y), (SIZE - MARGIN, y)], fill=lerp(BG_TOP, BG_BOTTOM, t) + (255,))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [MARGIN, MARGIN, SIZE - MARGIN, SIZE - MARGIN], RADIUS, fill=255)
    img.paste(gradient, (0, 0), mask)

    # ── 纸张轮廓 ──
    # 右上角是斜切 + 折角的形状，所以不能用 rounded_rectangle：
    # 手工拼一条路径 —— 左上 / 右下 / 左下三个圆角，右上走斜线。
    pw, ph = 420, 540
    px = (SIZE - pw) // 2
    py = 214
    fold = 142
    r = 26

    path = []
    path += arc_points(px + r, py + r, r, math.pi, 1.5 * math.pi)        # 左上圆角
    path.append((px + pw - fold, py))                                    # 上边 → 折角起点
    path.append((px + pw, py + fold))                                    # 斜切线
    path.append((px + pw, py + ph - r))                                  # 右边
    path += arc_points(px + pw - r, py + ph - r, r, 0, 0.5 * math.pi)    # 右下圆角
    path.append((px + r, py + ph))                                       # 下边
    path += arc_points(px + r, py + ph - r, r, 0.5 * math.pi, math.pi)   # 左下圆角
    path.append((px, py + r))                                            # 左边闭合

    def draw_paper(target, fill):
        ImageDraw.Draw(target).polygon(path, fill=fill)

    # 影子：同一轮廓模糊 + 下移，垫在纸张下面（一点就够，别做成"发光"）
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_paper(shadow, (0, 0, 0, 62))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    img.alpha_composite(shadow, (0, 12))

    paper_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_paper(paper_layer, PAPER + (255,))
    # 折角三角：正好补上被斜切掉的右上角，看着就是"纸角折了起来"
    ImageDraw.Draw(paper_layer).polygon(
        [(px + pw - fold, py), (px + pw, py), (px + pw, py + fold)], fill=FOLD + (255,))
    img.alpha_composite(paper_layer)

    # ── 纸上的内容：四行字 + 一条高亮 ──
    lines = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    left, right = px + 58, px + pw - 58
    bar_h = 27
    for i in range(4):
        y = py + 128 + i * 82
        end = right if i != 3 else left + int((right - left) * 0.62)
        colour = LINE_ACCENT if i == 3 else LINE
        ld.rounded_rectangle([left, y, end, y + bar_h], bar_h // 2, fill=colour + (255,))
    img.alpha_composite(lines)

    return img


def write_icns(master: Image.Image, out_dir: str) -> str:
    iconset = os.path.join(out_dir, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    # iconset 的十个尺寸（1x / 2x 成对），全部从 1024 原图 Lanczos 缩下去
    for base in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            edge = base * scale
            name = f"icon_{base}x{base}{suffix}.png"
            master.resize((edge, edge), Image.LANCZOS).save(os.path.join(iconset, name))

    icns = os.path.join(out_dir, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    return icns


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    master = build()
    png = os.path.join(OUT_DIR, "AppIcon-1024.png")
    master.save(png)
    icns = write_icns(master, OUT_DIR)
    for path in (png, icns):
        print(f"{path}  {os.path.getsize(path) // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
