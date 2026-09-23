# v0 staged failure diagnostics — plan (plan only)

**Status:** plan doc, no code. Planning climb ran on claude-opus-5-5. The implementation climb runs on grok-4.7 with `fast=false`.

**Goal:** A failed or empty take must never look like an empty `transcript.txt` with no explanation. Each pipeline stage writes one checkpoint line. The first failing stage names its underlying error and a probable fix. QA runs a preflight before P1.

**This work adds diagnostics only.** P1–P6 pass/fail semantics, `grade.py` gate logic, the `events.jsonl` row set and keys (P5 compares shapes), `transcript.txt`, and `session.json` stay byte-for-byte as they are. No new `ann` kinds. Diagnostics go to separate files and log channels.

---

## 1. Line formats (stable, QA-parsed)

```
STAGE <name> <OK|FAIL> [k=v ...]
TRACE last-ok=<name|none> first-fail=<name> error="<underlying>"
TRACE cause="<probable cause>" fix="<known fix>"
PREFLIGHT <check> <PASS|FAIL> [k=v ...]
PREFLIGHT RESULT <PASS|FAIL> failed=<n>
```

The grammar is fixed. The first token is `STAGE`, `TRACE`, or `PREFLIGHT`. The second token is a name from the fixed set below. The third token is one of the two verdicts. After that come space-separated `k=v` pairs. A value containing spaces is double-quoted, `"` inside it becomes `\"`, and a newline becomes `\n`. The whole line is capped at 1 KB, and a truncated error body ends in `…(+N bytes)`. Each line has no prefix, so `grep '^STAGE '` and `awk '{print $2,$3}'` work on it. When a line is also sent to `os_log`, the log header (timestamp and pid) is added only there; the file copy carries none of it.

Stage names are fixed, and so is their order:

| # | name | OK means | detail keys |
|---|---|---|---|
| 1 | `tcc-check` | launch probe `.granted` | `screen=`, `mic=` (authorizationStatus), `owns=`, `entitlement=`, `responsible=`; on FAIL `error=` block reason |
| 2 | `capture-start` | `SCStream.startCapture` returned | `display=`; on FAIL `domain=` `code=` `error=` (NSError, not flattened) |
| 3 | `frames-received` | ≥1 `CMSampleBuffer` on **each** track | `system=<n> microphone=<n> invalid=<n> empty=<n>` |
| 4 | `pcm-extract` | ≥1 `PCMFrame` extracted on each track | `system=<n> microphone=<n> failed=<n> osstatus=<first non-zero> zeroEnergy=<track,…>` |
| 5 | `api-connect` | `transcript.created` received on every track's socket | `track=` `engine=` `ms=`; on FAIL `http=` `close=` `error=` `body=` |
| 6 | `api-stream` | >0 bytes sent on each track | `system=<bytes> microphone=<bytes> pending=<bytes> sendErrors=<n>` |
| 7 | `segments-received` | ≥1 stored final on any track | `system=<n> microphone=<n> partials=<n> blankDropped=<n> restated=<n> apiErrors=<n>` |
| 8 | `transcript-write` | `transcript.txt` assembled and non-empty | `bytes=` `segments=` `recovered=`; on FAIL `error=` |

When each line is written:
- Stages 1, 2, and 5 are written the moment they resolve.
- The count stages (3, 4, 6, 7) are written once at a **10 s checkpoint** after `capture-start`, the same window the `noAudio` check uses, and again at session close. P1 `kill -9`s the app, so the checkpoint line may be the only one that lands.
- Stage 8 is written at close, or by `Recovery.scan` on the relaunch.
- The **last** line for a stage is its verdict. The trace uses the first FAIL in file order.
- A FAIL at a gating stage (1, 2, or 5) means the later stages are never written. The trace treats a stage that was never written as `not-reached`.

`zeroEnergy` is informational and keeps `pcm-extract` at OK, because P4 is a legitimate silence run. The cause table (§3) uses it when `segments-received` fails.

### Sample (goes into `docs/qa/v0-diagnostics.md` on implement)

