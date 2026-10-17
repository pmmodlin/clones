#!/usr/bin/env python3
"""Renders the README terminal illustration (docs/images/terminal-*.svg).

Usage: python3 scripts/render-terminal.py en|ru > docs/images/terminal-en.svg
The text mirrors real `clones` output; sizes and PIDs are example values.
"""
import sys
from html import escape

LANG = sys.argv[1] if len(sys.argv) > 1 else "en"
FG, DIM, GREEN, PROMPT = "#e6e6e6", "#8b8b8b", "#5fd17a", "#c98bff"
RED, GREENDOT = "#E5484D", "#30A46C"

def t(en, ru):
    return ru if LANG == "ru" else en

# Each line: list of (text, color, bold)
L = []
def line(*segs): L.append([s if isinstance(s, tuple) else (s, FG, False) for s in segs])

line(("$ ", PROMPT, True), ("clones add work", FG, True))
line(t("Profile ", "Профиль "), ("● ", RED, False), ("work", FG, True),
     t(" created: ~/.clones/work", " создан: ~/.clones/work"))
line(t("Launcher: /Applications/Claude Work.app — pin it to the Dock", "Лаунчер: /Applications/Claude Work.app — закрепите его в Dock"))
line((t("Start: clones run work   •   first sign-in: clones login work",
        "Запуск: clones run work   •   первый вход в аккаунт: clones login work"), DIM, False))
line()
line(("$ ", PROMPT, True), ("clones run work", FG, True))
line(t("“work” started (PID 4211).", "«work» запущен (PID 4211)."))
line()
line(("$ ", PROMPT, True), ("clones ls", FG, True))
line(("NAME      STATUS   PID     SIZE  MCP  APP", DIM, False))
line("default   ", ("stopped", DIM, False), "     -   1.2 GB    3  ", ("-", DIM, False))
line(("● ", GREENDOT, False), "personal  ", ("running", GREEN, False), "  4188   180 MB    0  /Applications/Claude Personal.app")
line(("● ", RED, False), "work      ", ("running", GREEN, False), "  4211   310 MB    5  /Applications/Claude Work.app")

CW, LH, PAD, TOP = 8.4, 20, 18, 46
width = int(PAD * 2 + CW * max(sum(len(s[0]) for s in l) for l in L if l)) + 4
height = TOP + LH * len(L) + PAD
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="clones in a terminal">',
       f'<rect width="{width}" height="{height}" rx="10" fill="#1e1e22"/>',
       f'<rect width="{width}" height="30" rx="10" fill="#2b2b31"/><rect y="20" width="{width}" height="10" fill="#2b2b31"/>',
       '<circle cx="18" cy="15" r="6" fill="#ff5f57"/><circle cx="38" cy="15" r="6" fill="#febc2e"/><circle cx="58" cy="15" r="6" fill="#28c840"/>',
       f'<text x="{width/2}" y="19" fill="#9a9aa2" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif" font-size="12" text-anchor="middle">zsh</text>',
       '<g font-family="SFMono-Regular,Menlo,Consolas,\'DejaVu Sans Mono\',monospace" font-size="14" xml:space="preserve" style="white-space:pre">']
for i, segs in enumerate(L):
    if not segs:
        continue
    y = TOP + LH * i
    # Each fragment is placed on its own column so alignment never depends on space handling.
    col, spans = 0, []
    for txt, c, b in segs:
        x = PAD + col * CW
        weight = ' font-weight="bold"' if b else ""
        spans.append(f'<tspan x="{x:.1f}" fill="{c}"{weight}>{escape(txt).replace(" ", "\u00a0")}</tspan>')
        col += len(txt)
    out.append(f'<text y="{y}">{"".join(spans)}</text>')
out += ["</g>", "</svg>"]
print("\n".join(out))
