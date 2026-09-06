"""Trace the HQPlayer bitmap logo into SVG path data.

Boundary-edge extraction + Ramer-Douglas-Peucker simplification, written out in
full because this box has no numpy/skimage. The method walks the directed unit
edges separating inside pixels from outside ones and chains them head-to-tail;
every loop closes, and holes fall out with the opposite winding, which is what
fill-rule="evenodd" wants.

Source: https://signalyst.com/wp-content/uploads/2024/04/cropped-favicon-1.png
512x512, transparent background, green ECG trace + magenta eighth note.
"""
from PIL import Image

def mask_from(path, scale=None, thicken=0, alpha=70):
    im = Image.open(path).convert('RGBA')
    if scale:
        im = im.resize((scale, scale), Image.LANCZOS)
    W, H = im.size
    px = im.load()
    m = set()
    for x in range(W):
        for y in range(H):
            r, g, b, a = px[x, y]
            if a > alpha and not (r > 235 and g > 235 and b > 235):
                m.add((x, y))
    for _ in range(thicken):
        add = set()
        for (x, y) in m:
            for d in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                add.add((x + d[0], y + d[1]))
        m |= add
    return m, W, H

def loops(mask):
    edges = {}
    for (x, y) in mask:
        if (x, y - 1) not in mask: edges[(x, y)] = (x + 1, y)
        if (x + 1, y) not in mask: edges[(x + 1, y)] = (x + 1, y + 1)
        if (x, y + 1) not in mask: edges[(x + 1, y + 1)] = (x, y + 1)
        if (x - 1, y) not in mask: edges[(x, y + 1)] = (x, y)
    out = []
    while edges:
        start = next(iter(edges))
        loop = [start]; cur = start
        while True:
            nxt = edges.pop(cur, None)
            if nxt is None or nxt == start:
                break
            loop.append(nxt); cur = nxt
        if len(loop) > 7:
            out.append(loop)
    return out

def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    ax, ay = pts[0]; bx, by = pts[-1]
    dx, dy = bx - ax, by - ay
    n = (dx * dx + dy * dy) ** 0.5
    worst, wi = -1.0, 0
    for i in range(1, len(pts) - 1):
        cx, cy = pts[i]
        d = (abs(dy * cx - dx * cy + bx * ay - by * ax) / n) if n else \
            (((cx - ax) ** 2 + (cy - ay) ** 2) ** 0.5)
        if d > worst:
            worst, wi = d, i
    if worst > eps:
        return rdp(pts[:wi + 1], eps)[:-1] + rdp(pts[wi:], eps)
    return [pts[0], pts[-1]]

def to_path(ls, W, size=24.0, eps=1.0, prec=2):
    """Simplify, then FIT the artwork to the viewBox.

    Fitting is not cosmetic: the trace runs to the edge of the source (the
    baseline spans it) and dilation pushes it past, so a naive scale by
    size/W emits negative coordinates that clip in the browser. The logo is
    1.41:1, so it fits to WIDTH and centres vertically.
    """
    simp = []
    for lp in ls:
        p = rdp(lp + [lp[0]], eps)
        if len(p) >= 4:
            simp.append(p[:-1])
    xs = [x for p in simp for (x, y) in p]
    ys = [y for p in simp for (x, y) in p]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sc = size / max(x1 - x0, y1 - y0)
    ox = -x0 * sc + (size - (x1 - x0) * sc) / 2.0
    oy = -y0 * sc + (size - (y1 - y0) * sc) / 2.0
    def f(v):
        return ('%.*f' % (prec, v)).rstrip('0').rstrip('.') or '0'
    parts = []
    for p in simp:
        d = 'M' + f(p[0][0] * sc + ox) + ' ' + f(p[0][1] * sc + oy)
        for (x, y) in p[1:]:
            d += 'L' + f(x * sc + ox) + ' ' + f(y * sc + oy)
        parts.append(d + 'Z')
    return ''.join(parts)

def build(res, thick, eps, size=24.0):
    m, W, H = mask_from('hqp512.png', scale=res, thicken=thick)
    return to_path(loops(m), W, size, eps), len(loops(m))

def svg(d, size=24):
    return ('<svg width="%d" height="%d" version="1.1" viewBox="0 0 24 24" '
            'xmlns="http://www.w3.org/2000/svg">\n <path d="%s" fill="#000" '
            'fill-rule="evenodd"/>\n</svg>\n' % (size, size, d))

if __name__ == '__main__':
    import sys
    for cfg in [(160, 0, 0.8), (128, 1, 1.0), (128, 2, 1.0), (112, 2, 1.1)]:
        res, thick, eps = cfg
        d, n = build(res, thick, eps)
        tag = '%d_%d_%s' % (res, thick, eps)
        open('t%s.svg' % tag, 'w').write(svg(d, 24))
        open('big%s.svg' % tag, 'w').write(svg(d, 384))
        print('%-14s loops=%d chars=%d' % (tag, n, len(d)))
