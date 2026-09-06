"""Generate images/hqplayer.svg - the HQPlayer wordmark knocked out of a waveform.

THE LETTERS ARE TRACED FROM THE RENDERED <text>, THEN FITTED WITH CURVES.

Tracing is not laziness - it is the only route that keeps SF Pro's letterforms:
  * macOS's system font CANNOT be read with fontTools. /System/Library/Fonts/
    SFNS.ttf reports numberOfContours=1 for 'a' and 'e' - the counters are not
    in the shipped outlines at all - and 'P' has two same-wound contours. Real
    text renders correctly only because CoreText does not use those outlines.
    Extracting glyphs from it yields letters with no counters (nonzero) or
    shredded ones (evenodd). Verified; do not retry it.
  * No other installed face is SF Pro. The alternatives (Avenir, Optima,
    Helvetica Neue) are a different typeface and would change the design.
  * skia-pathops is not installed, so there is no boolean-op route either.

So: rasterise the real <text>, walk the boundary, and FIT CURVES to it. The
first version emitted the RDP polygon directly and the letterforms were visibly
faceted - that is what `wordmark.smooth_d` fixes, with a midpoint quadratic
spline that keeps vertices sharper than `corner_deg` as corners (the stems of
H/P/l/r) and curves everything else.

Tracing also SIDESTEPS the overlap problem that killed the font route: a traced
boundary has clean, non-overlapping, correctly-nested contours, so fill-rule
evenodd behaves - counters come back as ink, which is what the design wants.

WHY evenodd AND NOT <text fill="#FFF">:
Material's _svgHandler rewrites every fill= hex as it serves the file, so white
text becomes the THEME colour and the knockout disappears. It also only injects
a fill on a bare <path> when the file contains NO fill= anywhere - so the text's
own fill silently stopped the waveform being themed too. One path, fill="#000"
fill-rule="evenodd", fixes both: fill-rule survives the regex (it has a "-"
where the pattern wants "="), and the single fill= themes correctly.
"""
import wordmark

WAVE=('M22 12L20 13L19 14L18 13L17 16L16 13L15 21L14 13L13 15L12 13L11 17L10 13L9 22'
      'L8 13L7 19L6 13L5 14L4 13L2 12L4 11L5 10L6 11L7 5L8 11L9 2L10 11L11 7L12 11'
      'L13 9L14 11L15 3L16 11L17 8L18 11L19 10L20 11L22 12Z')

# Letter-spacing and the font-size that PRESERVES the wordmark's width (14.4u)
# and centre (x=12) - they trade off, so spacing it out means shrinking it:
#   ls +0.20 -> fs 2.88, x 11.94   (tightest)
#   ls +0.35 -> fs 2.65, x 11.95   <- shipped
#   ls +0.50 -> fs 2.42, x 11.95
#   ls +0.65 -> fs 2.19, x 11.95   (smallest)
# x is NOT 12: text-anchor="middle" counts the TRAILING letter-space in the
# advance width, so positive spacing shifts the ink right and must be corrected.
LS, FS, X = 0.35, 2.65, 11.95

if __name__ == '__main__':
    d, n = wordmark.wordmark_d('HQPlayer', FS, LS, X)
    svg = (f'<svg width="24" height="24" version="1.1" viewBox="0 0 24 24" '
           f'xmlns="http://www.w3.org/2000/svg">\n'
           f' <path d="{WAVE}{d}" fill="#000" fill-rule="evenodd"/>\n</svg>')
    open('hqplayer.svg','w').write(svg)
    print(f"wrote hqplayer.svg: {len(svg)} bytes, {n} contours, "
          f"{d.count('Q')} curves, {d.count('L')} lines")
