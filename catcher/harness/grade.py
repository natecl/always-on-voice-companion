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
import re
import sys
from array import array
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


def pcm_samples(path: Path) -> array:
    samples = array("h")
    raw = path.read_bytes()
    samples.frombytes(raw[: len(raw) // 2 * 2])
    if sys.byteorder == "big":
        samples.byteswap()
    return samples


def pcm_duration_ms(path: Path) -> int:
    if not path.is_file():
        return 0
    return path.stat().st_size // 2 * 1000 // SAMPLE_RATE


def pcm_windows_ac(path: Path) -> list[tuple[int, int, float]]:
    """Mean-removed RMS per 100 ms window, full scale 1. DC offset is not
    speech; this matches the verifier's `PCMEnergy.acRMS`."""
    if not path.is_file():
        return []
    samples = pcm_samples(path)
    window = SAMPLE_RATE // 10
    windows: list[tuple[int, int, float]] = []
    for index in range(0, len(samples), window):
        chunk = samples[index : index + window]
        count = len(chunk)
        mean = sum(chunk) / count
        energy = sum(value * value for value in chunk) / count
        rms = math.sqrt(max(0.0, energy - mean * mean)) / 32768
        start = index * 1000 // SAMPLE_RATE
        end = (index + count) * 1000 // SAMPLE_RATE
        windows.append((start, end, rms))
    return windows


def sustained_runs(
    windows: list[tuple[int, int, float]],
    floor: float,
    hold_ms: int | None = None,
    dip_ms: int | None = None,
) -> list[tuple[int, int]]:
    """Runs of windows above `floor` that hold for `hold_ms`, bridging
    sub-floor gaps shorter than `dip_ms`. Mirrors `AudioFlowCheck`."""
    hold = int(THRESHOLDS["speechHoldMs"]) if hold_ms is None else hold_ms
    dip = int(THRESHOLDS["speechDipMs"]) if dip_ms is None else dip_ms
    runs: list[tuple[int, int]] = []
    current: tuple[int, int] | None = None
    for start, end, rms in windows:
        if rms <= floor:
            continue
        if current is not None and start - current[1] < dip:
            current = (current[0], end)
        else:
            if current is not None:
                runs.append(current)
            current = (start, end)
    if current is not None:
        runs.append(current)
    return [run for run in runs if run[1] - run[0] >= hold]


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * (len(ordered) - 1) + 0.5))]


def detail_text(row: dict) -> str:
    detail = row.get("detail")
    return detail if isinstance(detail, str) else ""


def detail_field(row: dict, key: str) -> str | None:
    match = re.search(rf"(?:^|\s){re.escape(key)}=(\S+)", detail_text(row))
    return match.group(1) if match else None


def detail_int(row: dict, key: str) -> int | None:
    raw = detail_field(row, key)
    try:
        return int(raw) if raw is not None else None
    except ValueError:
        return None


def noaudio_rows(rows: list[dict]) -> list[dict]:
    return [row for row in rows_of(rows, "ann") if row.get("kind") == "noAudio"]


def noaudio_over_speech(session: Path, rows: list[dict]) -> tuple[bool, str]:
    """P1.n / P6.n. The PCM files start at capture start (`observedFromMs`)."""
    floor = float(THRESHOLDS["speechEvidenceRmsFloor"])
    limit = int(THRESHOLDS["silenceLimitMs"])
    hits = noaudio_rows(rows)
    if not hits:
        return True, "no noAudio ann"
    runs = {
        track: sustained_runs(pcm_windows_ac(session / f"{track}.pcm"), floor)
        for track in ("system", "microphone")
    }
    problems: list[str] = []
    for row in hits:
        origin = detail_int(row, "observedFromMs") or 0
        to = int(row.get("atMs", 0)) - origin
        start = to - limit
        for track, spans in runs.items():
            over = [f"{a}-{b}" for a, b in spans if a < to and b > start]
            if over:
                problems.append(f"noAudio atMs={row.get('atMs')} over {track} speech (pcm ms {', '.join(over)})")
    if problems:
        return False, "noAudio fired over speech; floor too high: " + "; ".join(problems)
    return True, f"{len(hits)} noAudio ann(s), none over sustained speech (floor {floor})"


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
        windows = [item for item in pcm_windows_ac(pcm) if item[2] > THRESHOLDS["p1GapRmsFloor"]]
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
    quiet_ok, quiet = noaudio_over_speech(session, rows)
    gate.check("no-noaudio-over-speech", quiet_ok, quiet)
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


