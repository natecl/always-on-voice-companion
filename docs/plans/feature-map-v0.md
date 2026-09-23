# v0 FEATURE_MAP — plan (plan only)

**Status:** implemented in `277b3c61872db76b2b62b3f4e27942f60be705ff`. Planned against `95837a8891a07f4169ecfa9b869a7a80c4545ad3`. Map: [`../FEATURE_MAP.md`](../FEATURE_MAP.md).

**Goal:** One page that answers "which v0 surfaces exist, where does each live, what proves it, and what was the last Mac grade?" Today that answer is spread across `docs/plans/v0-catcher.md`, `docs/qa/v0-grading.md`, `docs/qa/v0-diagnostics.md`, `catcher/harness/grade.py`, and a board file on a Mac's `/tmp`. The map points at those files; it does not replace or restate them.

**Evidence the map records:** Mac run at `95837a8`, `Catcher.app` CDHash `62450598`, board `/tmp/catcher-auto/95837a8-20260923-003139/board.json`, P1–P6 all `pass`, preflight `PASS`. The board is not in git (see §5).

---

## 1. Path

**`docs/FEATURE_MAP.md`**, not `docs/catcher/FEATURE_MAP.md`.

- `docs/` is split by document kind (`plans/`, `qa/`, `knowledge/`), not by component. No `docs/catcher/` exists; creating it for one file adds a second axis.
- A feature map is a repo-level index, a sibling of `docs/product-vision.md` and `docs/proven-better-new.md`. When the surfaces above v0 (notes, Jev, interjection) land, they get rows in the same file under a new section, not a new `docs/<component>/` folder.
- An upper-case root-level name marks it as the source of truth, like `README.md`. `catcher/README.md` stays the build how-to.

## 2. Row inventory

Eleven rows. Each is a surface that at least one of P1–P6 or preflight grades on the Mac. The gate id is the one `grade.py --gate` accepts, or `PREFLIGHT` for `preflight.txt`. Owner paths are relative to `catcher/`, and name the symbol so the row survives line drift.

