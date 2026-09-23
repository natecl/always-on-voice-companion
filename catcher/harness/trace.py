#!/usr/bin/env python3
"""Print the two TRACE lines for a session.

Reads <session>/stages.log. The last line of a stage (one per track for
api-connect) is its verdict. Works when the app was kill -9'd before it
wrote a TRACE of its own. Standard library only.
"""

from __future__ import annotations

import os
import sys

STAGE_ORDER = [
    "tcc-check",
    "capture-start",
    "frames-received",
    "pcm-extract",
    "api-connect",
    "api-stream",
    "segments-received",
    "transcript-write",
]


def tokenize(line: str) -> list[str]:
    tokens: list[str] = []
    current: list[str] = []
    in_quote = False
    escape = False
    for character in line:
        if escape:
            current.append("\\")
            current.append(character)
            escape = False
            continue
        if character == "\\":
            escape = True
            continue
        if character == '"':
            in_quote = not in_quote
            current.append(character)
            continue
        if character == " " and not in_quote:
            if current:
                tokens.append("".join(current))
                current = []
            continue
        current.append(character)
    if escape:
        current.append("\\")
    if current:
        tokens.append("".join(current))
    return tokens


def unescape(raw: str) -> str:
    out: list[str] = []
    escape = False
    for character in raw:
        if escape:
            if character == "n":
                out.append("\n")
            elif character == '"':
                out.append('"')
            elif character == "\\":
                out.append("\\")
            else:
                out.append(character)
            escape = False
            continue
        if character == "\\":
            escape = True
            continue
        out.append(character)
    if escape:
        out.append("\\")
    return "".join(out)


def parse_field(token: str) -> tuple[str, str] | None:
    if "=" not in token:
        return None
    key, raw = token.split("=", 1)
    if not key:
        return None
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        raw = unescape(raw[1:-1])
    return key, raw


def parse_line(line: str) -> dict | None:
    tokens = tokenize(line.strip())
    if not tokens or tokens[0] not in {"STAGE", "TRACE", "PREFLIGHT"}:
        return None
    fields: list[tuple[str, str]] = []
    if tokens[0] == "TRACE":
        for token in tokens[1:]:
            field = parse_field(token)
            if field:
                fields.append(field)
        return {"kind": "TRACE", "name": None, "verdict": None, "fields": fields}
    if len(tokens) < 3:
        return None
    for token in tokens[3:]:
        field = parse_field(token)
        if field:
            fields.append(field)
    return {"kind": tokens[0], "name": tokens[1], "verdict": tokens[2], "fields": fields}


def field(line: dict, key: str) -> str | None:
    for name, value in line["fields"]:
        if name == key:
            return value
    return None


def as_int(line: dict, key: str) -> int:
    raw = field(line, key)
    try:
        return int(raw or "0")
    except ValueError:
        return 0


def quote(value: str) -> str:
    if value and not any(character in value for character in ' "\\\n\t'):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def format_fields(prefix: str, fields: list[tuple[str, str]]) -> str:
    parts = [prefix]
    for key, value in fields:
        parts.append(f"{key}={quote(value)}")
    return " ".join(parts)


def verdict_lines(lines: list[dict]) -> list[dict]:
    last: dict[str, int] = {}
    stages = [
        (index, line)
        for index, line in enumerate(lines)
        if line["kind"] == "STAGE" and line["name"] in STAGE_ORDER
    ]
    for index, line in stages:
        track = field(line, "track") or ""
        last[f"{line['name']}\t{track}"] = index
    return [lines[index] for index in sorted(last.values())]


def last_stage(lines: list[dict], name: str) -> dict | None:
    found = [line for line in lines if line["kind"] == "STAGE" and line["name"] == name]
    return found[-1] if found else None


def zero_energy_tracks(line: dict) -> list[str]:
    raw = field(line, "zeroEnergy") or ""
    return [part.strip() for part in raw.split(",") if part.strip() and part.strip() != "none"]


