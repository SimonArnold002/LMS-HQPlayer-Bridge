#!/usr/bin/env python3
"""Generate README.html (and the GitHub Pages index.html redirect) from README.md.

Zero dependencies — a focused Markdown converter for the subset README.md uses
(headings, paragraphs, bold/italic/code/links, ordered + nested unordered lists,
GFM tables, blockquotes, fenced code, hr). The "Features at a glance" table is
rendered as a card grid; every other table becomes a styled <table>. The hero
(title, tagline, badges, Download/Install buttons) is built from the title +
intro paragraph plus the fixed template below.

The version badge is read live from install.xml (single source of truth), so a
regen always reflects the current release — nothing is hardcoded here.

Run from the repo root:  python3 tools/make_readme_html.py
These are docs only — not part of the plugin zip.
"""

import os
import re
import sys

ZIP_NAME = "HQPlayerBridge.zip"
GITHUB_URL = "https://github.com/SimonArnold002/LMS-HQPlayer-Bridge"
# The version badge is read live from install.xml; the rest are static.
STATIC_BADGES = ["LMS 8.0.0+", "HQPlayer Embedded 6", "No extra audio hop"]


def read_version(root):
    """Current plugin version from install.xml (the single source of truth)."""
    try:
        with open(os.path.join(root, "HQPlayerBridge", "install.xml"), encoding="utf-8") as f:
            m = re.search(r"<version>([^<]+)</version>", f.read())
            return m.group(1).strip() if m else None
    except OSError:
        return None

CSS = """
  :root {
    --lb-purple: #353070;
    --lb-purple-dark: #211d4d;
    --lb-orange: #eb743b;
    --ink: #1c1c28;
    --muted: #5b5b6b;
    --line: #e4e4ec;
    --bg: #f7f7fa;
    --card: #ffffff;
    --code-bg: #f0f0f5;
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    color: var(--ink);
    background: var(--bg);
    line-height: 1.6;
    -webkit-font-smoothing: antialiased;
  }
  a { color: var(--lb-orange); text-decoration: none; }
  a:hover { text-decoration: underline; }

  header.hero {
    background: linear-gradient(135deg, var(--lb-purple) 0%, var(--lb-purple-dark) 100%);
    color: #fff;
    padding: 56px 24px 48px;
    text-align: center;
  }
  header.hero h1 { margin: 0 0 10px; font-size: 2.1rem; letter-spacing: -0.01em; }
  header.hero p.tagline { margin: 0 auto; max-width: 660px; color: #d6d4ea; font-size: 1.08rem; }
  header.hero p.tagline a { color: #ffb58c; }
  .badges { margin-top: 22px; display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
  .badge {
    display: inline-block; padding: 5px 13px; border-radius: 999px;
    font-size: 0.82rem; font-weight: 600;
    background: rgba(255,255,255,0.12); color: #fff; border: 1px solid rgba(255,255,255,0.22);
  }
  .badge.accent { background: var(--lb-orange); border-color: var(--lb-orange); }
  .hero-actions { margin-top: 26px; display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; }
  .btn { display: inline-block; padding: 11px 22px; border-radius: 8px; font-weight: 600; font-size: 0.95rem; }
  .btn-primary { background: var(--lb-orange); color: #fff; }
  .btn-primary:hover { text-decoration: none; filter: brightness(1.06); }
  .btn-ghost { background: rgba(255,255,255,0.12); color: #fff; border: 1px solid rgba(255,255,255,0.30); }
  .btn-ghost:hover { text-decoration: none; background: rgba(255,255,255,0.20); }

  main { max-width: 880px; margin: 0 auto; padding: 8px 24px 64px; }
  section { margin-top: 44px; }
  h2 {
    font-size: 1.45rem; margin: 0 0 6px; padding-bottom: 8px;
    border-bottom: 3px solid var(--lb-orange); display: inline-block;
  }
  h3 { font-size: 1.12rem; margin: 26px 0 6px; color: var(--lb-purple); }
  p { margin: 10px 0; }
  ul, ol { padding-left: 22px; }
  li { margin: 5px 0; }
  li > ul { margin-top: 5px; }

  table {
    width: 100%; border-collapse: collapse; margin: 14px 0;
    background: var(--card); border-radius: 10px; overflow: hidden;
    box-shadow: 0 1px 3px rgba(0,0,0,0.06); font-size: 0.95rem;
  }
  th, td { text-align: left; padding: 11px 14px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { background: var(--lb-purple); color: #fff; font-weight: 600; }
  tr:last-child td { border-bottom: none; }
  tr:nth-child(even) td { background: #fafafc; }
  td strong { color: var(--lb-purple); }

  code {
    background: var(--code-bg); padding: 2px 6px; border-radius: 5px;
    font-family: "SF Mono", SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.88em;
  }
  pre {
    background: var(--lb-purple-dark); color: #f3f1ff; padding: 16px 18px;
    border-radius: 10px; overflow-x: auto; font-size: 0.9rem;
  }
  pre code { background: none; padding: 0; color: inherit; }

  blockquote {
    margin: 14px 0; padding: 12px 18px; background: #fff7f1;
    border-left: 4px solid var(--lb-orange); border-radius: 0 8px 8px 0; color: var(--muted);
  }
  blockquote p { margin: 0; }

  .feature-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 14px; margin-top: 16px; }
  .card {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px 18px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.05);
  }
  .card h4 { margin: 0 0 6px; font-size: 1rem; color: var(--lb-purple); }
  .card p { margin: 0; font-size: 0.9rem; color: var(--muted); }
  .card .needs { display: block; margin-top: 8px; font-size: 0.78rem; font-weight: 600; color: var(--lb-orange); }

  footer {
    text-align: center; color: var(--muted); font-size: 0.88rem;
    padding: 32px 24px 48px; border-top: 1px solid var(--line); margin-top: 48px;
  }
  @media (max-width: 600px) {
    header.hero h1 { font-size: 1.6rem; }
    main { padding: 8px 16px 48px; }
  }
"""