| # | Surface label | Owner path(s) @ 95837a8 | Prove command | Gate id | Pass evidence the row cites |
|---|---|---|---|---|---|
| 1 | Preflight (signing, TCC, mic device, display, API key/reach/auth/STT) | `harness/preflight.sh`; `Sources/Diagnostics/Preflight.swift`; `Sources/CatcherApp/PreflightHost.swift`; `Sources/CatcherApp/CatcherApp.swift` (`preflight` branch); `Sources/SessionStore/LaunchConfiguration.swift` (`--preflight`) | `./catcher/harness/run.sh preflight <dir>` | `PREFLIGHT` | `<dir>/preflight.txt` ends `PREFLIGHT RESULT PASS` |
| 2 | System-audio capture (ScreenCaptureKit `.audio`, 16 kHz mono PCM16, `excludesCurrentProcessAudio`) | `Sources/AudioCapture/SCKCaptureSession.swift` (`SCKCaptureSession`, `PCMOutput`); `CaptureConfig.swift`; `SampleBufferPCM.swift`; `PCMFrame.swift` | `run.sh p1 <dir>` | `P1` | system-track WER ≤ 15 % vs `harness/fixtures/known-60s.ref.txt`, no > 2 s hole (uses `system.pcm`) |
| 3 | Dual-track capture (mic + system, kept separate end to end) | `Sources/AudioCapture/CaptureConfig.swift` (`captureMicrophone`); `SCKCaptureSession.swift`; `Sources/Pipeline/TrackRouter.swift`; `Sources/Pipeline/Pipeline.swift` (`ingest`) | `run.sh p6 <dir>` | `P6` | ≥ 1 `seg` on `microphone` and ≥ 1 on `system` |
| 4 | Grok STT WebSocket streaming (`wss://api.x.ai/v1/stt`, one socket per track) | `Sources/GrokEngine/GrokEngine.swift` (`connect`, `readUntilCreated`, `pump`); `GrokWebSocket.swift`; `GrokMessages.swift`; `Sources/TranscriptionEngine/EngineFactory.swift` | `run.sh p1 <dir>` and `run.sh p6 <dir>` (`CATCHER_ENGINE=grok`, `XAI_API_KEY`) | `P1`, `P6` | P1 WER line; P6 non-null `speaker` on a system `seg` |
| 5 | Engine swap / JSONL schema (stub engine produces the Grok row shape) | `Sources/TranscriptionEngine/StubEngine.swift`; `Sources/SessionStore/Rows.swift`; `JSONLWriter.swift`; `harness/p5_stub.sh` | `run.sh p5 <stub-dir> <grok-session-dir>` | `P5` | `schema ok; JSONL key shape matches the reference session` |
| 6 | Reconnect: degraded → gap → resumed | `Sources/GrokEngine/GrokEngine.swift` (`reconnect`, `handle(.closed)`); `Reconnect.swift` (`BackoffSchedule`, `GapAccount`, `TimestampRebase`); `Sources/Verifier/Checks/TransportHeartbeatCheck.swift` | root, `CATCHER_ALLOW_PF=1 run.sh p3 <dir>` | `P3` | `ann` kinds `degraded`, `gap`, `resumed` in that order |
| 7 | Post-resume segments (transcript continues after reconnect) | `Sources/GrokEngine/GrokEngine.swift` (post-resume yield, `005264d`); `Sources/Pipeline/Pipeline.swift` (`consumeEvents`) | same P3 run as row 6 | `P3` | ≥ 1 `seg` with `startMs` ≥ `resumed.atMs` |
| 8 | noAudio silence detection (≤ 10 s) | `Sources/Verifier/Checks/AudioFlowCheck.swift` (`observe`, `evaluate`); `Sources/Verifier/Verifier.swift`; `harness/p4_silence.sh` | output muted, `run.sh p4 <dir>` | `P4` | `ann` `kind: noAudio` with `atMs` in `[silence_at, silence_at+10000]` |
| 9 | Crash recovery (`end.recovered`) | `Sources/SessionStore/Recovery.swift` (`scan`); `Assembler.swift` (`write`, `summary`); `Rows.swift` (`EndRow.recovered`); `Sources/CatcherApp/CatcherApp.swift` (launch `Recovery.scan`) | `run.sh p1 <dir>` (`kill -9`, relaunch) | `P1` (`--expect-recovery`) | `session.json` `recovered: true`, or `ann recovered`, or `end.recovered: true` |
| 10 | TCC grant at launch (Screen & System Audio Recording + Microphone for `com.catcher.app`) | `Sources/AudioCapture/PermissionGate.swift`; `MicrophoneAuthority.swift`; `SCKCaptureSession.swift` (`SCKPermissionProbe`); `Sources/CatcherApp/Catcher.entitlements`; `scripts/build-app.sh`; `harness/lib.sh` (`require_stable_signature`, LaunchServices launch) | `run.sh preflight <dir>`, then any gate that records | `PREFLIGHT` (`tcc-screen`, `tcc-mic`) | `PREFLIGHT tcc-screen PASS`, `PREFLIGHT tcc-mic PASS` |
| 11 | TCC revoke mid-session → blocked | `Sources/AudioCapture/CaptureError.swift` (`classify`); `SCKCaptureSession.swift` (`stream(_:didStopWithError:)`, `classify`); `Sources/Pipeline/Pipeline.swift` (`consumeFailures`, `probeLoop`, `halt`); `Sources/Verifier/Checks/PermissionCheck.swift` | `CATCHER_ALLOW_TCC_RESET=1 run.sh p2 <dir>` | `P2` | `ann blocked` within 2 s of revoke on `revoke_session`, no `seg` after it |

Rows 6 and 7 stay separate because the recent fixes (`480d3f0`, `005264d`) touched them independently; a map that merges them hides which half regressed. Rows 10 and 11 stay separate because preflight proves the grant and P2 proves the revoke.

Stage diagnostics (`stages.log`, `trace.py`) do not get a row. They grade nothing (`docs/qa/v0-grading.md`). The map's "How to read a red row" note links to `docs/qa/v0-diagnostics.md` instead.

## 3. Row format and status string

The implement climb writes `docs/FEATURE_MAP.md` with one table, columns in this order:

```
| Surface | Owner | Prove | Gate | Status |
```

- **Surface:** the label from §2, verbatim.
- **Owner:** backticked paths relative to repo root (`catcher/Sources/...`), symbol in parentheses. No line numbers.
- **Prove:** the `run.sh` command, with required env vars inline.
- **Gate:** `P1`–`P6` or `PREFLIGHT`.
- **Status:** exactly

  ```
  GREEN @95837a8 CDHash 62450598 board /tmp/catcher-auto/95837a8-20260923-003139/board.json
  ```

  Grammar: `<GREEN|RED|UNGRADED> @<short-sha> CDHash <cdhash-prefix> board <path>`. `RED` adds ` gate=<id> evidence="<grade.json evidence>"`. `UNGRADED` has no CDHash or board; it is for a new row no Mac run has scored. Every row in the first map is `GREEN` from the one board.

