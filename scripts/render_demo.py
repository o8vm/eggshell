#!/usr/bin/env python3
"""Render the recorded LLVM walkthrough from the published measurement record.

Requires Python 3, rsvg-convert, ImageMagick (magick), and ffmpeg.
No model calls, private transcripts, or benchmark execution are involved.
"""

import copy
import html
import json
import math
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "docs/assets/demo"
RECORD = ROOT / "docs/benchmarks/llvm-follow-up.json"
BG, INK, MUTED = "#f7f3ea", "#191b17", "#5e6257"
GREEN, PALE, AMBER = "#285d42", "#e7eedf", "#9b4c2c"
WIDTH, HEIGHT = 1280, 800
FONT = "DejaVu Sans, sans-serif"
NS = "{http://www.w3.org/2000/svg}"
ET.register_namespace("", NS[1:-1])


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def text(x, y, value, size=24, color=INK, weight=400, anchor="start"):
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
            f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}">'
            f'{html.escape(str(value))}</text>')


def lines(x, y, values, size=25, color=INK, step=39, weight=400):
    return "".join(text(x, y + i * step, v, size, color, weight)
                   for i, v in enumerate(values))


def box(x, y, width, height, fill="#fffdf8", stroke="#dedfd3", radius=20):
    return (f'<rect x="{x}" y="{y}" width="{width}" height="{height}" '
            f'rx="{radius}" fill="{fill}" stroke="{stroke}"/>')


def logo():
    # Embed the canonical artwork unchanged, preserving its viewBox and ratio.
    node = copy.deepcopy(ET.parse(
        ROOT / "docs/assets/brand/eggshell-primary-horizontal.svg").getroot())
    node.set("x", "44")
    node.set("y", "14")
    node.set("width", "198")
    node.set("height", "76")
    node.set("aria-labelledby", "logo-title logo-desc")
    for child in node.iter():
        if child.get("id") in {"title", "desc"}:
            child.set("id", "logo-" + child.get("id"))
    return ET.tostring(node, encoding="unicode")


def frame(title, subtitle, content, page=None, description=""):
    progress = ""
    if page:
        for i in range(4):
            progress += box(64 + i * 294, 710, 274, 5,
                            GREEN if i + 1 == page else "#d8dccf", "none", 2)
        progress += text(1216, 763, f"{page} / 4", 17, MUTED, anchor="end")
    return (f'<svg xmlns="{NS[1:-1]}" width="{WIDTH}" height="{HEIGHT}" '
            f'viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-labelledby="title desc">'
            f'<title id="title">{html.escape(title)}</title>'
            f'<desc id="desc">{html.escape(description or subtitle)}</desc>'
            f'<rect width="{WIDTH}" height="{HEIGHT}" rx="28" fill="{BG}"/>'
            + logo()
            + text(1216, 60, "RECORDED LLVM STUDY · ENGLISH SUMMARY", 16, MUTED,
                   600, "end")
            + text(64, 147, title, 43, INK, 700)
            + text(64, 194, subtitle, 22, MUTED)
            + content + progress
            + text(64, 763, "Source records & limits: docs/demo.md", 17, MUTED)
            + "</svg>\n")


def measurements():
    data = json.loads(RECORD.read_text())
    completed, failed = data["completed_trials"], data["failed_attempts"]
    for row in [*completed, *failed, data["fresh_reference"]]:
        if row["input_tokens"] + row["output_tokens"] != row["total_tokens"]:
            raise ValueError("Input/output accounting mismatch")
    totals = data["token_accounting"]
    n = len(completed)
    total = sum(row["total_tokens"] for row in completed)
    all_total = total + sum(row["total_tokens"] for row in failed)
    fresh = data["fresh_reference"]["total_tokens"]
    inclusive = all_total / n
    reduction = 100 * (1 - inclusive / fresh)
    checks = {
        "completed_trials": n,
        "failed_attempts": len(failed),
        "completed_total_tokens": total,
        "completed_mean_tokens": total / n,
        "completed_mean_reduction_percent": 100 * (1 - total / n / fresh),
        "all_attempts_total_tokens": all_total,
        "all_attempts_tokens_per_completion": inclusive,
        "all_attempts_per_completion_reduction_percent": reduction,
    }
    for key, value in checks.items():
        if not math.isclose(totals[key], value, rel_tol=1e-12):
            raise ValueError(f"Published measurement mismatch: {key}")
    counts = {key: sum(t["quality"]["label"] == key for t in completed)
              for key in data["quality_review"]["counts"]}
    if counts != data["quality_review"]["counts"]:
        raise ValueError("Quality count mismatch")
    # The story illustrates the first completed trial, never a selected best run.
    if completed[0]["trial"] != 1:
        raise ValueError("The illustrated trial must be trial 1")
    return data, fresh, inclusive, reduction, counts


