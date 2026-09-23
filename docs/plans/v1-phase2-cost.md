# v1 Phase 2 — cost meter and cost loop (plan only)

**Status:** plan doc, no code. Cap GO 2026-09-23. Planned from `10db545` on `main` (v0 transcript foundation, hardened GREEN at `b14e31a`). Nothing here is built or graded.

**v1 one-liner:** Granola mechanics, instant, zero friction, cheap enough to leave on.

**Bar this phase owns:**

- **B1: ≤ $0.25 per session-hour, metered over a 60-minute session on a Mac.**

**Cap-calls locked:**

- The meter is a per-session rollup, with per-minute streaming components logged underneath it for the B1 audit.
- The meter does not depend on the UI (Phase 1). This phase builds no UI. It exposes a readout interface that Phase 1 can use later.

**Out of scope:** ambient always-recording, Jev and interjection (v2), live UI, brief generation, the start hotkey and orb, and all Phase 1 and Phase 3 surfaces except the interfaces named in §9. This plan does not touch `docs/briefs/v1-better.md`, which Phase 1 owns.

---

## 0. The headline: v0 as wired fails B1 by construction

v0 opens **one Grok streaming socket per track** (`TrackRouter`, one `GrokEngine` per `AudioTrack`) and streams every captured frame on both tracks for the whole session. xAI lists streaming STT at **$0.20 per hour of audio** ([pricing](https://docs.x.ai/developers/pricing); [07-transcription.md](../knowledge/07-transcription.md)). [v0-catcher.md §6](v0-catcher.md) already flags this: two sockets cost about $0.40/hr.

| | Billed audio-seconds per session-hour | $ per session-hour at $0.20/audio-hr |
|---|---|---|
| v0 today (2 tracks, continuous) | 7,200 | **$0.40** |
| B1 ceiling | 4,500 | $0.25 |

To meet B1, billed audio has to drop by at least 37.5%, assuming xAI bills what the client sends (unverified; see §6.2). This phase has two parts:

1. **Meter it (Step A).** This is behavior-neutral. It makes the $0.40 visible, auditable, and reconciled against the xAI bill. It also runs a *shadow* speech gate that reports what a gated send path would have cost, without changing what is sent.
2. **Close the loop (Step C).** Pick one lever based on the calibration and shadow numbers, build it, and re-prove P1–P6 plus B1 on a Mac.

The meter comes first because the lever choice depends on facts nobody has measured yet: xAI's billing unit, and the speech duty cycle and echo share of real sessions.

## 1. What is metered

Every metered quantity is a **monotonic integer counter**, owned by the component that spends the money. It is sampled once per session-minute and priced from a versioned rate card (§4). The rows store raw units; `usd` is derived from them and the grader re-derives it.

### 1.1 Streaming components (per track, per minute)

| Field | Meaning | Source (Step A hook) | Why it is logged |
|---|---|---|---|
| `wireBytes` | PCM16 bytes the socket's `sendBinary` accepted, counting every send including replays and the tail. Never decremented. | `GrokEngine.pump` success branch and `flushTail`, one new line each | **The billable unit under the audio model.** `bytesSent` is *not* this: `reclaimReplay` decrements `bytesSent` so it stays an audio cursor. |
| `audioMs` | `wireBytes / 32` (16 kHz × 2 B mono = 32 B/ms) | derived | What the rate card prices (`usdPerHour` × `audioMs` / 3,600,000) |
| `replayBytes` | Bytes moved back to `pending` after they were already on the wire | `GrokEngine.reclaimReplay`, one new line | Reconnect double-billing. Bounded by `replayCap` (30 s) per reconnect per track. |
| `tailBytes` | Bytes sent by `flushTail` at stop | `GrokEngine.flushTail` | Explains the last partial minute |
| `socketAttempts` | Transport `connect` calls | `GrokEngine.connect` and the `open(_:)` helper | Handshake churn. Relevant if xAI bills per connection. |
| `socketsOpened` | Sockets that reached `transcript.created` | `GrokEngine.apply(.created)` | Same |
| `socketOpenMs` | Wall ms from `transcript.created` to socket loss or `finish` | `apply(.created)` start, `socketDied` and `finish` end | **The billable unit under the socket-time model** (§6.2) |
| `serverAudioMs` | Per socket, the maximum `start + duration` seen on `transcript.partial` / `transcript.done`, summed across sockets | `GrokEngine.apply(.partial / .done)` | The server's own view of audio received. The grader fails B1 if the client meter is below it (under-metering). |
| `shadowGateMs` | Ms a shadow speech gate would have held open (pre-roll + speech + hangover). Nothing is gated. | `Pipeline.ingest` → `CostMeter.observeFrame` | What the lever in §8 L2 would bill, measured on the same run |
| `bothOpenMs` (microphone row only) | Ms both tracks' shadow gates were open at once | same | The echo share. Speakers bleeding into the mic is what can break the gate lever (§8). |

### 1.2 Components that are zero today, but in the formula

| Component id | Priced by | Owner |
|---|---|---|
| `stt.stream` | `audioMs` (or `socketOpenMs`, per `billingModel`) | This phase. The only non-zero component in v1 Phase 2. |
| `stt.stub` | rate 0 | `StubEngine`. Lets the meter be tested end to end with no API spend. |
| `llm.*`, `tts.*`, `jev.*` | `inputTokens`, `outputTokens`, `requests` | Phase 3 and v2. Registered via the hook in §9.2. None exist in this phase. |

Not metered: local CPU, bandwidth (xAI does not bill it), and disk. Opus encoding cuts bandwidth, not the bill, and is not a cost lever.

## 2. Where the logs live

A new file per session: **`<session-dir>/cost.jsonl`**, next to `events.jsonl` and `stages.log`. It is append-only, one JSON object per line, and fsync'd after each minute's rows and after the rollup.

It is deliberately **not** `events.jsonl`. P5 compares that file's row kinds and keys against a Grok reference, so any new row there is a v0 regression. It is also not `stages.log`, whose line grammar is fixed and QA-parsed. None of the existing readers open `cost.jsonl`: `resolve_session` and `Recovery.scan` look for `events.jsonl`, and `SessionStore.list` skips directories without it. The file contains no transcript text.

### 2.1 Row schema (v1)

```jsonc
{"t":"cost.session","v":1,"sessionId":"…","app":"0.0.1+<sha>","engine":"grok-voice-transcribe-2.0","rateCard":"xai-stt-2026-09-18","billingModel":"uncalibrated","startedAt":"…"}
{"t":"cost.min","m":0,"fromMs":0,"toMs":60000,"track":"system","component":"stt.stream","wireBytes":1920000,"audioMs":60000,"replayBytes":0,"tailBytes":0,"socketAttempts":1,"socketsOpened":1,"socketOpenMs":59588,"serverAudioMs":59700,"shadowGateMs":31200,"usd":0.003333}
{"t":"cost.min","m":0,"fromMs":0,"toMs":60000,"track":"microphone","component":"stt.stream", …,"bothOpenMs":18400,"usd":0.003333}
…
{"t":"cost.rollup","wallMs":3600412,"minutes":61,"clean":true,"recovered":false,
 "units":{"system":{"wireBytes":…,"audioMs":…,"replayBytes":…,"socketOpenMs":…,"serverAudioMs":…,"shadowGateMs":…},"microphone":{…}},
 "usd":0.4001,"usdPerSessionHr":0.4000,"usdIfSocketBilled":0.3998,"shadowUsdPerSessionHr":0.2290}
```

- `t` values are dotted (`cost.*`), so a row written to the wrong file is obvious. They cannot collide with `session`, `seg`, `ann`, or `end`.
- `m` is the session-minute index. `fromMs` and `toMs` are session-clock ms (`Pipeline.nowMs`, origin at `start()`), the same clock as `events.jsonl` `atMs`. The last minute is partial (`toMs` = close time).
- Each minute has one row per (track, component). A 60-minute session with only `stt.stream` has about 122 minute rows, around 40 KB.
- Minute rows are **deltas**, and the rollup is the **sum of deltas**. Units are integers, so the sum is exact.

### 2.2 Durability and crash path

- The minute rows are written by a `meterTask` in `Pipeline`, next to `checkpointTask`. The write runs off-actor on a detached utility task, the same pattern `persist` uses. That is 2 fsyncs a minute, and none of them are on the frame path.
- At close, `closeSession` writes the final partial minute and then `cost.rollup`, **before** `store.end`, so `end` stays the last write of a session. `failClosed` goes through `closeSession`, so it gets the same rows.
- After a `kill -9`, the file has minute rows and no rollup. `CostLog.recoverAll(root:)`, called from `CatcherApp` launch right after `Recovery.scan`, finds every `cost.jsonl` without a rollup. It drops a truncated last line and writes a rollup from the surviving minute rows, with `clean:false, recovered:true` and `wallMs` set to the last `toMs`. At most one minute per track is lost. **A recovered rollup never passes B1** (§6).
- `Recovery.swift` is not edited. That keeps the P1 `--expect-recovery` owner path untouched.

## 3. Session rollup formula

For a session with rate card \(R\), billing model \(b\), and components \(c\) over tracks \(k\):

\[
\text{usd} = \sum_{c}\sum_{k} U_{c,k}^{(b)} \cdot r_c
\qquad
\text{usdPerSessionHr} = \frac{\text{usd}}{\text{wallMs} / 3{,}600{,}000}
\]

- \(U_{c,k}^{(b)}\) is the billable-unit total, which is the sum of that component's minute deltas. For `stt.stream`: under \(b\) = `audio` it is \(\sum \text{audioMs}\), and under \(b\) = `socket` it is \(\sum \text{socketOpenMs}\). Both are always logged, so either model can be applied after the fact.
- \(r_c\) is the component rate in USD per unit from the rate card. For `stt.stream` that is `usdPerHour / 3,600,000` per ms.
- **The session-hour denominator is session wall time**, `wallMs` = close time on the session clock. It must equal `events.jsonl` `end.atMs` within 1 s. Audio-hours are never the denominator: a 60-minute session costs whatever both tracks billed in those 60 minutes.
- While `billingModel` is `uncalibrated`, the app and grader report \(\max(\text{usd}_{audio}, \text{usd}_{socket})\), the pessimistic figure. The rollup always carries both.
- `shadowUsdPerSessionHr` applies the same formula with \(U = \sum \text{shadowGateMs}\). It is informational and never the B1 number.

## 4. Rate card and constants

Two new versioned files next to `thresholds.json`. That file is v0 verifier constants with its own drift test, and it stays untouched.

**`catcher/harness/rates.json`**: the vendor price card. It changes when xAI changes prices.

```jsonc
{
  "id": "xai-stt-2026-09-18",
  "source": "https://docs.x.ai/developers/pricing",
  "retrieved": "2026-09-23",
  "billingModel": "uncalibrated",          // "audio" | "socket" | "uncalibrated"
  "components": {
    "stt.stream": { "usdPerHour": 0.20, "unit": "audioMs" },
    "stt.stub":   { "usdPerHour": 0.00, "unit": "audioMs" }
  },
  "calibration": { "status": "pending", "evidence": null }   // "reconciled" + evidence path after C1–C5
}
```

**`catcher/harness/metering.json`**: the B1 bar and grading constants. It changes when Cap changes the bar.

```jsonc
{
  "b1UsdPerSessionHr": 0.25,
  "b1MinSessionMs": 3600000,
  "b1MinSystemSpeechDuty": 0.40,
  "serverUnderMeterTolerance": 0.02,
  "reconcileTolerance": 0.05,
  "shadowGate": { "rmsFloor": 0.02, "holdMs": 120, "preRollMs": 300, "hangoverMs": 1000 }
}
```

The app mirrors both in `Metering/RateCard.swift` and `Metering/MeteringConstants.swift`. A `MeteringTests` case parses the JSON and fails on drift, using the same pattern as the thresholds drift test. `hangoverMs` must stay above `endpointing=800`, or the server never sees the trailing silence it needs to emit `speech_final`. The shadow gate's `rmsFloor` is a starting value. The baseline run (§6) calibrates it against the grader's `p1GapRmsFloor` and `speechEvidenceRmsFloor`.

## 5. Step A: module and hook sites (behavior-neutral)

### 5.1 New module

`catcher/Sources/Metering/` is a new SwiftPM target with **no dependencies**, like `Diagnostics`, so every target can import it.

- `CostRows.swift`: `Codable` rows for `cost.session`, `cost.min`, and `cost.rollup`, plus a reader that tolerates a truncated last line.
- `CostLog.swift`: an append and fsync writer for `cost.jsonl`, plus `recoverAll(root:)` (§2.2).
- `CostMeter.swift`: an actor that holds the last sample per (track, component). `sample(atMs:counters:)` returns minute rows. `rollup(wallMs:clean:recovered:)` returns the rollup. `snapshot(atMs:)` is the pull interface in §9.1. `observeFrame(track:pcm16:atMs:)` feeds the shadow gate.
- `ShadowGate.swift`: a per-track RMS gate with hold, pre-roll, and hangover. It accumulates `shadowGateMs` and cross-track `bothOpenMs`. It only computes: it cannot drop, delay, or alter a frame.
- `RateCard.swift`, `MeteringConstants.swift`: the §4 mirrors.
- `MeterCounters.swift`: `MeterCounters` (the §1.1 fields) and the `MeteredEngine` protocol. They live here, not in `TranscriptionEngine`, so the protocol has no engine dependency.

`Package.swift`: add `Metering` and `MeteringTests`. `TranscriptionEngine`, `GrokEngine`, and `Pipeline` gain a `Metering` dependency. `project.yml` adds the target to the app.

### 5.2 Hook sites

| File / symbol | Change | Rule |
|---|---|---|
| `GrokEngine/GrokEngine.swift` | Conform to `MeteredEngine` with `meterCounters() async -> MeterCounters`. Add counter lines at `pump` success (`wireBytes`), `flushTail` (`wireBytes`, `tailBytes`), `reclaimReplay` (`replayBytes`), `connect` / `open(_:)` (`socketAttempts`), `apply(.created)` (`socketsOpened`, open-start), `socketDied` and `finish` (`socketOpenMs`), `apply(.partial/.done)` (`serverAudioMs`). | **Additive lines only.** No edit inside `reconnect(code:reason:announced:prepared:)`. `bytesSent` semantics unchanged. `EngineDiagnosticsSnapshot` and `EngineEvent` unchanged: a new `EngineEvent` case breaks exhaustive switches in `Verifier` and `TrackRouter`. |
| `TranscriptionEngine/StubEngine.swift` | Conform to `MeteredEngine`. `wireBytes += frame.data.count` in `send`, and `socketsOpened = 1` on connect. | Row output unchanged (P5). |
| `Pipeline/Pipeline.swift` `init` | New optional parameters `meterIntervalMs: Int = 60_000` and `costLog: (@Sendable (URL) -> CostLog)?`. | Existing call sites and tests compile unchanged. |
| `Pipeline.start()` after `store.begin` | Write `cost.session`. Start `meterTask`. | Nothing reordered |
| `Pipeline.ingest` | One call, `await meter.observeFrame(...)`, after `verifier.observeFrame`. | The frame reaching `engine.send` is the same value. No new `await` before `verifier.observeFrame`. |
| New `meterTask` (next to `checkpointTask`) | Sleeps to each `meterIntervalMs` boundary on the session clock, gathers `MeterCounters` from `engines[track] as? MeteredEngine`, writes the rows off-actor. | Cancelled in `closeSession` next to `checkpointTask`. The final rows come from `closeSession` itself, not the task. |
| `Pipeline.closeSession` | After the engines have finished (so the tail is counted) and before `store.end`: final minute rows and `cost.rollup`. | `store.end` / `assemble` order unchanged |
| New `Pipeline.cost` (nonisolated `AsyncStream<CostSnapshot>`) plus `costSnapshot()` | §9.1 | **No new `PipelineUIEvent` case.** App views switch on it exhaustively. |
| `CatcherApp/CatcherApp.swift` | One call, `CostLog.recoverAll(root:)`, after `Recovery.scan` | Failure is logged with `ErrorDetail`, never fatal |

### 5.3 Step A tests (Tier L)

- `MeteringTests`: rows round-trip; minute deltas from counter sequences; the rollup equals the sum of the minutes exactly; re-pricing under `audio`, `socket`, and `uncalibrated`; `recoverAll` on a truncated file; `ShadowGate` timing on synthetic frames (hold, pre-roll, hangover, `bothOpenMs`); rates.json and metering.json drift.
- `GrokEngineTests`: a scripted transport with one reconnect. `wireBytes` is monotonic and ≥ `bytesSent`, `replayBytes` > 0, `socketsOpened == 2`, and `socketOpenMs` stops at `socketDied`. Existing tests stay unedited.
- `PipelineTests`: a stub session with `meterIntervalMs = 50` and an injected clock writes a `cost.jsonl` whose minutes are contiguous, one row per track per minute, and whose rollup `wallMs` equals `end.atMs` (±1 s). **The `events.jsonl` row kinds and keys are byte-identical to a pre-meter stub session** (P5 guard). `ingest` passes the frame through unchanged.

## 6. Proving B1 on a Mac over 60 minutes

### 6.1 The B1 run

**`catcher/harness/b1_cost.sh <dir>`**, reachable as `run.sh b1 <dir>` (one new `case` arm, wrapped in the existing `run_gate`):

1. `source lib.sh`, then `begin_harness_run "$SESSION" B1`. `harness_run.json` gets `gate: B1` and the usual provenance.
2. `caffeinate -dimsu` for the whole run. `HostClock` is `mach_absolute_time`, which stops during system sleep, and `holdOffAppNap` allows idle sleep. A sleeping Mac would under-count session-hours.
3. `launch_catcher "$SESSION" 1` with `CATCHER_ENGINE=grok`. **The same binary and default configuration as the P1–P6 verdict.**
4. Profile `meeting` (the B1 bar): loop `fixtures/meeting-60m.wav` with `afplay` through the **built-in speakers** at conversational volume, with the mic open and **no headphones**. This is the honest zero-friction case: speaker bleed puts echo on the mic track. The fixture is a real multi-party conversation with natural pauses. It is not in git if it is large; its SHA-256 goes in `harness_run.json`. The fixture source is a Cap-call (§12).
5. Wait until the session clock passes 3,600 s plus a margin, then send SIGTERM for a clean stop (same as P6), `resolve_session`, then `cost_grade.py --session <uuid-dir> --gate B1`.

Informational profiles, which report numbers but never grade B1:

- `--profile headphones`: output to headphones, so the mic hears only the room.
- `--profile idle`: 60 minutes of muted output in a quiet room. This is the cost of leaving it on through a quiet hour.

### 6.2 Billing calibration (C1–C5)

B1 can only be claimed against the real bill, and xAI's docs say "per hour of audio" without defining whether that means audio sent, speech after the server's VAD gate, or socket time, or whether a multichannel stream bills once or per channel. Each calibration runs on a **dedicated xAI key with no other traffic**, long enough to resolve on the xAI usage console (≥ $0.20 each, which is 1 audio-hour). Nathan holds console access (§12).

| # | Run | Result if billing is audio-sent | What it decides |
|---|---|---|---|
| C1 | 1 socket, 60 min continuous speech PCM | $0.20 | Rate and unit sanity. Meter matches the bill. |
| C2 | 1 socket held open 60 min, 6 min of audio sent | $0.02 | Audio billing vs socket-time billing. If the server closes an idle socket, record the close code and time; that is part of the answer. |
| C3 | 1 socket, 60 min of digital zeros | $0.20 | Whether silence is billed. If not, the server VAD already discounts v0 and a client gate saves less than the shadow number suggests. |
| C4 | 1 socket, `multichannel=true&channels=2`, 60 min | $0.20 if billed once, $0.40 if per channel | Whether §8 L1 is a lever at all |
| C5 | One full `run.sh b1` on the dedicated key | meter `usd` within ±5% of the console | **Reconciliation.** Sets `calibration.status = "reconciled"` in rates.json. |

C1–C4 need a client that the app cannot act as (1 socket, multichannel, zeros). The client is `catcher/harness/stt_calibrate.swift`, compiled by the harness the same way `launch_services.swift` is. It writes its own `cost.jsonl`-shaped minute rows so the meter math is exercised against the bill too. It is harness code, not product code. Results go into `docs/qa/v1-cost-grading.md` (written during implementation) and `rates.json` `calibration.evidence`.

### 6.3 `cost_grade.py` (new; `grade.py` untouched)

It uses only the standard library. It reuses `grade.py`'s provenance check by import, read-only, the same way `trace.py` sits beside `grade.py`. It writes `<uuid-dir>/cost-grade.json` with `{"result", "evidence", "checks"}` and the v0 result vocabulary (`pass` / `fail` / `invalid` / `unproven`). Only `pass` counts.

| Check | Pass when | Else |
|---|---|---|
| `b1.provenance` | `harness_run.json` gate `B1`, a Mac, macOS ≥ 15, CDHash present, header `app` SHA equals `catcherGitSHA` and is not `-dirty` | `unproven` |
| `b1.engine` | `cost.session` and `events.jsonl` engine are Grok | `fail` (a stub cannot prove cost) |
| `b1.calibrated` | `rates.json` `calibration.status == "reconciled"`, `billingModel` is not `uncalibrated`, and the `rateCard` id in the header equals rates.json `id` | `unproven` |
| `b1.clean` | the rollup has `clean:true, recovered:false`, and `events.jsonl` `end.clean` is true | `invalid` (re-run) |
| `b1.duration` | `wallMs ≥ 3,600,000`, and `abs(wallMs − end.atMs) ≤ 1000` | `invalid` if short, `fail` if the clocks disagree |
| `b1.minutes` | `m` is contiguous from 0, every minute has a row for each track, and `toMs(m) == fromMs(m+1)` | `fail` (a meter hole is unaudited spend) |
| `b1.sum` | for every unit, the sum of minute rows equals the rollup, as exact integers | `fail` |
| `b1.reprice` | the grader re-prices the unit totals with `rates.json` and gets the rollup `usd` within 1e-6 | `fail` |
| `b1.wire` | per track, `wireBytes − replayBytes` is within one chunk plus the tail of the `<track>.pcm` byte count while the send gate is off; with a gate, `wireBytes ≤ pcm + replay` | `fail` (the meter is lying about what was sent) |
| `b1.server` | per track, `serverAudioMs ≤ audioMs × (1 + serverUnderMeterTolerance)` | `fail` (under-metering) |
| `b1.premise` | system-track speech duty on `system.pcm` (AC RMS over `speechEvidenceRmsFloor`) ≥ `b1MinSystemSpeechDuty` | `invalid` (a quiet run cannot pass the bar) |
| **`b1.bar`** | `usdPerSessionHr ≤ 0.25` under the calibrated `billingModel` | **`fail`** |

The evidence line always prints `usdPerSessionHr`, `usdIfSocketBilled`, `shadowUsdPerSessionHr`, per-track `audioMs`, `replayBytes`, `bothOpenMs`, and the speech duty, pass or fail. The baseline run is useful even when it is red.

## 7. Audit trail

The chain for "B1 GREEN at `<sha>`" is: the Mac `cost-grade.json` `pass` → `cost.jsonl` minute rows → `rates.json` card id and reconciled calibration evidence → the `harness_run.json` provenance. The evidence tiers mirror [v0-grading.md](../qa/v0-grading.md#evidence-tiers):

| Tier | What | Counts for |
|---|---|---|
| **B-M** | `cost-grade.json` `result: pass` for gate B1 from a Mac `run.sh b1` at a SHA whose rate card is `reconciled` | The only B1 claim |
| **B-C** | C1–C5 console readings plus the `stt_calibrate` rows, recorded in `docs/qa/v1-cost-grading.md` | That the meter matches the bill. A prerequisite for B-M. |
| **L** | `swift test` (`MeteringTests`, `PipelineTests`, `GrokEngineTests`) and `harness/tests/test_cost_grade.py` | Regression only. Never cited as B1 evidence. |

Every check is recomputable from the session directory alone, except reconciliation, which reads the console once per rate card. The `cost.min` rows answer "where did the money go, minute by minute, per track", which is what a failing B1 needs. A red row points at the minute (a reconnect storm shows up as `replayBytes`, and echo as `bothOpenMs`).

## 8. Closing the loop: levers to get under $0.25

Step C is a **separate implementation climb**, started only after Step A is merged, the C1–C5 calibration is recorded, and one baseline `meeting` B1 run exists (expected `fail` at about $0.40). Cap picks the lever from those numbers.

### L2 (primary candidate): client speech gate per track

Send a track's audio only while its gate is open (pre-roll + speech + hangover). The shadow gate from Step A is this gate, so `shadowUsdPerSessionHr` from the baseline run is a direct prediction of L2's B1 number on the same audio.

Worked example with illustrative assumptions, to be replaced by the baseline run's measured numbers: 60-minute meeting, 50% system speech, 30% own speech, 8 utterance bursts per minute per track, and 1.3 s pre-roll plus hangover per burst.

| Case | System billed s | Mic billed s | $/session-hr |
|---|---|---|---|
| Headphones | 1,800 + 624 = 2,424 | 1,080 + 624 = 1,704 | **$0.23** (pass, about 8% under) |
| Speakers (mic hears the system audio, about 80% mic duty) | 2,424 | ~3,900 | **$0.35** (fail) |

The echo share (`bothOpenMs`) decides whether L2 passes alone. If the speakers profile fails in the shadow numbers, L2 needs an echo-aware mic gate: open the mic gate only when the mic level clearly exceeds the level predicted from concurrent system audio. Real AEC (VoiceProcessingIO) is a larger capture change and is not proposed here.

Implementation shape: a `SpeechGateEngine` wrapper (`TranscriptionEngine/SpeechGateEngine.swift`, reusing `Metering/ShadowGate.swift` for the gate decision) conforming to `TranscriptionEngine`, placed by `EngineFactory` around `GrokEngine`. `GrokEngine` is not modified. The wrapper drops closed-gate frames and keeps a monotone `SkipMap` from sent-audio ms to session ms. It injects `GrokEngineConfiguration.nowMs` so that all of `GrokEngine`'s internal times, including the post-reconnect `socketOriginMs = max(audioMs, currentMs())`, are in sent-audio ms. It then maps every outgoing `TranscriptEvent` time and `.gap(fromMs:toMs:)` back to session ms. The `Verifier` still sees every frame, because `ingest` calls `observeFrame` before `send`. So P4 `noAudio` and the P1 RMS evidence are unaffected by construction.

What it must re-prove: **P1** (no > 2 s hole in system speech, WER), **P3** (gap, resume, and the live tail once the replay buffer holds only gated audio), **P5** (identical row shape), **P6** (mic segments survive the gate at conversational volume), and **B1**.

### L1 (conditional): one multichannel socket for both tracks

This applies only if C4 shows a 2-channel stream bills once. It gives $0.20/session-hr even with continuous streaming, and less when combined with a union gate. The cost is the most invasive change available. It breaks v0's one-engine-per-track design (`TrackRouter`, per-track reconnect and gap accounting, per-track `bytesSent` clocks) and puts all of P1, P3, P5, and P6 back in question. Channel-interleaved PCM also cannot be gated per track. Recommend it only if L2 cannot clear the speakers profile.

### Rejected for this phase

- **Batch for one track:** $0.10/hr, but it breaks "instant".
- **Opus:** bandwidth only; it is also unsupported with multichannel.
- **Idle socket close / reopen:** saves only under socket-time billing (C2). It adds handshake latency at speech onset and needs a new non-degraded close state in the verifier, so it touches P3 semantics.
- **Engine switch:** the bake-off in [07-transcription.md](../knowledge/07-transcription.md) is its own track.

**Recommendation:** L2 with an echo-aware mic gate, behind `CATCHER_SEND_GATE=off|shadow|on`. Step A ships `shadow` as the only mode. Step C makes `on` the default. P1–P6 and B1 are graded at that default in the same Mac session set, so a single binary and configuration carries both claims.

## 9. Interfaces to Phase 1 and Phase 3 (named, not built)

### 9.1 Phase 1: cost readout (UI is not built here)

```swift
public struct CostSnapshot: Sendable, Equatable {
    public var sessionMs: Int
    public var usd: Double
    public var usdPerSessionHr: Double
    public var perTrack: [String: TrackCost]      // "system" / "microphone" → audioMs, usd
    public var rateCardID: String
    public var billingModel: String               // "audio" | "socket" | "uncalibrated"
    public var calibrated: Bool
}
// Pipeline
public nonisolated let cost: AsyncStream<CostSnapshot>   // push: each meter minute and at close
public func costSnapshot() async -> CostSnapshot?        // pull: live from counters, any cadence
```

The contract for Phase 1: the readout must show `uncalibrated` when `calibrated == false`, and must never present the pessimistic number as the bill. That is the same loud-not-silent rule as the verifier. A per-second UI tick uses the pull API. The push stream stays per-minute, so the audit rows and the readout come from the same samples.

### 9.2 Phase 3 and later: metered-component hook

```swift
// Metering
public enum MeterUnit: String, Sendable { case audioMs, inputTokens, outputTokens, requests }
extension CostMeter {
    public func record(component: String, track: String?, unit: MeterUnit, amount: Int)
}
```

- A new spend surface picks a namespaced component id (`llm.notes`, `jev.judge`, …), adds a `rates.json` entry, and calls `record` where the money is spent. It gets per-minute rows and rollup inclusion without further work.
- A component without a rate-card entry is written with `usd: null`, and `cost_grade.py` fails B1 with `unpriced component <id>`. Unpriced spend cannot be averaged in silently.
- **Budget:** B1 is total spend. Proposed split, a Cap-call: STT ≤ $0.20/session-hr, leaving ≥ $0.05 for Phase 3 components on the same bar.

## 10. Risks

- **Billing unit unknown.** Audio sent, speech after VAD, or socket time, and per channel or not. This changes both the formula and the lever. Mitigation: C1–C4 before any lever work, both units always logged, and a pessimistic max while uncalibrated.
- **Console granularity.** The xAI usage view may aggregate by day or round to cents. Mitigation: 1-hour calibrations (≥ $0.20 each), a dedicated key per case if the console splits usage by key, and ±5% tolerance on C5.
- **Echo breaks the gate lever.** The zero-friction case (no headphones) roughly doubles mic duty. It is measured by `bothOpenMs` in Step A before anyone builds L2.
- **The gate hurts transcripts.** Clipped onsets (pre-roll), lost `speech_final` (hangover must exceed `endpointing=800`), timestamp drift (`SkipMap`), and diarization continuity across gated spans (server speaker ids are unverified across skipped audio). Mitigation: full P1/P3/P5/P6 re-grade in Step C, and the shadow gate's hold and floor tuned on the baseline run before `on`.
- **Reconnect double-billing.** Up to 30 s of replay per track per reconnect. Logged as `replayBytes`, and bounded, so it does not threaten B1 unless there is a reconnect storm. A storm is visible per minute.
- **Meter under-counts.** Bytes accepted by `send` on a socket that turns out to be dead are counted (upper bound). The tail is counted at `flushTail`. `b1.server` and `b1.wire` cross-check against independent sources (server cursor, PCM files).
- **Clock.** `mach_absolute_time` pauses in sleep, so the harness uses `caffeinate`. Session time and wall time can still diverge on a real user's Mac, where the readout labels session time. `b1.duration` pins the two clocks together on the grading run.
- **The 60-minute run is fragile.** A crash or network blip is fine for the meter (recovery and reconnect are metered), but a recovered session is `invalid`, so re-run. Budget one re-run.
- **P2 timing.** Meter writes are once a minute and off-actor, never on the frame or `blocked` path. The rollup is written in `closeSession`, which the P2 `halt(clean: false)` already reaches.
- **Rate drift.** An xAI price change needs a new `rates.json` id. A B1 grade names the card it was priced with, and a mismatch is `unproven`.

## 11. Protecting v0 GREEN

- **Not edited:** `events.jsonl` rows and keys, `transcript.txt`, `session.json`, `stages.log` grammar, `grade.py`, `verdict.py`, `trace.py`, `thresholds.json`, `p1`–`p6` scripts, `Recovery.swift`, `GrokEngine.reconnect`, `Reconnect.swift`, and every `Verifier` check.
- **Additive only:** the `GrokEngine` counter lines (§5.2), one `ingest` call, one new task, close-path rows, and one launch call in `CatcherApp`.
- Step A changes owner paths of the P1, P3, P5, and P6 rows (`GrokEngine.swift`, `Pipeline.swift`, `StubEngine.swift`) and the crash-recovery row (`CatcherApp.swift`). Per the FEATURE_MAP rule, those v0 rows do not flip on their own. **Before merging Step A, run preflight and P1–P6 `verdict` on the Mac at the Step A SHA.** GREEN there is what lets the meter merge, and only that run updates the v0 rows.
- Step C (the lever) changes the send path, so it requires a full re-grade (preflight, P1–P6 verdict, and B1) at one SHA and CDHash.
- The `catcher-ci.yml` jobs pick up `MeteringTests` (`swift test`) and `test_cost_grade.py` (`unittest discover -s catcher/harness/tests`) with no workflow edit.

## 12. Build order and done-checks for implementation

| Step | Work | Done when |
|---|---|---|
| **A: meter** | §5 (Metering module, engine counters, `meterTask`, shadow gate, `cost.jsonl`, `recoverAll`, `rates.json`, `metering.json`, Readout API §9.1, hook API §9.2), plus the §5.3 tests. One commit each for the module, the engine counters, the pipeline, and the app launch, so a v0 regression is local to one commit. | `swift test` is green on `macos-15` CI. A stub session writes a valid `cost.jsonl`. The P5 shape guard passes. The Mac preflight and P1–P6 verdict are GREEN at the Step A SHA. |
| **B: measure** | `b1_cost.sh`, the `run.sh b1` arm, `cost_grade.py`, `test_cost_grade.py` (synthetic pass, bar fail, short `invalid`, low-duty `invalid`, uncalibrated `unproven`, sum mismatch `fail`, unpriced component `fail`), `stt_calibrate.swift`, `docs/qa/v1-cost-grading.md`. Run C1–C5 and one `meeting` baseline, plus `headphones` and `idle`. | rates.json is `reconciled` with evidence. The baseline `cost-grade.json` exists (expected `fail` with about $0.40 in the evidence) and reports `shadowUsdPerSessionHr` and `bothOpenMs`. FEATURE_MAP rows for the meter surfaces move from `PLANNED` to their graded status. |
| **C: lever** | Cap picks from §8 using the step B numbers. That lever is built behind `CATCHER_SEND_GATE`, with `on` as the default. | At one SHA and CDHash on the Mac: preflight, P1–P6 `verdict` GREEN, **and** `cost-grade.json` B1 `pass` on the `meeting` profile. |

### Cap-calls still open

1. **The B1 profile:** speakers with no headphones (proposed) or headphones. Also the source and licence of `meeting-60m.wav`, and whether a scripted "me" speaker is added.
2. **The lever,** after step B (L2 with an echo-aware mic gate proposed; L1 only if C4 bills once and L2 misses).
3. **The budget split** between STT and Phase 3 components on the $0.25 bar ($0.20 / $0.05 proposed).
4. **Calibration owner:** a dedicated xAI key and console access for C1–C5 (Nathan).
5. **Whether an uncalibrated B1 can ever be claimed.** Proposed: no. `b1.calibrated` makes it `unproven`.

Rows: [FEATURE_MAP.md](../FEATURE_MAP.md#v1-phase-2--cost-metering-planned). v0 gates: [qa/v0-grading.md](../qa/v0-grading.md). v0 slice: [v0-catcher.md](v0-catcher.md).
