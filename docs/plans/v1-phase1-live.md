# v1 Phase 1 — live loop (plan only)

**Status:** plan doc, no code. Cap GO 2026-09-23 for PLAN. IMPLEMENT starts only on a separate Cap GO.

**Source of truth:** [`../briefs/v1-better.md`](../briefs/v1-better.md). Where this plan and the brief disagree, the brief wins.

**Base:** `main` @ `10db545`. The v0 transcript foundation (hardened GREEN at `b14e31a`, rows in [`../FEATURE_MAP.md`](../FEATURE_MAP.md)) is protected. Phase 1 adds code next to it and changes v0 files only where this plan names the change. It does not delete or rewrite v0 behaviour.

**Bars this phase owns:**

- **B2:** partials ≤ 2 s behind speech.
- **B4:** cold → capturing ≤ 5 s and ≤ 2 clicks. Tap, hotkey, or orb only. Never ambient always-record.

**Cap-calls this phase implements:** start = global hotkey **and** orb click (both).

**Not this phase:** B1 meter (Phase 2), B3 brief (Phase 3), B5 and B6 as phase gates (Phase 4). B6 is still re-run on every Phase 1 merge, because every slice touches the app or the pipeline (section 6.4). Ambient recording, Jev and interjection, memory, iOS and Windows, cost meter implementation, brief generation.

---

## 0. Precedence notes for Cap

Two older docs say things the v1 brief overrides. This plan follows the brief and does not edit those docs:

- `docs/knowledge/granola-baseline.md` calls our Better "ambient, just on". The v1 brief says **never ambient always-record**. Phase 1 starts only on an explicit user input.
- The same doc names a "judgment brief" as the output format. The v1 brief locks **Granola-style shareable summary blocks** and moves judgment to v2.
- `docs/knowledge/09-v0-shipped.md` rule L1 ("one Cloud Agent climb at a time") was a v0 rule. The v1 brief allows parallel tracks on separate branches, with Cap merging serially. L2 (one fix per QA cycle), L3 (fixtures change only on Cap GO), and L4 (VM tests are not Mac gates) still apply.

## 1. Starting point at `10db545` (what the code does today)

Everything below was read from the code. It is the baseline Phase 1 measures before changing anything.

**Start path.** The only start control is the window's `RecordButton` (`catcher/Sources/CatcherApp/Views/RecordButton.swift`). Its keyboard shortcut is `.defaultAction` (Return), and it only works while the window is key. It calls `CatcherModel.toggle()` → `Pipeline.start()`. There is no global hotkey, orb, or menu bar item. `--auto-record` / `CATCHER_AUTO_RECORD=1` starts a recording at launch **without** requiring `--harness`.

**What `Pipeline.start()` does, in order** (`catcher/Sources/Pipeline/Pipeline.swift`):

1. Create the session dir and write the `session` header.
2. `launchProbe()`, which is `PermissionGate.startCaptureProbe()` by default. That call is `SCKPermissionProbe.run()`: it resolves screen capture, runs the microphone prompt gate, then **starts and stops a real `SCKCaptureSession`**. This runs on every start, not only at app launch.
3. Create one engine per track.
4. `capture.start()`: `SCShareableContent.excludingDesktopWindows` → build filter/config → `stream.startCapture()`.
5. `engine.connect(track:)` **sequentially** for system, then microphone. Each call waits for `transcript.created` (5 s handshake timeout).
6. Start consumers (frames, events, failures, tick, probe, checkpoint). Frames captured during step 5 queue in the capture `AsyncStream` and are sent after connect.

At app launch, `CatcherModel.onAppear()` also runs `Recovery.scan` and a full `PermissionGate.startCaptureProbe()`, then applies the result to `status`. That launch probe opens a real stream with `captureMicrophone: true` (`CaptureConfig.make()`), so the screen-recording and microphone indicators flash at every launch. A start pressed during the probe runs a second full probe inside `Pipeline.start()`.

**Partial path.** Grok is opened with `interim_results=true` (`GrokWebSocket.url`). `GrokEngine.commit` yields interim results as `.transcript(kind: .partial)`. In `Pipeline.consumeEvents`, a partial waits on `store.syncedFinalCount`, `verifier.observeEngine`, and `ledger.notePartial` before it is yielded on `ui`. `CatcherModel.apply` keeps one partial per track and calls `rebuildLines()`, which rebuilds and **re-sorts every final** on every event. Partials are never persisted: `grade.py` fails P5 on a `seg` with `final:false` and on any unknown `t=` row in `events.jsonl`.

**Timing that exists today.** No input → capturing stamp. No speech → partial-on-screen stamp. `PCMFrame.hostTime` is `HostClock.now()` taken in `PCMOutput.stream(_:didOutputSampleBuffer:of:)` after extraction and gain, not the sample buffer's presentation timestamp. Word times from Grok are rebased to per-track audio milliseconds (`TimestampRebase`, origin 0 on the first socket).

