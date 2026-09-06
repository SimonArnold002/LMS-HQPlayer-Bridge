"""Trace the rendered wordmark and emit SMOOTH curves, not polygons."""
import subprocess, os, math, tempfile
from PIL import Image

FAM="system-ui, -apple-system, 'Roboto', 'Product Sans', 'Segoe UI', sans-serif"

def render(text, fs, ls, x, R):
    s=(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="{R}" height="{R}">'
       f'<text x="{x}" y="13" text-anchor="middle" font-family="{FAM}" font-size="{fs}" '
       f'font-weight="900" letter-spacing="{ls}" fill="#000">{text}</text></svg>')
    tmp=tempfile.mkdtemp(); src=os.path.join(tmp,'t.svg'); open(src,'w').write(s)
    subprocess.run(['qlmanage','-t','-s',str(R),'-o',tmp,src],capture_output=True)
    im=Image.open(os.path.join(tmp,'t.svg.png')).convert('RGBA')
    bg=Image.new('RGBA',im.size,(255,255,255,255)); bg.alpha_composite(im)
    return bg.convert('L').resize((R,R),Image.LANCZOS)

def mask_of(img, thresh=128):
    W,H=img.size; px=img.load()
    bb=img.point(lambda v:255 if v<thresh else 0).getbbox()
    if not bb: return set(),(0,0)
    x0,y0,x1,y1=bb
    m={(x,y) for y in range(y0,y1) for x in range(x0,x1) if px[x,y]<thresh}
    return m,(x0,y0)

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
        if len(loop)>16: out.append(loop)
    return out

def rdp(p,eps):
    if len(p)<3: return p
    dmax=0.0; idx=0
    (x1,y1),(x2,y2)=p[0],p[-1]
    dx,dy=x2-x1,y2-y1; L=math.hypot(dx,dy) or 1.0
    for i in range(1,len(p)-1):
        d=abs(dy*p[i][0]-dx*p[i][1]+x2*y1-y2*x1)/L
        if d>dmax: dmax,idx=d,i
    if dmax>eps: return rdp(p[:idx+1],eps)[:-1]+rdp(p[idx:],eps)
    return [p[0],p[-1]]

def simplify_closed(l,eps):
    x0,y0=l[0]
    k=max(range(len(l)),key=lambda i:(l[i][0]-x0)**2+(l[i][1]-y0)**2)
    return rdp(l[:k+1],eps)[:-1]+rdp(l[k:]+[l[0]],eps)[:-1]

def turn(a,b,c):
    v1=(b[0]-a[0],b[1]-a[1]); v2=(c[0]-b[0],c[1]-b[1])
    l1=math.hypot(*v1); l2=math.hypot(*v2)
    if l1<1e-9 or l2<1e-9: return 0.0
    cs=max(-1.0,min(1.0,(v1[0]*v2[0]+v1[1]*v2[1])/(l1*l2)))
    return math.degrees(math.acos(cs))

def smooth_d(poly, corner_deg, T, prec=2):
    """Midpoint quadratic spline: smooth vertices become curves, corners stay sharp."""
    n=len(poly)
    corner=[turn(poly[i-1],poly[i],poly[(i+1)%n])>corner_deg for i in range(n)]
    mid=lambda a,b:((a[0]+b[0])/2.0,(a[1]+b[1])/2.0)
    f=lambda p:f"{round(T(p)[0],prec):g} {round(T(p)[1],prec):g}"
    start = poly[0] if corner[0] else mid(poly[-1],poly[0])
    out=["M"+f(start)]
    for i in range(n):
        P=poly[i]; N=poly[(i+1)%n]
        if corner[i]:
            out.append("L"+f(P))
            nxt = N if corner[(i+1)%n] else mid(P,N)
            if nxt!=P: out.append("L"+f(nxt))
        else:
            out.append("Q"+f(P)+" "+f(mid(P,N)))
    return "".join(out)+"Z"

def wordmark_d(text='HQPlayer', fs=2.65, ls=0.35, x=11.95, R=2048, eps=2.2, corner_deg=42, prec=2):
    img=render(text,fs,ls,x,R)
    m,_=mask_of(img)
    s=24.0/R
    T=lambda p:(p[0]*s,p[1]*s)
    parts=[]
    for l in loops(m):
        q=simplify_closed(l,eps)
        if len(q)<3: continue
        parts.append(smooth_d(q,corner_deg,T,prec))
    return "".join(parts), len(parts)
