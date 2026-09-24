#!/usr/bin/env python3
"""Board runner pieces that the shell should not reimplement.

`reap-orphans` kills leftover CatcherApp and fixture afplay processes.
`exec-gate` runs one gate with no stdin and a deadline.
`compose` writes board.json and board.md from files on disk. A field with
no readable source is "not-observed"; the board never fills that in.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

GATES = ("p1", "p2", "p3", "p4", "p5", "p6")
HERE = Path(__file__).resolve().parent


def orphan_kind(command: str) -> str | None:
    """CatcherApp from any build, or afplay of this harness's fixture."""
    if "/Contents/MacOS/CatcherApp" in command:
        return "catcher"
    if "afplay" in command and "known-60s.wav" in command:
        return "afplay"
    return None


def list_processes() -> list[tuple[int, str]]:
    try:
        listed = subprocess.run(
            ["ps", "-ax", "-o", "pid=", "-o", "command="],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return []
    found: list[tuple[int, str]] = []
    for line in listed.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        found.append((pid, command.strip()))
    return found


def reap_orphans(
    obs_path: Path,
    *,
    lister=list_processes,
    killer=None,
    pause=time.sleep,
    now=time.time,
) -> int:
    """SIGKILL matching processes. Survivors after 5s are a failed premise."""
    if killer is None:
        killer = os.kill
    obs_path.parent.mkdir(parents=True, exist_ok=True)
    before = [(pid, command) for pid, command in lister() if orphan_kind(command)]
    killed: list[dict[str, object]] = []
    for pid, command in before:
        try:
            killer(pid, signal.SIGKILL)
            killed.append({"pid": pid, "command": command, "kind": orphan_kind(command)})
        except OSError as error:
            killed.append({"pid": pid, "command": command, "error": str(error)})
    deadline = now() + 5
    survivors = before
    while survivors and now() < deadline:
        pause(0.25)
        survivors = [(pid, command) for pid, command in lister() if orphan_kind(command)]
    record = {
        "atWallMs": int(now() * 1000),
        "killed": killed,
        "survivors": [{"pid": pid, "command": command} for pid, command in survivors],
        "tag": "orphan-survived" if survivors else "ok",
    }
    with obs_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")
    return 1 if survivors else 0


def exec_gate(timeout: float, log_path: Path, obs_path: Path, command: list[str]) -> int:
    """Run a gate with stdin closed. A timeout kills the process group."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    timed_out = False
    try:
        output, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        output, _ = proc.communicate()
    log_path.write_bytes(output or b"")
    if timed_out:
        obs_path.parent.mkdir(parents=True, exist_ok=True)
        obs_path.write_text(json.dumps({"tag": "timeout"}) + "\n", encoding="utf-8")
        return 124
    return proc.returncode if proc.returncode is not None else 1


def _load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def field(value, source: str) -> dict[str, object]:
    if value is None:
        return {"value": "not-observed", "source": source}
    return {"value": value, "source": source}


def file_stamp(run: Path, relative: str) -> dict[str, object]:
    path = run / relative
    if not path.is_file():
        return {"bytes": "not-observed", "sha256": "not-observed", "source": relative}
    data = path.read_bytes()
    return {
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "source": relative,
    }


def preflight_line(run: Path) -> str | None:
    path = run / "preflight" / "preflight.txt"
    if not path.is_file():
        return None
    lines = [line for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    for line in reversed(lines):
        if line.startswith("PREFLIGHT RESULT "):
            return line
    return None


def preflight_lines(run: Path) -> list[str] | None:
    path = run / "preflight" / "preflight.txt"
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def afplay_rows(run: Path) -> list[dict[str, str]] | None:
    path = run / "obs" / "afplay.log"
    if not path.is_file():
        return None
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        fields: dict[str, str] = {}
        for part in line.split():
            if "=" in part:
                key, value = part.split("=", 1)
                fields[key] = value
        rows.append(fields)
    return rows


def orphan_summary(run: Path) -> dict[str, object] | None:
    path = run / "obs" / "orphans.jsonl"
    if not path.is_file():
        return None
    killed = 0
    survivors = 0
    tags: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            return None
        killed += len(record.get("killed") or [])
        survivors += len(record.get("survivors") or [])
        tags.append(str(record.get("tag", "")))
    return {"killed": killed, "survivors": survivors, "tags": tags}


def compose(
    run: Path,
    *,
    stopped: str | None = None,
    expect_sha: str | None = None,
    expect_cdhash: str | None = None,
) -> dict[str, object]:
    """Build the board from the run directory. Writes board.json and board.md."""
    run.mkdir(parents=True, exist_ok=True)
    verdict_path = run / "v0-verdict.json"
    verdict = _load_json(verdict_path) if verdict_path.is_file() else None
    env = _load_json(run / "obs" / "board-env.json")
    if not isinstance(env, dict):
        env = None
    result_line = preflight_line(run)
    lines = preflight_lines(run)
    launched = [name for name in GATES if (run / name).is_dir()]
    ledger = afplay_rows(run)
    plays = [row for row in ledger if row.get("action") == "play"] if ledger is not None else None
    hard_gate = None
    if plays is not None:
        hard_gate = all(row.get("token") == "RAISE OK" for row in plays)
    orphans = orphan_summary(run)
    eligible = True
    if isinstance(env, dict) and env.get("greenEligible") is False:
        eligible = False

    gates: dict[str, object] = {}
    rig_obs: dict[str, object] = {}
    for name in GATES:
        upper = name.upper()
        obs_rel = f"{name}/rig_obs.json"
        obs = _load_json(run / obs_rel)
        if not isinstance(obs, dict):
            obs = None
        rig_obs[upper] = obs if obs is not None else "not-observed"
        graded = None
        if isinstance(verdict, dict):
            entry = (verdict.get("gates") or {}).get(upper)
            if isinstance(entry, dict):
                graded = entry.get("result")
        tag = obs.get("tag") if isinstance(obs, dict) else None
        block = obs.get("block", tag) if isinstance(obs, dict) else None
        row = {
            "result": field(graded, "v0-verdict.json"),
            "tag": field(tag, obs_rel),
            "block": field(block, obs_rel),
        }
        observed_ok = all(item["value"] != "not-observed" for item in row.values())
        row_pass = observed_ok and graded == "pass" and tag == "ok"
        row["pass"] = {
            "value": row_pass if observed_ok else "not-observed",
            "source": f"v0-verdict.json+{obs_rel}",
        }
        gates[upper] = row

    identity_sha = None
    identity_cdhash = None
    if isinstance(verdict, dict) and verdict.get("sha") and verdict.get("cdhash"):
        identity_sha = str(verdict.get("sha"))
        identity_cdhash = str(verdict.get("cdhash"))
    elif isinstance(env, dict):
        identity_sha = env.get("catcherGitSHA") or None
        identity_cdhash = env.get("cdhash") or None
    wrong_build = False
    if expect_sha and identity_sha and identity_sha != expect_sha:
        wrong_build = True
    if expect_cdhash and identity_cdhash and not str(identity_cdhash).lower().startswith(expect_cdhash.lower()):
        wrong_build = True
    # The brief quotes CDHash 57250034 and the full hash. A full observation
    # matches either form; a different hash matches neither.

    preflight_pass = result_line is not None and result_line.startswith("PREFLIGHT RESULT PASS")
    verdict_green = isinstance(verdict, dict) and verdict.get("verdict") == "GREEN"
    tags_ok = all(
        isinstance(rig_obs[name.upper()], dict) and rig_obs[name.upper()].get("tag") == "ok"
        for name in GATES
    )
    orphans_ok = isinstance(orphans, dict) and orphans.get("survivors") == 0 and "orphan-survived" not in (orphans.get("tags") or [])
    audio_gates = [name for name in ("p1", "p3", "p5", "p6") if name in launched]
    if audio_gates:
        afplay_ok = bool(plays) and hard_gate is True
    else:
        # Nothing that plays was launched. An empty ledger is the observation.
        afplay_ok = hard_gate is True or ledger is None or plays == []

    if wrong_build:
        verdict_value = "invalid (wrong build)"
    elif (
        stopped is None
        and preflight_pass
        and verdict_green
        and tags_ok
        and orphans_ok
        and afplay_ok
        and eligible
        and all(row["pass"]["value"] is True for row in gates.values())
    ):
        verdict_value = "GREEN"
    else:
        verdict_value = "RED"

    logs = {
        relative: file_stamp(run, relative)
        for relative in ["obs/afplay.log", "obs/orphans.jsonl", "obs/board-env.json", "preflight/preflight.txt", "v0-verdict.json"]
        + [f"{name}/gate.log" for name in GATES]
        + [f"{name}/rig_obs.json" for name in GATES]
    }
    board = {
        "verdict": {
            "value": verdict_value,
            "source": "preflight/preflight.txt+v0-verdict.json+rig_obs.json+obs/afplay.log+obs/orphans.jsonl+obs/board-env.json",
        },
        "stopped": field(stopped, "preflight/preflight.txt" if stopped == "preflight" else "obs/orphans.jsonl"),
        "preflight": field(result_line, "preflight/preflight.txt"),
        "preflightLines": field(lines, "preflight/preflight.txt"),
        "gatesLaunched": {"value": len(launched), "source": "gate-dirs"},
        "gatesLaunchedNames": {"value": launched, "source": "gate-dirs"},
        "afplayLaunched": field(None if plays is None else len(plays), "obs/afplay.log"),
        "afplayHardGate": field(hard_gate, "obs/afplay.log"),
        "orphans": field(orphans, "obs/orphans.jsonl"),
        "sha": field(identity_sha, "v0-verdict.json" if isinstance(verdict, dict) else "obs/board-env.json"),
        "cdhash": field(identity_cdhash, "v0-verdict.json" if isinstance(verdict, dict) else "obs/board-env.json"),
        "harnessGitSHA": field(env.get("harnessGitSHA") if isinstance(env, dict) else None, "obs/board-env.json"),
        "greenEligible": field(env.get("greenEligible") if isinstance(env, dict) else None, "obs/board-env.json"),
        "gates": gates,
        "rigObs": rig_obs,
        "logs": logs,
    }
    (run / "board.json").write_text(json.dumps(board, indent=2) + "\n", encoding="utf-8")
    (run / "board.md").write_text(render_markdown(board), encoding="utf-8")
    return board


def render_markdown(board: dict) -> str:
    """Paste-ready table. Every cell comes from board.json."""
    lines = [
        f"# Catcher board: {board['verdict']['value']}",
        "",
        f"sha: {board['sha']['value']} ({board['sha']['source']})",
        f"cdhash: {board['cdhash']['value']} ({board['cdhash']['source']})",
        f"harness: {board['harnessGitSHA']['value']} ({board['harnessGitSHA']['source']})",
        f"stopped: {board['stopped']['value']}",
        f"preflight: {board['preflight']['value']}",
        f"gates launched: {board['gatesLaunched']['value']} {board['gatesLaunchedNames']['value']}",
        f"afplay launched: {board['afplayLaunched']['value']} (hard gate {board['afplayHardGate']['value']})",
        f"orphans: {json.dumps(board['orphans']['value'], sort_keys=True)}",
        "",
        "| gate | result | tag | block | pass | source |",
        "|---|---|---|---|---|---|",
    ]
    pre = board["preflight"]["value"]
    lines.append(f"| preflight | {pre} | | | | {board['preflight']['source']} |")
    for name, row in board["gates"].items():
        lines.append(
            f"| {name} | {row['result']['value']} | {row['tag']['value']} | {row['block']['value']} | {row['pass']['value']} | {row['tag']['source']} |"
        )
    lines.append("")
    lines.append("## P3 observation")
    p3 = board["rigObs"].get("P3")
    if isinstance(p3, dict):
        for key in ("ruleset", "anchor", "statesKilled", "statesLeft", "block", "tag"):
            lines.append(f"- {key}: {p3.get(key, 'not-observed')}")
        for sample in p3.get("samples") or []:
            lines.append(
                f"- sample +{sample.get('offsetMs')}ms dropsIn={sample.get('dropsIn')} "
                f"dropsOut={sample.get('dropsOut')} peers443={sample.get('peers443')}"
            )
    else:
        lines.append(f"- {p3}")
    lines.append("")
    lines.append("## Logs")
    for relative, stamp in board["logs"].items():
        lines.append(f"- {relative}: bytes={stamp['bytes']} sha256={stamp['sha256']}")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Catcher board helpers")
    sub = parser.add_subparsers(dest="command", required=True)

    reap = sub.add_parser("reap-orphans")
    reap.add_argument("obs", type=Path)

    execute = sub.add_parser("exec-gate")
    execute.add_argument("--timeout", type=float, required=True)
    execute.add_argument("--log", type=Path, required=True)
    execute.add_argument("--obs", type=Path, required=True)
    execute.add_argument("command", nargs=argparse.REMAINDER)

    build = sub.add_parser("compose")
    build.add_argument("--run", type=Path, required=True)
    build.add_argument("--stopped", choices=("preflight", "orphans"))
    build.add_argument("--expect-sha")
    build.add_argument("--expect-cdhash")

    args = parser.parse_args(argv)
    if args.command == "reap-orphans":
        return reap_orphans(args.obs)
    if args.command == "exec-gate":
        command = list(args.command)
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            print("exec-gate needs a command", file=sys.stderr)
            return 2
        return exec_gate(args.timeout, args.log, args.obs, command)
    board = compose(
        args.run,
        stopped=args.stopped,
        expect_sha=args.expect_sha,
        expect_cdhash=args.expect_cdhash,
    )
    print(args.run / "board.json")
    print(board["verdict"]["value"])
    return 0 if board["verdict"]["value"] == "GREEN" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
