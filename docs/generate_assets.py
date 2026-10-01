#!/usr/bin/env python3
"""Generates the README diagrams in docs/assets/ as paired light/dark SVGs.

Every diagram is drawn once and emitted twice, so the two themes can never drift apart.
The README picks one with <picture> + prefers-color-scheme, which GitHub maps to the
viewer's own theme setting.

    python3 docs/generate_assets.py
"""
from pathlib import Path

OUT = Path(__file__).parent / "assets"

THEMES = {
    "light": dict(
        bg="#ffffff", panel="#f6f8fa", card="#ffffff", stroke="#d0d7de",
        text="#1f2328", muted="#59636e", accent="#bc6c00", glow="#ffb847",
        accent_soft="#fff4df", link="#5b5bd6", link_soft="#eeeeff",
        good="#1a7f37", good_soft="#e6f6ea", hero_a="#fff8ec", hero_b="#f1f0ff",
    ),
    "dark": dict(
        bg="#0d1117", panel="#161b22", card="#0d1117", stroke="#30363d",
        text="#e6edf3", muted="#9198a1", accent="#ffb847", glow="#ffb847",
        accent_soft="#2b2112", link="#a5a5ff", link_soft="#1c1c3a",
        good="#3fb950", good_soft="#12261a", hero_a="#1d1608", hero_b="#14142b",
    ),
}

SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"


def style(c):
    return f"""<style>
  text {{ font-family: {SANS}; fill: {c['text']}; }}
  .mono {{ font-family: {MONO}; }}
  .muted {{ fill: {c['muted']}; }}
  .accent {{ fill: {c['accent']}; }}
  .link {{ fill: {c['link']}; }}
  .good {{ fill: {c['good']}; }}
  .lane {{ font-size: 11px; font-weight: 700; letter-spacing: 1.6px; fill: {c['muted']}; }}
  .card {{ fill: {c['card']}; stroke: {c['stroke']}; stroke-width: 1.2; }}
  .panel {{ fill: {c['panel']}; stroke: {c['stroke']}; stroke-width: 1; }}
  .wire {{ stroke: {c['muted']}; stroke-width: 1.6; fill: none; }}
  .flow {{ stroke: {c['accent']}; stroke-width: 2; fill: none; stroke-dasharray: 6 7;
           animation: flow 1.1s linear infinite; }}
  .bar {{ fill: {c['glow']}; transform-box: fill-box; transform-origin: center;
          animation: wave 1.5s ease-in-out infinite; }}
  .pulse {{ transform-box: fill-box; transform-origin: center;
            animation: pulse 3.2s ease-in-out infinite; }}
  @keyframes flow {{ to {{ stroke-dashoffset: -26; }} }}
  @keyframes wave {{ 0%,100% {{ transform: scaleY(.35); }} 50% {{ transform: scaleY(1); }} }}
  @keyframes pulse {{ 0%,100% {{ transform: scale(.94); opacity: .75; }}
                      50% {{ transform: scale(1.06); opacity: 1; }} }}
  @media (prefers-reduced-motion: reduce) {{ .flow, .bar, .pulse {{ animation: none; }} }}
</style>"""


def svg(w, h, c, body, label):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" '
        f'height="{h}" role="img" aria-label="{label}">\n{style(c)}\n'
        f'<defs><marker id="tip" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
        f'markerHeight="7" orient="auto-start-reverse"><path d="M0 0 10 5 0 10z" '
        f'fill="{c["muted"]}"/></marker>'
        f'<marker id="tipA" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
        f'markerHeight="7" orient="auto-start-reverse"><path d="M0 0 10 5 0 10z" '
        f'fill="{c["accent"]}"/></marker></defs>\n{body}\n</svg>\n'
    )


