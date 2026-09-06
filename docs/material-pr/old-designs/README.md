Superseded icon designs, kept only so nothing is lost — none of this generates
the shipped icon.

* `make-icon.py` + `wordmark.py` — the HQPlayer wordmark knocked out of a
  waveform. Traces the rendered `<text>` and curve-fits it, because macOS's
  SFNS.ttf has no usable glyph outlines (see CLAUDE.md).
* `make-icon-ecg.py` — an ECG trace and an eighth note, drawn to the measured
  proportions of Signalyst's mark, with the trace as a hollow outlined ribbon.
* `trace-logo.py` — boundary-edge trace of Signalyst's raster logo. The original
  submission; rejected for not being a Material icon.

The shipped `../hqplayer.svg` is a hand-authored path and needs no generator.