```
STAGE tcc-check OK screen=granted mic=authorized owns=true entitlement=true responsible=Catcher
STAGE capture-start OK display=1
STAGE api-connect OK track=system engine=grok ms=412
STAGE api-connect OK track=microphone engine=grok ms=398
STAGE frames-received OK system=1002 microphone=1000 invalid=0 empty=0
STAGE pcm-extract OK system=1002 microphone=1000 failed=0 osstatus=0 zeroEnergy=system
STAGE api-stream OK system=320000 microphone=320000 pending=0 sendErrors=0
STAGE segments-received FAIL system=0 microphone=3 partials=4 blankDropped=21 restated=0 apiErrors=0
STAGE transcript-write OK bytes=88 segments=3 recovered=false
TRACE last-ok=api-stream first-fail=segments-received error="system: 0 finals from 320000 bytes; every system PCM frame is zero"
TRACE cause="system track captured digital silence" fix="nothing was playing on the captured display, or the mixdown cancelled; check system.pcm peak/RMS and the chosen display"
```

## 2. Where the checkpoints live

The file sink is `<session-dir>/stages.log`, opened in append mode and fsync'd on every FAIL line and every checkpoint. Launch-level lines, written before any session directory exists (the launch probe and preflight), go to `<CATCHER_SESSION_ROOT>/launch-stages.log`. Every line is mirrored to `os_log` with subsystem `com.catcher.app` and category `stage`, and to stderr. The harness launches through `open`, which detaches stdout and stderr, so **the file is the source of truth**. None of the existing readers look at `stages.log`: `resolve_session` looks for `events.jsonl`, `Recovery.scan` reads only `events.jsonl`, and `SessionStore.list` skips directories without that file.

### New module

`catcher/Sources/Diagnostics/` is a new SwiftPM target with no dependencies, so every other target can import it.

- `Stage.swift`: the `Stage` enum (the 8 names in order), `Verdict`, and `StageLine` with a formatter and a parser. The parser round-trips through tests.
- `StageSink.swift`: the `StageSink` protocol, `FileStageSink` (append + fsync + os_log + stderr), and `RecordingStageSink` for tests.
- `StageLedger.swift`: an actor that holds per-track counters and produces the checkpoint and close lines, so hooks only bump counters.
- `FailureTrace.swift`: takes `[StageLine]` and returns the last OK, the first FAIL (or `not-reached`), and the underlying error, then matches against the cause table.
- `CauseTable.swift`: an ordered list of `(stage, predicate on detail) → (cause, fix)`, see §3.
- `ErrorDetail.swift`: `describe(_ error: Error) -> [String: String]`. It returns `domain`, `code`, `osstatus` (with FourCC when printable), `underlying` (walks `NSUnderlyingErrorKey`), and `localizedDescription`. Every catch site uses this, so no call site hand-formats an error.
- `Preflight.swift`: the checks listed in §4. The ScreenCaptureKit and AVFoundation parts sit behind `#if canImport(ScreenCaptureKit)`, and the file calls into `AudioCapture` through a closure it is given, so the Diagnostics module stays dependency-free.

`Package.swift` changes: add the `Diagnostics` target and a `DiagnosticsTests` test target. `AudioCapture`, `GrokEngine`, `Pipeline`, and `SessionStore` each gain a `Diagnostics` dependency. `project.yml` adds the target to the app.

### Hook sites (file → stage)

The Pipeline is the observer, so most hooks go there. The capture and engine code only expose counters and error details, and keep their control flow as it is.

