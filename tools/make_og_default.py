"""공유 링크 미리보기 기본 카드(1200x630) 생성 → web/og-default.png
사진/영상이 아닌 파일(zip 등)·폴더를 공유했을 때 디스코드·카톡 등에 뜨는 이미지."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1200, 630
BG, PINK, HOT, PURPLE, DIM = (11, 7, 16), (255, 111, 181), (255, 45, 142), (183, 156, 255), (154, 144, 191)
web = Path(__file__).resolve().parents[1] / "web"
pixel = ImageFont.truetype(str(web / "PressStart2P.ttf"), 64)
kr = ImageFont.truetype("/usr/share/fonts/OTF/IBMPlexSansKR-SemiBold.otf", 40)

img = Image.new("RGB", (W, H), BG)
# 은은한 핑크·퍼플 빛 번짐
glow = Image.new("RGB", (W, H), BG)
g = ImageDraw.Draw(glow)
g.ellipse((-200, -250, 700, 450), fill=(70, 18, 52))
g.ellipse((650, 250, 1450, 900), fill=(42, 26, 78))
img = Image.blend(img, glow.filter(ImageFilter.GaussianBlur(120)), 1.0)
d = ImageDraw.Draw(img)


def heart(cx, cy, s, color):
    """픽셀 하트 (7x6 도트)"""
    rows = ["0110110", "1111111", "1111111", "0111110", "0011100", "0001000"]
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == "1":
                x0, y0 = cx + (x - 3.5) * s, cy + (y - 3) * s
                d.rectangle((x0, y0, x0 + s - 1, y0 + s - 1), fill=color)


d.rounded_rectangle((40, 40, W - 40, H - 40), radius=36, outline=(255, 111, 181, 60), width=3)
heart(W // 2, 190, 18, HOT)
title = "SHINODRIVE"
tw = d.textlength(title, font=pixel)
d.text(((W - tw) / 2 + 5, 305 + 5), title, font=pixel, fill=(90, 20, 60))   # 그림자
d.text(((W - tw) / 2, 305), title, font=pixel, fill=PINK)
sub = "파일이 공유됐어요 — 눌러서 받기"
sw = d.textlength(sub, font=kr)
d.text(((W - sw) / 2, 420), sub, font=kr, fill=(244, 236, 255))
for x, y, s, c in [(170, 520, 6, PURPLE), (1030, 130, 7, PINK), (1060, 500, 5, DIM), (140, 140, 5, PINK)]:
    heart(x, y, s, c)

out = web / "og-default.png"
img.save(out, optimize=True)
print(out, out.stat().st_size, "bytes")
