#!/usr/bin/env python3
"""UTUVO Type app icon 單一正本：產生 Icon Composer 文件 `assets/branding/AppIcon.icon`，
iOS 與 macOS 共用同一份（品牌一致）。並用 Apple 自己的渲染器（ictool）算出：
  - iOS app 內品牌位 BrandMark（淡／深色）
  - macOS 26 以前的 `.icns` 備援、1024 PNG、popover／設定側欄用的 `utuvo-type-logo.png`
macOS 26+ 的 Liquid Glass icon 由 scripts/build-app.sh 用 actool 從同一份 `.icon` 編進 Assets.car。

為什麼不是一張 PNG：iOS 26 起 app icon 的 Liquid Glass（邊緣高光、透光、深色／透明／染色外觀）
是系統依圖層即時算的；把玻璃「畫」進一張 PNG 會看起來廉價、在 iOS 上還會變成方塊裡套方塊。

用法：python3 scripts/make-icon.py
"""
import json, os, shutil, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRANDING = os.path.join(ROOT, "assets", "branding")
PKG = os.path.join(BRANDING, "AppIcon.icon")
BRAND = os.path.join(ROOT, "ios", "Assets.xcassets", "BrandMark.imageset")
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"


def c(rgb):
    return "extended-srgb:%.5f,%.5f,%.5f,1.000" % tuple(v / 255 for v in rgb)


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>\n'


def bubble(x0, y0, x1, y1, r, tip):
    tx, ty = tip
    bx = x0 + r * 0.9
    return (f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="{r}" ry="{r}"/>'
            f'<path d="M {bx - 40} {y1 - 90} C {bx - 40} {y1 + 10}, {tx + 40} {ty - 30}, {tx} {ty} '
            f'C {tx + 110} {ty - 6}, {bx + 150} {y1 + 20}, {bx + 190} {y1 - 60} Z"/>')


def cursor(cx, cy, h, w, s, dot_r, dot_dx):
    top, bot = cy - h / 2, cy + h / 2
    return (f'<rect x="{cx - w / 2}" y="{top}" width="{w}" height="{s}" rx="{s / 2}"/>'
            f'<rect x="{cx - w / 2}" y="{bot - s}" width="{w}" height="{s}" rx="{s / 2}"/>'
            f'<rect x="{cx - s / 2}" y="{top + s / 2}" width="{s}" height="{h - s}" rx="{s / 2}"/>'
            f'<circle cx="{cx + dot_dx}" cy="{bot - dot_r}" r="{dot_r}"/>')


# 品牌字型 UTUVO Display 不隨 repo 發佈（字型與 logo 不在 MIT 範圍）。外框已寫進 Assets/cursor.svg，
# 沒有字型也能建置；要重排「I.」時用 UTUVO_BRAND_FONT=<UTUVODisplay-Regular.otf 路徑> 執行。
BRAND_FONT = os.environ.get("UTUVO_BRAND_FONT", "")


def brand_text(text, cx, cy, cap_height):
    """用品牌 UTUVO Display 的字形（向量外框）排 `text`，置中於 (cx, cy)，大寫高＝cap_height。
    只取外框、不改字形。"""
    from fontTools.ttLib import TTFont
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.boundsPen import BoundsPen
    font = TTFont(BRAND_FONT)
    gs, cmap = font.getGlyphSet(), font.getBestCmap()
    cap = font["OS/2"].sCapHeight or font["head"].unitsPerEm * 0.7
    k = cap_height / cap
    # 先量整串字的寬（advance）與實際外框
    x, placed = 0, []
    for ch in text:
        name = cmap[ord(ch)]
        placed.append((name, x))
        x += gs[name].width
    bp = BoundsPen(gs)
    for name, dx in placed:
        gs[name].draw(TransformPen(bp, (1, 0, 0, 1, dx, 0)))
    x0, y0, x1, y1 = bp.bounds
    ox = cx - (x0 + x1) / 2 * k
    oy = cy + (y0 + y1) / 2 * k          # 字型 y 向上、SVG y 向下
    pen = SVGPathPen(gs)
    for name, dx in placed:
        gs[name].draw(TransformPen(pen, (k, 0, 0, -k, ox + dx * k, oy)))
    return f'<path d="{pen.getCommands()}"/>'