def render():
    data, fresh, inclusive, reduction, counts = measurements()
    saved_cost = data["seed"]["preceding_investigation_total_tokens"]
    story = []
    body = box(64, 237, 1152, 106, INK, "none")
    body += text(90, 274, "CHAT 1 · INVESTIGATE", 18, "#b5d0ae", 700)
    body += text(90, 317, "How does Clang choose a toolchain?", 30, "#fffdf8", 600)
    body += box(64, 363, 556, 222) + box(644, 363, 572, 222, PALE)
    body += text(90, 407, "Map the path through the source", 24, INK, 700)
    body += lines(90, 452, ["Driver options → target triple", "→ toolchain → arguments → job"], 24)
    body += text(90, 554, "Sources and test locations retained", 19, MUTED)
    body += text(670, 407, "Useful findings saved in .egg", 24, GREEN, 700)
    body += lines(670, 452, ["Toolchain selection and cache rules", "How per-toolchain arguments form"], 23)
    body += text(670, 554, "Local memory organization · no LLM calls", 19, GREEN)
    body += text(64, 637, f"Prior investigation: {saved_cost:,} tokens, recorded separately.", 22, MUTED)
    body += text(64, 672, "Follow-up savings start after this work already exists.", 22, MUTED)
    story.append(frame("Do the investigation once.",
                       "A real Clang source investigation becomes reusable evidence.", body, 1))

    body = box(64, 237, 1152, 106, INK, "none")
    body += text(90, 274, "CHAT 2 · A SEPARATE CHAT", 18, "#b5d0ae", 700)
    body += text(90, 317, "Which target and language options change the result?", 30, "#fffdf8", 600)
    body += box(64, 363, 1152, 218, PALE)
    body += text(90, 407, "PRIOR WORK DELIVERED AT THE START", 18, GREEN, 700)
    body += lines(90, 455, ["Target triple → toolchain selection and caching",
                           "Per-toolchain arguments → TranslateXarchArgs"], 28, GREEN, 46)
    body += text(90, 552, "The answer explicitly reports these findings as reused.", 22, MUTED)
    body += text(64, 632, "The selected handoff contains the earlier answer and tool evidence.", 23)
    body += text(64, 671, "The graph and retrieval run locally; selected context still uses model tokens.", 21, MUTED)
    story.append(frame("Start from the findings.",
                       "Same project and source snapshot. Independent chat. Related question.", body, 2))

    body = box(64, 237, 1152, 184)
    body += text(90, 278, "NEW INVESTIGATION", 18, GREEN, 700)
    body += lines(90, 323, ["Check language flags and target-specific test cases.",
                           "Identify a possible mismatch: -x order vs. input type."], 28, step=43)
    body += text(90, 396, "Examples include SPIR-V, Darwin argument forwarding, and clang-cl inputs.", 21, MUTED)
    body += box(64, 440, 1152, 140, "#f6e8da", "#e7cbb4")
    body += text(90, 481, "LEFT OPEN", 18, AMBER, 700)
    body += lines(90, 523, ["No built Clang / FileCheck: runtime behavior remains unverified.",
                           "No patch applied to the fixed source snapshot."], 24, step=35)
    body += text(64, 635, f"Illustrated run: trial 1 · {data['completed_trials'][0]['total_tokens']:,} total tokens", 23, INK, 600)
    body += text(64, 675, "Review: usable, based on source evidence. Dynamic confirmation remains open.", 21, MUTED)
    story.append(frame("Carry the work forward.",
                       "English summary of the first completed answer: reused, new, and unverified.", body, 3))

    body = box(64, 237, 712, 359)
    body += text(90, 278, "MODEL INPUT + OUTPUT TOKENS", 18, MUTED, 700)
    body += text(90, 329, "Fresh · one reference run", 24)
    body += text(748, 329, f"{fresh:,}", 25, INK, 700, "end")
    body += box(90, 350, 658, 34, "#8b9184", "none", 6)
    body += text(90, 432, "Eggshell · per completion", 24)
    body += text(748, 432, f"{inclusive:,.0f}", 25, GREEN, 700, "end")
    body += box(90, 453, round(658 * inclusive / fresh, 2), 34, GREEN, "none", 6)
    body += lines(90, 538, ["Includes both failed attempts.",
                           "All 12 attempts ÷ 10 completions."], 21, MUTED, 31)
    body += box(796, 237, 420, 359, PALE)
    body += text(824, 329, f"{reduction:.0f}%", 80, GREEN, 700)
    body += text(824, 371, "fewer follow-up tokens", 24, GREEN, 600)
    body += text(824, 426, "ANSWER REVIEW · 10 TRIALS", 17, MUTED, 700)
    body += lines(824, 472, [f"{counts['usable']} usable",
                            f"{counts['usable_with_minor_corrections']} minor corrections",
                            f"{counts['needs_material_correction']} substantive correction"], 23, step=38)
    body += lines(64, 636, ["One task; one fresh reference; prior investigation excluded.",
                           "Source-based, non-blinded review. General savings and quality parity unproven."], 21, MUTED, 36)
    story.append(frame("See the cost and the quality.",
                       "The comparison includes every attempt, not only the successful runs.", body, 4,
                       "One fresh reference used 5,355,282 tokens. All 12 Eggshell attempts divided by "
                       "10 completions used 962,207 tokens per completion: 82% fewer. Six answers "
                       "were usable, three needed minor corrections, and one needed a substantive correction. "
                       "Prior investigation cost is excluded. This is a historical single-task study."))

    # A still overview is available for reduced motion and link previews.
    body = ""
    cards = [
        (64, "1 · INVESTIGATE", ["Map the Clang", "driver and save", "work with evidence."]),
        (460, "2 · NEW CHAT", ["Reuse target and", "argument findings", "from the first chat."]),
        (856, "3 · CONTINUE", ["Check new edge cases.", "Keep unverified", "runtime tests open."]),
    ]
    for x, label, detail in cards:
        body += box(x, 237, 360, 209, PALE if x == 460 else "#fffdf8")
        body += text(x + 24, 281, label, 18, GREEN, 700)
        body += lines(x + 24, 329, detail, 25, step=37)
    body += box(64, 472, 1152, 153, INK, "none")
    body += text(92, 536, f"{reduction:.0f}% fewer tokens", 42, "#e1efd7", 700)
    body += text(92, 586, "Follow-up cost, including failed attempts", 21, "#e1efd7")
    body += text(685, 517, "10 completed answer reviews", 22, "#e1efd7", 600)
    body += lines(685, 558, [f"{counts['usable']} usable · {counts['usable_with_minor_corrections']} minor corrections",
                            f"{counts['needs_material_correction']} substantive correction"], 23, "#fffdf8", 36)
    body += text(64, 671, "One task. One fresh reference. Prior work excluded. Watch the 30-second walkthrough.", 21, MUTED)
    poster = frame("A new chat. A head start.",
                   "Recorded LLVM study · local memory organization without LLM calls", body,
                   description="A static overview of the recorded four-step Eggshell walkthrough. "
                   "Investigate in one chat, reuse findings in another, and check unresolved cases. "
                   "82% fewer follow-up tokens including failed attempts, with disclosed quality limits.")

    DEST.mkdir(parents=True, exist_ok=True)
    names = ["01-investigate", "02-reuse", "03-continue", "04-results"]
    for name, svg in zip(names, story):
        (DEST / f"{name}.svg").write_text(svg)
    (DEST / "overview.svg").write_text(poster)
    with tempfile.TemporaryDirectory(prefix="eggshell-demo-") as temp:
        temp = Path(temp)
        pngs = []
        for name in names:
            png = temp / f"{name}.png"
            run("rsvg-convert", str(DEST / f"{name}.svg"), "-o", str(png))
            pngs.append(png)
        run("magick", "-delay", "750", *map(str, pngs), "-loop", "0",
            "-layers", "Optimize", str(DEST / "walkthrough.gif"))
        concat = temp / "frames.txt"
        concat.write_text("".join(f"file '{p}'\nduration 7.5\n" for p in pngs)
                          + f"file '{pngs[-1]}'\n")
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
            "-safe", "0", "-i", str(concat), "-t", "30", "-r", "24",
            "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", str(DEST / "walkthrough.mp4"))
    print("Rendered four scenes, a static overview, GIF, and 30-second MP4.")
    print(f"Verified {len(data['completed_trials'])} completions, "
          f"{len(data['failed_attempts'])} failures, and {reduction:.1f}% inclusive reduction.")


if __name__ == "__main__":
    render()