def slug(text):
    s = re.sub(r"<[^>]+>", "", text).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s


def inline(text):
    """Convert inline Markdown to HTML (code spans protected from other rules)."""
    codes = []

    def stash(m):
        codes.append(m.group(1))
        return "\x00%d\x00" % (len(codes) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", text)

    def unstash(m):
        c = codes[int(m.group(1))]
        c = c.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        return "<code>%s</code>" % c

    return re.sub(r"\x00(\d+)\x00", unstash, text)


def parse_table(lines, i):
    """Parse a GFM table starting at line i. Returns (header, rows, next_i)."""
    def cells(row):
        row = row.strip()
        if row.startswith("|"):
            row = row[1:]
        if row.endswith("|"):
            row = row[:-1]
        return [c.strip() for c in row.split("|")]

    header = cells(lines[i])
    i += 2  # skip header + separator
    rows = []
    while i < len(lines) and "|" in lines[i] and lines[i].strip():
        rows.append(cells(lines[i]))
        i += 1
    return header, rows, i


def render_table(header, rows):
    out = ["<table>", "<thead><tr>"]
    out += ["<th>%s</th>" % inline(h) for h in header]
    out.append("</tr></thead>")
    out.append("<tbody>")
    for r in rows:
        out.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in r) + "</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def render_cards(header, rows):
    out = ['<div class="feature-cards">']
    for r in rows:
        feat = re.sub(r"\*\*", "", r[0]).strip()
        gives = r[1] if len(r) > 1 else ""
        needs = (r[2] if len(r) > 2 else "").strip()
        card = ['<div class="card"><h4>%s</h4><p>%s</p>' % (inline(feat), inline(gives))]
        if needs and needs not in ("—", "-"):
            label = "nothing" if needs.lower() == "nothing" else needs
            card.append('<span class="needs">Needs: %s</span>' % inline(label))
        card.append("</div>")
        out.append("".join(card))
    out.append("</div>")
    return "\n".join(out)


def render_list(lines, i):
    """Render an (optionally nested) list via an indent stack. Returns (html, next_i)."""
    item_re = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")
    html = []
    stack = []  # list of (indent, tag)

    def close_to(indent):
        while stack and stack[-1][0] > indent:
            html.append("</li></%s>" % stack.pop()[1])

    while i < len(lines):
        m = item_re.match(lines[i])
        if not m:
            if lines[i].strip() == "":
                break
            break
        indent = len(m.group(1))
        ordered = m.group(2)[0].isdigit()
        tag = "ol" if ordered else "ul"
        if not stack:
            html.append("<%s>" % tag)
            stack.append((indent, tag))
        elif indent > stack[-1][0]:
            html.append("<%s>" % tag)
            stack.append((indent, tag))
        else:
            close_to(indent)
            html.append("</li>")
        html.append("<li>%s" % inline(m.group(3)))
        i += 1

    while stack:
        html.append("</li></%s>" % stack.pop()[1])
    return "\n".join(html), i