def card(x, y, w, h, title, sub=None, mono=True, fill=None, stroke=None):
    extra = ""
    if fill:
        extra = f' style="fill:{fill};stroke:{stroke}"'
    cls = "mono" if mono else ""
    ty = y + h / 2 + (5 if sub is None else -3)
    out = f'<rect class="card" x="{x}" y="{y}" width="{w}" height="{h}" rx="9"{extra}/>'
    out += (f'<text class="{cls}" x="{x + w / 2}" y="{ty}" text-anchor="middle" '
            f'font-size="13" font-weight="600">{title}</text>')
    if sub:
        out += (f'<text class="muted" x="{x + w / 2}" y="{ty + 17}" text-anchor="middle" '
                f'font-size="11.5">{sub}</text>')
    return out


# --------------------------------------------------------------------------- hero

def hero(c):
    w, h = 1200, 340
    b = [f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
         f'<stop offset="0" stop-color="{c["hero_a"]}"/><stop offset="1" stop-color="{c["hero_b"]}"/>'
         f'</linearGradient><radialGradient id="blob"><stop offset="0" stop-color="{c["glow"]}"/>'
         f'<stop offset=".55" stop-color="{c["glow"]}" stop-opacity=".55"/>'
         f'<stop offset="1" stop-color="{c["glow"]}" stop-opacity="0"/></radialGradient></defs>',
         f'<rect x="1" y="1" width="{w - 2}" height="{h - 2}" rx="18" fill="url(#g)" '
         f'stroke="{c["stroke"]}"/>',
         '<circle class="pulse" cx="118" cy="128" r="62" fill="url(#blob)"/>',
         f'<circle cx="118" cy="128" r="20" fill="{c["glow"]}"/>',
         '<text x="206" y="134" font-size="78" font-weight="800" letter-spacing="-2">Friday</text>',
         '<text class="muted" x="210" y="180" font-size="21">A local-first, project-aware '
         'meeting copilot for macOS.</text>',
         '<text class="muted" x="210" y="210" font-size="21">It listens, remembers what '
         'matters, and answers from evidence.</text>']
    # waveform
    heights = [22, 40, 64, 34, 86, 52, 110, 70, 96, 44, 78, 120, 58, 90, 36, 72, 104, 48, 66, 28]
    for i, bh in enumerate(heights):
        x = 870 + i * 15
        b.append(f'<rect class="bar" x="{x}" y="{118 - bh / 2}" width="7" height="{bh}" rx="3.5" '
                 f'style="animation-delay:{-(i % 7) * 0.19:.2f}s" opacity="{0.55 + (i % 4) * 0.15:.2f}"/>')
    # chips
    x = 210
    for label in ["macOS 13+", "Swift · SwiftUI", "Core Data, on-device", "Gemini Live + REST",
                  "697 offline tests"]:
        cw = len(label) * 7.6 + 30
        b.append(f'<rect x="{x}" y="252" width="{cw}" height="32" rx="16" fill="{c["card"]}" '
                 f'stroke="{c["stroke"]}"/>')
        b.append(f'<text x="{x + cw / 2}" y="273" text-anchor="middle" font-size="13.5" '
                 f'font-weight="600">{label}</text>')
        x += cw + 12
    return svg(w, h, c, "\n".join(b), "Friday: a local-first, project-aware meeting copilot for macOS")


# ----------------------------------------------------------------------- pipeline

def pipeline(c):
    w, h = 1200, 230
    steps = [
        ("Conversation", "mic + system audio", "one live transcript"),
        ("Extraction", "debounced, batched,", "credential-gated"),
        ("Structured state", "items · decisions", "events · memories"),
        ("Relationships", "typed edges only,", "never inferred"),
        ("Retrieval", "project-scoped,", "scored, budgeted"),
        ("Grounded answer", "cites its sources,", "or says it has none"),
    ]
    bw, gap, x0, y = 168, 28, 26, 62
    b = [f'<rect class="panel" x="1" y="1" width="{w - 2}" height="{h - 2}" rx="16"/>',
         '<text class="lane" x="26" y="36">FROM WHAT WAS SAID TO WHAT IS KNOWN</text>']
    for i, (title, s1, s2) in enumerate(steps):
        x = x0 + i * (bw + gap)
        last = i == len(steps) - 1
        fill = c["accent_soft"] if last else c["card"]
        stroke = c["accent"] if last else c["stroke"]
        b.append(f'<rect x="{x}" y="{y}" width="{bw}" height="118" rx="12" fill="{fill}" '
                 f'stroke="{stroke}" stroke-width="1.3"/>')
        b.append(f'<text class="accent" x="{x + 16}" y="{y + 28}" font-size="12" '
                 f'font-weight="700">{i + 1:02d}</text>')
        b.append(f'<text x="{x + 16}" y="{y + 56}" font-size="16" font-weight="700">{title}</text>')
        b.append(f'<text class="muted" x="{x + 16}" y="{y + 81}" font-size="12.5">{s1}</text>')
        b.append(f'<text class="muted" x="{x + 16}" y="{y + 99}" font-size="12.5">{s2}</text>')
        if not last:
            b.append(f'<path class="flow" marker-end="url(#tipA)" '
                     f'd="M{x + bw + 3} {y + 59} H{x + bw + gap - 3}"/>')
    return svg(w, h, c, "\n".join(b), "Pipeline: conversation, extraction, structured state, "
               "relationships, retrieval, grounded answer")


