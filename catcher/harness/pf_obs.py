#!/usr/bin/env python3
"""Parse pfctl and lsof text for the P3 gate.

The shell records the raw command output. This module decides what it
showed. Nothing here runs pfctl.
"""

from __future__ import annotations

import ipaddress
import re
import sys
from pathlib import Path


def _body(text: str) -> list[str]:
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("No ALTQ") or stripped.startswith("ALTQ related"):
            continue
        lines.append(stripped)
    return lines


def classify_ruleset(text: str) -> str:
    """com.apple | catcher | empty | foreign.

    Stock pf.conf evaluates anchor "com.apple/*". A ruleset that is only
    `anchor "catcher"` evaluates that name instead. An empty ruleset
    evaluates nothing, so a block loaded into it matches no packet.
    """
    lines = _body(text)
    body = "\n".join(lines)
    if 'anchor "com.apple/*"' in body:
        return "com.apple"
    if not lines:
        return "empty"
    if 'anchor "catcher"' in body:
        return "catcher"
    return "foreign"


def info_enabled(text: str) -> bool:
    return bool(re.search(r"^Status:\s+Enabled\b", text, re.MULTILINE))


def enable_token(text: str) -> str:
    match = re.search(r"Token\s*:\s*(\S+)", text)
    return match.group(1) if match else ""


def sudo_denied(text: str) -> bool:
    lowered = text.lower()
    return (
        "password is required" in lowered
        or "no tty present" in lowered
        or "a terminal is required" in lowered
    )


def normalize_ip(raw: str | None) -> str | None:
    if raw is None:
        return None
    text = raw.strip().strip("[]").rstrip(".")
    if not text or text.startswith("*"):
        return None
    if "%" in text:
        text = text.split("%", 1)[0]
    if text.startswith("::ffff:"):
        text = text[7:]
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    mapped = getattr(addr, "ipv4_mapped", None)
    return str(mapped or addr)


def split_endpoint(token: str) -> tuple[str | None, str | None]:
    token = token.strip()
    if not token or token.startswith("*"):
        return None, None
    if token.startswith("["):
        host, _, rest = token[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
        return normalize_ip(host), port or None
    if token.count(":") == 1 and token.split(":", 1)[0].count(".") == 3:
        host, port = token.split(":", 1)
        return normalize_ip(host), port
    host, sep, port = token.rpartition(":")
    if not sep:
        return None, None
    return normalize_ip(host), port or None


def lsof_peers(text: str) -> list[tuple[str, str]]:
    """(local, remote) for connections whose remote port is 443.

    `lsof -Fn` emits `nlocal->remote`. A missing local address is kept as
    an empty string so the caller can still name the remote.
    """
    found: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for line in text.splitlines():
        if not line.startswith("n") or "->" not in line:
            continue
        left, right = line[1:].split("->", 1)
        local, _ = split_endpoint(left)
        remote, port = split_endpoint(right)
        if remote is None or port not in ("443", "https"):
            continue
        key = (local or "", remote)
        if key in seen:
            continue
        seen.add(key)
        found.append(key)
    return found


def dig_addresses(text: str) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        addr = normalize_ip(line.strip())
        if addr and addr not in seen:
            seen.add(addr)
            found.append(addr)
    return found


def blocks_present(text: str) -> bool:
    """Both directions of the block, after pf expands `proto { tcp udp }`."""
    body = "\n".join(_body(text))
    return "block drop out" in body and "block drop in" in body


def table_covers(text: str, peers: list[str]) -> bool:
    have = {addr for line in text.splitlines() if (addr := normalize_ip(line.strip()))}
    return all(peer in have for peer in peers)


_ENDPOINT = re.compile(
    r"\[([0-9A-Fa-f:.%]+)\][:.](\d+)"
    r"|(\d{1,3}(?:\.\d{1,3}){3})[:.](\d+)"
    r"|([0-9A-Fa-f:]+(?:%[0-9A-Za-z]+)?)\[(\d+)\]"
)


def _endpoint_ip_port(match: re.Match[str]) -> tuple[str, str]:
    if match.group(1) is not None:
        return match.group(1), match.group(2)
    if match.group(3) is not None:
        return match.group(3), match.group(4)
    return match.group(5), match.group(6)


def states_for_peers(text: str, peers: list[str]) -> list[str]:
    """State lines that still name a live peer on port 443."""
    wanted = set(peers)
    hits: list[str] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        found: list[tuple[str, str]] = []
        for match in _ENDPOINT.finditer(line):
            raw, port = _endpoint_ip_port(match)
            ip = normalize_ip(raw)
            if ip:
                found.append((ip, port))
        if "443" not in {port for _, port in found}:
            continue
        if any(ip in wanted for ip, _ in found):
            hits.append(line.strip())
    return hits


def killed_states(text: str) -> int:
    total = 0
    seen = False
    for line in text.splitlines():
        match = re.search(r"killed\s+(\d+)\s+states", line)
        if match:
            total += int(match.group(1))
            seen = True
    return total if seen else 0


def rule_counters(text: str) -> tuple[int, int]:
    """(drops out, drops in) summed across every block-drop rule.

    pfctl prints one rule per protocol. A UDP rule at Packets: 0 does not
    cancel a TCP rule that has already dropped.
    """
    outgoing = 0
    incoming = 0
    pending: str | None = None
    for line in text.splitlines():
        if "block drop" in line:
            pending = line
            continue
        if pending is None:
            continue
        match = re.search(r"Packets:\s*(\d+)", line)
        if not match:
            continue
        count = int(match.group(1))
        if "block drop out" in pending:
            outgoing += count
        elif "block drop in" in pending:
            incoming += count
        pending = None
    return outgoing, incoming


def _read_stdin() -> str:
    return sys.stdin.read()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: pf_obs.py classify|enabled|token|sudo-denied|peers|dig|blocks|counters|killed", file=sys.stderr)
        return 2
    command = argv[1]
    text = _read_stdin()
    if command == "classify":
        print(classify_ruleset(text))
    elif command == "enabled":
        print("yes" if info_enabled(text) else "no")
        return 0 if info_enabled(text) else 1
    elif command == "token":
        print(enable_token(text))
    elif command == "sudo-denied":
        denied = sudo_denied(text)
        print("yes" if denied else "no")
        return 0 if denied else 1
    elif command == "peers":
        for local, remote in lsof_peers(text):
            print(f"{local} {remote}")
    elif command == "dig":
        for addr in dig_addresses(text):
            print(addr)
    elif command == "blocks":
        present = blocks_present(text)
        print("yes" if present else "no")
        return 0 if present else 1
    elif command == "counters":
        outgoing, incoming = rule_counters(text)
        print(f"{outgoing} {incoming}")
    elif command == "killed":
        print(killed_states(text))
    elif command == "states-left":
        peers = Path(argv[2]).read_text(encoding="utf-8").split()
        left = states_for_peers(text, peers)
        print(len(left))
        for line in left:
            print(line)
        return 0 if not left else 1
    elif command == "table-covers":
        peers = Path(argv[2]).read_text(encoding="utf-8").split()
        covers = table_covers(text, peers)
        print("yes" if covers else "no")
        return 0 if covers else 1
    else:
        print(f"unknown command {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
