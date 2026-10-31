import argparse
import json
import os
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='从 scripts/brand_icon.png 生成 FlGuo 平台图标；需要 Pillow。')
parser.add_argument('--output', type=Path, default=root)
parser.add_argument('--source', type=Path, default=root / 'scripts/brand_icon.png')
parser.add_argument('--font', type=Path)
options = parser.parse_args()
output = options.output

with Image.open(options.source) as original:
    if original.width != original.height:
        raise SystemExit('图标源必须为正方形，避免拉伸或裁切原图。')
    if original.width < 1:
        raise SystemExit('图标源尺寸无效。')
    source = original.convert('RGBA')

# 原图保持不变；平台派生图只缩放，不重绘或锐化图案。
foreground = source.resize((1024, 1024), Image.Resampling.LANCZOS)
icon = Image.new('RGBA', (1024, 1024), 'white')
icon.alpha_composite(foreground)
icon = icon.convert('RGB')  # iOS App Store 图标不允许透明通道。
rounded = foreground

# Android adaptive 的108dp画布保留72dp图形，避免系统圆形/方形蒙版裁掉主体。
adaptive = Image.new('RGBA', (1536, 1536))
adaptive.alpha_composite(foreground, (256, 256))
# 原图含白底，不能直接拿alpha作单色图标，否则只剩一整块圆角方形。
mask = ImageChops.multiply(
    ImageOps.invert(ImageOps.grayscale(foreground.convert('RGB'))),
    foreground.getchannel('A'),
)
silhouette = Image.new('RGBA', (1024, 1024), 'white')
silhouette.putalpha(mask)
monochrome = Image.new('RGBA', (1536, 1536))
monochrome.alpha_composite(silhouette, (256, 256))


def save(image, name, **kwargs):
    destination = output / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, **kwargs)


def asset_catalog(directory, image):
    contents = json.loads((root / directory / 'Contents.json').read_text(encoding='utf-8'))
    for entry in contents['images']:
        if 'filename' in entry:
            size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
            save(image.resize((size, size), Image.Resampling.LANCZOS), directory / entry['filename'])


asset_catalog(Path('ios/Runner/Assets.xcassets/AppIcon.appiconset'), icon)
save(rounded.resize((256, 256), Image.Resampling.LANCZOS),
     'windows/runner/resources/app_icon.ico', format='ICO',
     sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
macos_canvas = Image.new('RGBA', (1024, 1024))
macos_badge = rounded.resize((824, 824), Image.Resampling.LANCZOS)
macos_canvas.alpha_composite(macos_badge, (100, 100))
asset_catalog(Path('macos/Runner/Assets.xcassets/AppIcon.appiconset'), macos_canvas)
for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
    legacy = round(48 * scale)
    layer = round(108 * scale)
    save(rounded.resize((legacy, legacy), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
    save(adaptive.resize((layer, layer), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher_foreground.png')
    save(monochrome.resize((layer, layer), Image.Resampling.LANCZOS),
         f'android/app/src/main/res/mipmap-{density}/ic_launcher_monochrome.png')

# 选择平台可用字体；不再要求macOS字体路径，Windows也可重复生成同一套资源。
font_path = options.font
if font_path is None:
    candidates = [
        Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts/segoeuib.ttf',
        Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'),
    ]
    font_path = next((candidate for candidate in candidates if candidate.exists()), None)
if font_path is None or not font_path.is_file():
    raise SystemExit('没有可用的横幅字体，请通过 --font 指定字体文件。')
font = ImageFont.truetype(str(font_path), 76)
for resource in ['tv_banner', 'tv_banner_all_sources']:
    banner = Image.new('RGB', (640, 360), '#F5F9FC')
    badge = rounded.resize((180, 180), Image.Resampling.LANCZOS)
    banner.paste(badge, (44, 90), badge)
    draw = ImageDraw.Draw(banner)
    draw.text((255, 128), 'FlGuo', font=font, fill='#3B4552')
    save(banner, f'android/app/src/main/res/drawable-xhdpi/{resource}.png')
print(f'已从 {options.source.name} 生成 Android/iOS/Windows/macOS 图标及电视横幅。')