def group(name, image, color, dark_color, translucency):
    fills = [{"value": {"solid": c(color)}}]
    if dark_color:
        fills.append({"appearance": "dark", "value": {"solid": c(dark_color)}})
    return {"layers": [{"glass": True, "image-name": image, "name": name, "fill-specializations": fills,
                        "position": {"scale": 1.0, "translation-in-points": [0, 0]}}],
            "lighting": "individual", "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": translucency}}


def main():
    # 沒有字型時沿用已提交的 cursor.svg：先讀起來再重建整包。
    old_cursor = os.path.join(PKG, "Assets", "cursor.svg")
    kept = open(old_cursor).read() if os.path.isfile(old_cursor) else None
    shutil.rmtree(PKG, ignore_errors=True)
    os.makedirs(os.path.join(PKG, "Assets"))
    open(os.path.join(PKG, "Assets", "bubble.svg"), "w").write(svg(bubble(184, 238, 840, 720, 170, (238, 846))))
    # 「I.」用品牌字型 UTUVO Display（跟 wordmark 同一套字），不再是自畫的襯線 I-beam。
    cursor_svg = os.path.join(PKG, "Assets", "cursor.svg")
    if os.path.isfile(BRAND_FONT):
        open(cursor_svg, "w").write(svg(brand_text("I.", 512, 478, 262)))
    elif kept:
        open(cursor_svg, "w").write(kept)
    else:
        raise SystemExit("缺 Assets/cursor.svg：請設 UTUVO_BRAND_FONT 指向 UTUVODisplay-Regular.otf")
    doc = {
        # 品牌橘，照 Apple 自家 icon 的淡兩段漸層（上亮下深）。
        "fill": {"linear-gradient": [c((250, 140, 38)), c((244, 100, 12))]},
        # 第一個群組在最上面。深色外觀：泡泡系統會轉橘，游標改白才看得清楚。
        "groups": [group("cursor", "cursor.svg", (236, 90, 12), (255, 247, 238), 0.15),
                   group("bubble", "bubble.svg", (255, 255, 255), None, 0.5)],
        "supported-platforms": {"squares": "shared"},
    }
    json.dump(doc, open(os.path.join(PKG, "icon.json"), "w"), indent=2)

    os.makedirs(BRAND, exist_ok=True)
    for f in os.listdir(BRAND):
        os.remove(os.path.join(BRAND, f))
    images = []
    for rendition, name, appearance in (("Default", "BrandMark", None), ("Dark", "BrandMark-dark", "dark")):
        out = os.path.join(BRAND, f"{name}@3x.png")
        subprocess.run([ICTOOL, PKG, "--export-image", "--output-file", out, "--platform", "iOS",
                        "--rendition", rendition, "--width", "44", "--height", "44", "--scale", "3",
                        "--design-generation", "27"], check=True, capture_output=True)
        entry = {"filename": f"{name}@3x.png", "idiom": "universal", "scale": "3x"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
              open(os.path.join(BRAND, "Contents.json"), "w"), indent=2)
    render_macos()
    print("wrote", PKG, "BrandMark, macOS icns／logo")


def ictool(out, size, platform="macOS", rendition="Default"):
    subprocess.run([ICTOOL, PKG, "--export-image", "--output-file", out, "--platform", platform,
                    "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "1",
                    "--design-generation", "27"], check=True, capture_output=True)


def render_macos():
    """macOS 14–25 讀 CFBundleIconFile（.icns）；同一份 .icon 用 macOS 規格渲染，外觀跟 26+ 一致。"""
    iconset = os.path.join(BRANDING, "UTUVOType.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    from PIL import Image
    for pt in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            px = pt * scale
            out = os.path.join(iconset, f"icon_{pt}x{pt}{suffix}.png")
            # macOS 格線：本體 824/1024 置中（ictool 出滿版，直接用會比 Dock 裡別的 app 大一圈）
            body = max(1, round(px * 824 / 1024))
            ictool(out, body)
            canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
            off = (px - body) // 2
            canvas.alpha_composite(Image.open(out).convert("RGBA"), (off, off))
            canvas.save(out)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(BRANDING, "UTUVOType.icns")], check=True)
    Image.open(os.path.join(iconset, "icon_512x512@2x.png")).save(os.path.join(BRANDING, "UTUVOType-1024.png"))
    ictool(os.path.join(BRANDING, "utuvo-type-logo.png"), 512)
    shutil.copy(os.path.join(BRANDING, "utuvo-type-logo.png"), os.path.join(ROOT, "docs", "assets", "logo.png"))


if __name__ == "__main__":
    main()