## 2. Definitions: making B2 and B4 binary

The brief gives the bars. These are the measurement definitions IMPLEMENT builds to. Each **[default]** is what IMPLEMENT uses unless Cap overrides it before slice S0 merges (section 9).

### B2: partials ≤ 2 s behind speech

- **Word lag** = `shownAtMs − capturedAtMs(word.end)`.
  - `capturedAtMs(word.end)` is the session time at which the PCM frame containing the word's last sample reached the pipeline. The word's audio-ms end time maps to a frame through a per-track audio timeline (section 3.2).
  - `shownAtMs` is the session time of the first UI apply (partial **or** final) on the same track whose words include this word. A match is the same normalized text with start times within 300 ms. If no partial ever showed it, the final's apply time is used.
  - Anchor is word **end** [default], because a word cannot be transcribed before it is spoken.
- **Population:** system-track words from the 60 s known fixture (`known-60s.wav`, the locally replaced reading used for P1 per L3). Only words whose audio ended **after** the `live` mark count [default]. Words captured while the orb was still arming are reported as `startBacklog` and do not grade.
- **Pass:** p95 word lag ≤ 2000 ms over ≥ 100 graded words [default], with no reconnect gap in the session. A session with a `gap` ann is `invalid` for B2, because rebased times after a reconnect use a wall-clock origin (`socketOriginMs = max(audioMs, currentMs())`).
- **Always reported:** p50, p95, and max, plus the hop breakdown: capture → sent, sent → received, received → shown.
- **External cross-check (must also hold):** the harness stamps `playWallMs` just before `afplay`. The grader finds the fixture's first speech onset from the WAV (AC RMS ≥ `speechEvidenceRmsFloor`). The first system partial's shown wall time must be ≤ `playWallMs + onset + firstWordDuration + 2000`. This catches a broken internal clock mapping, which the per-word metric cannot see, because it trusts `hostTime`.
- Mic-track lag is reported, not graded: live human speech is not reproducible.

### B4: cold → capturing ≤ 5 s, ≤ 2 clicks

- **Capturing** [default] = the `live` mark. The controller may set it only when **both** tracks have delivered a frame to the pipeline **and** both engines have reported `streaming`. Before that, the orb shows `arming`. This matches the v0 rule "no fake recording": the orb never says live while audio could still be lost to a failed connect.
- **Inputs** = user actions that count toward the 2-click limit: a launch (Dock, Spotlight, or `open`), a hotkey chord, an orb click, or a Record button click. One-time permission onboarding is excluded [default]: B4 is graded with Screen & System Audio Recording and Microphone already granted (`PREFLIGHT RESULT PASS`).
- **Scenarios**, all required:

| Scenario | Precondition | Inputs | t0 | Pass |
|---|---|---|---|---|
| `warm-hotkey` | App resident, idle ≥ 30 s, no window focused | hotkey (1) | harness input wall ms | `live − t0 ≤ 5000` |
| `warm-orb` | same | orb click (1) | harness input wall ms | `live − t0 ≤ 5000` |
| `cold` | App process not running | launch (1) + orb click or hotkey (1) | launch invocation wall ms | `live − t0 ≤ 5000` |

- Each scenario passes 5 of 5 consecutive runs [default]. Any single run over 5 s fails the scenario.
- **Never-ambient checks** (every B4 run): no session directory exists before the recording input; no socket to `api.x.ai` from the app during the idle window (`lsof -i -a -p <pid>`, captured by the harness); exactly one `start` row, and its `source` matches the input the harness sent; nothing started from a launch alone.

## 3. Architecture

```
 Carbon global hotkey ─┐
 Orb click (NSPanel) ──┼──► StartRequest{source, inputHostTime} ──► CaptureController (actor)
 Record button ────────┤                                             │  desired: on/off
 --harness --auto-rec ─┘ (harness only)                              │  phase: idle → arming → live → stopping
                                                                     ▼            (blocked from verifier)
                                                        Pipeline.start(request:) / stop()
                                                                     │
       ┌─────────────────────────────────────────────────────────────┼───────────────────────────┐
       ▼                                                             ▼                           ▼
 LatencyProbe (per-track AudioTimeline:               ui: AsyncStream<PipelineUIEvent>    lifecycle: sessionStarted /
 audio-ms → frame hostTime; marks)                               │                        sessionEnded(dir, clean)
       │                                                         ▼                         (Phase 2/3 subscribe)
       ▼                                             LiveTranscript (incremental)
 latency.jsonl (sidecar, harness mode)                           │  shown stamp ──► LatencyProbe
                                                                 ▼
                                          LiveTranscriptView · OrbView · MenuBarExtra
                                          OrbState = f(controller phase, VerifierStatus)
```

