#!/usr/bin/env python3
"""Re-grade the six gate roots and write v0-verdict.json.

GREEN only when P1–P6 are all `pass`, every session is from one CatcherGitSHA
and one CDHash, and the P5 shape reference is the same build's Grok session
(the P1 session unless --shape-reference is given). grade.json files on disk
are not trusted; each root is graded again here.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grade  # noqa: E402

REF = HERE / "fixtures" / "known-60s.ref.txt"


def newest_session(root: Path) -> Path:
    candidates = grade.child_sessions(root)
    if not candidates:
        raise SystemExit(f"no events.jsonl under {root}")
    candidates.sort(key=lambda path: (path / "events.jsonl").stat().st_mtime)
    return candidates[-1]


def pick_session(gate: str, root: Path) -> Path:
    return grade.pick_revoke_session(root) if gate == "P2" else newest_session(root)


def grade_root(gate: str, root: Path, *, shape_reference: Path | None, ref: Path) -> dict[str, object]:
    session = pick_session(gate, root)
    rows, _note = grade.load_rows(session)
    run = grade.load_harness_run(session) or {}
    graded = grade.grade_gate(
        gate,
        session,
        rows,
        ref=ref,
        expect_recovery=gate == "P1",
        shape_reference=shape_reference if gate == "P5" else None,
    )
    obs = grade.load_rig_obs(session)
    return {
        **graded,
        "session": str(session),
        "sha": grade.app_sha(rows),
        "cdhash": str((run.get("codesign") or {}).get("cdhash", "")),
        "engine": str(grade.header(rows).get("engine", "")),
        "rig": obs if isinstance(obs, dict) else "not-observed",
    }


def preflight_result(path: Path) -> str:
    """Last PREFLIGHT RESULT line, or a missing marker the board can quote."""
    if not path.is_file():
        report = path / "preflight.txt"
    else:
        report = path
    if not report.is_file():
        return "missing"
    lines = [line.strip() for line in report.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    for line in reversed(lines):
        if line.startswith("PREFLIGHT RESULT "):
            return line
    return "missing"


def decide(gates: dict[str, dict[str, object]]) -> tuple[str, list[str], str, str]:
    reasons: list[str] = []
    for name in grade.GATES:
        entry = gates.get(name)
        if entry is None:
            reasons.append(f"{name} missing")
        elif entry.get("result") != "pass":
            reasons.append(f"{name} {entry.get('result')}")
    shas = {str(entry.get("sha", "")) for entry in gates.values()}
    cdhashes = {str(entry.get("cdhash", "")) for entry in gates.values()}
    if len(shas) != 1 or "" in shas:
        reasons.append(f"CatcherGitSHA differs or is missing across gates: {sorted(shas)}")
    if len(cdhashes) != 1 or "" in cdhashes:
        reasons.append(f"CDHash differs or is missing across gates: {sorted(cdhashes)}")
    sha = next(iter(shas)) if len(shas) == 1 else ""
    cdhash = next(iter(cdhashes)) if len(cdhashes) == 1 else ""
    return ("GREEN" if not reasons else "RED"), reasons, sha, cdhash


def graded_on() -> str:
    host = platform.system()
    if host != "Darwin":
        return f"{host} {platform.release()}"
    model = ""
    try:
        model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        pass
    return f"Darwin {platform.mac_ver()[0]} {model}".strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Six-gate, one-build v0 verdict")
    for name in grade.GATES:
        parser.add_argument(f"--{name.lower()}", type=Path, required=True, help=f"{name} root passed to run.sh")
    parser.add_argument("--shape-reference", type=Path, help="Grok session for P5; defaults to the P1 session")
    parser.add_argument("--ref", type=Path, default=REF)
    parser.add_argument("--preflight", type=Path, help="preflight dir or preflight.txt; a non-PASS verdict is RED")
    parser.add_argument("--out", type=Path, required=True, help="v0-verdict.json path or a directory for it")
    args = parser.parse_args()
    roots = {name: getattr(args, name.lower()) for name in grade.GATES}
    shape_reference = args.shape_reference or newest_session(roots["P1"])
    gates = {
        name: grade_root(name, roots[name], shape_reference=shape_reference, ref=args.ref)
        for name in grade.GATES
    }
    verdict, reasons, sha, cdhash = decide(gates)
    preflight = None
    if args.preflight is not None:
        preflight = preflight_result(args.preflight)
        if not preflight.startswith("PREFLIGHT RESULT PASS"):
            reasons.append(f"preflight {preflight}")
            verdict = "RED"
    report = {
        "verdict": verdict,
        "sha": sha,
        "cdhash": cdhash,
        "reasons": reasons,
        "preflight": preflight if preflight is not None else "not-requested",
        "shapeReference": str(shape_reference),
        "gates": gates,
        "gradedOn": graded_on(),
        "gradedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    out = args.out / "v0-verdict.json" if args.out.is_dir() or not args.out.suffix else args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(out)
    print(f"{verdict} sha={sha or '-'} cdhash={cdhash or '-'}")
    for reason in reasons:
        print(f"  {reason}")
    return 0 if verdict == "GREEN" else 1


if __name__ == "__main__":
    sys.exit(main())