def ann_track(row: dict) -> str | None:
    detail = row.get("detail")
    if isinstance(detail, dict):
        track = detail.get("track")
        return str(track) if track is not None else None
    return detail_field(row, "track")


def session_end_ms(rows: list[dict]) -> int:
    ends = rows_of(rows, "end")
    if ends:
        return int(ends[-1].get("atMs", 0))
    last = 0
    for row in rows:
        last = max(last, int(row.get("atMs", 0) or 0), int(row.get("endMs", 0) or 0))
    return last


def p3_system_tail_need_ms(resumed_at: int, backlog_ms: int, thresholds: dict | None = None) -> int:
    """Session clock `system:tail` requires.

    `liveFrom = resumed.atMs + backlogMs + p3LiveMarginMs`, then
    `end >= liveFrom + p3MinTailMs - 5000`. The 5s slack is the grader's,
    not a thresholds.json key. `Pipeline.LiveTailFloor.grader` matches this.
    """
    t = THRESHOLDS if thresholds is None else thresholds
    live_from = resumed_at + backlog_ms + int(t["p3LiveMarginMs"])
    return live_from + int(t["p3MinTailMs"]) - 5000


def p3_chain(rows: list[dict], track: str, pf_on: int) -> tuple[list, tuple | None, tuple | None]:
    """(gaps, gap, resumed) for one track, each an (index, row) pair.

    The gap is the first one ending at or after pfOn; an earlier reconnect is
    not the block. `resumed` is the first one after that gap in file order.
    `p3_net_kill.sh` uses this so it waits on the same chain this file grades.
    """
    mine = [(index, row) for index, row in enumerate(rows) if row.get("t") == "ann" and ann_track(row) == track]
    gaps = [(index, row) for index, row in mine if row.get("kind") == "gap"]
    if not gaps:
        return gaps, None, None
    gap = next(((index, row) for index, row in gaps if int(row["detail"].get("toMs", 0)) >= pf_on), gaps[0])
    resumed = next(((index, row) for index, row in mine if index > gap[0] and row.get("kind") == "resumed"), None)
    return gaps, gap, resumed


def p3_assumed_backlog_ms(resumed_row: dict, gap_row: dict, thresholds: dict | None = None) -> int:
    t = THRESHOLDS if thresholds is None else thresholds
    backlog = detail_int(resumed_row, "backlogMs")
    if backlog is not None:
        return backlog
    span = int(gap_row["detail"].get("toMs", 0)) - int(gap_row["detail"].get("fromMs", 0))
    return span + int(t["p3FallbackReplayMs"])


def p3_harness_tail_need_ms(rows: list[dict], pf_on_wall_ms: int, thresholds: dict | None = None) -> int | None:
    """`system:tail` need for the chain grade_p3 will grade, or None until
    that chain's `resumed` row is on disk. A reconnect that ended before pfOn
    is not the block, so it does not end the harness wait."""
    t = THRESHOLDS if thresholds is None else thresholds
    pf_on = wall_to_session_ms(rows, pf_on_wall_ms)
    if pf_on is None:
        return None
    _, gap, resumed = p3_chain(rows, "system", pf_on)
    if gap is None or resumed is None or int(gap[1]["detail"].get("toMs", 0)) < pf_on:
        return None
    resumed_at = int(resumed[1].get("atMs", 0))
    return p3_system_tail_need_ms(resumed_at, p3_assumed_backlog_ms(resumed[1], gap[1], t), t)


def grade_p3(gate: Gate, session: Path, rows: list[dict], run: dict | None) -> None:
    """Clocks: pfOn/pfOff are wall time mapped through startedAt; ann and
    seg times are the engine's rebased session clock. Evidence prints both."""
    run = run or {}
    pf_on = wall_to_session_ms(rows, run.get("pfOnWallMs")) if isinstance(run.get("pfOnWallMs"), int) else None
    pf_off = wall_to_session_ms(rows, run.get("pfOffWallMs")) if isinstance(run.get("pfOffWallMs"), int) else None
    if not gate.check(
        "pf-window",
        pf_on is not None and pf_off is not None and pf_off > pf_on,
        f"pfOn={pf_on} pfOff={pf_off} session ms (harness_run.json pfOnWallMs/pfOffWallMs)",
    ):
        return
    assert pf_on is not None and pf_off is not None
    mic_gap = any(
        row.get("t") == "ann" and row.get("kind") == "gap" and ann_track(row) == "microphone" for row in rows
    )
    grade_p3_track(gate, session, rows, "system", pf_on, pf_off)
    if mic_gap:
        grade_p3_track(gate, session, rows, "microphone", pf_on, pf_off)


