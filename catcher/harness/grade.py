#!/usr/bin/env python3
"""Read a Catcher session and write grade.json for the requested P gates.

Each gate is {"result", "evidence", "checks"}. `result` is one of:

  pass      every check passed and provenance says a Mac harness run
  fail      a check failed
  invalid   the run did not set up the premise (re-run; not a product result)
  unproven  checks passed but provenance is missing or not a Mac harness run
  n/a       not requested

Only `pass` counts. This script does not claim a build is green; verdict.py
is the only artifact that can.
"""

from __future__ import annotations

import argparse
import json
import math
import platform
import struct
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from wer import word_error_rate  # noqa: E402

GATES = ("P1", "P2", "P3", "P4", "P5", "P6")
SAMPLE_RATE = 16000
THRESHOLDS: dict[str, float] = json.loads((HERE / "thresholds.json").read_text(encoding="utf-8"))

SESSION_KEYS = {"t", "id", "startedAt", "engine", "tracks", "app"}
SEG_REQUIRED = {"t", "seq", "track", "startMs", "endMs", "final", "text", "words"}
SEG_OPTIONAL = {"speaker", "conf"}
ANN_REQUIRED = {"t", "atMs", "kind"}
ANN_OPTIONAL = {"detail"}
END_REQUIRED = {"t", "atMs", "clean"}
END_OPTIONAL = {"recovered"}

GATE_CHECK = "gate"
PREMISE_CHECK = "premise"
PROVENANCE_CHECK = "provenance"


class Gate:
    """Ordered checks. A premise failure is `invalid`, a gate failure is
    `fail`, a provenance failure is `unproven`. Evidence lists the failures
    first so the reason is on the first line of grade.json."""

    def __init__(self) -> None:
        self.checks: list[dict[str, object]] = []

    def check(self, name: str, ok: bool, detail: str, kind: str = GATE_CHECK) -> bool:
        self.checks.append({"name": name, "ok": bool(ok), "detail": detail, "kind": kind})
        return bool(ok)

    def failed(self, kind: str) -> list[dict[str, object]]:
        return [item for item in self.checks if not item["ok"] and item["kind"] == kind]

    def result(self) -> dict[str, object]:
        if self.failed(PREMISE_CHECK):
            status = "invalid"
        elif self.failed(GATE_CHECK):
            status = "fail"
        elif self.failed(PROVENANCE_CHECK):
            status = "unproven"
        else:
            status = "pass"
        bad = [item for item in self.checks if not item["ok"]]
        good = [item for item in self.checks if item["ok"]]
        evidence = "; ".join(f"{item['name']}: {item['detail']}" for item in bad + good)
        return {"result": status, "evidence": evidence, "checks": self.checks}


def not_requested() -> dict[str, object]:
    return {"result": "n/a", "evidence": "not requested", "checks": []}


def load_rows(session: Path) -> tuple[list[dict], str]:
    path = session / "events.jsonl"
    if not path.exists():
        raise SystemExit(f"missing {path}")
    notes: list[str] = []
    rows: list[dict] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    usable = [line for line in lines if line.strip()]
    for index, line in enumerate(usable):
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            if index == len(usable) - 1:
                notes.append("dropped truncated final line")
                break
            raise SystemExit(f"corrupt JSONL line {index + 1}")
    return rows, "; ".join(notes)


def rows_of(rows: list[dict], kind: str) -> list[dict]:
    return [row for row in rows if row.get("t") == kind]


def header(rows: list[dict]) -> dict:
    return next((row for row in rows if row.get("t") == "session"), {})