def silence_sentence(lines: list[dict]) -> str | None:
    pcm = last_stage(lines, "pcm-extract")
    stream = last_stage(lines, "api-stream")
    segments = last_stage(lines, "segments-received")
    if not pcm or not stream or not segments:
        return None
    parts = []
    for track in zero_energy_tracks(pcm):
        bytes_sent = as_int(stream, track)
        finals = as_int(segments, track)
        if bytes_sent > 0 and finals == 0:
            parts.append(f"{track}: {finals} finals from {bytes_sent} bytes; every {track} PCM frame is zero")
    return "; ".join(parts) if parts else None


def contains(line: dict, needle: str) -> bool:
    return any(needle in value for _, value in line["fields"])


def url_error(line: dict) -> bool:
    codes = {"-1003", "-1009", "-1004"}
    blob = " ".join(value for _, value in line["fields"])
    if "NSURLError" not in blob:
        return False
    code = field(line, "code") or ""
    return code in codes or any(item in blob for item in codes)


def cause_for(failing: dict, lines: list[dict]) -> tuple[str, str]:
    name = failing["name"]
    if name == "tcc-check":
        if field(failing, "entitlement") == "false":
            return "hardened build without audio-input", "rebuild with scripts/build-app.sh"
        if field(failing, "owns") == "false":
            return "started from a shell; TCC bills Terminal/Cursor", 'launch with open -n "$CATCHER_APP"'
        if field(failing, "mic") == "denied":
            return "denied row for com.catcher.app", "Privacy → Microphone toggle"
        if field(failing, "mic") == "notDetermined":
            return "Allow never answered", "Request microphone with Catcher frontmost; quit Zoom"
        if field(failing, "screen") == "denied":
            return "Screen & System Audio Recording missing", "grant it to com.catcher.app, relaunch"
    elif name == "capture-start":
        if field(failing, "code") == "-3801":
            return "user declined screen capture", "grant Screen & System Audio Recording"
        return "SCStream failed to start", "copy the domain/code line into the report"
    elif name == "frames-received":
        system = as_int(failing, "system")
        microphone = as_int(failing, "microphone")
        if system == 0 and microphone > 0:
            return "no system buffers on the chosen display", "play audio on the captured display; check the display choice"
        if microphone == 0:
            return "mic device missing or not delivered", "check the default input device (preflight mic-device)"
    elif name == "pcm-extract":
        if field(failing, "osstatus") == "-12737":
            return "retained-block-buffer variant used", "regression in SampleBufferPCM.extract"
        if as_int(failing, "failed") > 0 and contains(failing, "unsupportedFormat"):
            return "SCK format changed", "the mBytesPerFrame/format detail names it"
    elif name == "api-connect":
        if contains(failing, "missing XAI_API_KEY"):
            return "key not forwarded", "export XAI_API_KEY; open --env forwards it via lib.sh"
        if field(failing, "http") in {"401", "403"}:
            return "key rejected", "rotate the key; body shows the xAI reason"
        if contains(failing, "handshakeTimeout"):
            return "socket open but no transcript.created", "check the model= query and xAI status"
        if url_error(failing):
            return "DNS / offline / refused", "network, VPN, or a leftover P3 pf rule (pfctl -sr)"
    elif name == "api-stream":
        pcm = last_stage(lines, "pcm-extract")
        if as_int(failing, "system") == 0 and pcm and pcm["verdict"] == "OK":
            return "pump never ran (ready=false)", "engine state bug; include the snapshot"
    elif name == "segments-received":
        if as_int(failing, "apiErrors") > 0:
            return "xAI returned errors mid-stream", "the first error body is in error="
        if silence_sentence(lines):
            return (
                "system track captured digital silence",
                "nothing was playing on the captured display, or the mixdown cancelled; check system.pcm peak/RMS and the chosen display",
            )
        if as_int(failing, "blankDropped") > 0 and as_int(failing, "system") == 0:
            return "only endpoint spam came back", "audio too quiet or not speech"
    elif name == "transcript-write":
        if field(failing, "error"):
            return "assemble/end failed", "the error names the path and errno"
        if as_int(failing, "bytes") == 0 and as_int(failing, "segments") == 0:
            return "nothing to write", "the trace points upstream; this is a symptom"
    return "", ""