def grade_p3_track(gate: Gate, session: Path, rows: list[dict], track: str, pf_on: int, pf_off: int) -> None:
    t = THRESHOLDS
    within = int(t["p3DegradeWithinMs"])
    mine = [(index, row) for index, row in enumerate(rows) if row.get("t") == "ann" and ann_track(row) == track]
    gaps, chosen, resumed = p3_chain(rows, track, pf_on)
    # P3.a
    if not gate.check(f"{track}:gap", chosen is not None, f"{len(gaps)} gap ann(s) with track={track}"):
        return
    assert chosen is not None
    gap_index, gap = chosen
    gap_from = int(gap["detail"].get("fromMs", 0))
    gap_to = int(gap["detail"].get("toMs", 0))
    span = gap_to - gap_from
    gate.check(
        f"{track}:gap-span",
        span >= int(t["p3MinGapSpanMs"]),
        f"gap {gap_from}-{gap_to} spans {span}ms (need {int(t['p3MinGapSpanMs'])}); "
        + ("ok" if span >= int(t["p3MinGapSpanMs"]) else "block shorter than expected; check pfctl -a catcher -sr"),
        PREMISE_CHECK,
    )
    # P3.b. Startup handshake and earlier heartbeat degrades are not the chain.
    degrades = [
        (index, row) for index, row in mine
        if row.get("kind") == "degraded" and pf_on <= int(row.get("atMs", -1)) <= pf_on + within
    ]
    tied = gate.check(
        f"{track}:degrade-in-block",
        bool(degrades),
        f"degraded track={track} at {int(degrades[0][1]['atMs'])} in [{pf_on}, {pf_on + within}]" if degrades
        else f"no degraded with track={track} in [{pf_on}, {pf_on + within}]",
    )
    if not gate.check(f"{track}:resumed", resumed is not None, f"resumed track={track} after the gap " + ("present" if resumed else "missing")):
        return
    assert resumed is not None
    resumed_index, resumed_row = resumed
    resumed_at = int(resumed_row.get("atMs", 0))
    # P3.c
    if tied:
        degraded_index = degrades[0][0]
        gate.check(
            f"{track}:order",
            degraded_index < gap_index < resumed_index,
            f"file order degraded={degraded_index} gap={gap_index} resumed={resumed_index}",
        )
    gate.check(
        f"{track}:gap-covers-block",
        gap_from <= pf_on + within and gap_to >= pf_off - 1000,
        f"gap {gap_from}-{gap_to} vs block {pf_on}-{pf_off}",
    )
    # P3.d
    if resumed_at < pf_off - 1000:
        gate.check(
            f"{track}:resume-after-unblock",
            False,
            f"resumed atMs={resumed_at} while pf was still on (pfOff={pf_off}); the block was not real",
            PREMISE_CHECK,
        )
    else:
        upper = pf_off + int(t["p3ResumeWithinMs"])
        gate.check(
            f"{track}:resume-after-unblock",
            resumed_at <= upper,
            f"resumed atMs={resumed_at} (engine clock) in [{pf_off - 1000}, {upper}] (wall pfOff={pf_off})",
        )
    # P3.e. The first finals after resume are replayed/queued audio.
    backlog = detail_int(resumed_row, "backlogMs")
    assumed = p3_assumed_backlog_ms(resumed_row, gap, t)
    live_from = resumed_at + assumed + int(t["p3LiveMarginMs"])
    segs = [row for row in rows_of(rows, "seg") if row.get("track") == track]
    live = [row for row in segs if int(row.get("startMs", 0)) >= live_from]
    backlog_segs = [row for row in segs if resumed_at <= int(row.get("startMs", 0)) < live_from]
    words = sum(len(str(row.get("text", "")).split()) for row in live)
    need_live = track == "system" or bool([
        run for run in sustained_runs(pcm_windows_ac(session / f"{track}.pcm"), float(t["speechEvidenceRmsFloor"]))
        if run[1] > live_from
    ])
    backlog_note = f"backlogMs={backlog}" if backlog is not None else f"no backlogMs; assumed gap+{int(t['p3FallbackReplayMs'])}={assumed}"
    detail = (
        f"{len(live)} live seg(s), {words} words from liveFrom={live_from} "
        f"(resumed {resumed_at} + {backlog_note} + margin {int(t['p3LiveMarginMs'])}); "
        f"{len(backlog_segs)} backlog seg(s) in [resumed, liveFrom) do not count"
    )
    if need_live:
        gate.check(f"{track}:live-seg", bool(live) and words >= int(t["p3MinLiveWords"]), detail + f" (need {int(t['p3MinLiveWords'])} words)")
    else:
        gate.check(f"{track}:live-seg", True, "no sustained speech in the PCM after liveFrom; " + detail)
    # P3.f
    relapses: list[str] = []
    for index, row in mine:
        if index <= resumed_index or row.get("kind") not in ("degraded", "gap"):
            continue
        if not any(later > index and other.get("kind") == "resumed" for later, other in mine):
            relapses.append(f"{row.get('kind')} at {row.get('atMs')} (line {index + 1}) with no later resumed")
    gate.check(f"{track}:no-relapse", not relapses, "; ".join(relapses) or "no degrade or gap left open after resume")
    if track == "system":
        end = session_end_ms(rows)
        need_end = p3_system_tail_need_ms(resumed_at, assumed, t)
        gate.check(f"{track}:tail", end >= need_end, f"session ends at {end}, need {need_end} (liveFrom + tail - 5s)")