# ------------------------------------------------------------------- architecture

def architecture(c):
    w, h = 1200, 760
    b = [f'<rect class="panel" x="1" y="1" width="{w - 2}" height="{h - 2}" rx="16"/>']

    def lane(y, label):
        b.append(f'<text class="lane" x="30" y="{y}">{label}</text>')

    def down(x, y1, y2, flow=False):
        cls, tip = ("flow", "tipA") if flow else ("wire", "tip")
        b.append(f'<path class="{cls}" marker-end="url(#{tip})" d="M{x} {y1} V{y2}"/>')

    # surfaces
    lane(40, "SURFACES")
    for i, (t, s) in enumerate([("Overlay", "help me right now  ·  ⌘⇧A"),
                                ("Workspace", "state of everything  ·  ⌘0"),
                                ("Knowledge Graph", "how it all connects  ·  ⌘⇧G"),
                                ("Settings", "keys, models, privacy  ·  ⌘,")]):
        b.append(card(30 + i * 288, 54, 276, 58, t, s, mono=False))
    down(600, 116, 146)

    # orchestration
    lane(166, "ORCHESTRATION")
    b.append(card(30, 180, 1140, 56, "AIEngineController",
                  "one shared object graph behind every surface, so there is exactly one set of stores",
                  fill=c["link_soft"], stroke=c["link"]))

    # three pipelines
    cols = [
        (30, "LISTEN", [None,  # mic and system audio are parallel inputs, drawn below
                        ("AudioMixer", "one real waveform"),
                        ("GeminiLiveClient", "WebSocket, transcription only"),
                        ("ChatSessionManager", "appends what was heard, live")]),
        (414, "UNDERSTAND", [("ExtractionHeuristics", "local pre-filter, no model"),
                             ("SensitiveContentGate", "drops credential-like text"),
                             ("ExtractionLLMClient", "structured candidates"),
                             ("ExtractionCoordinator", "project resolution, linking")]),
        (798, "ANSWER", [("ContextEngine", "retrieve, score, budget"),
                         ("CrossLayerConflictResolver", "deterministic dedup"),
                         ("ContextPacketFormatter", "evidence + grounding directive"),
                         ("GeminiResponseGenerator", "streaming, one shot")]),
    ]
    for x, label, items in cols:
        down(x + 186, 240, 268)
        b.append(f'<rect x="{x}" y="272" width="372" height="298" rx="12" fill="{c["bg"]}" '
                 f'stroke="{c["stroke"]}" stroke-dasharray="4 4"/>')
        b.append(f'<text class="lane accent" x="{x + 18}" y="298">{label}</text>')
        for i, item in enumerate(items):
            y = 310 + i * 64
            if item is None:
                b.append(card(x + 18, y, 163, 48, "Microphone", "AudioCaptureManager", mono=False))
                b.append(card(x + 191, y, 163, 48, "System audio", "SystemAudioCaptureManager",
                              mono=False))
            else:
                b.append(card(x + 18, y, 336, 48, *item))
            if i < len(items) - 1:
                down(x + 186, y + 50, y + 62, flow=True)
        down(x + 186, 574, 602)

    # managers + stores
    lane(622, "STATE, IN MEMORY, MIRRORED TO DISK")
    for i, (m, s, d) in enumerate([
            ("ChatSessionManager", "ChatSessionStore", "every word, never trimmed"),
            ("MemoryManager", "MemoryStore", "entities, edges, supersession"),
            ("ProjectManager", "ProjectStore", "items, decisions, events")]):
        x = 30 + i * 384
        b.append(f'<rect x="{x}" y="636" width="372" height="96" rx="12" fill="{c["good_soft"]}" '
                 f'stroke="{c["good"]}" stroke-width="1.2"/>')
        b.append(f'<text class="mono" x="{x + 18}" y="664" font-size="13" font-weight="600">{m}</text>')
        b.append(f'<text class="mono good" x="{x + 18}" y="688" font-size="13" '
                 f'font-weight="600">↳ {s}</text>')
        b.append(f'<text class="muted" x="{x + 18}" y="713" font-size="11.5">{d}  ·  '
                 f'own Core Data stack</text>')
    return svg(w, h, c, "\n".join(b), "Architecture: four surfaces share one AIEngineController, "
               "which drives the listen, understand and answer pipelines over three local stores")