Above the table: a three-line header with the graded commit, CDHash, board path, and the rule "a row is GREEN only when a Mac `grade.json` / `preflight.txt` at that SHA passes its gate; `swift test` never changes a status". Below it: a short "Updating a row" section (re-run the gate on a Mac, copy SHA/CDHash/board, change only that row's Status) and the diagnostics link.

## 4. Conventions to mirror

- Tables and plain prose like `docs/qa/v0-grading.md` (its Gates table is the closest template). Pipe tables, backticked paths, gate ids in bold only in the first column if at all.
- Relative links from `docs/`: `qa/v0-grading.md`, `plans/v0-catcher.md`, `../catcher/harness/README.md`.
- No gate criteria restated beyond the one-phrase pass evidence; `docs/qa/v0-grading.md` stays the definition, and the map links to it.
- The short SHA is 7 characters, as in the board directory name.

## 5. Files the implement climb adds or changes

| File | Change |
|---|---|
| `docs/FEATURE_MAP.md` | **add**: header, 11-row table from §2 in the §3 format, "Updating a row", diagnostics link. |
| `README.md` | one line under "Repo map": `` `docs/FEATURE_MAP.md` — v0 surfaces, owners, prove commands, last Mac grade ``. |
| `docs/qa/v0-grading.md` | one sentence after "What a pass is not": when a Mac run passes, update the Status column in `../FEATURE_MAP.md`. |
| `docs/plans/feature-map-v0.md` | status line → "implemented in `<sha>`". |

Nothing under `catcher/` changes.

## 6. Risks and open questions

1. **Board is not in git.** `/tmp/catcher-auto/...` lives on one Mac and is gone on reboot, so the Status link cannot be opened from the repo. Options: (a) cite the path only, as the parent asks; (b) also commit the board's `grade.json` files under `docs/qa/runs/95837a8/`. Plan default is (a); (b) needs Cap's GO because it adds a new artifact directory and its schema is unreviewed here.
2. **Board schema unknown.** This VM cannot read the board. The implement climb must not invent per-gate evidence strings beyond what `grade.py` prints; if Cap supplies the board, copy its `evidence` values into the Pass column, otherwise use the §2 criteria phrasing.
3. **CDHash is 8 hex chars.** `codesign -dvvv` prints 40. An 8-char prefix is fine for humans but cannot be matched mechanically; confirm the prefix is what Cap wants long-term.
4. **P1 fixture caveat.** `harness/README.md` says the committed `known-60s.wav` is a carrier, not a reading, so P1 WER fails on it. A P1 `pass` on the board means the Mac run used a replaced fixture. The map should say "P1 graded with a locally replaced fixture" unless the fixture is committed first.
5. **Owner drift.** Rows 6, 7, 8, and 11 point at code changed in the last ten commits. Symbol names were checked at `95837a8`; if the implement climb starts from a later tip, re-check them with `rg` before writing.
6. **Status staleness.** Any commit after `95837a8` that touches an owner path makes that row's GREEN a claim about an older binary. The map should say so in the header, not mark rows red automatically (that would be verifier logic).
7. **Branch collision.** `cursor/v0-catcher-impl-4b65` is the active implementation branch. This plan and the map touch only docs, so a textual conflict is limited to `README.md` and `docs/qa/v0-grading.md`; keep those edits to one appended line each.

## 7. Out of scope

- Verifier logic: `catcher/Sources/Verifier/**`, `catcher/harness/grade.py`, `trace.py`, and every `p*.sh`. The map reads their results; it never changes how a gate passes.
- Knowledge essays: `docs/knowledge/**` is not rewritten or re-summarized.
- Changing `docs/plans/v0-catcher.md`, `docs/plans/v0-stage-diagnostics.md`, or the gate definitions in `docs/qa/v0-grading.md`.
- Any automation that writes the Status column from a board.
- Rows for surfaces above v0 (notes, Jev, interjection, context graph).

## 8. Done-check for the implementation climb

- `docs/FEATURE_MAP.md` exists with exactly the 11 rows of §2, in that order, each Status equal to the §3 string.
- Every owner path in the table resolves (`test -e` on each backticked path at the implement tip).
- `README.md` and `docs/qa/v0-grading.md` each gain exactly one line; `git diff --stat` shows no file under `catcher/` or `docs/knowledge/`.
