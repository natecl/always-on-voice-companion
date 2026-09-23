#!/usr/bin/env python3
"""Grade one B2 or B4 session from latency.jsonl.

Reads events.jsonl only for the v0 facts the bar needs (engine, gap, segments,
provenance). It does not write events.jsonl and it does not change grade.py.
A pass here is Tier G for that bar. It is not a phase verdict, and it is not
a v0 P-gate.

Exit 0 only when the requested gate is `pass`.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grade  # noqa: E402

THRESHOLDS: dict[str, float | int | str] = json.loads((HERE / "thresholds_v1.json").read_text(encoding="utf-8"))
SCENARIOS = ("cold-record", "warm-hotkey", "warm-orb", "cold")

# t0 is the harness clock the 5 s bar is measured from. The recording input is
# the gesture that is allowed to open a session.
T0_KIND = {
    "cold-record": "launch",
    "cold": "launch",
    "warm-hotkey": "hotkey",
    "warm-orb": "orb",
}
RECORDING_KIND = {
    "cold-record": "recordButton",
    "cold": "orb",
    "warm-hotkey": "hotkey",
    "warm-orb": "orb",
}
GATE_NAME = {name: f"B4-{name}" for name in SCENARIOS}
EXPECTED_INPUTS = {
    "cold-record": 2,
    "cold": 2,
    "warm-hotkey": 1,
    "warm-orb": 1,
}


def load_latency(session: Path) -> tuple[list[dict], str]:
    path = session / "latency.jsonl"
    if not path.is_file():
        return [], "no latency.jsonl"
    notes: list[str] = []
    rows: list[dict] = []
    usable = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    for index, line in enumerate(usable):
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            if index == len(usable) - 1:
                notes.append("dropped truncated final latency line")
                break
            raise SystemExit(f"corrupt latency.jsonl line {index + 1}")
        if isinstance(parsed, dict):
            rows.append(parsed)
    return rows, "; ".join(notes)


def normalize(text: str) -> str:
    return "".join(ch for ch in text.lower() if ch.isalnum())


def joined(latency: list[dict]) -> list[tuple[dict, int]]:
    shown: dict[tuple[object, object], int] = {}
    for row in latency:
        if row.get("t") == "ui" and isinstance(row.get("shownAtMs"), int):
            shown[(row.get("track"), row.get("seq"))] = int(row["shownAtMs"])
    pairs: list[tuple[dict, int]] = []
    for row in latency:
        if row.get("t") != "tx":
            continue
        stamp = shown.get((row.get("track"), row.get("seq")))
        if stamp is None:
            continue
        pairs.append((row, stamp))
    return pairs


def marks(latency: list[dict], name: str, track: str | None = None) -> list[dict]:
    found = []
    for row in latency:
        if row.get("t") != "mark" or row.get("name") != name:
            continue
        if track is not None and row.get("track") != track:
            continue
        found.append(row)
    return found


def clock_origin(latency: list[dict]) -> int | None:
    for row in latency:
        if row.get("t") == "clock" and isinstance(row.get("originWallMs"), int):
            return int(row["originWallMs"])
    return None


def wav_onset_ms(path: Path, floor: float) -> int | None:
    """First 100 ms window whose mean-removed RMS clears `floor`."""
    try:
        with wave.open(str(path), "rb") as handle:
            channels = handle.getnchannels()
            width = handle.getsampwidth()
            rate = handle.getframerate()
            raw = handle.readframes(handle.getnframes())
    except (wave.Error, EOFError, OSError):
        return None
    if width != 2 or rate <= 0 or channels not in (1, 2):
        return None
    step = 2 * channels
    count = len(raw) // step
    window = max(1, rate // 10)
    for start in range(0, count, window):
        chunk = raw[start * step : (start + window) * step]
        samples: list[float] = []
        for offset in range(0, len(chunk) - step + 1, step):
            left = struct.unpack_from("<h", chunk, offset)[0]
            if channels == 2:
                right = struct.unpack_from("<h", chunk, offset + 2)[0]
                samples.append((left + right) / 2)
            else:
                samples.append(float(left))
        if not samples:
            continue
        mean = sum(samples) / len(samples)
        energy = sum(value * value for value in samples) / len(samples)
        rms = math.sqrt(max(0.0, energy - mean * mean)) / 32768
        if rms >= floor:
            return start * 1000 // rate
    return None


def captured_for_real(gate: grade.Gate, session: Path, rows: list[dict]) -> None:
    pcm = session / "system.pcm"
    nonzero = False
    if pcm.is_file():
        nonzero = any(sample != 0 for sample in grade.pcm_samples(pcm))
    text = grade.system_text(rows).strip()
    detail = f"system.pcm nonzero={nonzero} system text {text[:80]!r}"
    gate.check("captured-for-real", nonzero and bool(text), detail)


def hop_text(values: list[int]) -> str:
    if not values:
        return "n/a"
    return f"p95={grade.percentile([float(value) for value in values], 0.95):.0f}"


def grade_b2(
    gate: grade.Gate,
    session: Path,
    rows: list[dict],
    latency: list[dict],
    run: dict | None,
    fixture: Path | None,
) -> None:
    grade.engine_check(gate, rows, "B2")
    gaps = [row for row in grade.rows_of(rows, "ann") if row.get("kind") == "gap"]
    gate.check(
        "no-gap",
        not gaps,
        "gap ann present; word times after a reconnect are not graded" if gaps else "no gap",
        grade.PREMISE_CHECK if gaps else grade.GATE_CHECK,
    )
    system_tx = [row for row in latency if row.get("t") == "tx" and row.get("track") == "system"]
    ui_keys = {(row.get("track"), row.get("seq")) for row in latency if row.get("t") == "ui"}
    missing_ui = [row for row in system_tx if (row.get("track"), row.get("seq")) not in ui_keys]
    present = (
        any(row.get("t") == "clock" for row in latency)
        and any(row.get("t") == "start" for row in latency)
        and bool(marks(latency, "live"))
        and not missing_ui
    )
    gate.check(
        "sidecar-present",
        present,
        f"clock/start/live present={present} system tx missing ui={len(missing_ui)}",
    )
    starts = [row for row in latency if row.get("t") == "start"]
    gate.check(
        "start-source",
        len(starts) == 1 and starts[0].get("source") == "harnessAutoRecord",
        f"start rows={len(starts)} source={starts[0].get('source') if starts else None}",
    )

    live_rows = marks(latency, "live")
    live_at = int(live_rows[0]["atMs"]) if live_rows and isinstance(live_rows[0].get("atMs"), int) else None
    window = int(THRESHOLDS["b2MatchWindowMs"])
    pairs = joined(latency)
    instances: list[dict] = []
    seen: list[tuple[str, int]] = []
    for row, shown in pairs:
        if row.get("track") != "system" or row.get("kind") != "final":
            continue
        if not isinstance(row.get("recvAtMs"), int):
            continue
        for word in row.get("words") or []:
            if not isinstance(word, dict):
                continue
            text = normalize(str(word.get("w", "")))
            if not text or not isinstance(word.get("e"), int) or not isinstance(word.get("capAtMs"), int):
                continue
            start = int(word.get("s") or 0)
            if any(text == prior and abs(start - prior_start) <= window for prior, prior_start in seen):
                continue
            seen.append((text, start))
            sent = word.get("sentAtMs")
            instances.append({
                "w": text,
                "s": start,
                "e": int(word["e"]),
                "cap": int(word["capAtMs"]),
                "sent": int(sent) if isinstance(sent, int) else None,
                "recv": int(row["recvAtMs"]),
                "shown": shown,
            })
    if live_at is None:
        backlog = instances
        graded_words: list[dict] = []
    else:
        backlog = [word for word in instances if word["e"] <= live_at]
        graded_words = [word for word in instances if word["e"] > live_at]

    candidates: list[tuple[int, str, int]] = []
    for row, shown in pairs:
        if row.get("track") != "system":
            continue
        for word in row.get("words") or []:
            if not isinstance(word, dict):
                continue
            text = normalize(str(word.get("w", "")))
            if not text:
                continue
            candidates.append((shown, text, int(word.get("s") or 0)))
    candidates.sort()

    def earliest(word: dict) -> int:
        for shown, text, start in candidates:
            if text == word["w"] and abs(start - word["s"]) <= window:
                return shown
        return int(word["shown"])

    lags: list[int] = []
    cap_sent: list[int] = []
    sent_recv: list[int] = []
    recv_shown: list[int] = []
    for word in graded_words:
        shown = earliest(word)
        lags.append(shown - word["cap"])
        if word["sent"] is not None:
            cap_sent.append(word["sent"] - word["cap"])
            sent_recv.append(word["recv"] - word["sent"])
        recv_shown.append(shown - word["recv"])

    minimum = int(THRESHOLDS["b2MinWords"])
    gate.check(
        "graded-words",
        len(graded_words) >= minimum,
        f"{len(graded_words)} system words ended after live (need {minimum}); startBacklog={len(backlog)}",
    )
    bar = int(THRESHOLDS["b2LagP95Ms"])
    if lags:
        ordered = [float(value) for value in lags]
        p50 = grade.percentile(ordered, 0.50)
        p95 = grade.percentile(ordered, 0.95)
        worst = max(lags)
        detail = (
            f"p50={p50:.0f} p95={p95:.0f} max={worst} bar={bar} anchor=word-end "
            f"capture→sent {hop_text(cap_sent)} sent→recv {hop_text(sent_recv)} "
            f"recv→shown {hop_text(recv_shown)}"
        )
        gate.check("lag-p95", p95 <= bar, detail)
    else:
        gate.check("lag-p95", False, "no graded words")

    play = run.get("playWallMs") if run else None
    origin = clock_origin(latency)
    onset = wav_onset_ms(fixture, float(grade.THRESHOLDS["speechEvidenceRmsFloor"])) if fixture and fixture.is_file() else None
    partials = [shown for row, shown in pairs if row.get("track") == "system" and row.get("kind") == "partial"]
    setup_missing = not isinstance(play, int) or onset is None or (fixture is None or not fixture.is_file())
    if not present:
        gate.check("first-word-external", False, "no latency sidecar to time the first partial")
    elif setup_missing or origin is None:
        gate.check(
            "first-word-external",
            False,
            f"playWallMs={play} origin={origin} onset={onset} fixture={fixture}",
            grade.PREMISE_CHECK,
        )
    elif not partials:
        gate.check("first-word-external", False, "no system partial was shown")
    else:
        duration = 0
        if graded_words:
            first = min(graded_words, key=lambda word: word["e"])
            duration = max(0, first["e"] - first["s"])
        shown_wall = origin + min(partials)
        limit = play + onset + duration + bar
        gate.check(
            "first-word-external",
            shown_wall <= limit,
            f"first partial wall {shown_wall} limit {limit} (play {play} + onset {onset} + firstWord {duration} + {bar})",
        )
    captured_for_real(gate, session, rows)


def grade_b4(
    gate: grade.Gate,
    session: Path,
    rows: list[dict],
    latency: list[dict],
    run: dict | None,
    scenario: str,
) -> None:
    grade.engine_check(gate, rows, "B4")
    run = run or {}
    inputs = run.get("inputs")
    if not isinstance(inputs, list) or not inputs:
        gate.check("inputs", False, "harness_run.json inputs missing", grade.PREMISE_CHECK)
        inputs = []
    live_rows = marks(latency, "live")
    origin = clock_origin(latency)
    live_at = int(live_rows[0]["atMs"]) if live_rows and isinstance(live_rows[0].get("atMs"), int) else None
    live_wall = origin + live_at if origin is not None and live_at is not None else None

    recording_kind = RECORDING_KIND[scenario]
    t0_kind = T0_KIND[scenario]
    before: list[dict] = []
    if live_wall is not None:
        before = [item for item in inputs if isinstance(item, dict) and isinstance(item.get("wallMs"), int) and int(item["wallMs"]) <= live_wall]
    expected = EXPECTED_INPUTS[scenario]
    maximum = int(THRESHOLDS["b4MaxInputs"])
    kinds = [str(item.get("kind")) for item in before]
    gate.check(
        "inputs≤2",
        len(before) == expected and len(before) <= maximum and t0_kind in kinds and recording_kind in kinds,
        f"inputs before live {kinds} (need {expected}, including {t0_kind} and {recording_kind})",
    )

    recording = [item for item in inputs if isinstance(item, dict) and item.get("kind") == recording_kind and isinstance(item.get("wallMs"), int)]
    started = grade.session_start_ms(rows)
    siblings = [
        path for path in grade.child_sessions(session.parent)
        if path.resolve() != session.resolve()
    ]
    if not recording or started is None:
        gate.check(
            "no-session-before-input",
            False,
            f"recording input={bool(recording)} startedAt={started} other sessions={len(siblings)}",
            grade.PREMISE_CHECK,
        )
    else:
        rec_wall = int(recording[0]["wallMs"])
        gate.check(
            "no-session-before-input",
            started >= rec_wall - 500 and not siblings,
            f"session wall {started} recording input {rec_wall} other sessions={len(siblings)}",
        )

    sockets = run.get("idleSocketLines")
    if not isinstance(sockets, list):
        gate.check("idle-no-socket", False, "idleSocketLines missing", grade.PREMISE_CHECK)
    else:
        hit = [str(line) for line in sockets if "api.x.ai" in str(line).lower()]
        gate.check("idle-no-socket", not hit, f"idle lines mentioning api.x.ai: {len(hit)}")

    starts = [row for row in latency if row.get("t") == "start"]
    gate.check(
        "single-start",
        len(starts) == 1 and starts[0].get("source") == recording_kind,
        f"start rows={len(starts)} source={starts[0].get('source') if starts else None} (need {recording_kind})",
    )

    needed = [
        marks(latency, "first-frame", "system"),
        marks(latency, "first-frame", "microphone"),
        marks(latency, "streaming", "system"),
        marks(latency, "streaming", "microphone"),
    ]
    have = [item[0]["atMs"] for item in needed if item and isinstance(item[0].get("atMs"), int)]
    honest = live_at is not None and len(have) == 4 and live_at >= max(int(value) for value in have)
    gate.check(
        "live-honest",
        honest,
        f"live={live_at} marks={have}",
    )
    t0_rows = [item for item in inputs if isinstance(item, dict) and item.get("kind") == t0_kind and isinstance(item.get("wallMs"), int)]
    bar = int(THRESHOLDS["b4LiveWithinMs"])
    if live_wall is None or not t0_rows:
        gate.check("live-within", False, f"live wall={live_wall} t0={t0_kind} missing")
    else:
        delta = live_wall - int(t0_rows[0]["wallMs"])
        gate.check("live-within", delta <= bar, f"live − {t0_kind} = {delta} ms (bar {bar})")

    captured_for_real(gate, session, rows)
    stops = marks(latency, "stop-requested")
    end = grade.rows_of(rows, "end")
    clean = bool(end) and end[-1].get("clean") is True
    gate.check(
        "stopped-by-input",
        bool(stops) and stops[0].get("source") == recording_kind and clean,
        f"stop source={stops[0].get('source') if stops else None} clean={clean}",
    )


def grade_gate(
    name: str,
    session: Path,
    *,
    scenario: str | None = None,
    fixture: Path | None = None,
    no_provenance: bool = False,
) -> dict[str, object]:
    rows, _note = grade.load_rows(session)
    latency, _latency_note = load_latency(session)
    run = grade.load_harness_run(session)
    gate = grade.Gate()
    if name == "B2":
        grade_b2(gate, session, rows, latency, run, fixture)
        provenance_name = "B2"
    elif name == "B4":
        if scenario not in SCENARIOS:
            gate.check("scenario", False, f"scenario {scenario!r} is not one of {SCENARIOS}")
            provenance_name = "B4"
        else:
            grade_b4(gate, session, rows, latency, run, scenario)
            provenance_name = GATE_NAME[scenario]
    else:
        gate.check("gate", False, f"unknown gate {name}")
        provenance_name = name
    grade.provenance_checks(gate, session, rows, provenance_name, run, no_provenance)
    return gate.result()


def main() -> int:
    parser = argparse.ArgumentParser(description="Grade a Catcher session for B2 or B4")
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--gate", required=True, choices=("B2", "B4"))
    parser.add_argument("--scenario", choices=SCENARIOS)
    parser.add_argument("--fixture", type=Path, help="wav whose onset anchors the B2 external check")
    parser.add_argument("--no-provenance", action="store_true", help="unit tests only; forces unproven")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.gate == "B4" and args.scenario is None:
        parser.error("B4 requires --scenario")
    graded = grade_gate(
        args.gate,
        args.session,
        scenario=args.scenario,
        fixture=args.fixture,
        no_provenance=args.no_provenance,
    )
    report: dict[str, object] = {
        "session": str(args.session),
        "gate": args.gate,
        args.gate: graded,
    }
    if args.scenario is not None:
        report["scenario"] = args.scenario
    out = args.out or (args.session / "grade_v1.json")
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0 if graded["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