# ------------------------------------------------------------------ data boundary

def boundary(c):
    w, h = 1200, 400
    b = [f'<rect class="panel" x="1" y="1" width="{w - 2}" height="{h - 2}" rx="16"/>']

    def column(x, cw, colour, soft, heading, sub, rows):
        b.append(f'<rect x="{x}" y="30" width="{cw}" height="340" rx="14" fill="{soft}" '
                 f'stroke="{colour}" stroke-width="1.3"/>')
        b.append(f'<text x="{x + 26}" y="70" font-size="19" font-weight="700" '
                 f'style="fill:{colour}">{heading}</text>')
        b.append(f'<text class="muted" x="{x + 26}" y="93" font-size="12.5">{sub}</text>')
        for i, (t, s) in enumerate(rows):
            y = 116 + i * 60
            b.append(f'<rect class="card" x="{x + 22}" y="{y}" width="{cw - 44}" height="50" rx="9"/>')
            b.append(f'<text x="{x + 40}" y="{y + 21}" font-size="14" font-weight="600">{t}</text>')
            b.append(f'<text class="muted" x="{x + 40}" y="{y + 39}" font-size="12">{s}</text>')

    column(30, 500, c["good"], c["good_soft"], "Stays on your Mac",
           "~/Library/Application Support/FounderOfficeCopilot/", [
               ("Every transcript and session", "ChatSessions store, never trimmed or deleted"),
               ("The memory graph", "entities, edges and their supersession history"),
               ("Projects, items, decisions, events", "isolated per project by construction"),
               ("Your Gemini API key", "macOS Keychain, never UserDefaults, never logged"),
           ])
    column(670, 500, c["accent"], c["accent_soft"], "Sent to Gemini",
           "only what a single request needs, never a database dump", [
               ("Live audio", "streamed for transcription while listening"),
               ("The current turn + its context block", "the evidence selected for this question"),
               ("Extraction batches", "transcript text, to be turned into structured records"),
               ("One screen still, only if you enable it", "off by default, and listed in the answer's sources"),
           ])
    b.append('<path class="flow" marker-end="url(#tipA)" d="M542 200 H656"/>')
    b.append('<text class="lane" x="600" y="184" text-anchor="middle">PER REQUEST</text>')
    return svg(w, h, c, "\n".join(b), "Data boundary: transcripts, memory, projects and the API key "
               "stay on the Mac; live audio, the current turn, extraction batches and an optional "
               "screen still are sent to Gemini")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, draw in [("hero", hero), ("pipeline", pipeline),
                       ("architecture", architecture), ("data-boundary", boundary)]:
        for theme, colours in THEMES.items():
            path = OUT / f"{name}-{theme}.svg"
            path.write_text(draw(colours), encoding="utf-8")
            print("wrote", path.relative_to(OUT.parent.parent))