def underlying(failing: dict | None, lines: list[dict]) -> str:
    if failing is None:
        return ""
    error = field(failing, "error")
    if error:
        return error
    if failing["name"] == "segments-received":
        sentence = silence_sentence(lines)
        if sentence:
            return sentence
    http = field(failing, "http")
    body = field(failing, "body")
    if http and body:
        return f"http={http} {body}"
    if http:
        return f"http={http}"
    domain = field(failing, "domain")
    code = field(failing, "code")
    if domain and code:
        return f"{domain} {code}"
    return ""


def trace_lines(stage_text: str) -> tuple[str, str]:
    parsed = [item for item in (parse_line(line) for line in stage_text.splitlines()) if item]
    verdicts = verdict_lines(parsed)
    failing = next((line for line in verdicts if line["verdict"] == "FAIL"), None)
    if failing is None:
        last_ok = next((line["name"] for line in reversed(verdicts) if line["verdict"] == "OK"), "none")
        error = ""
        cause, fix = "", ""
        first = "not-reached"
    else:
        index = verdicts.index(failing)
        last_ok = next((line["name"] for line in reversed(verdicts[:index]) if line["verdict"] == "OK"), "none")
        first = failing["name"] or "not-reached"
        error = underlying(failing, parsed)
        cause, fix = cause_for(failing, parsed)
    summary = format_fields("TRACE", [("last-ok", last_ok or "none"), ("first-fail", first), ("error", error)])
    detail = format_fields("TRACE", [("cause", cause), ("fix", fix)])
    return summary, detail


def resolve(root: str) -> str:
    if os.path.isfile(os.path.join(root, "stages.log")) or os.path.isfile(os.path.join(root, "events.jsonl")):
        return root
    found = []
    if os.path.isdir(root):
        for name in os.listdir(root):
            child = os.path.join(root, name)
            if not os.path.isdir(child):
                continue
            stages = os.path.join(child, "stages.log")
            events = os.path.join(child, "events.jsonl")
            if os.path.isfile(stages) or os.path.isfile(events):
                stamp_path = stages if os.path.isfile(stages) else events
                found.append((os.path.getmtime(stamp_path), child))
    if not found:
        return root
    found.sort()
    return found[-1][1]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: trace.py <session-root-or-session-dir>", file=sys.stderr)
        return 2
    session = resolve(argv[1])
    path = os.path.join(session, "stages.log")
    if not os.path.isfile(path):
        print('TRACE last-ok=none first-fail=not-reached error="stages.log missing"')
        print('TRACE cause="" fix=""')
        return 0
    text = open(path, encoding="utf-8").read()
    summary, detail = trace_lines(text)
    print(summary)
    print(detail)
    return 0


SAMPLE = """\
STAGE tcc-check OK screen=granted mic=authorized owns=true entitlement=true responsible=Catcher
STAGE capture-start OK display=1
STAGE api-connect OK track=system engine=grok ms=412
STAGE api-connect OK track=microphone engine=grok ms=398
STAGE frames-received OK system=1002 microphone=1000 invalid=0 empty=0
STAGE pcm-extract OK system=1002 microphone=1000 failed=0 osstatus=0 zeroEnergy=system
STAGE api-stream OK system=320000 microphone=320000 pending=0 sendErrors=0
STAGE segments-received FAIL system=0 microphone=3 partials=4 blankDropped=21 restated=0 apiErrors=0
STAGE reconnect OK track=system attempt=1 code=1006 reason="inbound stall"
STAGE transcript-write OK bytes=88 segments=3 recovered=false
"""


def _self_test() -> None:
    summary, detail = trace_lines(SAMPLE)
    assert summary == 'TRACE last-ok=api-stream first-fail=segments-received error="system: 0 finals from 320000 bytes; every system PCM frame is zero"', summary
    assert detail == 'TRACE cause="system track captured digital silence" fix="nothing was playing on the captured display, or the mixdown cancelled; check system.pcm peak/RMS and the chosen display"', detail
    empty, _ = trace_lines("STAGE tcc-check OK screen=granted\nSTAGE capture-start OK display=1\n")
    assert empty == "TRACE last-ok=capture-start first-fail=not-reached error=\"\"" or empty.endswith('error=""'), empty


if __name__ == "__main__":
    if os.environ.get("TRACE_SELF_TEST") == "1":
        _self_test()
        print("trace.py self-test ok")
        raise SystemExit(0)
    raise SystemExit(main(sys.argv))