| File / symbol | Stage | Change |
|---|---|---|
| `Pipeline/Pipeline.swift` `init` | — | New optional parameter `stages: (URL?) -> any StageSink`, defaulting to a `FileStageSink` factory. Existing call sites and tests compile unchanged. |
| `Pipeline.start()` after `launchProbe()` | tcc-check | One line from `PermissionState`, plus `PermissionGate.readMicrophoneAuthority()` for the detail keys. |
| `Pipeline.start()` `capture.start()` catch | capture-start | Log `ErrorDetail.describe(error)` **before** the error is flattened into `CaptureError.unavailable(String)`. The flattening itself stays. |
| `Pipeline.start()` after `engine.connect` / catch | api-connect | OK per track. FAIL detail comes from `EngineDiagnostics.snapshot()` (see the GrokEngine rows below). |
| `Pipeline.start()` store-create catch, `failClosed` | trace | `failClosed` also emits the trace block. |
| `Pipeline.ingest` | pcm-extract counters | `ledger.frameExtracted(track, energy:)`. The energy check is one pass that looks for any non-zero Int16. |
| `Pipeline.ingest` `engine.send` catch | api-stream | `sendErrors += 1`; the first error is kept with its code. |
| `Pipeline.consumeEvents` | segments-received | Count finals stored, partials, blank or restated finals (`storeFinal` returned false), and `.error` events. The first API error text is kept verbatim. |
| New `checkpointTask` next to `tickTask` | 3, 4, 6, 7 | A single sleep of 10 s, then write the count stages. |
| `Pipeline.closeSession` | 3, 4, 6, 7, 8 + trace | Replace the two `try?` calls on `store.end` / `store.assemble` with `do/catch` that logs a `transcript-write FAIL error=…`. The control flow stays the same (close continues). Read `transcript.txt` size for `bytes=`. Emit the trace when any stage FAILed or `segments=0`. |
| `AudioCapture/SCKCaptureSession.swift` `PCMOutput.stream(_:didOutputSampleBuffer:of:)` | frames-received | Lock-free per-track counters for raw buffers, invalid buffers, and zero-sample buffers, incremented **before** the existing `guard`s. |
| `SCKCaptureSession` (new method only) | frames-received, pcm-extract | Conform to a new `CaptureDiagnostics` protocol with `func counters() -> CaptureCounters` (raw, invalid, empty, extractFailed, firstOSStatus, firstFailureDetail). This is a separate protocol, so `AudioCapturing` and every test fake stay untouched. The Pipeline casts with `as? CaptureDiagnostics`. |
| `SCKCaptureSession.emitFailure` | pcm-extract | Keep the report-once `failures` behaviour. Count **every** extraction failure in the counters, not only the first. |
| `PCMOutput` catch of `SampleBufferPCM.Failure` / generic | pcm-extract | Keep the real error in the detail instead of the `status: -1`, so the trace shows `unsupportedFormat("mBytesPerFrame 8 != 4")`. |
| `AudioCapture/SampleBufferPCM.swift` `pcmFromContiguousBlock` | pcm-extract | `try? convertToPCM16Mono` and the ignored `CMBlockBufferGetDataPointer` status get recorded: the first status and failure are stored in a static last-fallback-error slot that the counters read. The return value is unchanged. |
| `GrokEngine/GrokWebSocket.swift` `receive()` catch | api-connect | Add `http=<(task.response as? HTTPURLResponse)?.statusCode>` and the `NSError` domain and code to the `.closed` reason string. `URLSessionWebSocketTask` does not expose the upgrade response body, so the body comes from the HTTPS probe below. |
| `GrokEngine/GrokEngine.swift` (additive only) | api-connect, api-stream | Conform to a new `EngineDiagnostics` protocol in `TranscriptionEngine` with `func snapshot() async -> EngineDiagnosticsSnapshot` (bytesSent, pending.count, handshakeMs, lastClose code and reason, lastError, unknownMessages). Record the handshake time in `apply(.created)`. Record `handshakeFailure` detail in `handle(.closed)` **before** the reconnect branch. `reconnect()` stays untouched. `EngineEvent` stays untouched: an added enum case would break exhaustive switches in Verifier and TrackRouter. |
| `GrokEngine.connect` handshake-failure path | api-connect | On a `closed` or `handshakeTimeout` before `transcript.created`, run one `GrokProbe.fetchAuthStatus` (HTTPS GET with the same bearer, 3 s timeout) and attach `http=` and `body=` (truncated) to the snapshot. This recovers the 401 or 403 JSON body that the WebSocket upgrade hides. The call runs only on failure, never on the happy path. |
| `GrokEngine/GrokMessages.swift` `decode` | segments-received | `try? decode` → `.unknown(text)` is where an API error sent under an unexpected shape disappears. The first 3 raw unknown or undecodable messages are kept, truncated, in the snapshot. An `error` frame's `message` is kept verbatim, and `error`/`code` fields are decoded when present. The `GrokServerMessage` cases do not change. |
| `SessionStore/Recovery.swift` | transcript-write | After `Assembler.write`, append `STAGE transcript-write … recovered=true` to that session's `stages.log`. A failure throws exactly as it does now, and is logged first. |
| `CatcherApp/CatcherApp.swift` | preflight + audit | Handle `--preflight` (§4). Log the `try?` pid write, the `Recovery.scan` failure, and the `SessionStore.list` failure with `ErrorDetail`. Without the pid line, the harness only prints "did not write catcher.pid". |
| `SessionStore/LaunchConfiguration.swift` | preflight | Add `preflight: Bool` from `--preflight` / `CATCHER_PREFLIGHT=1`, and forward it in `mergedEnvironment`. |

