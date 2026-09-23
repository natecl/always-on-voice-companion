#!/usr/bin/env python3
"""Grade gate B3. Writes grade.json {"B3": {...}}.

Does not edit grade.py. Provenance checks are the v0 ones, called with gate
name B3. Product numbers that the plan put in thresholds.json live here
instead: that file is the v0 contract and this climb does not change it.

Result vocabulary matches grade.py: pass, fail, invalid, unproven.
Only a Mac harness `pass` counts. `--no-provenance` is for unit tests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grade  # noqa: E402

B3_LATENCY_MS = 30_000
SCHEMA = "catcher.brief/1"
FOOTER = "Notes by Catcher"
NETWORK_MARKERS = (
    "transport",
    "timed out",
    "missing xai_api_key",
    "network",
    "offline",
    "http 408",
    "http 429",
    "http 500",
    "http 502",
    "http 503",
    "http 504",
)

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict | None:
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return loaded if isinstance(loaded, dict) else None


def final_seqs(rows: list[dict]) -> set[int]:
    seqs: set[int] = set()
    for row in rows:
        if row.get("t") == "seg" and row.get("final") is True and isinstance(row.get("seq"), int):
            seqs.add(row["seq"])
    return seqs


def escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def subtitle(brief: dict) -> str:
    source = brief.get("source") if isinstance(brief.get("source"), dict) else {}
    try:
        minutes = max(0, int(source.get("durationMs", 0))) // 60_000
    except (TypeError, ValueError):
        minutes = 0
    length = f"{minutes} min"
    created = str(brief.get("createdAt", ""))
    day = created[:10]
    parts = day.split("-")
    if len(parts) != 3:
        return length
    try:
        year, month, day_n = int(parts[0]), int(parts[1]), int(parts[2])
    except ValueError:
        return length
    if not (1 <= month <= 12 and 1 <= day_n <= 31):
        return length
    return f"{MONTHS[month - 1]} {day_n}, {year} · {length}"


def item_suffix(item: dict) -> str:
    owner = item.get("owner")
    due = item.get("due")
    if owner is not None and due is not None:
        return f" ({owner}, {due})"
    if owner is not None:
        return f" ({owner})"
    if due is not None:
        return f" ({due})"
    return ""


def markdown_block(block: dict) -> str:
    lines = [f"## {block.get('heading', '')}"]
    action = block.get("kind") == "actionItems"
    for item in block.get("items") or []:
        if not isinstance(item, dict):
            continue
        text = str(item.get("text", ""))
        if action:
            lines.append(f"- [ ] {text}{item_suffix(item)}")
        else:
            lines.append(f"- {text}")
    return "\n".join(lines) + "\n"


def render_markdown(brief: dict) -> str:
    """Reference copy of BriefRenderer.markdown. Caveats stay out. Footer stays on."""
    blocks = [markdown_block(block) for block in brief.get("blocks") or [] if isinstance(block, dict)]
    text = f"# {brief.get('title', '')}\n{subtitle(brief)}\n\n" + "\n".join(blocks)
    if not text.endswith("\n"):
        text += "\n"
    text += f"\n{FOOTER}\n"
    return text


def html_block(block: dict) -> list[str]:
    action = block.get("kind") == "actionItems"
    lines = [f"<h2>{escape(str(block.get('heading', '')))}</h2>", "<ul>"]
    for item in block.get("items") or []:
        if not isinstance(item, dict):
            continue
        body = str(item.get("text", ""))
        if action:
            body += item_suffix(item)
        lines.append(f"<li>{escape(body)}</li>")
    lines.append("</ul>")
    return lines


def render_html(brief: dict) -> str:
    lines = [f"<h1>{escape(str(brief.get('title', '')))}</h1>", f"<p>{escape(subtitle(brief))}</p>"]
    for block in brief.get("blocks") or []:
        if isinstance(block, dict):
            lines.extend(html_block(block))
    lines.append(f"<p>{escape(FOOTER)}</p>")
    return "\n".join(lines) + "\n"


def network_error(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in NETWORK_MARKERS)


def median(values: list[int]) -> int:
    if not values:
        return 0
    return int(statistics.median(values))


def grade_b3(root: Path, observe: dict | None, *, no_provenance: bool) -> dict:
    gate = grade.Gate()
    sessions = []
    if isinstance(observe, dict) and isinstance(observe.get("sessions"), list):
        sessions = [item for item in observe["sessions"] if isinstance(item, dict)]
    long_runs = []
    if isinstance(observe, dict):
        long_box = observe.get("long")
        if isinstance(long_box, dict) and isinstance(long_box.get("runs"), list):
            long_runs = [item for item in long_box["runs"] if isinstance(item, dict)]

    if len(sessions) != 3:
        gate.check(
            "sessions",
            False,
            f"B3a needs 3 sessions in one app run, found {len(sessions)}",
            grade.PREMISE_CHECK,
        )
    if len(long_runs) != 3:
        gate.check(
            "long-runs",
            False,
            f"B3b needs 3 brief-bench runs, found {len(long_runs)}",
            grade.PREMISE_CHECK,
        )

    latencies: list[int] = []
    assemble_gaps: list[int] = []
    provenance_rows: list[dict] | None = None
    provenance_dir: Path | None = None

    for index, observed in enumerate(sessions, start=1):
        label = f"s{index}"
        directory = Path(str(observed.get("directory", "")))
        if not directory.is_dir():
            gate.check("session-dir", False, f"{label} missing directory {directory}", grade.PREMISE_CHECK)
            continue
        error_path = directory / "brief-error.json"
        brief_path = directory / "brief.json"
        markdown_path = directory / "brief.md"
        if not brief_path.is_file() or not markdown_path.is_file():
            record = load_json(error_path) if error_path.is_file() else None
            reason = str(record.get("error", "")) if record else ""
            if error_path.is_file() and network_error(reason):
                gate.check(
                    "network",
                    False,
                    f"{label} brief-error.json ({reason}); re-run, not a product fail",
                    grade.PREMISE_CHECK,
                )
            elif error_path.is_file():
                gate.check("notes-failed", False, f"{label} brief-error.json ({reason})")
            else:
                gate.check("brief-missing", False, f"{label} has no brief.md and no brief-error.json")
            continue

        brief = load_json(brief_path)
        if brief is None:
            gate.check("schema", False, f"{label} brief.json is not an object")
            continue
        try:
            rows, _note = grade.load_rows(directory)
        except SystemExit as exc:
            gate.check("events", False, f"{label} {exc}")
            continue
        if provenance_rows is None:
            provenance_rows = rows
            provenance_dir = directory

        schema_ok = (
            brief.get("schema") == SCHEMA
            and brief.get("cost") is None
            and any(isinstance(block, dict) and block.get("kind") == "summary" for block in brief.get("blocks") or [])
        )
        items = [
            item
            for block in brief.get("blocks") or []
            if isinstance(block, dict)
            for item in (block.get("items") or [])
            if isinstance(item, dict)
        ]
        schema_ok = schema_ok and len(items) >= 1
        gate.check("schema", schema_ok, f"{label} schema {brief.get('schema')!r} items {len(items)} cost {brief.get('cost')!r}")

        seqs = final_seqs(rows)
        cited = [item for item in items if item.get("cites")]
        bad = [
            cite
            for item in items
            for cite in (item.get("cites") or [])
            if cite not in seqs
        ]
        gate.check(
            "cites",
            bool(cited) and not bad,
            f"{label} cited items {len(cited)} unresolved {bad}",
        )

        rendered = render_markdown(brief)
        markdown = markdown_path.read_text(encoding="utf-8")
        caveats = brief.get("caveats") if isinstance(brief.get("caveats"), list) else []
        leaked = [str(item) for item in caveats if item and str(item) in markdown]
        gate.check(
            "shareable",
            bool(markdown.strip()) and markdown == rendered and not leaked and FOOTER in markdown,
            f"{label} equal {markdown == rendered} footer {FOOTER in markdown} leaked {leaked}",
        )

        pasted = observed.get("pbpaste")
        types = observed.get("pasteboardTypes") if isinstance(observed.get("pasteboardTypes"), list) else []
        html_ok = "public.html" in types
        html_body = observed.get("html")
        if isinstance(html_body, str) and html_body:
            html_ok = html_ok and html_body == render_html(brief)
        gate.check(
            "copy",
            pasted == markdown and html_ok,
            f"{label} pbpaste match {pasted == markdown} types {types}",
        )

        source = brief.get("source") if isinstance(brief.get("source"), dict) else {}
        events_path = directory / "events.jsonl"
        try:
            events_hash = sha256_file(events_path)
            session_hash = sha256_file(directory / "session.json")
            transcript_hash = sha256_file(directory / "transcript.txt")
        except OSError as exc:
            gate.check("untouched", False, f"{label} {exc}")
            events_hash = session_hash = transcript_hash = ""
        untouched = (
            events_hash == source.get("eventsSha256")
            and events_hash == observed.get("eventsSha256AtAssembled")
            and session_hash == observed.get("sessionJsonSha256AtAssembled")
            and transcript_hash == observed.get("transcriptSha256AtAssembled")
        )
        gate.check("untouched", untouched, f"{label} events {events_hash}")

        header_engine = str(grade.header(rows).get("engine", ""))
        notes_engine = ""
        engine_box = brief.get("engine")
        if isinstance(engine_box, dict):
            notes_engine = str(engine_box.get("name", ""))
        grok = str(grade.THRESHOLDS["grokEngine"])
        engine_ok = header_engine == grok and notes_engine not in ("", "stub")
        detail = f"{label} header {header_engine!r} notes {notes_engine!r}"
        if notes_engine == "stub" or header_engine == "stub":
            detail = f"stub engine cannot prove B3 ({detail})"
        gate.check("engine", engine_ok, detail)

        try:
            stop = int(observed["stopSentWallMs"])
            seen = int(observed["observedWallMs"])
            assembled = int(observed["assembledWallMs"])
        except (KeyError, TypeError, ValueError):
            gate.check("latency-sample", False, f"{label} missing stop/observed/assembled wall times", grade.PREMISE_CHECK)
            continue
        latencies.append(seen - stop)
        assemble_gaps.append(assembled - stop)

    if latencies:
        slowest = max(latencies)
        gate.check(
            "latency",
            slowest <= B3_LATENCY_MS and all(value >= 0 for value in latencies),
            f"max {slowest} ms, p50 {median(latencies)} ms, samples {latencies}, bar {B3_LATENCY_MS}",
        )
    stage_values: list[int] = []
    for run in long_runs:
        try:
            stage_values.append(int(run["totalMs"]))
        except (KeyError, TypeError, ValueError):
            gate.check("long-sample", False, f"B3b run missing totalMs {run}", grade.PREMISE_CHECK)
    if stage_values and assemble_gaps:
        combined = max(stage_values) + max(assemble_gaps)
        gate.check(
            "long",
            combined <= B3_LATENCY_MS and min(stage_values) >= 0 and min(assemble_gaps) >= 0,
            f"max B3b totalMs {max(stage_values)} + max stop-to-assembled {max(assemble_gaps)} = {combined} (bar {B3_LATENCY_MS})",
        )

    if provenance_dir is not None and provenance_rows is not None:
        run = grade.load_harness_run(provenance_dir)
        grade.provenance_checks(gate, provenance_dir, provenance_rows, "B3", run, no_provenance)
    elif not gate.failed(grade.PREMISE_CHECK):
        gate.check("provenance", False, "no session to prove", grade.PROVENANCE_CHECK)

    return gate.result()


def main() -> int:
    parser = argparse.ArgumentParser(description="Grade B3 into grade.json")
    parser.add_argument("--root", type=Path, required=True, help="Harness root that contains harness_run.json and the session directories")
    parser.add_argument("--observe", type=Path, help="Defaults to <root>/b3_observe.json")
    parser.add_argument("--out", type=Path, help="Defaults to <root>/grade.json")
    parser.add_argument("--no-provenance", action="store_true", help="Unit tests only. Forces unproven.")
    args = parser.parse_args()
    observe_path = args.observe or (args.root / "b3_observe.json")
    observe = load_json(observe_path)
    report = {"B3": grade_b3(args.root, observe, no_provenance=args.no_provenance)}
    out = args.out or (args.root / "grade.json")
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0 if report["B3"]["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