def grade_p4(gate: Gate, session: Path, rows: list[dict], silence_at: int | None) -> None:
    limit = int(THRESHOLDS["silenceLimitMs"])
    slack = int(THRESHOLDS["noAudioEmitSlackMs"])
    hits = noaudio_rows(rows)
    first = hits[0] if hits else None
    observed = detail_int(first, "observedFromMs") if first else None
    # Default: the 10 s window is measured from capture start.
    if silence_at is None:
        silence_at = observed if observed is not None else 0
    in_window = [row for row in hits if silence_at <= int(row.get("atMs", -1)) <= silence_at + limit]
    # P4.a
    if not gate.check(
        "noaudio-in-window",
        bool(in_window),
        f"noAudio atMs={in_window[0].get('atMs')} in [{silence_at}, {silence_at + limit}]" if in_window
        else f"no noAudio ann with atMs in [{silence_at}, {silence_at + limit}]",
    ):
        return
    row = in_window[0]
    emitted = detail_int(row, "emittedAtMs")
    # P4.b
    if not gate.check(
        "emitted-in-time",
        emitted is not None and emitted <= silence_at + limit + slack,
        "cannot prove emission time (no emittedAtMs)" if emitted is None
        else f"emittedAtMs={emitted}, bar {silence_at + limit + slack}",
    ):
        return
    origin = observed if observed is not None else 0
    watched = emitted - origin
    # P4.c
    no_frames = detail_text(row).startswith("no frames")
    gate.check(
        "capture-live",
        not no_frames,
        "detector not exercised; capture dead (no frames for >10s)" if no_frames else "noAudio from observed frames",
    )
    for track in ("system", "microphone"):
        have = pcm_duration_ms(session / f"{track}.pcm")
        gate.check(
            f"{track}-pcm",
            have >= watched - 1000,
            f"{track}.pcm {have}ms, need {watched - 1000}ms (capture start to emission)",
        )
    # P4.d premise: the room was quiet and the output muted.
    speech_floor = float(THRESHOLDS["speechEvidenceRmsFloor"])
    for track in ("system", "microphone"):
        windows = [item for item in pcm_windows_ac(session / f"{track}.pcm") if item[0] < watched]
        spans = sustained_runs(windows, speech_floor)
        gate.check(
            f"quiet-{track}",
            not spans,
            f"sustained {track} audio above {speech_floor} at pcm ms {', '.join(f'{a}-{b}' for a, b in spans)}; operator not quiet / output not muted"
            if spans else f"no sustained {track} audio above {speech_floor} before emission",
            PREMISE_CHECK,
        )
    system_windows = [item for item in pcm_windows_ac(session / "system.pcm") if item[0] < watched]
    peak = max((item[2] for item in system_windows), default=0.0)
    digital = float(THRESHOLDS["p1GapRmsFloor"])
    gate.check(
        "system-muted",
        peak <= digital,
        f"system peak AC RMS {peak:.4f} (muted output is <= {digital})",
        PREMISE_CHECK,
    )
    # P4.e
    spoken = [
        seg for seg in rows_of(rows, "seg")
        if str(seg.get("text", "")).strip() and int(seg.get("startMs", 0)) < emitted
    ]
    gate.check("no-seg-before-emission", not spoken, f"{len(spoken)} non-blank seg(s) before emittedAtMs")
    flowing = [
        ann for ann in rows_of(rows, "ann")
        if ann.get("kind") == "degraded" and "audio is flowing" in detail_text(ann) and int(ann.get("atMs", 0)) <= emitted
    ]
    gate.check("no-flowing-heartbeat", not flowing, f"{len(flowing)} 'audio is flowing' degraded row(s) before emission")


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


