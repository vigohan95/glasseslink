import os
from PIL import Image, ImageDraw

size = 1024
img = Image.new("RGB", (size, size), (12, 14, 18))
d = ImageDraw.Draw(img)
# subtle vignette: a large rounded rect in a slightly lighter tone
d.rounded_rectangle([72, 72, size - 72, size - 72], radius=170, fill=(20, 23, 30))

# two lenses + bridge + temples, drawn as thick rounded strokes
fg = (110, 205, 255)
thick = 46
# left lens
d.rounded_rectangle([196, 396, 470, 610], radius=88, outline=fg, width=thick)
# right lens
d.rounded_rectangle([554, 396, 828, 610], radius=88, outline=fg, width=thick)
# bridge
d.line([470, 452, 554, 452], fill=fg, width=thick)
# temples
d.line([196, 430, 120, 392], fill=fg, width=thick)
d.line([828, 430, 904, 392], fill=fg, width=thick)

out = os.path.join("ios", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(out, exist_ok=True)
img.save(os.path.join(out, "icon-1024.png"), "PNG")

with open(os.path.join(out, "Contents.json"), "w", encoding="utf-8") as f:
    f.write('''{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
''')
with open(os.path.join("ios", "Assets.xcassets", "Contents.json"), "w", encoding="utf-8") as f:
    f.write('{ "info" : { "author" : "xcode", "version" : 1 } }\n')
print("icon written")