def convert_body(md_lines):
    """Convert the section body (everything from the first '## ') to HTML."""
    out = []
    i = 0
    section_open = False
    cur_h2 = ""

    def para_flush(buf):
        if buf:
            out.append("<p>%s</p>" % inline(" ".join(buf)))
            buf.clear()

    para = []
    while i < len(md_lines):
        line = md_lines[i]
        s = line.strip()

        if s.startswith("## "):
            para_flush(para)
            if section_open:
                out.append("</section>")
            title = s[3:].strip()
            cur_h2 = title
            out.append('<section id="%s">' % slug(title))
            out.append("<h2>%s</h2>" % inline(title))
            section_open = True
            i += 1
            continue

        if s.startswith("### "):
            para_flush(para)
            out.append("<h3>%s</h3>" % inline(s[4:].strip()))
            i += 1
            continue

        if s == "---" or s == "":
            para_flush(para)
            i += 1
            continue

        if s.startswith("```"):
            para_flush(para)
            i += 1
            code = []
            while i < len(md_lines) and not md_lines[i].strip().startswith("```"):
                code.append(md_lines[i])
                i += 1
            i += 1  # closing fence
            esc = "\n".join(code).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            out.append("<pre><code>%s</code></pre>" % esc)
            continue

        if s.startswith(">"):
            para_flush(para)
            quote = []
            while i < len(md_lines) and md_lines[i].strip().startswith(">"):
                quote.append(md_lines[i].strip()[1:].strip())
                i += 1
            out.append("<blockquote><p>%s</p></blockquote>" % inline(" ".join(quote)))
            continue

        # GFM table: a '|' line followed by a '---' separator line
        if "|" in line and i + 1 < len(md_lines) and re.match(r"^\s*\|?[\s:|-]+\|?\s*$", md_lines[i + 1]) and "-" in md_lines[i + 1]:
            para_flush(para)
            header, rows, i = parse_table(md_lines, i)
            if cur_h2.lower().startswith("features"):
                out.append(render_cards(header, rows))
            else:
                out.append(render_table(header, rows))
            continue

        if re.match(r"^\s*([-*]|\d+\.)\s+", line):
            para_flush(para)
            html, i = render_list(md_lines, i)
            out.append(html)
            continue

        para.append(s)
        i += 1

    para_flush(para)
    if section_open:
        out.append("</section>")
    return "\n".join(out)


def build(md, version=None):
    lines = md.splitlines()
    title = next((l[2:].strip() for l in lines if l.startswith("# ")), "README")

    # Tagline = first non-empty paragraph after the title, before the first '## '.
    tagline = ""
    started = False
    for l in lines:
        if l.startswith("# "):
            started = True
            continue
        if not started:
            continue
        if l.startswith("## "):
            break
        if l.strip() and not l.strip().startswith("---"):
            tagline = l.strip()
            break

    body_start = next((idx for idx, l in enumerate(lines) if l.startswith("## ")), len(lines))
    body = convert_body(lines[body_start:])

    # Version badge first (accent), then the static badges.
    badge_labels = (["v%s" % version] if version else []) + STATIC_BADGES
    badges = "\n".join(
        '    <span class="badge%s">%s</span>' % (" accent" if i == 0 else "", b)
        for i, b in enumerate(badge_labels)
    )

    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{css}</style>
</head>
<body>

<header class="hero">
  <h1>{title}</h1>
  <p class="tagline">{tagline}</p>
  <div class="badges">
{badges}
  </div>
  <div class="hero-actions">
    <a class="btn btn-primary" href="{zip}">Download latest</a>
    <a class="btn btn-ghost" href="#installation">Installation</a>
  </div>
</header>

<main>
{body}
</main>

<footer>
  <p>{title} — a plugin for Lyrion Music Server ·
  <a href="{gh}">View on GitHub</a></p>
</footer>

</body>
</html>
""".format(
        title=inline(title),
        css=CSS,
        tagline=inline(tagline),
        badges=badges,
        zip=ZIP_NAME,
        body=body,
        gh=GITHUB_URL,
    )


INDEX_REDIRECT = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=README.html">
<link rel="canonical" href="README.html">
<title>HQPlayer Bridge — LMS Plugin</title>
</head>
<body>
<p>Redirecting to <a href="README.html">the HQPlayer Bridge page</a>…</p>
</body>
</html>
"""


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    md_path = os.path.join(root, "README.md")
    with open(md_path, encoding="utf-8") as f:
        md = f.read()

    version = read_version(root)
    html = build(md, version)
    with open(os.path.join(root, "README.html"), "w", encoding="utf-8") as f:
        f.write(html)
    with open(os.path.join(root, "index.html"), "w", encoding="utf-8") as f:
        f.write(INDEX_REDIRECT)

    print("Wrote README.html (%d bytes) and index.html (redirect)" % len(html))


if __name__ == "__main__":
    main()