The v0 invariants carry over unchanged. Capture → one engine per track → JSONL. The verifier observes and is never in the data path. `events.jsonl` stays byte-compatible with the v0 schema, and all Phase 1 telemetry goes to a sidecar.

### 3.1 Instant start (B4)

1. **One owner of start and stop.** Every start goes through `CaptureController`: hotkey, orb, Record button, and harness auto-record. The controller holds a desired on/off state, and the last input wins. Presses while `arming` or `stopping` update the desired state, and the controller reconciles once the pipeline call returns. Key auto-repeat and presses < 300 ms apart are ignored. The controller stamps the input time from the event (`NSEvent.timestamp` for clicks, Carbon event time for the hotkey) and passes it as `StartRequest.inputHostTime`.
2. **The no-ambient invariant is enforced in code.** `StartSource` is `{ hotkey, orb, recordButton, harnessAutoRecord }`. `harnessAutoRecord` can only be built when `LaunchConfiguration.harness == true`. `--auto-record` without `--harness` becomes a no-op plus a log line. This is a v0 behaviour change: the harness always passes both flags, so no gate changes. A launch, a login item launch, a wake, or an audio device change never builds a `StartRequest`. A unit test covers every constructor.
3. **Resident app.** A `MenuBarExtra` scene gives status, Start/Stop, Open window, Launch at login, and Quit. `applicationShouldTerminateAfterLastWindowClosed` returns false, so closing the window leaves the hotkey and orb working. Launch at login uses `SMAppService.mainApp` and is **off by default** [default]. Resident idle means no `SCStream`, no socket, and no session dir.
4. **No stream at idle launch.** When grants are already authorized (`CGPreflightScreenCaptureAccess()`, microphone `authorized`, `ownsTCCIdentity`, audio-input entitlement), the resident launch skips the real-stream launch probe. That probe flashes the recording indicators, which at login would look like ambient recording. The full probe still runs when any grant is missing (the first-run prompt flow is unchanged) and in harness mode (the PREFLIGHT and P-gate launch paths are unchanged).
5. **Global hotkey.** Carbon `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring grant. One default chord, ⌃⌥⌘R [default], defined as a constant in one file. A registration failure (`eventHotKeyExistsErr`) is loud on the orb tooltip, the menu bar, and a log line. Rebinding UI is out of scope.
6. **Orb.** A borderless, non-activating `NSPanel` at `.floating` level with `[.canJoinAllSpaces, .fullScreenAuxiliary]`. It is draggable, its position persists in `UserDefaults`, and a click does not take focus from the meeting app. A left click is a `StartRequest(source: .orb)`. A right click opens the same menu as the menu bar item. States (section 3.3).
7. **Start-path latency cuts.** Conditional: only if the measurement shows B4 failing or its margin under 1 s. Each cut is its own QA cycle (L2).
   - (a) **Grant-cached start probe.** When grants are authorized and the process has already started one capture this launch, inject a cheap `launchProbe` (`PermissionGate.recheck()` plus authority readback) in place of the full `SCKPermissionProbe.run()`. The real `capture.start()` stays the proof: a failure still routes to `verifier.observeCapture` → `blocked`, so a revoke between sessions is still loud.
   - (b) **Concurrent capture and connect.** Run `capture.start()` and both `engine.connect` calls in one task group. Any failure tears down all three (capture stop, engines finish) and fails closed as today. Frames still queue in the capture stream until the consumers start.
   - (c) **`SCShareableContent` prewarm** at idle, refreshed on display-change notifications. It is only a content query and opens no stream.

Target budget for `cold` (targets, not measurements; S0 measures the real split): launch → orb clickable ≤ 2.0 s, input → `live` ≤ 2.0 s, margin 1.0 s.

### 3.2 Streaming partials → UI (B2)

1. **Measure every hop.** `LatencyProbe` (Pipeline module, lock-based, `Sendable`) keeps a per-track `AudioTimeline`: cumulative sample count → frame `hostTime`, appended in `Pipeline.ingest`. For each transcript event the pipeline yields, it records `recvAtMs` and each word's `capAtMs`. The engine's per-chunk send time gives the capture → sent hop (read from `EngineDiagnostics`, or a new optional `sentAtMs` hook, with no behaviour change). The app reports `shownAtMs` after it applies the event.
2. **Incremental live transcript.** `LiveTranscript` replaces `rebuildLines()`. It appends finals, replaces the single partial row per track, and inserts by `startMs` without re-sorting the whole list. The view uses `LazyVStack` with a `ScrollViewReader` that stays pinned to the tail unless the user scrolls up. Partials stay grey and finals stay solid with per-track colour (v0 look). This keeps the received → shown hop flat over a 60 min session, not growing with the final count.
3. **Early partial yield** (conditional, only if received → shown p95 > 100 ms in S0). In `consumeEvents`, yield partials to `ui` before the verifier and ledger awaits. Partials never touch the store, so this cannot change `events.jsonl`. It does change the order the verifier sees events in, so it gets its own QA cycle.
4. **Out of our hands.** The sent → received hop (network plus Grok interim cadence) belongs to the engine. The v0 lock stays: 100 ms / 3,200 B chunks and `endpointing=800` (P1). If sent → received alone is over about 1.7 s at p95, B2 fails on the engine, and the hop breakdown shows that. The escalation is to Cap: the `TranscriptionEngine` slot for a second engine exists, but implementing one is not Phase 1.
5. **Optional precision fix.** Add `presentationHostTime` (the sample buffer PTS on the host clock) to `PCMFrame` as a new optional field, so SCK's own delivery delay can be reported. This is an additive `AudioCapture` change that touches P1, P4, and P6. Do it only if the external cross-check and the internal metric disagree by more than 200 ms.

### 3.3 Orb states

`OrbState` is a pure function of the controller phase and `VerifierStatus`. It lives in `StartControl` so it can be unit-tested on Linux.

| OrbState | When | Look | Click |
|---|---|---|---|
| `idle` | not recording, permissions OK | hollow grey | start |
| `arming` | request accepted, `live` not yet set | pulsing grey | desired = off |
| `live` | `live` set, verifier `ok` | solid red | stop |
| `degraded` | live, verifier `degraded` (reconnect or gap) | amber | stop |
| `noAudio` | live, verifier `noAudio` | amber with slash | stop |
| `blocked` | verifier or permission `blocked` | red with "!" | re-grant (same routing as `CatcherModel.regrant()`); never starts |
| `stopping` | stop requested, `end` not yet written | fading red | ignored (desired = off) |

A level ring from live RMS is out of scope for Phase 1: it needs a new `PipelineUIEvent` case.

### 3.4 Telemetry sidecar: `latency.jsonl`

It sits in the session dir next to `events.jsonl` and is written when `CATCHER_HARNESS=1` (same rule as `system.pcm`) [default]. Writes are append-only and buffered. A write failure logs one `StageMirror` note and disables the sidecar for that session. It never fails the session, and the verifier never reads it. `events.jsonl`, `transcript.txt`, and `session.json` do not change.

```jsonc
{"t":"clock","originWallMs":1790000000000,"app":"0.0.1+<sha>"}               // session ms 0 == originWallMs
{"t":"start","source":"hotkey","inputAtMs":-38,"processStartAtMs":-41200}    // negative: before session origin
{"t":"mark","name":"capture-started","atMs":412}
{"t":"mark","name":"first-frame","track":"system","atMs":431}
{"t":"mark","name":"first-frame","track":"microphone","atMs":436}
{"t":"mark","name":"streaming","track":"system","atMs":1180}
{"t":"mark","name":"streaming","track":"microphone","atMs":1205}
{"t":"mark","name":"live","atMs":1206}
{"t":"tx","track":"system","seq":17,"kind":"partial","recvAtMs":5210,"words":[{"w":"hello","s":4300,"e":4610,"capAtMs":4655,"sentAtMs":4702}]}
{"t":"ui","track":"system","seq":17,"shownAtMs":5226}
{"t":"mark","name":"stop-requested","source":"hotkey","atMs":64010}
{"t":"mark","name":"ended","atMs":64420}
```

`stop-requested` and `ended` exist so Phase 3 can measure stop → brief (B3) without a new stamp. Phase 2 reuses the writer (`SessionSidecar`) for `meter.jsonl` (section 7).

## 4. Module and file map

### 4.1 New files

```
catcher/
  Sources/
    StartControl/                        # new SwiftPM target; depends on Pipeline, Verifier, SessionStore; Linux-testable
      StartRequest.swift                 # StartSource {hotkey, orb, recordButton, harnessAutoRecord}; inputHostTime; harness-only constructor
      CaptureController.swift            # actor; desired on/off, last input wins; debounce; the only caller of Pipeline.start/stop
      CaptureRunning.swift               # protocol the controller drives; Pipeline conforms (extension here) so tests use a fake
      ControllerPhase.swift              # idle / arming / live / stopping; live only after both first-frame + both streaming
      OrbState.swift                     # f(phase, VerifierStatus) -> OrbState (table in 3.3)
      SessionLifecycle.swift             # AsyncStream<.sessionStarted(URL) | .sessionEnded(URL, clean: Bool)> for Phase 2/3
    LiveTranscript/                      # new SwiftPM target; depends on TranscriptionEngine; Linux-testable
      LiveTranscript.swift               # incremental finals + one partial per track; ordered by startMs without full resort
    Pipeline/
      LatencyProbe.swift                 # AudioTimeline per track; tx/ui/mark rows; start row from StartRequest
    SessionStore/
      SessionSidecar.swift               # non-gating buffered JSONL writer (latency.jsonl now, meter.jsonl in Phase 2)
    CatcherApp/
      Start/GlobalHotkey.swift           # Carbon RegisterEventHotKey; loud on registration failure
      Start/OrbPanel.swift               # non-activating floating NSPanel; position persistence; harness writes orb_frame.json
      Views/OrbView.swift                # renders OrbState; accessibilityIdentifier "orb"
      Resident/MenuBar.swift             # MenuBarExtra scene: status, Start/Stop, Open window, Launch at login, Quit
      Resident/LoginItem.swift           # SMAppService.mainApp register/unregister; off by default
      Resident/AppDelegate.swift         # applicationShouldTerminateAfterLastWindowClosed -> false
  Tests/
    StartControlTests/                   # desired-state reconcile, debounce, no-ambient constructors, live-honesty, OrbState table
    LiveTranscriptTests/                 # partial replace, final insert order, 10k-final apply cost stays flat
    PipelineTests/LatencyProbeTests.swift  # audio-ms -> hostTime mapping, gap => invalid marker, sidecar failure never fails session
  harness/
    run_v1.sh                            # run_v1.sh b2|b4 <dir> [warm-hotkey|warm-orb|cold]; v1p1-verdict <out> ...
    b2_partials.sh                       # launch --harness --auto-record, stamp playWallMs, afplay fixture, stop, grade B2
    b4_start.sh                          # the three scenarios; idle window with lsof capture; input stamps into harness_run.json
    input_events.swift                   # compiled like launch_services.swift; posts the hotkey chord / a click at orb_frame.json center via CGEvent
    grade_v1.py                          # B2 and B4 graders; imports grade.py for provenance_checks, load_rows, pcm helpers
    verdict_v1.py                        # v1-phase1-verdict.json: B2 + B4 (3 scenarios) + v0-verdict GREEN on one SHA and CDHash
    thresholds_v1.json                   # b2LagP95Ms 2000, b2MinWords 100, b2MatchWindowMs 300, b4LiveWithinMs 5000, b4MaxInputs 2, b4Runs 5, b4IdleMs 30000
    tests/test_grade_v1.py               # synthetic latency.jsonl sessions; Tier L only