## 3. Failure trace and cause table

`FailureTrace` runs in two places:
- **In the app**, at `closeSession`, `failClosed`, and whenever `segments-received` fails at the checkpoint. It appends the `TRACE` lines to `stages.log` and routes the `cause` through `Loud.defaultLog`. This adds no annotation row and does not change the banner.
- **In the harness**, as the new `catcher/harness/trace.py` (standard library only). It reads `stages.log` from the resolved session and prints the same two `TRACE` lines. It also works on a `kill -9` run where the app never wrote a trace.

The first version of the cause table, first match wins:

| stage FAIL | match on detail | cause | fix |
|---|---|---|---|
| tcc-check | `entitlement=false` | hardened build without audio-input | rebuild with `scripts/build-app.sh` |
| tcc-check | `owns=false` | started from a shell; TCC bills Terminal/Cursor | launch with `open -n "$CATCHER_APP"` |
| tcc-check | `mic=denied` | denied row for com.catcher.app | Privacy → Microphone toggle |
| tcc-check | `mic=notDetermined` | Allow never answered | Request microphone with Catcher frontmost; quit Zoom |
| tcc-check | `screen=denied` | Screen & System Audio Recording missing | grant it to com.catcher.app, relaunch |
| capture-start | `code=-3801` (`SCStreamErrorDomain`) | user declined screen capture | grant Screen & System Audio Recording |
| capture-start | other | SCStream failed to start | copy the `domain`/`code` line into the report |
| frames-received | `system=0 microphone>0` | no system buffers on the chosen display | play audio on the captured display; check the display choice |
| frames-received | `microphone=0` | mic device missing or not delivered | check the default input device (preflight `mic-device`) |
| pcm-extract | `osstatus=-12737` | retained-block-buffer variant used | regression in `SampleBufferPCM.extract` |
| pcm-extract | `failed>0` + `unsupportedFormat` | SCK format changed | the `mBytesPerFrame`/format detail names it |
| api-connect | `detail=missing XAI_API_KEY` | key not forwarded | `export XAI_API_KEY`; `open --env` forwards it via `lib.sh` |
| api-connect | `http=401` / `http=403` | key rejected | rotate the key; body shows the xAI reason |
| api-connect | `handshakeTimeout` | socket open but no `transcript.created` | check the `model=` query and xAI status |
| api-connect | NSURLError `-1003` / `-1009` / `-1004` | DNS / offline / refused | network, VPN, or a leftover P3 `pf` rule (`pfctl -sr`) |
| api-stream | `system=0` with `pcm-extract OK` | pump never ran (`ready=false`) | engine state bug; include the snapshot |
| segments-received | `apiErrors>0` | xAI returned errors mid-stream | the first error body is in `error=` |
| segments-received | zero-energy track, bytes>0 | captured digital silence | check the audio source and `system.pcm` peak/RMS |
| segments-received | `blankDropped>0 system=0` | only endpoint spam came back | audio too quiet or not speech |
| transcript-write | `error=` present | assemble/end failed | the error names the path and errno |
| transcript-write | `bytes=0 segments=0` | nothing to write | the trace points upstream; this is a symptom |

Every `TRACE error=` value is the verbatim underlying error: the `NSError` domain and code, the OSStatus, the HTTP status and body, or the xAI `error` message. It is never a summary.

## 4. Preflight command

Every TCC answer has to come from com.catcher.app as its own responsible process, so preflight runs **inside Catcher.app launched through `open`**, never as a shell tool.

