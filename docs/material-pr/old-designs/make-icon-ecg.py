"""Generate images/hqplayer.svg for the Material PR.

The trace is drawn as a HOLLOW OUTLINED RIBBON, not a solid stroke: the note is
solid, so an outlined trace separates the two without cutting either and reads
lighter than it at every size.

A polyline offset to both sides SELF-INTERSECTS where the spike meets the
baseline and leaves junction lines across the shape. So the ribbon is rasterised
at 32x, its true outline walked (boundary-edge extraction) to union it, and that
simplified with Ramer-Douglas-Peucker. Pillow only - no numpy/potrace here.

TWO TRAPS, both of which cost a round:
  * RDP needs an OPEN polyline. Run it on a closed loop and every contour
    collapses to two points (the first-to-last chord has zero length). Split the
    loop at the point farthest from its start and simplify the two halves.
  * The ribbon extends `half` BEYOND the polyline's end points, and its own
    stroke adds half of stroke-width on top. Pull the waveform's ends in or it
    clips silently at the viewBox edge.

Waveform coordinates are MEASURED off Signalyst's mark - see CLAUDE.md.
"""
from PIL import Image, ImageDraw
import math

S=32                      # supersample: 24 units -> 768 px
N=24*S

def build_mask(pts, half):
    im=Image.new('1',(N,N),0); d=ImageDraw.Draw(im)
    r=half*S
    for (x1,y1),(x2,y2) in zip(pts,pts[1:]):
        d.line([x1*S,y1*S,x2*S,y2*S], fill=1, width=int(round(2*r)))
    for (x,y) in pts:            # round joins / caps
        d.ellipse([x*S-r,y*S-r,x*S+r,y*S+r], fill=1)
    px=im.load()
    return {(x,y) for y in range(N) for x in range(N) if px[x,y]}

def loops(mask):
    e={}
    for (x,y) in mask:
        if (x,y-1) not in mask: e[(x,y)]=(x+1,y)
        if (x+1,y) not in mask: e[(x+1,y)]=(x+1,y+1)
        if (x,y+1) not in mask: e[(x+1,y+1)]=(x,y+1)
        if (x-1,y) not in mask: e[(x,y+1)]=(x,y)
    out=[]
    while e:
        s=next(iter(e)); loop=[s]; c=s
        while True:
            n=e.pop(c,None)
            if n is None or n==s: break
            loop.append(n); c=n
        if len(loop)>8: out.append(loop)
    return out

def rdp(p,eps):
    if len(p)<3: return p
    dmax=0.0; idx=0
    (x1,y1),(x2,y2)=p[0],p[-1]
    dx,dy=x2-x1,y2-y1; L=math.hypot(dx,dy) or 1.0
    for i in range(1,len(p)-1):
        d=abs(dy*p[i][0]-dx*p[i][1]+x2*y1-y2*x1)/L
        if d>dmax: dmax,idx=d,i
    if dmax>eps:
        return rdp(p[:idx+1],eps)[:-1]+rdp(p[idx:],eps)
    return [p[0],p[-1]]

def simplify_closed(l,eps):
    # RDP needs an OPEN polyline: split the loop at the point farthest from l[0]
    x0,y0=l[0]
    k=max(range(len(l)), key=lambda i:(l[i][0]-x0)**2+(l[i][1]-y0)**2)
    a=rdp(l[:k+1],eps); b=rdp(l[k:]+[l[0]],eps)
    return a[:-1]+b[:-1]

def to_path(ls,eps):
    segs=[]
    for l in ls:
        q=simplify_closed(l,eps)
        if len(q)<3: continue
        segs.append("M"+" L".join(f"{x/S:.2f} {y/S:.2f}" for x,y in q)+"Z")
    return "".join(segs)

# ends pulled in so ribbon + its own stroke stay inside the 24 box
wave=[(1.9,16.5),(7.4,16.5),(8.5,13.7),(9.6,16.5),(10.4,16.5),
      (11.9,3.1),(13.0,16.5),(13.7,19.6),(14.8,13.9),(15.7,16.5),(22.1,16.5)]
NOTE=('<path d="M15.6 3.2h1.2v15.6h-1.2z M16.8 3.2C19.8 4.4 21.2 7 20.8 10.2 '
      '20.4 13.4 19 15 17.2 16.4c1.6-1.8 2.6-3.8 2.4-6.2-.2-2.8-1-4.6-2.8-6z" fill="#000"/>\n'
      ' <ellipse cx="13.9" cy="18.8" rx="2.7" ry="1.5" transform="rotate(-20 13.9 18.8)" fill="#000"/>')

HALF   = 1.05    # ribbon half-width
STROKE = 0.9     # outline weight
EPS    = 2.0     # RDP tolerance, in supersampled px

mask = build_mask(wave, HALF)
d    = to_path(loops(mask), EPS)
svg  = (f'<svg width="24" height="24" version="1.1" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">\n'
        f' <path d="{d}" fill="none" stroke="#000" stroke-width="{STROKE}" stroke-linejoin="round"/>\n'
        f' {NOTE}\n</svg>')
open('hqplayer.svg','w').write(svg)
print(f"wrote hqplayer.svg  ({d.count('L')} outline points)")
