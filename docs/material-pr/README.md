# Add HQPlayer player icon

Adds a player icon for HQPlayer instances, which report `model` as `hqplayer`.

New `images/hqplayer.svg` (24×24, single path, `fill="#000"`) and one entry in
`misc/player-icons.json`.

## The artwork

A pulse trace — the idea behind HQPlayer's own mark, drawn as a plain Material
icon rather than copied from it. One path, monochrome, no strokes, so
`_svgHandler` themes it with the single `fill=` substitution and it inverts
correctly on a dark background.

## Copyright

Original artwork, drawn for this PR. No affiliation or endorsement implied.

Happy to drop the artwork and point the entry at an existing icon
(`amplifier` works) if you'd rather not carry it — the mapping is the useful part.
