"""Render Linsli's magnifying glass at macOS icon sizes."""
import math
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
size = 1024
im = Image.new("RGBA", (size, size))
mask = Image.new("L", im.size)
ImageDraw.Draw(mask).rounded_rectangle((83, 73, 941, 931), 190, fill=255)
shadow = Image.new("L", im.size)
ImageDraw.Draw(shadow).rounded_rectangle((86, 90, 938, 943), 190, fill=100)
im.putalpha(shadow.filter(ImageFilter.GaussianBlur(13)))
tile = Image.new("RGBA", im.size)
d = ImageDraw.Draw(tile)
for y in range(size):
    t = y / size
    d.line((0,y,size,y), fill=(int(39-27*t),int(83-54*t),int(93-54*t),255))
tile.putalpha(mask)
im.alpha_composite(tile)
d = ImageDraw.Draw(im)
def rod(start, end, width, color):
    d.line((*start,*end), fill=color, width=width)
    r = width/2
    for x,y in (start,end): d.ellipse((x-r,y-r,x+r,y+r),fill=color)
rod((603,610),(764,774),78,"#142c35")
rod((602,598),(764,761),70,"#aed9d2")
rod((623,618),(754,749),47,"#7bafb0")
cx,cy=449,438
def disc(r, color, x=cx, y=cy):
    d.ellipse((x-r,y-r,x+r,y+r), fill=color)
disc(258,"#142f37",cx+3,cy+12)
disc(258,"#d1ede5")
disc(242,"#73999b")
disc(233,"#193d49")
for r in range(222,0,-1):
    t=r/222
    color=tuple(round(a+(b-a)*t**1.6) for a,b in [(32,12),(140,61),(152,79)])
    disc(r,color,cx-37*(1-t),cy-50*(1-t))
d.arc((cx-197,cy-197,cx+197,cy+197),212,266,fill="#d6fcf1",width=16)
d.arc((cx-198,cy-198,cx+198,cy+198),35,77,fill="#5ea5b1",width=8)
for n in (16,32,128,256,512):
    for scale in (1,2):
        im.resize((n*scale,n*scale),Image.Resampling.LANCZOS).save(out / f"icon_{n}x{n}{'@2x' if scale==2 else ''}.png")