def mic_speech_levels(session: Path) -> list[float]:
    """AC RMS of the operator's speech windows: above the digital floor and
    inside a run that holds 300 ms."""
    windows = pcm_windows_ac(session / "microphone.pcm")
    runs = sustained_runs(windows, float(THRESHOLDS["p1GapRmsFloor"]))
    return [rms for start, end, rms in windows if any(a <= start and end <= b for a, b in runs)]


def grade_p6(gate: Gate, session: Path, rows: list[dict]) -> None:
    segs = rows_of(rows, "seg")
    tracks = {row.get("track") for row in segs}
    speaker = any(row.get("track") == "system" and row.get("speaker") for row in segs)
    gate.check("system-seg", "system" in tracks, f"tracks={sorted(t for t in tracks if t)}")
    gate.check("microphone-seg", "microphone" in tracks, f"tracks={sorted(t for t in tracks if t)}")
    gate.check("system-speaker", speaker, f"systemSpeaker={speaker}")
    quiet_ok, quiet = noaudio_over_speech(session, rows)
    gate.check("no-noaudio-over-speech", quiet_ok, quiet)
    # P6.m. Evidence always carries the calibration percentiles.
    levels = mic_speech_levels(session)
    floor = float(THRESHOLDS["verifierRmsFloor"])
    need = float(THRESHOLDS["p6MicSpeechFloorRatio"]) * floor
    p10, p50, p90 = (percentile(levels, fraction) for fraction in (0.1, 0.5, 0.9))
    gate.check(
        "mic-speech-clears-floor",
        bool(levels) and p50 >= need,
        (f"microphone.pcm missing or no sustained speech" if not levels else
         f"mic speech AC RMS p10={p10:.4f} p50={p50:.4f} p90={p90:.4f}; need p50 >= {need:.4f} "
         f"({THRESHOLDS['p6MicSpeechFloorRatio']}x noAudio floor {floor})"
         + ("" if p50 >= need else "; normal speech is under the noAudio floor")),
    )


def grade_gate(
    name: str,
    session: Path,
    rows: list[dict],
    *,
    ref: Path | None = None,
    expect_recovery: bool = False,
    revoke_at: int | None = None,
    silence_at: int | None = None,
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
        grade_p3(gate, session, rows, run)
    elif name == "P4":
        grade_p4(gate, session, rows, silence_at)
    elif name == "P5":
        grade_p5(gate, rows, shape_reference)
    elif name == "P6":
        grade_p6(gate, session, rows)
    provenance_checks(gate, session, rows, name, run, no_provenance)
    return gate.result()


def main() -> int:
    parser = argparse.ArgumentParser(description="Grade a Catcher session directory")
    parser.add_argument("--session", type=Path)
    parser.add_argument("--pick-revoke-session", type=Path)
    parser.add_argument("--gate", action="append", choices=GATES, dest="gates")
    parser.add_argument("--ref", type=Path)
    parser.add_argument("--revoke-at-ms", type=int)
    parser.add_argument("--silence-at-ms", type=int, help="default: capture start (noAudio observedFromMs)")
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
