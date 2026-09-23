# v0 catcher — implementation plan (plan only)

**Status:** plan doc, no code. Product slice APPROVED by Nathan 2026-09-22. Planning climb ran on Fable 5.1; the implementation climb is to run on grok-4.7 with `fast=true` (Nathan's unlock).

**Slice:** Mac app: system audio + mic → transcription → verified transcript on disk. Nothing else. Red v0 blocks everything above it (notes, Jev, interjection, context graph).

Source knowledge: [`../knowledge/08-capture-layer.md`](../knowledge/08-capture-layer.md) (SCK config, wire format, failure table), [`../knowledge/07-transcription.md`](../knowledge/07-transcription.md) (engine pick + bake-off), [`../knowledge/06-strategic-reads.md`](../knowledge/06-strategic-reads.md) (v0 slice, build order). `spike/` is the Jev harness — on HOLD, untouched by this plan.

---

## 1. Architecture (one paragraph)

```
ScreenCaptureKit ──.audio (system) ──┐
                 ──.microphone (mic) ─┤  PCMFrame{track, pcm16 @16k mono, hostTime}
                                      ▼
                          Pipeline (one engine stream per track)
                                      ▼
                TranscriptionEngine (protocol) ── GrokEngine | StubEngine | (AssemblyAIEngine later)
                                      ▼
                          TranscriptEvent{track, partial|final, words[], speaker, confidence}
                                      ▼
                     SessionStore: append-only JSONL → assemble on clean stop
                                      
        Verifier taps every hop above (frames, engine state, events, store) and
        writes annotations into the same JSONL + drives the UI status. It never
        sits *in* the data path, so it cannot itself become a silent-failure point.
```

Locked decisions honored: 16 kHz mono PCM16, `excludesCurrentProcessAudio=true`, 2×2 @ 1 fps video stub, whole-display capture, `endpointing=800`, two tracks preserved end to end, JSONL append-only + annotations, engine swappable without touching capture or verifier.

## 2. Build order and module responsibilities

| # | Module | Owns | Does not own |
|---|---|---|---|
| 1 | **Capture** (`AudioCapture`) | SCK stream lifecycle, complete config object (never partial `updateConfiguration`), PCM extraction via `CMSampleBufferCopyPCMDataIntoAudioBufferList`, `PermissionGate.startCaptureProbe()` at launch, per-track `PCMFrame` fan-out, stream-delegate error surfacing (incl. mid-session TCC revoke) | any transcription, any UI, any disk writes |
| 2 | **Verifier** (`Verifier`) | The five checks (permission, audio-flowing RMS, transport heartbeat, transcript sanity, crash safety), a single `VerifierStatus` (`ok` / `degraded` / `noAudio` / `blocked`), annotation emission, "loud" surfacing contract (banner + system notification + JSONL annotation + log line — all four, always) | capture, engine internals, store format |
| 3 | **Engine** (`TranscriptionEngine` protocol + `GrokEngine` + `StubEngine`) | `send(frame)` → `AsyncStream<TranscriptEvent>`; connection state machine (`connecting → ready → streaming → degraded → closed/failed`); Grok: wait for `transcript.created` before first byte, `~100 ms / 3,200 B` binary frames, `audio.done` on stop, reconnect + exponential backoff, gap reporting via `EngineEvent.gap(from:to:)` | RMS, permissions, disk |
| 4 | **Store + minimal UI** (`SessionStore`, `CatcherApp`) | Store: session dir, `events.jsonl` append with `fsync` per segment, assembler (JSONL → `transcript.txt` + `session.json`), recovery scan on launch. UI: record button, live transcript (per-track colouring), session list, verifier status pill | product features beyond the four views |
| 5 | **P1–P6 harness + QA docs** (`harness/`) | Fixture audio, scripted fault injection, `wer.py`, `grade.py` that reads a session's JSONL and emits `grade.json` with binary P1–P6 results, QA runbook | shipping code |

Build order rationale (from `06-strategic-reads.md`): capture is the hard part and gates everything; the verifier is the *product* of v0 and must exist before Grok so the first live run is already loud on failure; Grok lands behind the interface so P5 (stub) is trivially true by construction; store + UI last because they are proven-copy work; the harness exists so QA — not the builder — grades green.

## 3. File map (proposed)

New top-level dir `catcher/` (product vision names v0 "the catcher"). SwiftPM for everything testable without TCC; a thin Xcode app target on top because an `.app` bundle with `Info.plist` (`NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`) is required for TCC. Project file generated from `project.yml` (xcodegen) so it stays text-diffable.

```
catcher/
  Package.swift                          # library targets + tests; builds on macOS CI
  project.yml                            # xcodegen → CatcherApp.xcodeproj (gitignored)
  README.md                              # build/run, dev TCC gotcha (terminal vs app is the granted binary)

  Sources/
    AudioCapture/
      CaptureConfig.swift                # the one complete SCContentFilter/SCStreamConfiguration factory
      SCKCaptureSession.swift            # start/stop/delegate; whole-display filter; two SCStreamOutput handlers
      PCMFrame.swift                     # {track: .system|.microphone, data: Data(pcm16), hostTime, sampleCount}
      SampleBufferPCM.swift              # CMSampleBufferCopyPCMDataIntoAudioBufferList wrapper (not the -12737 variant)
      PermissionGate.swift               # launch-time startCapture probe → .granted | .blocked(reason)
      CaptureError.swift                 # typed: tccDenied, tccRevokedMidSession, streamStopped(underlying)

    TranscriptionEngine/
      TranscriptionEngine.swift          # protocol: connect(track:) / send(PCMFrame) / finish() / events: AsyncStream<EngineEvent>
      TranscriptEvent.swift              # {track, kind: .partial|.final, text, words:[{w,startMs,endMs,conf}], speaker?, confidence?, seq}
      EngineEvent.swift                  # .transcript(TranscriptEvent) | .state(EngineState) | .gap(fromMs,toMs) | .error(EngineError)
      EngineState.swift                  # connecting, ready, streaming, degraded(reason), closed, failed(reason)
      StubEngine.swift                   # deterministic: emits canned finals per N frames; used by P5 and unit tests
      EngineFactory.swift                # env/flag `CATCHER_ENGINE=grok|stub` → engine; the only place engines are named

    GrokEngine/                          # separate target so AssemblyAIEngine/ can be added as a sibling
      GrokEngine.swift                   # TranscriptionEngine impl
      GrokWebSocket.swift                # URLSessionWebSocketTask; URL builder (model, sample_rate=16000, encoding=pcm, interim_results=true, endpointing=800, language=en)
      GrokMessages.swift                 # Codable for transcript.created / transcript.partial / transcript.done / audio.done
      Reconnect.swift                    # backoff schedule, gap accounting, resume semantics

    Verifier/
      Verifier.swift                     # aggregates checks → VerifierStatus; publishes annotations
      VerifierStatus.swift               # ok / degraded / noAudio / blocked + human string
      Annotation.swift                   # {atMs, kind, detail} — the JSONL "ann" row
      Checks/
        PermissionCheck.swift            # consumes PermissionGate + CaptureError.tccRevokedMidSession
        AudioFlowCheck.swift             # per-track RMS over sliding window; ≈0 for >10 s while recording → noAudio
        TransportHeartbeatCheck.swift    # transcript.created deadline; time-since-last-event; reconnect/gap → degraded
        TranscriptSanityCheck.swift      # final-text length vs session duration (words-per-minute floor) → flag
        CrashSafetyCheck.swift           # asserts fsync'd segment count grows while streaming; launch-time recovery report
      Loud.swift                         # the surfacing contract: banner + UNUserNotification + annotation + os_log

    SessionStore/
      SessionStore.swift                 # create/open session dir, append(row), close
      JSONLWriter.swift                  # append-only, one JSON object per line, fsync after each final segment
      Rows.swift                         # Codable rows: "session" header, "seg", "ann", "end"
      Assembler.swift                    # JSONL → transcript.txt (interleaved by time, [me]/[them] + speaker) + session.json summary
      Recovery.swift                     # on launch: find sessions without "end" row → mark recovered, assemble what exists
      SessionPaths.swift                 # ~/Library/Application Support/Catcher/sessions/<uuid>/

    Pipeline/
      Pipeline.swift                     # Capture → per-track engine → Store; installs Verifier taps; the only orchestrator
      TrackRouter.swift                  # one engine stream per track; guarantees events carry their track id

    CatcherApp/                          # app target (SwiftUI), macOS 15+
      CatcherApp.swift                   # launch: Recovery scan → PermissionGate probe → UI
      Info.plist                         # NSScreenCaptureUsageDescription, NSMicrophoneUsageDescription
      Views/
        RecordButton.swift
        LiveTranscriptView.swift         # partials grey, finals solid, per-track colour, speaker label
        SessionListView.swift
        VerifierStatusView.swift         # pill: OK / DEGRADED / NO AUDIO / BLOCKED (+ re-grant button when blocked)

  Tests/
    AudioCaptureTests/                   # config completeness, PCM extraction from synthetic CMSampleBuffers
    TranscriptionEngineTests/            # StubEngine contract; protocol conformance test shared by every engine
    GrokEngineTests/                     # message decoding, URL builder (endpointing=800 asserted), backoff schedule, gap math
    VerifierTests/                       # RMS→noAudio timing, heartbeat timeout, sanity thresholds — all with synthetic frames
    SessionStoreTests/                   # append/recover/assemble; truncated-last-line recovery

  harness/                               # P1–P6, run on a real Mac by QA
    README.md                            # runbook: prerequisites, grant flow, how to read grade.json
    fixtures/
      known-60s.wav                      # scripted 60 s speech, known reference
      known-60s.ref.txt                  # reference transcript for WER
    run.sh                               # `run.sh p1|p2|p3|p4|p5|p6 <session-dir>` → orchestrates below
    p1_known_audio.sh                    # afplay fixture into system output; then grade.py --wer --gaps
    p2_tcc_revoke.sh                     # tccutil reset ScreenCapture <bundle id> mid-session; timestamps block latency; re-grant instructions
    p3_net_kill.sh                       # pfctl rule blocking api.x.ai for N s mid-session; expects degraded + gap + resume
    p4_silence.sh                        # mute output + no mic input for 16 s; expects noAudio ≤ 10 s after capture start
    p5_stub.sh                           # CATCHER_ENGINE=stub, replays p1; asserts identical JSONL shape
    p6_two_track.sh                      # plays fixture + human speaks; asserts both tracks + speaker labels present
    wer.py                               # normalised WER against .ref.txt
    grade.py                             # reads events.jsonl → grade.json {P1..P6: pass|fail|n/a, evidence}

docs/
  plans/v0-catcher.md                    # this file
  qa/v0-grading.md                       # (written in step 5) how QA runs harness/ and records P1–P6
```

`.github/workflows/catcher-ci.yml` — `macos-15` runner: `swift build` + `swift test` for the library targets. No P-gate runs in CI (see risks).

## 4. Session format (JSONL)

One object per line, append-only, `fsync` after every `seg` with `final:true` and every `ann`.

```jsonc
{"t":"session","id":"…","startedAt":"…","engine":"grok-voice-transcribe-2.0","tracks":["system","microphone"],"app":"0.0.1"}
{"t":"seg","seq":12,"track":"system","startMs":10420,"endMs":13880,"final":true,"text":"…","speaker":"S1","conf":0.93,"words":[{"w":"…","s":10420,"e":10610,"c":0.97}]}
{"t":"ann","atMs":41000,"kind":"degraded","detail":"ws closed (1006); reconnect #1 in 1s"}
{"t":"ann","atMs":47210,"kind":"gap","detail":{"fromMs":41000,"toMs":47210,"track":"system"}}
{"t":"ann","atMs":47210,"kind":"resumed"}
{"t":"end","atMs":60000,"clean":true}
```

Partials are UI-only and never written. Assembly on clean stop produces `transcript.txt` (time-interleaved, prefixed `[me]`/`[them] S1`) and `session.json`. A session dir without an `end` row is a crash; `Recovery` assembles whatever is there and annotates `recovered:true`.

## 5. P1–P6 ownership map

| Gate | Pass condition | Owning files (primary → supporting) | Harness |
|---|---|---|---|
| **P1** Known 60 s system audio → transcript, WER ≤ 15 %, no silent gap > 2 s | `AudioCapture/SCKCaptureSession.swift`, `AudioCapture/SampleBufferPCM.swift` → `GrokEngine/GrokEngine.swift`, `GrokEngine/GrokWebSocket.swift` (endpointing=800) → `SessionStore/JSONLWriter.swift`, `SessionStore/Assembler.swift` | `p1_known_audio.sh`, `wer.py`, `grade.py --gaps` (gap = span with no `seg` on the system track > 2 s while RMS > 0) |
| **P2** Revoke Screen Recording → loud block ≤ 2 s + re-grant path; no fake recording | `AudioCapture/PermissionGate.swift`, `AudioCapture/CaptureError.swift` (`tccRevokedMidSession`) → `Verifier/Checks/PermissionCheck.swift`, `Verifier/Loud.swift` → `CatcherApp/Views/VerifierStatusView.swift` (re-grant button deep-links System Settings) → `CatcherApp/CatcherApp.swift` (launch probe) | `p2_tcc_revoke.sh` (timestamps revoke vs `ann kind:blocked`) |
| **P3** Network kill mid-session → DEGRADED + gap timestamp + resume plus a live seg past backlog; no silent loss | `GrokEngine/Reconnect.swift`, `TranscriptionEngine/EngineEvent.swift` (`.gap`) → `Verifier/Checks/TransportHeartbeatCheck.swift` → `SessionStore/Rows.swift` (`ann gap/degraded/resumed`) → `VerifierStatusView.swift` | `p3_net_kill.sh` (pfctl block api.x.ai 15 s with the fixture looping; asserts per-track `degraded` → `gap` → `resumed` rows tied to the recorded pf window and a live `seg` after `resumed + backlogMs`) |
| **P4** Silence (16 s harness run) → no-audio within 10 s of capture start | `Verifier/Checks/AudioFlowCheck.swift` → `Verifier/Loud.swift` → `AudioCapture/PCMFrame.swift` (frames still flow; content is zero) | `p4_silence.sh` (asserts `ann kind:noAudio` within 10 s of capture start, emitted in time, from live frames, in a quiet room) |
| **P5** Stub engine behind same interface → pipeline unchanged | `TranscriptionEngine/TranscriptionEngine.swift`, `TranscriptionEngine/StubEngine.swift`, `TranscriptionEngine/EngineFactory.swift` → `Pipeline/Pipeline.swift` (must have zero engine-specific branches) | `p5_stub.sh` (`CATCHER_ENGINE=stub`; `grade.py` diffs JSONL *shape* against a Grok run; `Tests/TranscriptionEngineTests` conformance suite passes for both) |
| **P6** System + live mic → both tracks preserved, speaker labels present | `AudioCapture/SCKCaptureSession.swift` (two `SCStreamOutput` types), `Pipeline/TrackRouter.swift` (one engine stream per track) → `TranscriptionEngine/TranscriptEvent.swift` (`track` mandatory, `speaker` optional) → `SessionStore/Assembler.swift` ([me]/[them] + speaker) | `p6_two_track.sh` (asserts `seg` rows with `track:microphone` **and** `track:system`, and ≥1 non-null `speaker` on the system track) |

Cross-cutting: `Verifier/Checks/CrashSafetyCheck.swift` + `SessionStore/Recovery.swift` back the "kill -9 leaves recoverable segments" requirement; `harness/run.sh` includes a `kill -9` step inside P1 and asserts recovery on next launch (evidence recorded in `grade.json`, not a separate gate).

## 6. Risk notes

**ScreenCaptureKit / TCC**
- Audio-only SCK is undocumented; works on 14/15/26 in shipping apps but can regress per OS point release. Mitigation: pin minimum to macOS 15 (needed for `.microphone` anyway), keep the 2×2 @ 1 fps video stub, treat "stream output NOT found" console noise as expected.
- Dev gotcha: during `swift run`/Xcode debug the *granted binary* is the terminal/IDE, not the app. Harness must run the built `.app` bundle, or P2 grades the wrong thing.
- Mid-session revoke behaviour differs by OS: sometimes the delegate gets `didStopWithError`, sometimes buffers just stop. `PermissionCheck` must therefore fire on **either** the typed error **or** `AudioFlowCheck` + a failing `PermissionGate` re-probe. The ≤ 2 s bound is the tight part of P2; budget for a 1 s re-probe cadence while recording.
- `updateConfiguration` replaces, never merges. Enforce one `CaptureConfig.make()` factory; forbid ad-hoc config mutation in review.

**Grok streaming**
- Model is days old; every accuracy figure is vendor-reported. P1's 15 % WER bar may fail on the engine, not our code — the harness must make that attributable (record raw PCM alongside the session in harness mode so the same audio can be re-run against AssemblyAI in the bake-off).
- `endpointing=800` is the whole difference between sentences and confetti; assert it in a URL-builder unit test so it cannot be lost in a refactor.
- Handshake: no audio before `transcript.created`. If the socket opens but the event never arrives, the failure is *quiet* by default. `TransportHeartbeatCheck` owns the deadline (proposed 5 s) and goes loud.
- Reconnect semantics are unverified: does a new socket resume word timestamps from 0? `Reconnect.swift` must re-base timestamps onto session time and emit the gap explicitly; never trust engine-relative times in the store.
- Two sockets per session (one per track) doubles the streaming cost ($0.20/hr → $0.40/hr) and the concurrent-session count. Fine for v0; the 2-channel multichannel mode is the bake-off alternative, not v0.
- Diarization labels are per-stream: `S1` on the system track and `S1` on the mic track are unrelated. Assembler must namespace by track; the interface itself stays diarization-agnostic (locked).

**Mac CI / build**
- P1–P6 need a logged-in GUI session, TCC grants, real audio output, and network fault injection — none of which a hosted runner provides. CI runs `swift build` + `swift test` only; the gates are a QA-run harness on a physical Mac, and green is claimed only from a `v0-verdict.json` produced there.
- `.xcodeproj` generated from `project.yml` avoids merge-conflict churn but adds an xcodegen dependency for the app target. Library targets stay pure SwiftPM.
- Signing: TCC keys permissions to the bundle identifier + code signature; an unsigned or ad-hoc-signed rebuild can silently re-prompt or lose the grant. Use a stable dev signing identity for harness builds.

**Two-track preservation**
- SCK delivers `.audio` and `.microphone` as separate `SCStreamOutput` callbacks with their own clocks; interleaving in the assembler needs a shared session clock (host time at session start). Establish that in `Pipeline`, not in the engine.
- Any place that types the track as a string instead of the `AudioTrack` enum is a place a track can be lost. `TranscriptEvent.track` is non-optional by design.
- Mic track has no "them" diarization value and system track has no "me"; the UI must not imply otherwise.

**Silent-failure traps (the reason the verifier exists)**
- Frames flowing but all-zero (muted output, wrong device, revoked permission on some OS versions) → looks like recording. `AudioFlowCheck` (RMS) is the only defence; it must run per track and never be disabled by the engine's state.
- Half-open WebSocket: OS reports connected, server stopped acking. Heartbeat on *events received*, not socket state.
- Engine returns only partials and no finals → store stays empty while UI looks alive. `TranscriptSanityCheck` compares stored final text vs elapsed time; partials never count.
- Store write failure (disk full, sandbox path) → transcript "recorded" to nowhere. `JSONLWriter` errors are fatal-loud, not logged-and-continued.
- Verifier itself crashing or being starved. It runs as a separate actor with its own timer; a dead verifier is a `degraded` state surfaced by the UI's own watchdog on `VerifierStatus` staleness.
- Permission granted to the wrong binary (dev vs app). Covered above; the harness README makes this the first checklist item.

## 7. Explicitly out of scope for v0

Notes, Jev, interjection, context graph, iOS/Windows, AssemblyAI implementation (interface slot only), bake-off harness, Opus encoding, any UI beyond the four views. `spike/` is not touched.

## 8. Done-check for this plan's implementation climb

The implementation is done when `run.sh verdict` on a QA Mac writes `v0-verdict.json` with `GREEN` (P1–P6 all `pass` on one SHA and CDHash), and `docs/qa/v0-grading.md` lets QA reproduce it without the builder present. Until QA produces that file, v0 is red.

Hardened GREEN evidence (Cap-reported, not in git): `b14e31a` (`b14e31a99a431e5cac6a49669f5c1955de38a1d1`), CDHash `57250034b55e54e3ad6798983edf6e62c1553653`, board `/tmp/catcher-auto/b14e31a-20260923-055848/board.json`. Preflight and P1–P6 pass under the hardened verifier (soft-pass killed). `MicrophoneGain` on the mic path (floor 0.05 unchanged); P6 p50 0.2039, micGainMax 16. This supersedes `95837a8`. Reconcile and merge stay with Cap/Nathan.