def session_start_ms(rows: list[dict]) -> int | None:
    started_at = header(rows).get("startedAt")
    if not started_at:
        return None
    try:
        started = datetime.fromisoformat(str(started_at).replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(started.timestamp() * 1000)


def wall_to_session_ms(rows: list[dict], wall_ms: int | None) -> int | None:
    if wall_ms is None:
        return None
    start = session_start_ms(rows)
    if start is None:
        return None
    return wall_ms - start


def system_text(rows: list[dict]) -> str:
    segs = [row for row in rows_of(rows, "seg") if row.get("track") == "system" and row.get("final") is not False]
    segs.sort(key=lambda row: (row.get("startMs", 0), row.get("seq", 0)))
    return " ".join(str(row.get("text", "")) for row in segs)


def pcm_windows(path: Path) -> list[tuple[int, int, float]]:
    raw = path.read_bytes()
    count = len(raw) // 2
    if count == 0:
        return []
    samples = struct.unpack("<" + "h" * count, raw[: count * 2])
    window = SAMPLE_RATE // 10
    windows: list[tuple[int, int, float]] = []
    for index in range(0, len(samples), window):
        chunk = samples[index : index + window]
        energy = sum((sample / 32768) ** 2 for sample in chunk)
        rms = math.sqrt(energy / len(chunk))
        start = index * 1000 // SAMPLE_RATE
        end = (index + len(chunk)) * 1000 // SAMPLE_RATE
        windows.append((start, end, rms))
    return windows


def overlaps(start: int, end: int, seg: dict) -> bool:
    return start < int(seg.get("endMs", 0)) and end > int(seg.get("startMs", 0))


def gap_evidence(session: Path, rows: list[dict]) -> tuple[bool, str]:
    limit = int(THRESHOLDS["p1GapLimitMs"])
    segs = [row for row in rows_of(rows, "seg") if row.get("track") == "system"]
    segs.sort(key=lambda row: int(row.get("startMs", 0)))
    if not segs:
        return False, "no system-track seg rows"
    pcm = session / "system.pcm"
    if pcm.exists() and pcm.stat().st_size > 0:
        windows = [item for item in pcm_windows(pcm) if item[2] > THRESHOLDS["p1GapRmsFloor"]]
        uncovered: list[tuple[int, int]] = []
        for start, end, _rms in windows:
            if any(overlaps(start, end, seg) for seg in segs):
                continue
            if uncovered and start <= uncovered[-1][1] + 20:
                uncovered[-1] = (uncovered[-1][0], max(uncovered[-1][1], end))
            else:
                uncovered.append((start, end))
        holes = [f"{start}-{end}" for start, end in uncovered if end - start > limit]
        if holes:
            return False, f"system.pcm speech without a seg >{limit}ms: " + ", ".join(holes)
        return True, f"no silent gap >{limit}ms across {len(windows)} speech windows"
    holes = []
    for previous, nxt in zip(segs, segs[1:]):
        gap = int(nxt.get("startMs", 0)) - int(previous.get("endMs", 0))
        if gap > limit:
            holes.append(str(gap))
    if holes:
        return False, f"system.pcm missing; inter-segment holes >{limit}ms: " + ", ".join(holes)
    return True, f"system.pcm missing; no inter-segment hole >{limit}ms"


def shape_keys(rows: list[dict]) -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for row in rows:
        kind = str(row.get("t"))
        found.setdefault(kind, set()).update(row.keys())
    return found


def schema_problems(rows: list[dict]) -> list[str]:
    problems: list[str] = []
    for index, row in enumerate(rows, start=1):
        kind = row.get("t")
        keys = set(row.keys())
        if kind == "session":
            missing = SESSION_KEYS - keys
            if missing:
                problems.append(f"line {index} session missing {sorted(missing)}")
        elif kind == "seg":
            missing = SEG_REQUIRED - keys
            extra = keys - SEG_REQUIRED - SEG_OPTIONAL
            if missing or extra:
                problems.append(f"line {index} seg missing {sorted(missing)} extra {sorted(extra)}")
            if row.get("final") is False:
                problems.append(f"line {index} partial was written")
        elif kind == "ann":
            missing = ANN_REQUIRED - keys
            extra = keys - ANN_REQUIRED - ANN_OPTIONAL
            if missing or extra:
                problems.append(f"line {index} ann missing {sorted(missing)} extra {sorted(extra)}")
        elif kind == "end":
            missing = END_REQUIRED - keys
            extra = keys - END_REQUIRED - END_OPTIONAL
            if missing or extra:
                problems.append(f"line {index} end missing {sorted(missing)} extra {sorted(extra)}")
        else:
            problems.append(f"line {index} unknown t={kind}")
    return problems


def recovered(session: Path, rows: list[dict]) -> bool:
    summary = session / "session.json"
    if summary.exists():
        try:
            if json.loads(summary.read_text(encoding="utf-8")).get("recovered") is True:
                return True
        except json.JSONDecodeError:
            pass
    if any(row.get("kind") == "recovered" for row in rows_of(rows, "ann")):
        return True
    return any(row.get("recovered") is True for row in rows_of(rows, "end"))


def platform_system() -> str:
    return platform.system()


def load_harness_run(session: Path) -> dict | None:
    """`<root>/harness_run.json`, written by lib.sh before launch. The session
    is `<root>/<uuid>`; a session graded in place may carry its own copy."""
    for candidate in (session.parent / "harness_run.json", session / "harness_run.json"):
        if candidate.is_file():
            try:
                loaded = json.loads(candidate.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                return None
            return loaded if isinstance(loaded, dict) else None
    return None


def app_sha(rows: list[dict]) -> str:
    app = str(header(rows).get("app", ""))
    return app.split("+", 1)[1] if "+" in app else ""


def macos_major(version: str) -> int:
    try:
        return int(str(version).split(".")[0])
    except ValueError:
        return 0


def provenance_checks(gate: Gate, session: Path, rows: list[dict], name: str, run: dict | None, no_provenance: bool) -> None:
    if no_provenance:
        gate.check("provenance", False, "--no-provenance: unit-test grading, never a pass", PROVENANCE_CHECK)
        return
    host = platform_system()
    gate.check("graded-on-mac", host == "Darwin", f"grade host {host}; Linux/CI grading is Tier L", PROVENANCE_CHECK)
    if run is None:
        gate.check("harness-run", False, "no harness_run.json next to the session; not a harness run", PROVENANCE_CHECK)
        return
    gate.check("harness-run", run.get("gate") == name, f"harness_run.json gate={run.get('gate')!r}, grading {name}", PROVENANCE_CHECK)
    minimum = int(THRESHOLDS["minMacOSMajor"])
    gate.check(
        "macos",
        run.get("host", "Darwin") == "Darwin" and macos_major(str(run.get("macOS", ""))) >= minimum,
        f"harness host {run.get('host')!r} macOS {run.get('macOS')!r} (need Darwin >= {minimum})",
        PROVENANCE_CHECK,
    )
    sha = app_sha(rows)
    plist = str(run.get("catcherGitSHA", ""))
    good_sha = bool(sha) and sha == plist and sha != "unknown" and not sha.endswith("-dirty")
    gate.check("build-sha", good_sha, f"header app sha {sha!r}, harness CatcherGitSHA {plist!r}", PROVENANCE_CHECK)
    started = session_start_ms(rows)
    wall = run.get("startedWallMs")
    gate.check(
        "session-after-harness-start",
        started is not None and isinstance(wall, int) and started >= wall,
        f"session startedAt {started} vs harness startedWallMs {wall}",
        PROVENANCE_CHECK,
    )
    sign = run.get("codesign") or {}
    signed = bool(sign.get("cdhash")) and sign.get("signature") != "adhoc"
    gate.check("codesign", signed, f"cdhash {sign.get('cdhash')!r} signature {sign.get('signature')!r}", PROVENANCE_CHECK)


def engine_check(gate: Gate, rows: list[dict], name: str) -> None:
    engine = str(header(rows).get("engine", ""))
    if name == "P5":
        gate.check("engine=stub", engine == "stub", f"header engine {engine!r}; P5 must be the stub")
        return
    grok = str(THRESHOLDS["grokEngine"])
    detail = f"header engine {engine!r}"
    if engine == "stub":
        detail = f"stub engine cannot prove P1/P3/P6 ({detail})"
    gate.check("engine=grok", engine == grok, detail)


def grade_p1(gate: Gate, session: Path, rows: list[dict], ref: Path | None, expect_recovery: bool) -> None:
    if ref is None or not ref.exists():
        gate.check("reference", False, "missing reference transcript")
        return
    bar = float(THRESHOLDS["p1WerBar"])
    score = word_error_rate(ref.read_text(encoding="utf-8"), system_text(rows))
    gate.check("wer", score <= bar, f"WER {score:.3f} on the system track (bar {bar})")
    gaps_ok, gaps = gap_evidence(session, rows)
    gate.check("gaps", gaps_ok, gaps)
    if expect_recovery:
        did = recovered(session, rows)
        gate.check("recovery", did, "recovery " + ("present" if did else "missing"))


def launch_failure(session: Path) -> bool:
    """A later session that died in startCapture at t=0, with no captured audio.

    P2 must not grade that directory. The revoke happened on the session that
    was already recording.
    """
    try:
        rows, _note = load_rows(session)
    except SystemExit:
        return False
    blocked = [row for row in rows_of(rows, "ann") if row.get("kind") == "blocked"]
    if not blocked or any(int(row.get("atMs", -1)) != 0 for row in blocked):
        return False
    for name in ("system.pcm", "microphone.pcm"):
        pcm = session / name
        if pcm.is_file() and pcm.stat().st_size > 0:
            return False
    return True


def child_sessions(root: Path) -> list[Path]:
    found: list[Path] = []
    if (root / "events.jsonl").is_file():
        found.append(root)
    if root.is_dir():
        for child in root.iterdir():
            if child.is_dir() and (child / "events.jsonl").is_file():
                found.append(child)
    return found


def pointer_session(root: Path, name: str) -> Path | None:
    pointer = root / name
    if not pointer.is_file():
        return None
    raw = pointer.read_text(encoding="utf-8").strip()
    if not raw:
        return None
    target = Path(raw)
    if not target.is_absolute():
        target = root / raw
    if (target / "events.jsonl").is_file():
        return target
    return None


def pick_revoke_session(root: Path) -> Path:
    """Session that was recording when Screen Recording was revoked.

    `revoke_session` is written before `tccutil`. `live_session` is the first
    recording the app pinned. A newer directory that is only `blocked` at
    atMs=0 is a post-regrant startCapture failure and is not the score.
    """
    for name in ("revoke_session", "live_session"):
        pinned = pointer_session(root, name)
        if pinned is not None:
            return pinned
    candidates = child_sessions(root)
    if not candidates:
        raise SystemExit(f"no events.jsonl under {root}")
    recording = [path for path in candidates if not launch_failure(path)]
    pool = recording or candidates
    pool.sort(key=lambda path: (path / "events.jsonl").stat().st_mtime)
    return pool[-1]


def grade_p2(gate: Gate, rows: list[dict], revoke_at: int | None) -> None:
    blocked = [row for row in rows_of(rows, "ann") if row.get("kind") == "blocked"]
    if not gate.check("blocked", bool(blocked), "ann kind=blocked " + ("present" if blocked else "missing")):
        return
    at = int(blocked[0].get("atMs", -1))
    within = int(THRESHOLDS["p2BlockWithinMs"])
    if revoke_at is not None:
        latency = at - revoke_at
        gate.check("latency", 0 <= latency <= within, f"blocked atMs={at}, {latency}ms from revoke (bar {within})")
    late = [row for row in rows_of(rows, "seg") if int(row.get("startMs", 0)) > at]
    gate.check("no-seg-after-block", not late, f"{len(late)} seg(s) after the block")


def grade_p3(gate: Gate, rows: list[dict]) -> None:
    anns = rows_of(rows, "ann")
    degraded_at = next((index for index, row in enumerate(anns) if row.get("kind") == "degraded"), None)
    gap_at = next((index for index, row in enumerate(anns) if row.get("kind") == "gap"), None)
    resumed_at = next((index for index, row in enumerate(anns) if row.get("kind") == "resumed"), None)
    if degraded_at is None or gap_at is None or resumed_at is None:
        gate.check("chain", False, "need ann kinds degraded, gap, resumed in that order")
        return
    if not gate.check("order", degraded_at < gap_at < resumed_at, f"degraded={degraded_at} gap={gap_at} resumed={resumed_at}"):
        return
    resumed_ms = int(anns[resumed_at].get("atMs", 0))
    later = [row for row in rows_of(rows, "seg") if int(row.get("startMs", 0)) >= resumed_ms]
    gate.check("seg-after-resume", bool(later), f"{len(later)} seg(s) at or after resumed atMs")


def grade_p4(gate: Gate, rows: list[dict], silence_at: int) -> None:
    limit = int(THRESHOLDS["silenceLimitMs"])
    hits = [
        row for row in rows_of(rows, "ann")
        if row.get("kind") == "noAudio" and silence_at <= int(row.get("atMs", -1)) <= silence_at + limit
    ]
    gate.check(
        "noaudio-in-window",
        bool(hits),
        f"noAudio atMs={hits[0].get('atMs')}" if hits else f"no noAudio ann with atMs in [{silence_at}, {silence_at + limit}]",
    )


def grade_p5(gate: Gate, rows: list[dict], reference: Path | None) -> None:
    problems = schema_problems(rows)
    gate.check("schema", not problems, "schema ok" if not problems else "; ".join(problems))
    if reference is None:
        gate.check("shape-reference", False, "no Grok shape reference; schema alone does not prove P5")
        return
    ref_dir = reference.parent if reference.name == "events.jsonl" else reference
    ref_rows, _note = load_rows(ref_dir)
    ref_engine = str(header(ref_rows).get("engine", ""))
    gate.check("reference-engine", ref_engine not in ("", "stub"), f"shape reference engine {ref_engine!r}; must be a Grok session")
    left_sha, right_sha = app_sha(rows), app_sha(ref_rows)
    gate.check(
        "reference-same-build",
        bool(left_sha) and left_sha == right_sha,
        f"stub build {left_sha!r}, reference build {right_sha!r}",
    )
    left = shape_keys(rows)
    right = shape_keys(ref_rows)
    same = left.keys() == right.keys() and all(left[key] == right[key] for key in left)
    gate.check(
        "shape",
        same,
        "JSONL key shape matches the reference session" if same
        else f"shape left={ {k: sorted(v) for k, v in left.items()} } right={ {k: sorted(v) for k, v in right.items()} }",
    )


def grade_p6(gate: Gate, rows: list[dict]) -> None:
    segs = rows_of(rows, "seg")
    tracks = {row.get("track") for row in segs}
    speaker = any(row.get("track") == "system" and row.get("speaker") for row in segs)
    gate.check("system-seg", "system" in tracks, f"tracks={sorted(t for t in tracks if t)}")
    gate.check("microphone-seg", "microphone" in tracks, f"tracks={sorted(t for t in tracks if t)}")
    gate.check("system-speaker", speaker, f"systemSpeaker={speaker}")


def grade_gate(
    name: str,
    session: Path,
    rows: list[dict],
    *,
    ref: Path | None = None,
    expect_recovery: bool = False,
    revoke_at: int | None = None,
    silence_at: int = 0,
    shape_reference: Path | None = None,
    no_provenance: bool = False,
) -> dict[str, object]:
    gate = Gate()
    run = load_harness_run(session)
    if revoke_at is None and run is not None and isinstance(run.get("revokeWallMs"), int):
        revoke_at = wall_to_session_ms(rows, run["revokeWallMs"])
    if name in ("P1", "P3", "P5", "P6"):
        engine_check(gate, rows, name)
    if name == "P1":
        grade_p1(gate, session, rows, ref, expect_recovery)
    elif name == "P2":
        grade_p2(gate, rows, revoke_at)
    elif name == "P3":
        grade_p3(gate, rows)
    elif name == "P4":
        grade_p4(gate, rows, silence_at)
    elif name == "P5":
        grade_p5(gate, rows, shape_reference)
    elif name == "P6":
        grade_p6(gate, rows)
    provenance_checks(gate, session, rows, name, run, no_provenance)
    return gate.result()


def main() -> int:
    parser = argparse.ArgumentParser(description="Grade a Catcher session directory")
    parser.add_argument("--session", type=Path)
    parser.add_argument("--pick-revoke-session", type=Path)
    parser.add_argument("--gate", action="append", choices=GATES, dest="gates")
    parser.add_argument("--ref", type=Path)
    parser.add_argument("--revoke-at-ms", type=int)
    parser.add_argument("--silence-at-ms", type=int, default=0)
    parser.add_argument("--shape-reference", type=Path)
    parser.add_argument("--expect-recovery", action="store_true")
    parser.add_argument("--no-provenance", action="store_true", help="unit tests only; forces unproven")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.pick_revoke_session is not None:
        print(pick_revoke_session(args.pick_revoke_session))
        return 0
    if args.session is None:
        parser.error("--session is required")
    session = args.session
    rows, note = load_rows(session)
    requested = set(args.gates or [])
    revoke_at = wall_to_session_ms(rows, args.revoke_at_ms) if args.revoke_at_ms is not None else None
    if args.revoke_at_ms is not None and revoke_at is None:
        revoke_at = args.revoke_at_ms
    report: dict[str, object] = {"session": str(session)}
    if note:
        report["notes"] = note
    exit_code = 0
    for name in GATES:
        if name not in requested:
            report[name] = not_requested()
            continue
        graded = grade_gate(
            name,
            session,
            rows,
            ref=args.ref,
            expect_recovery=args.expect_recovery,
            revoke_at=revoke_at,
            silence_at=args.silence_at_ms,
            shape_reference=args.shape_reference,
            no_provenance=args.no_provenance,
        )
        report[name] = graded
        if graded["result"] != "pass":
            exit_code = 1
    out = args.out or (session / "grade.json")
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(out)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