- **Entrypoint:** `catcher/harness/preflight.sh [session-root]`, also reachable as `run.sh preflight <dir>`, which adds one `case` arm. It sources `lib.sh`, runs `require_stable_signature` as the `signing` check, and then runs `open -n -W "$CATCHER_APP" --env … --args --preflight --session-root <dir>`. It prints `<dir>/preflight.txt` and exits 0 only when the file ends in `PREFLIGHT RESULT PASS`. `open` does not pass through the app's exit status, so the file is the verdict.
- **App side:** `CatcherModel.init` sees `launch.preflight`. It runs `Preflight.run()`, writes `preflight.txt` (fsync'd), mirrors the lines to `launch-stages.log` and `os_log`, and calls `NSApp.terminate`. It never records, never shows a prompt, and never opens Settings.

| check | how | PASS when |
|---|---|---|
| `signing` (shell) | existing `require_stable_signature` | not ad-hoc, bundle id `com.catcher.app`, and audio-input present if hardened |
| `tcc-screen` | `CGPreflightScreenCaptureAccess()` (no prompt) | true |
| `tcc-mic` | `PermissionGate.readMicrophoneAuthority()` | `authorized`, `owns=true`, `entitlement=true` |
| `mic-device` | `AVCaptureDevice.default(for: .audio)` | non-nil; the detail gives `uniqueID` and name |
| `capture-display` | `SCShareableContent` + `SystemAudioDisplayChoice.preferred` | a display is chosen |
| `capture-probe` | only when both TCC checks pass: start and stop an `SCKCaptureSession` for about 1 s, then read `CaptureDiagnostics.counters()` | start OK; the detail gives the buffer counts per track |
| `api-key` | `XAI_API_KEY` in the merged environment | non-empty (the detail gives the length only, never the key) |
| `api-reach` | TCP + TLS to `api.x.ai:443` via `URLSession` HEAD, 3 s | handshake OK; on FAIL the NSURLError code is in the detail |
| `api-auth` | `GrokProbe.fetchAuthStatus`: HTTPS GET with the bearer. The endpoint (`/v1/api-key`, or `/v1/models` as fallback) is to be confirmed against xAI docs during implementation. | 2xx; on FAIL `http=` + truncated `body=` |
| `api-stt` | open the STT WebSocket, wait for `transcript.created` (5 s), send `audio.done`, close | created received; the detail gives `ms=` or `close=` / `http=` |

When `CATCHER_ENGINE=stub`, the API checks print `PASS skipped=stub`. The runbook gets one new step: *"Run `run.sh preflight /tmp/catcher-pre` before P1. Do not start P1 on a FAIL line; its fix column is the next action."*

## 5. Error-path audit (implementation checklist)

Every item gets `ErrorDetail.describe(error)` in a `STAGE … FAIL` or trace line. Control flow and return values do not change.

- `Pipeline`: store create (102), engine create (120), capture start flattening (129–130), engine connect (143), `send` (292), `storeFinal` (312), annotation write (333), `try? FileHandle` for PCM (346, which is why a missing `system.pcm` looks like zero frames), PCM write catch (350), `try? synchronize/close` (357–358), `try? end/assemble` (367–368).
- `SCKCaptureSession`: `try? addStreamOutput(screen)` (528), startCapture catch (536, log before rethrowing), `try? stopCapture` (553), the `status: -1` placeholders (641, 643), and probe startCapture (205, which already has the domain and code; route it to `tcc-check`).
- `SampleBufferPCM`: `try? convertToPCM16Mono` (276), the discarded `CMBlockBufferGetDataPointer` status, and a non-`noErr` copy status that a recovered fallback hides (191 → 223).
- `GrokWebSocket.receive` catch (87): add the HTTP status and `NSError` code. `@unknown default` → `.text("")` gets logged.
- `GrokEngine`: connect catch (98), readLoop catch (152), `pump` send (324), `flushTail` (348, 354), and `.binary: break` (count it). `reconnect` catch (197) **only once §6 clears**.
- `GrokMessages.decode`: `try?` (60) and `.unknown`.
- `CatcherApp`: pid write (60–62), `Recovery.scan` (75), transcript read (277), session list (343), and the `openApplication` error (already logged; route it to `launch-stages.log`).
- `JSONLWriter` `deinit` `try? close` (31), `Recovery` `try? resourceValues` (28), and `Loud.prepare` ignoring the notification-authorization error.

## 6. Collision with parallel PR #5 work (P2 revoke / P3 reconnect)

Another agent owns the mid-session revoke (P2) and reconnect (P3) fixes on this same branch. **This plan does not edit any of these files or regions:**

- `harness/p2_tcc_revoke.sh`, `harness/p3_net_kill.sh`, and the `grade_p2` / `grade_p3` functions in `grade.py` (and `grade.py` generally, since trace lives in `trace.py`).
- `Pipeline.consumeFailures`, `Pipeline.probeLoop`, `Pipeline.halt`.
- `SCKCaptureSession.stream(_:didStopWithError:)`, `SCKCaptureSession.classify`, `SCKPermissionProbe.recheck`.
- `GrokEngine.reconnect`, `readUntilCreated`, `Reconnect.swift`.
- `Verifier/Checks/PermissionCheck.swift`, `TransportHeartbeatCheck.swift`.

The implementation climb must still watch for these:

1. **Textual conflicts in shared files.** `Pipeline.swift` (the `start`, `ingest`, `consumeEvents`, and `closeSession` hooks sit next to the owned functions), `GrokEngine.swift` (`handle(.closed)` sits just before `reconnect`), and `SCKCaptureSession.swift` (`PCMOutput` and `emitFailure` sit near `classify`). Mitigation: rebase onto the latest branch tip right before implementing. Add hooks as new lines and new methods; do not reflow or reorder existing code. Land capture, engine, and pipeline as separate commits so a conflict stays local.
2. **Semantic drift.** If the P2 fix changes what `classify` returns, or the P3 fix changes the reconnect state machine, the `api-connect` and `segments-received` detail may miss the new failure shapes. The cause table is data, so rows for `tccRevokedMidSession` and repeated reconnects are added after their fix lands, not guessed now. The mid-session revoke and reconnect paths get **no STAGE hook** in the first implementation; they already produce `blocked` / `degraded` / `gap` / `resumed` annotations that P2 and P3 grade.
3. **Gate timing.** P2 requires `blocked` within 2 s. The STAGE file writes are fsync'd on FAIL and at checkpoints only, never per frame, and they run off the frame path (the ledger is an actor; `ingest` only bumps counters). The checkpoint task must not block the actor for long: write the file on a detached utility task.
4. **P5 shape.** Nothing new goes into `events.jsonl`. A `DiagnosticsTests` / `PipelineTests` case asserts that the row kinds and keys of a stub session are unchanged.
5. **Preflight vs. P2 TCC reset.** Preflight never calls `tccutil` and never prompts, so it cannot leave TCC in a state P2 did not expect. Running preflight right after P2 correctly shows `tcc-screen FAIL` until QA re-grants.
6. **`run.sh` edit.** Only a `preflight)` case arm is added, plus an opt-in trace-on-failure. The latter changes `exec "$ROOT/pN…"` into run → capture the status → `trace.py` on non-zero → `exit $status`, preserving the exit code. If the other agent is editing `run.sh`, the trace step moves into a wrapper `harness/run_traced.sh` instead.

## 7. Tests and docs on implement

- `Tests/DiagnosticsTests`: format and parse round trip (quoting, truncation, fixed tokens); `FailureTrace` last-OK / first-FAIL / not-reached cases; cause-table matches for every row; `ErrorDetail` on a nested `NSError` and an OSStatus.
- `Tests/PipelineTests`: a fake capture that throws `NSError(SCStreamErrorDomain, -3801)` → `capture-start FAIL code=-3801` and a trace with `last-ok=tcc-check`; a fake engine that fails connect → `api-connect FAIL` carrying the engine's error text; a happy stub run gives all 8 stages OK in order; an assemble failure gives `transcript-write FAIL error=`; the `events.jsonl` shape is unchanged.
- `Tests/GrokEngineTests`: a fake transport closing with 401 before created → snapshot `lastClose` and `http`; an undecodable server frame lands in `unknownMessages`.
- `docs/qa/v0-diagnostics.md`: the formats in §1, the sample log, the preflight command path (`./catcher/harness/run.sh preflight /tmp/catcher-pre`), the cause table, and the one-liners `grep -E '^(STAGE|TRACE)' <uuid>/stages.log` and `log stream --predicate 'subsystem == "com.catcher.app" AND category == "stage"'`.
- `docs/qa/v0-grading.md`: one new setup step, "run preflight before P1", and a line saying `stages.log` does not grade anything.

## 8. Done-check for the implementation climb

- `swift build` and `swift test` are green on macOS CI. No existing test is edited except for additive `init` parameters.
- A stub session contains `stages.log` with the 8 stages in order and `events.jsonl` with the same shape as before.
- `run.sh preflight` on a Mac prints one `PREFLIGHT` line per check and a `RESULT`.
- A forced `XAI_API_KEY=bad` P1 run ends with `TRACE first-fail=api-connect … http=401` and an xAI body, instead of an empty transcript and nothing else.