docs/
  qa/v1-phase1-grading.md                # QA runbook for B2/B4 (written in S0), same evidence tiers as v0-grading.md
```

`run_v1.sh`, `grade_v1.py`, `verdict_v1.py`, and `thresholds_v1.json` are separate files, so the v0 `run.sh`, `grade.py`, `verdict.py`, and `thresholds.json` stay byte-identical. `grade_v1.py` imports `grade.py`. It does not modify it.

### 4.2 v0 files Phase 1 changes, and the gates each change can move

| File | Change | Slice | Gates to re-grade |
|---|---|---|---|
| `catcher/Package.swift` | add `StartControl`, `LiveTranscript` targets and tests | S0, ST1, LV1 | build only |
| `catcher/project.yml` | app depends on the new products | ST1, LV1 | build only |
| `catcher/Sources/Pipeline/Pipeline.swift` | `start(request:)` overload (plain `start()` forwards with `.recordButton`); `LatencyProbe` hooks in `ingest` / `consumeEvents` / `closeSession`; `lifecycle` stream | S0, ST1 | P1–P6 |
| `catcher/Sources/Pipeline/Pipeline.swift` | concurrent capture + connect (3.1 7b); early partial yield (3.2 3) | ST5b, LV2 (conditional) | P1–P6 |
| `catcher/Sources/SessionStore/SessionPaths.swift` | `latencyFile(in:)` | S0 | none |
| `catcher/Sources/CatcherApp/CatcherApp.swift` | `toggle()` → `CaptureController`; `apply` → `LiveTranscript`; shown stamp; `MenuBarExtra` scene; idle launch without stream probe when authorized and not harness; `--auto-record` requires `--harness` | S0, ST1–ST4, LV1 | PREFLIGHT, P1–P6 |
| `catcher/Sources/CatcherApp/Views/LiveTranscriptView.swift` | render from `LiveTranscript`; tail-pinned scroll | LV1 | P6 (UI only) |
| `catcher/Sources/CatcherApp/Views/RecordButton.swift` | unchanged; its action now goes through the controller | ST1 | — |
| `catcher/Sources/AudioCapture/PCMFrame.swift`, `SCKCaptureSession.swift` | optional `presentationHostTime` | LV3 (conditional) | P1, P4, P6 |

Not touched in Phase 1: `GrokEngine/*`, `Verifier/*`, `SessionStore/Rows.swift`, `JSONLWriter.swift`, `Assembler.swift`, `Recovery.swift`, `Diagnostics/*`, `harness/run.sh`, `grade.py`, `verdict.py`, `thresholds.json`, `harness/fixtures/*`, `spike/`.

## 5. Build order

One component per slice. Every slice closes on a Mac grade at its own SHA (section 6.4) before Cap merges it. Tracks LIVE and START run on separate branches after S0. Cap merges serially, and the second track to merge rebases and re-grades at the merged SHA.

| # | Slice (branch) | Component | Mac close |
|---|---|---|---|
| **S0** | `cursor/v1-p1-measure-*` | `SessionSidecar`, `LatencyProbe`, `start(request:)` overload, shown stamp in the app, `run_v1.sh` / `b2_partials.sh` / `b4_start.sh` / `input_events.swift` / `grade_v1.py` / `thresholds_v1.json`, `docs/qa/v1-phase1-grading.md` | **Baseline, not pass.** B2 numbers on today's UI path. B4 `cold` using the Record button (launch + click = 2 inputs). Both recorded in the QA doc. v0 verdict GREEN at this SHA. |
| **LV1** | `cursor/v1-p1-live-transcript-*` | `LiveTranscript` target + `LiveTranscriptView` on it | B2 pass (or a hop breakdown that names the engine) + v0 GREEN |
| LV2 | conditional | early partial yield in `consumeEvents` | B2 + v0 GREEN |
| LV3 | conditional | `presentationHostTime` on `PCMFrame` | B2 + v0 GREEN |
| **ST1** | `cursor/v1-p1-controller-*` | `StartControl` target; Record button and harness auto-record routed through `CaptureController`; `--auto-record` requires `--harness` | behaviour-preserving: v0 GREEN + B4 `cold` via Record button still measured |
| **ST2** | `cursor/v1-p1-hotkey-*` | `GlobalHotkey` | B4 `warm-hotkey` 5/5 + v0 GREEN |
| **ST3** | `cursor/v1-p1-orb-*` | `OrbPanel` + `OrbView` + `OrbState` | B4 `warm-orb` 5/5 + v0 GREEN |
| **ST4** | `cursor/v1-p1-resident-*` | `MenuBarExtra`, stay-alive, launch at login (off), idle launch without stream probe | B4 `cold` 5/5 + never-ambient checks + PREFLIGHT + v0 GREEN |
| ST5a/b/c | conditional, one per QA cycle | grant-cached start probe / concurrent capture + connect / content prewarm | the failing B4 scenario 5/5 + v0 GREEN |
| **Close** | — | none | `verdict_v1.py` → `v1-phase1-verdict.json` GREEN: B2 + all three B4 scenarios + `v0-verdict.json` GREEN, one `CatcherGitSHA`, one CDHash |

Why this order: S0 comes first so every later slice changes a measured number, and nobody guesses where the time goes (the v0 lesson: the verifier existed before Grok). LV1 is independent of start and may alone satisfy B2. ST1 comes before any new input so the no-ambient invariant exists before the hotkey does. ST4 is last in the track because `cold` needs the orb (ST3) and the resident launch path. The ST5 and LV2/LV3 slices exist only if the numbers ask for them.

## 6. Proving B2 and B4 on a Mac

### 6.1 Evidence tiers (same as v0)

- **Tier M:** `v1-phase1-verdict.json` with `"verdict": "GREEN"`, produced on a Mac by `run_v1.sh v1p1-verdict`. This is the only Phase 1 claim.
- **Tier G:** a `grade.json` from `grade_v1.py` with `result: pass` and provenance checked. It counts for that bar and scenario on that SHA.
- **Tier L:** `swift test`, `harness/tests/test_grade_v1.py`, and `macos-15` CI. Regression only, never cited as B2 or B4 evidence (L4).

Provenance reuses `grade.provenance_checks`: graded on Darwin, `harness_run.json` gate matches (`B2`, `B4-warm-hotkey`, `B4-warm-orb`, `B4-cold`), macOS ≥ 15, header `app` sha == `CatcherGitSHA` and not `unknown` or `-dirty`, session after harness start, non-ad-hoc CDHash. Result vocabulary is the same as v0: `pass`, `fail`, `invalid`, `unproven`, `n/a`.

### 6.2 B2 run (`run_v1.sh b2 <dir>`)

1. `begin_harness_run <dir> B2`, then `launch_catcher <dir> 1` (harness + auto-record, source `harnessAutoRecord`).
2. Wait for the `live` mark in `latency.jsonl`, then idle 2 s.
3. `append_harness_field <dir> playWallMs $(wall_ms)`, then `afplay known-60s.wav`, then idle 3 s.
4. SIGTERM (the existing `HarnessShutdown` path), then grade.

`grade_v1.py --gate B2` checks:

| Check | Pass |
|---|---|
| provenance | as 6.1 |
| `engine=grok` | header engine is Grok |
| `no-gap` | no `gap` ann (otherwise `invalid`) |
| `sidecar-present` | `clock`, `start`, `live` rows exist; every `tx` row on the system track has a matching `ui` row |
| `graded-words` | ≥ 100 system words ended after `live` |
| `lag-p95` | p95 word lag ≤ 2000 ms (evidence: p50, p95, max, hops, `startBacklog`) |
| `first-word-external` | first system partial shown wall ≤ `playWallMs + onset + firstWordDuration + 2000` |
| `captured-for-real` | `system.pcm` non-zero peak and RMS; non-blank system `seg` exists (same evidence rule as P1) |

### 6.3 B4 runs (`run_v1.sh b4 <dir> <scenario>`, ×5 each)

**`warm-*`:**

1. `launch_catcher <dir> 0` (harness, **no** auto-record).
2. Wait for `resident_ready` (the app writes it in harness mode when the orb is clickable and the hotkey is registered).
3. Idle `b4IdleMs` while sampling `lsof -i -a -p <pid>`.
4. Assert there is no `<uuid>/` dir yet.
5. Stamp `inputWallMs` and `input_events` (hotkey chord or a click at the center of `orb_frame.json`).
6. Wait for `live`, `afplay` 10 s of the fixture, stop with the same input, grade.

**`cold`:**

1. Make sure no `CatcherApp` process is running.
2. Stamp `launchWallMs`, then launch through LaunchServices without auto-record (input 1).
3. Wait for `resident_ready`, then stamp and send an orb click (input 2).
4. Continue as in `warm-*` from the `live` wait.

`inputs` (kind + wall ms) are recorded in `harness_run.json` for every scenario.

`grade_v1.py --gate B4 --scenario <s>` checks:

| Check | Pass |
|---|---|
| provenance | as 6.1 |
| `inputs≤2` | `harness_run.json` `inputs` count ≤ `b4MaxInputs`; `warm-*` has exactly 1 before `live` |
| `no-session-before-input` | the session header `startedAt` is after the recording input's wall ms; no other session dir under the root |
| `idle-no-socket` | no `api.x.ai` connection from the app pid in the idle `lsof` samples |
| `single-start` | exactly one `start` row; `source` matches the input kind (`hotkey` / `orb`) |
| `live-honest` | `live.atMs ≥ max(first-frame × 2 tracks, streaming × 2 tracks)` |
| `live-within` | `live` wall − t0 ≤ 5000 ms (t0 per scenario, converted through the `clock` row) |
| `captured-for-real` | non-blank system `seg` after `live`; `system.pcm` non-zero |
| `stopped-by-input` | `stop-requested` source matches the input; `end` row `clean:true` |

`verdict_v1.py` requires 5 consecutive `pass` runs per scenario, one SHA and one CDHash across all runs, and the B2 pass.

**Input driver.** `input_events.swift` posts CGEvents at the HID tap. It needs Accessibility for the host that runs the harness, a one-time setup documented in `v1-phase1-grading.md`. `cua-driver` on the grading Mac may replace it: set `CATCHER_INPUT_DRIVER=cua` and `CATCHER_CUA_CMD`. Either way, the harness stamps wall ms just before sending, so a driver delay counts against B4. That is stricter than a human press.

### 6.4 Every Phase 1 merge re-grades v0 (B6)

Every slice changes the app or the pipeline, so every slice's Mac close includes preflight + P1–P6 + `run.sh verdict` → `v0-verdict.json` GREEN at the slice SHA, using the unchanged v0 harness. A v0 row in `FEATURE_MAP.md` changes status only when that Mac run changes it. A red v0 gate blocks the slice's merge whatever B2 or B4 says.

## 7. Interfaces to Phase 2 and Phase 3 (named, not built)

Phase 1 builds the three hooks in the first two bullets, because it needs them itself. It builds none of the meter, readout, brief, or summary code.

- **`SessionLifecycle` stream** (built in ST1; the app uses it to refresh the session list). `.sessionStarted(dir)` / `.sessionEnded(dir, clean)`. Phase 2's meter rollup and Phase 3's brief generator subscribe to `.sessionEnded`.
- **`SessionSidecar`** (built in S0). Phase 2 adds `meter.jsonl` in the session dir with per-minute streaming component rows sampled from `EngineDiagnosticsSnapshot.bytesSent` per track, plus socket-minutes and reconnect count. It also adds a per-session rollup written at `.sessionEnded`. That covers Cap-call (2): rollup + per-minute components for the B1 audit. Where the rollup lives (`session.json` field vs `meter.json`) is a Phase 2 decision. `session.json` is v0 schema, so a new file is the default.
- **Stop marks** `stop-requested` / `ended` in `latency.jsonl` (built in S0). Phase 3 measures B3 as `brief written − stop-requested ≤ 30 s` from these.
- **Cost readout surface.** Phase 2 adds a readout to the `MenuBarExtra` and the window header. It is not on the orb, whose states stay those in 3.3. Phase 1 reserves no code for it.
- **Brief surface.** Phase 3 writes `brief.md` / `brief.json` (Granola-style shareable summary blocks, copyable, per Cap-call 1) into the session dir. `SessionListView` gains a brief pane. Phase 1 does not change `SessionListView`.
- **Phase 4.** B5 (60 s non-meeting audio WER ≤ 15 % + brief) reuses `wer.py` and the Phase 3 brief. B6 is the v0 verdict that every Phase 1 slice already runs.

## 8. Risks

**Start (B4)**

- **Launch probe flashes the indicators.** Today's launch probe opens a real stream, and `CaptureConfig` includes the mic, so the screen and mic indicators blink at every launch. At login that looks like ambient recording. Mitigation: 3.1 step 4. Risk: skipping it breaks the first-run prompt flow. Mitigation: keep the full probe whenever any grant is not authorized, and in harness mode.
- **Grant-cached start misses a revoke between sessions** (ST5a). Mitigation: the real `capture.start()` is still the proof and fails loud through the verifier. Add a unit test and one manual Mac check (revoke between sessions → `blocked`, no `seg`) to the ST5a close.
- **Concurrent connect changes timing.** P3's grader ignores startup degrades, but teardown on partial failure is new code. Mitigation: its own QA cycle, full P1–P6.
- **Carbon hotkey.** Chord collisions fail registration, and that failure is loud. Secure Event Input (password fields) may suppress hotkeys, to be verified on a Mac. Synthetic CGEvents may reach Carbon hotkeys differently from a physical key: the ST2 close includes one human-pressed run noted in the QA doc.
- **Non-activating panel.** Focus theft over full-screen Zoom or Meet would break "zero friction". Verify on a Mac with a full-screen call window in ST3.
- **SwiftUI lifecycle.** `MenuBarExtra` + `WindowGroup` + stay-alive must not break `HarnessShutdown` (SIGTERM → `stopAfterLiveTail`) or the LaunchServices relaunch path. Covered by v0 GREEN at ST4.
- **Input driver delay** counts against B4 (stricter than a human). If the driver alone costs > 300 ms, record it and report both numbers. Do not subtract it silently.

**Partials (B2)**

- **`hostTime` is arrival, not PTS.** SCK's internal delay is invisible to the per-word metric. Mitigation: the external first-word check, and LV3 if they disagree.
- **Reconnect breaks the audio-ms mapping.** Mitigation: `gap` → `invalid`, not `fail`.
- **"Shown" is a model mutation, not pixels.** It is off by up to one frame (~16 ms). Accepted and noted in the evidence.
- **The engine's interim cadence** is outside our control and is attributed by the hop breakdown (3.2 step 4).
- **Long sessions.** The v0 `rebuildLines()` is O(n log n) per event. LV1 removes it. A 60 min soak (report only in Phase 1) shares the run with Phase 2's B1 60 min meter.

**Process**

- **Parallel tracks both edit `CatcherApp.swift`** (`toggle` / `onAppear` vs `apply` / `rebuildLines`). Mitigation: disjoint regions, and the second merge rebases and re-grades.
- **Sidecar cost or failure.** The sidecar is harness-only, buffered, and non-gating. A failure disables it and never fails the session.
- **The fixture in git is a carrier** ([^1] in FEATURE_MAP). B2 uses the same locally replaced reading as P1. No fixture change without Cap GO (L3).

## 9. Proposed defaults Cap can override before S0 merges

IMPLEMENT proceeds on these unless Cap changes them. Each one is a single constant or a single sentence in `thresholds_v1.json` / `v1-phase1-grading.md`.

1. B2 statistic: p95 over ≥ 100 system fixture words (not every word).
2. B2 anchor: word end.
3. B2 excludes words captured before `live` (reported as `startBacklog`).
4. B4 "cold" = process not running, grants already in place. First-run onboarding excluded.
5. B4 "capturing" = `live` = both tracks framing and both engines streaming.
6. B4 repetitions: 5/5 per scenario.
7. Hotkey chord: ⌃⌥⌘R.
8. Launch at login: off by default.
9. `latency.jsonl` written in harness mode only.

## 10. Done-check for the IMPLEMENT climb

Phase 1 is done when `run_v1.sh v1p1-verdict` on the grading Mac writes `v1-phase1-verdict.json` with `GREEN`. That means: B2 pass; B4 `warm-hotkey`, `warm-orb`, and `cold` each 5/5; and `v0-verdict.json` GREEN, all on one `CatcherGitSHA` and one CDHash. `docs/qa/v1-phase1-grading.md` must let QA reproduce it without the builder present, and the Phase 1 rows in `FEATURE_MAP.md` must carry that SHA, CDHash, and board path. Until then, Phase 1 is not green.
