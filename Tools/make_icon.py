#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 Tools/artwork/icon-source.jpg 生成 1024x1024 App 图标。

为什么要单独一个脚本：
  AppIcon.appiconset 走的是 iOS 13+ 的单尺寸方案，只要一张 1024 的不透明 PNG，
  系统自己按需缩。所以这里不做 20/29/40/60/76/83.5 那一堆尺寸。

三条硬要求（不满足会被 Xcode 直接拒或上架被拒）：
  1. 1024x1024，无 alpha 通道（有 alpha 会被拒）
  2. 不能预先切圆角 —— 系统遮罩自己会切
  3. sRGB，8bit

用法：
  python3 Tools/make_icon.py                 # 生成到 Assets.xcassets
  python3 Tools/make_icon.py --preview out.jpg   # 另存一份预览图
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Tools", "artwork", "icon-source.jpg")
DST = os.path.join(ROOT, "NpcLab", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "icon-1024.png")
S = 1024

# 稍微收紧一点点构图，让狗头在图标里占比更大；1.0 = 不裁
ZOOM = 1.06
# 构图中心相对画面中心的偏移（-1..1），往左上挪一点，避开人头顶部的空白
OFFSET = (-0.03, 0.02)


def main():
    try:
        from PIL import Image, ImageEnhance, ImageFilter, ImageOps
    except ImportError:
        sys.exit("需要 Pillow：python3 -m pip install pillow")

    if not os.path.isfile(SRC):
        sys.exit("找不到源图 %s，把照片放到这个位置再跑" % SRC)

    im = Image.open(SRC)
    im = ImageOps.exif_transpose(im)          # 手机拍的图常带方向 tag
    im = im.convert("RGB")                    # 去掉 alpha

    # 居中裁成正方形（源图不是正方形时也不会拉变形）
    w, h = im.size
    side = min(w, h)
    cx, cy = w / 2.0 + OFFSET[0] * w, h / 2.0 + OFFSET[1] * h
    side = int(side / ZOOM)
    left = int(min(max(cx - side / 2.0, 0), w - side))
    top = int(min(max(cy - side / 2.0, 0), h - side))
    im = im.crop((left, top, left + side, top + side))

    im = im.resize((S, S), Image.LANCZOS)

    # 轻量修一下：小幅提饱和 + 锐化，缩图后不至于发灰
    im = ImageEnhance.Color(im).enhance(1.08)
    im = ImageEnhance.Contrast(im).enhance(1.04)
    im = im.filter(ImageFilter.UnsharpMask(radius=1.6, percent=68, threshold=2))

    os.makedirs(os.path.dirname(DST), exist_ok=True)
    im.save(DST, "PNG", optimize=True)
    print("icon -> %s  %d bytes  %dx%d  mode=%s"
          % (DST, os.path.getsize(DST), im.width, im.height, im.mode))

    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", default="")
    a, _ = ap.parse_known_args()
    if a.preview:
        im.save(a.preview, quality=92)
        print("preview ->", a.preview)


if __name__ == "__main__":
    main()
