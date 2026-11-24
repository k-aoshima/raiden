"""Blender で描いた中身（正方形）を、macOS のアイコンの格子に合わせて仕上げる。
1024 の中に 824×824（左上 100,100）、角の半径 185 の角丸の四角で切り抜き、下に薄い影を付ける。
形がこの格子とずれると、macOS 26 は灰色の台に載せて表示する。

  python3 tools/icon/finish_icon.py <描いた png> <出力の png>
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

src, out = sys.argv[1], sys.argv[2]
S, BODY, OFF, R, K = 1024, 824, 100, 185, 4   # K: 角をなめらかにするための拡大率
body = Image.open(src).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
mask = Image.new("L", (S * K, S * K), 0)
ImageDraw.Draw(mask).rounded_rectangle((OFF * K, OFF * K, (OFF + BODY) * K - 1, (OFF + BODY) * K - 1), R * K, fill=255)
mask = mask.resize((S, S), Image.LANCZOS)
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# 影: 角丸の形を下に 10 ずらしてぼかす
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh.putalpha(mask.point(lambda v: v * 0.28))
sh = sh.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -10)).filter(ImageFilter.GaussianBlur(14))
icon.alpha_composite(sh)
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
layer.paste(body, (OFF, OFF))
layer.putalpha(mask)
icon.alpha_composite(layer)
icon.save(out)
print("書き出し", out)
