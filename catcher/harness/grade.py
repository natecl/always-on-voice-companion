#!/usr/bin/env python3
"""Read a Catcher session and write grade.json for the requested P gates.

P1–P6 are graded from events.jsonl (and system.pcm / session.json when present).
Gates that were not requested are n/a. This script does not claim a build is
green; it only scores the session directory it was given.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wer import word_error_rate  # noqa: E402

GATES = ("P1", "P2", "P3", "P4", "P5", "P6")
SAMPLE_RATE = 16000
RMS_EPSILON = 0.001
GAP_LIMIT_MS = 2000

SESSION_KEYS = {"t", "id", "startedAt", "engine", "tracks", "app"}
SEG_REQUIRED = {"t", "seq", "track", "startMs", "endMs", "final", "text", "words"}
SEG_OPTIONAL = {"speaker", "conf"}
ANN_REQUIRED = {"t", "atMs", "kind"}
ANN_OPTIONAL = {"detail"}
END_REQUIRED = {"t", "atMs", "clean"}
END_OPTIONAL = {"recovered"}


def result(status: str, evidence: str) -> dict[str, str]:
    return {"result": status, "evidence": evidence}


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


def session_start_ms(rows: list[dict]) -> int | None:
    for row in rows:
        if row.get("t") == "session" and row.get("startedAt"):
            try:
                started = datetime.fromisoformat(row["startedAt"].replace("Z", "+00:00"))
            except ValueError:
                return None
            return int(started.timestamp() * 1000)
    return None


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
    segs = [row for row in rows_of(rows, "seg") if row.get("track") == "system"]
    segs.sort(key=lambda row: int(row.get("startMs", 0)))
    if not segs:
        return False, "no system-track seg rows"
    pcm = session / "system.pcm"
    if pcm.exists() and pcm.stat().st_size > 0:
        windows = [item for item in pcm_windows(pcm) if item[2] > RMS_EPSILON]
        uncovered: list[tuple[int, int]] = []
        for start, end, _rms in windows:
            if any(overlaps(start, end, seg) for seg in segs):
                continue
            if uncovered and start <= uncovered[-1][1] + 20:
                uncovered[-1] = (uncovered[-1][0], max(uncovered[-1][1], end))
            else:
                uncovered.append((start, end))
        holes = [f"{start}-{end}" for start, end in uncovered if end - start > GAP_LIMIT_MS]
        if holes:
            return False, "system.pcm speech without a seg >2s: " + ", ".join(holes)
        return True, f"no silent gap >2s across {len(windows)} speech windows"
    holes = []
    for previous, nxt in zip(segs, segs[1:]):
        gap = int(nxt.get("startMs", 0)) - int(previous.get("endMs", 0))
        if gap > GAP_LIMIT_MS:
            holes.append(str(gap))
    if holes:
        return False, "system.pcm missing; inter-segment holes >2s (ms): " + ", ".join(holes)
    return True, "system.pcm missing; no inter-segment hole >2s"


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


def grade_p1(session: Path, rows: list[dict], ref: Path | None, expect_recovery: bool) -> dict[str, str]:
    evidence: list[str] = []
    ok = True
    if ref is None or not ref.exists():
        return result("fail", "missing reference transcript")
    score = word_error_rate(ref.read_text(encoding="utf-8"), system_text(rows))
    evidence.append(f"WER {score:.3f} on the system track (bar 0.15)")
    if score > 0.15:
        ok = False
    gaps_ok, gaps = gap_evidence(session, rows)
    evidence.append(gaps)
    ok = ok and gaps_ok
    if expect_recovery:
        did = recovered(session, rows)
        evidence.append("recovery " + ("present" if did else "missing"))
        ok = ok and did
    return result("pass" if ok else "fail", "; ".join(evidence))


def grade_p2(rows: list[dict], revoke_at: int | None) -> dict[str, str]:
    blocked = [row for row in rows_of(rows, "ann") if row.get("kind") == "blocked"]
    if not blocked:
        return result("fail", "no ann kind=blocked")
    at = int(blocked[0].get("atMs", -1))
    evidence = [f"blocked atMs={at}"]
    ok = True
    if revoke_at is not None:
        latency = at - revoke_at
        evidence.append(f"latency {latency}ms from revoke")
        if latency < 0 or latency > 2000:
            ok = False
    late = [row for row in rows_of(rows, "seg") if int(row.get("startMs", 0)) > at]
    if late:
        evidence.append(f"{len(late)} seg(s) after the block")
        ok = False
    return result("pass" if ok else "fail", "; ".join(evidence))


def grade_p3(rows: list[dict]) -> dict[str, str]:
    anns = rows_of(rows, "ann")
    degraded_at = next((index for index, row in enumerate(anns) if row.get("kind") == "degraded"), None)
    gap_at = next((index for index, row in enumerate(anns) if row.get("kind") == "gap"), None)
    resumed_at = next((index for index, row in enumerate(anns) if row.get("kind") == "resumed"), None)
    if degraded_at is None or gap_at is None or resumed_at is None:
        return result("fail", "need ann kinds degraded, gap, resumed in that order")
    if not (degraded_at < gap_at < resumed_at):
        return result("fail", f"order degraded={degraded_at} gap={gap_at} resumed={resumed_at}")
    resumed_ms = int(anns[resumed_at].get("atMs", 0))
    later = [row for row in rows_of(rows, "seg") if int(row.get("startMs", 0)) >= resumed_ms]
    if not later:
        return result("fail", "no seg at or after resumed atMs")
    return result("pass", f"degraded → gap → resumed, then {len(later)} seg(s)")


def grade_p4(rows: list[dict], silence_at: int) -> dict[str, str]:
    hits = [
        row for row in rows_of(rows, "ann")
        if row.get("kind") == "noAudio" and silence_at <= int(row.get("atMs", -1)) <= silence_at + 10_000
    ]
    if not hits:
        return result("fail", f"no noAudio ann with atMs in [{silence_at}, {silence_at + 10000}]")
    return result("pass", f"noAudio atMs={hits[0].get('atMs')}")


def grade_p5(rows: list[dict], reference: Path | None) -> dict[str, str]:
    problems = schema_problems(rows)
    evidence = ["schema ok" if not problems else "; ".join(problems)]
    ok = not problems
    if reference is not None:
        ref_rows, _note = load_rows(reference if reference.is_dir() else reference.parent)
        if reference.name == "events.jsonl":
            ref_rows, _note = load_rows(reference.parent)
        left = shape_keys(rows)
        right = shape_keys(ref_rows)
        if left.keys() != right.keys() or any(left[key] != right[key] for key in left):
            ok = False
            evidence.append(f"shape left={ {k: sorted(v) for k, v in left.items()} } right={ {k: sorted(v) for k, v in right.items()} }")
        else:
            evidence.append("JSONL key shape matches the reference session")
    else:
        evidence.append("no shape reference; schema only")
    return result("pass" if ok else "fail", "; ".join(evidence))


def grade_p6(rows: list[dict]) -> dict[str, str]:
    segs = rows_of(rows, "seg")
    tracks = {row.get("track") for row in segs}
    speaker = any(row.get("track") == "system" and row.get("speaker") for row in segs)
    evidence = f"tracks={sorted(t for t in tracks if t)} systemSpeaker={speaker}"
    ok = "system" in tracks and "microphone" in tracks and speaker
    return result("pass" if ok else "fail", evidence)


def main() -> int:
    parser = argparse.ArgumentParser(description="Grade a Catcher session directory")
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--gate", action="append", choices=GATES, dest="gates")
    parser.add_argument("--ref", type=Path)
    parser.add_argument("--revoke-at-ms", type=int)
    parser.add_argument("--silence-at-ms", type=int, default=0)
    parser.add_argument("--shape-reference", type=Path)
    parser.add_argument("--expect-recovery", action="store_true")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    session = args.session
    rows, note = load_rows(session)
    requested = set(args.gates or [])
    revoke_at = wall_to_session_ms(rows, args.revoke_at_ms) if args.revoke_at_ms is not None else None
    if args.revoke_at_ms is not None and revoke_at is None:
        revoke_at = args.revoke_at_ms
    report: dict[str, object] = {"session": str(session)}
    if note:
        report["notes"] = note
    graders = {
        "P1": lambda: grade_p1(session, rows, args.ref, args.expect_recovery),
        "P2": lambda: grade_p2(rows, revoke_at),
        "P3": lambda: grade_p3(rows),
        "P4": lambda: grade_p4(rows, args.silence_at_ms),
        "P5": lambda: grade_p5(rows, args.shape_reference),
        "P6": lambda: grade_p6(rows),
    }
    exit_code = 0
    for gate in GATES:
        if gate not in requested:
            report[gate] = result("n/a", "not requested")
            continue
        graded = graders[gate]()
        report[gate] = graded
        if graded["result"] != "pass":
            exit_code = 1
    out = args.out or (session / "grade.json")
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(out)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
