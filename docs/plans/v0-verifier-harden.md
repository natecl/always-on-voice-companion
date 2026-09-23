# v0 verifier harden — plan (plan only)

**Status:** plan doc, no code. Audited at `95837a8891a07f4169ecfa9b869a7a80c4545ad3` (Mac GREEN as reported). Planning climb ran on claude-opus-5-5. The implementation climb runs on grok-4.7 with `fast=false`.

**Goal:** `grade.py` and the verifier must not report `pass` for a run that did not prove the gate. Three soft-pass classes are closed:

1. **Linux ≠ Mac.** A VM `swift test` against a scripted transport (whose `close()` returns) is not evidence for P1–P6. Mac `URLSession` parks `cancel()`/`receive()` under a `pf` drop.
2. **Reconnect without a live seg.** `degraded → gap → resumed` plus one seg can pass P3 even when the only seg after `resumed` is replayed backlog audio and the socket dies again.
3. **Resting mic vs `noAudio`.** The AC-RMS floor, the backdated `noAudio` stamp, and the spike clock from `95837a8` can pass P4 without an observed silence, and can fire `noAudio` over quiet real speech.

The Mac harness gates stay the source of truth. Everything added here makes a pass harder to get. Nothing makes a Mac pass easier.

---

## 0. Audit findings at `95837a8`

### Class 1 — Linux scripted close vs Mac URLSession hang

| Where | Finding |
|---|---|
| `catcher/harness/grade.py` (whole file) | No provenance. `grade.py --session <dir>` writes `pass` on any host, for any session directory, including one written by hand or by a unit test. |
| `grade.py` `grade_p6` (L343–349) | Does not check the `session` row's `engine`. A `CATCHER_ENGINE=stub` session passes P6 (the stub writes both tracks and `speaker: "S1"` on system). P3 has the same hole in principle (it grades whatever ann rows exist). `p1_known_audio.sh` honours `CATCHER_ENGINE` from the environment. |
| `grade.py` `main` | One gate per `grade.json`, one `grade.json` per session. Nothing checks that the six passes come from **one build**. "Mac GREEN @sha" is a human claim, not an artifact. |
| `SessionHeader.app` (`Pipeline.swift` L133, `SessionPaths.swift` L4) | Always `"0.0.1"`. A session cannot be tied to a commit or a signature. |
| `Tests/GrokEngineTests` `ScriptedTransport` | `close()` returns immediately and wakes `receive`. This fake is what let the pre-`480d3f0` handshake test pass while Mac hung (the comment at `GrokEngine.swift` L280–281 says so). Only `hungCloseStillEmitsGapAndStreaming` and a few `SocketSupply` tests model the Mac park (`hangClose`, `wakeReceiveOnClose=false`, `ignoreReceiveCancel`). Most reconnect tests run on the friendly profile only. |
| Commit messages (`005264d`) | "Linux swift test: 86 passed. This is not a Mac P3 pass." The disclaimer is prose. Nothing in the repo stops the same test count from being quoted as a P3 fix. |
| `.github/workflows/catcher-ci.yml` | Job name `library`. It runs `swift test` on `macos-15`, but it has no display, TCC, or `pf`, so it cannot run P1–P6. Nothing on the job says so. |

### Class 2 — reconnect OK, no live seg after `resumed`

| Where | Finding |
|---|---|
| `grade.py` `grade_p3` (L297–310) | Takes the **first** `degraded`, `gap`, and `resumed` by index, independently. A startup handshake `degraded`, or a heartbeat `degraded` on the other track, satisfies "degraded first". It needs one `seg` with `startMs >= resumed.atMs`, on any track. It does not check: the `pf` window, gap span, track, or a second degrade after resume. |
| `GrokEngine.swift` L483 + `Pipeline.swift` L543–556 | After a reconnect every final is rebased onto `socketOriginMs = max(audioMs, now)`, and the `resumed` ann is stamped with `gap.toMs` (same origin). So `seg.startMs >= resumed.atMs` holds **by construction** for any final from the new socket, including a final for audio that was recorded **before** or **during** the outage. |
| `GrokEngine.swift` L180, L691 | `pending` is unbounded during the outage and `replay` keeps up to 30 s. After a 15 s block the new socket first receives ≈ replay + outage audio (up to ~45 s). The first post-resume segs describe that backlog, not live speech. |
| `GrokEngine.swift` L589–600 `waitForPostResumeSegment` | `streaming` is held until one final is queued or 8 s pass, then announced anyway. The file order is `degraded, seg, gap, resumed`. One backlog final is enough for today's grade. |
| `TransportHeartbeatCheck.swift` + `Verifier.swift` L21 | **One** transport check for both tracks. `ready`, `degraded`, and `degradedReasons` are shared. Under `pf` both sockets die. The first track to reach `.streaming` writes `resumed` and clears `degraded` while the other track is still down. Identical `degraded` reason text from the second track is also de-duplicated away (L84). The verifier can show OK with one track dead. |
| `Annotation` detail for `degraded`/`resumed` | Text only, with no track. Only `gap` carries `track`. The grader cannot pair a chain per track. |
| `p3_net_kill.sh` | Plays no audio. It records no `pf` on/off time. The operator presses enter "after reconnect", so the post-resume tail length is whatever the operator chose. |

### Class 3 — resting-mic RMS vs `noAudio`

| Where | Finding |
|---|---|
| `AudioFlowCheck.swift` L16 | `rmsEpsilon = 0.05` (≈ −26 dBFS AC RMS). Quiet conversational speech into a laptop mic often sits at 0.01–0.05. That speech counts as silence, so `noAudio` can fire during a real conversation. That is a false P4 green and a false alarm in P1/P6. Nothing on a Mac measures this margin. |
| `AudioFlowCheck.swift` L18, L61–70 | "Sustained" means 300 ms of **consecutive** frames above the floor. Any one frame under the floor resets `pendingLoudSince`. Syllabic speech with short dips may never set `everLoud`. |
| `AudioFlowCheck.swift` L76–79 | For a never-loud track, silence is dated from `recordingStartedMs`. `Pipeline.start` calls `beginSession(atMs: 0)` (L143) **before** the launch probe, engine creation, and `capture.start()`. If the first frame arrives late, the silence window has only a few seconds of observed audio. |
| `AudioFlowCheck.swift` L111–125 | The `noAudio` ann `atMs` is **computed** as `since + 10_000` (or `start + 10_000`), not the time it was emitted. A tick loop that stalls until 25 s still writes `atMs: 10000`. `grade_p4` (L313–320) only checks `atMs ∈ [0, 10000]`, so a late detector passes. |
| `AudioFlowCheck.swift` L97–103 | The `noFrames` path (`no frames for >10s`) passes P4 with capture dead. `v0-grading.md` L59 already concedes that P4 does not prove capture. |
| `grade.py` L24, L90–105 | The grader's floor is `RMS_EPSILON = 0.001` on **raw** RMS (DC included), used only for P1 gaps. The verifier's floor is 0.05 on **AC** RMS. The two floors can drift apart silently. P4 never reads the PCM at all, so it cannot tell whether the room was actually quiet. |
| `Verifier.swift` L75, L107, L111 | `audioFlowing` for the heartbeat is the **instantaneous** "latest frame above floor" (`above` set), not the sustained state. One loud frame near a tick can still yield heartbeat `degraded "…while audio is flowing"` in a P4 run. Sanity uses `!allSilent`, which is true for the whole first 10 s. |

---

## 1. Cross-cutting changes (land first; every class uses them)

### 1.1 Result vocabulary

`grade.json` per gate becomes `{"result", "evidence", "checks"}`. `result` is one of:

- `pass`: every check passed **and** provenance is Mac-harness (§1.2).
- `fail`: a check failed.
- `invalid`: the run did not set up the premise, for example P4 with sustained speech in the PCM, or P3 where `pf` never blocked. This is not a pass and not a product failure. The operator re-runs.
- `unproven`: the checks passed but provenance is missing or not Mac. **Never a pass.**
- `n/a`: not requested.

`checks` is an ordered list of `{"name", "ok", "detail"}`, so the Linux unit tests can assert the logic without ever seeing `pass`. `grade.py` exits 0 only when every requested gate is `pass`.

### 1.2 Provenance

- **`catcher/scripts/build-app.sh`** writes `CatcherGitSHA` (the output of `git rev-parse HEAD`, plus `-dirty` when the tree is dirty) into `Info.plist`.
- **`SessionPaths.swift` / `CatcherMetadata`**: add `buildSHA`, read from the bundle's `CatcherGitSHA`, or `"unknown"` in a SwiftPM or test build. `Pipeline.start` writes `app: "0.0.1+<sha>"`. **Value only; the key set is unchanged**, so P5 shape is unaffected.
- **`catcher/harness/lib.sh`** `launch_catcher` writes `<root>/harness_run.json` once per gate run, before launch: `gate`, `startedWallMs`, `sw_vers -productVersion`, `uname -m`, `sysctl -n hw.model`, `CATCHER_APP` path, `codesign` `CDHash` / `TeamIdentifier` / `Authority`, the plist `CatcherGitSHA`, `CATCHER_ENGINE`, and the harness repo `git rev-parse HEAD`. Gate scripts append their own fields (P3 `pfOnWallMs`/`pfOffWallMs`, P2 `revokeWallMs`; P2 keeps `revoke_wall_ms` for compatibility).
- **`grade.py`** reads `harness_run.json` from the session's parent (or the session itself). A gate is `unproven` unless all of these hold:
  1. `platform.system() == "Darwin"` at grade time.
  2. `harness_run.json` exists and its `gate` matches.
  3. `sw_vers` is ≥ 15.
  4. The header `app` SHA equals `harness_run.json` `CatcherGitSHA` and is not `unknown` or `-dirty`.
  5. The session `startedAt` is at or after `startedWallMs`.
  6. For P1, P3, and P6, the header `engine` is not `stub`. For P5 it must be `stub`.

  `--no-provenance` exists only for unit tests: it forces `unproven` and still fills `checks`.

### 1.3 One verdict for the six gates

A new **`catcher/harness/verdict.py`** takes `--p1 … --p6 <root>` (the paths passed to `run.sh`). It **re-runs** `grade.py` on each root instead of trusting a `grade.json` on disk, and writes `v0-verdict.json`:

```json
{"verdict": "GREEN|RED", "sha": "…", "cdhash": "…", "gates": {"P1": {…}, …}, "gradedOn": "Darwin 15.x hw.model", "gradedAt": "ISO8601"}
```

`GREEN` requires all of the following:

- All six gates are `pass`.
- One `CatcherGitSHA` and one `CDHash` across all six.
- The P5 shape reference is a Grok session from the same SHA, the P1 session unless one is given.

`run.sh verdict <out> --p1 … --p6 …` wraps it. "Mac GREEN @sha" is only claimable with a `v0-verdict.json` whose `sha` is that commit.

### 1.4 One threshold file

A new **`catcher/harness/thresholds.json`** is the single source for grader numbers and mirrored verifier numbers:

- `verifierRmsFloor` (0.05, pending Q3)
- `speechHoldMs` (300)
- `silenceLimitMs` (10000)
- `noAudioEmitSlackMs` (1500)
- `p1GapRmsFloor` (0.001, AC)
- `p1GapLimitMs` (2000)
- `p3DegradeWithinMs`, `p3ResumeWithinMs`, `p3MinGapSpanMs`, `p3LiveMarginMs`, `p3MinLiveWords`, `p3MinTailMs`
- `p6MicSpeechFloorRatio` (2.0)

`grade.py` loads it. **`Tests/VerifierTests`** gains a test that reads the file via `#filePath` and asserts that `AudioFlowCheck.rmsEpsilon`, `speechHoldMs`, and `silenceLimitMs` match. That test is a drift guard. It is not P evidence.

### 1.5 Grader unit tests

A new **`catcher/harness/tests/test_grade.py`** (`unittest`, stdlib only) builds synthetic session directories, including synthetic PCM, and asserts `checks` for every rule below. Each soft-pass fixture from §0 must produce a non-`pass`, and each of today's genuine shapes must produce `checks` all ok (`result=unproven` off-Mac). CI runs it in a new `harness-grader` job on `ubuntu-latest`, named so it cannot be mistaken for a gate (§5).

---

## 2. Class 1 — VM tests never count as P1–P6

**Gates / assertions**

- **G1.1** Provenance per §1.2. Any gate graded off a Mac, from a non-harness directory, from an ad-hoc/dirty/unknown build, or with the wrong engine is `unproven` or `fail`, never `pass`.
- **G1.2** `grade_p1`, `grade_p3`, `grade_p6`: `checks` includes `engine=grok` (the header `engine` equals `EngineFactory.grokModelName`, recorded in `harness_run.json` by the harness). A stub header gives `fail` with the evidence "stub engine cannot prove P1/P3/P6".
- **G1.3** `grade_p5`: the header `engine == "stub"` and the reference header `engine != "stub"`, both with the same `CatcherGitSHA`.
- **G1.4** `verdict.py` per §1.3 is the only artifact that can say GREEN.
- **G1.5 (unit-test hygiene, not a gate).** In `Tests/GrokEngineTests`:
  - Add a `TransportProfile` enum with two cases. `.friendly` is today's `ScriptedTransport`. `.macParked` sets `hangClose`, `wakeReceiveOnClose=false`, `ignoreReceiveCancel=true`, and `hangConnect` for in-window retries.
  - Parameterise every reconnect/stall test over both profiles, using `@Test(arguments:)`: `reconnectEmitsGapAndRebasesWordTimes`, `postResumeFinalIsQueuedBeforeStreamingAndNotBeforeTheGap`, `reconnectSendsTheShortTailTheChunkPumpLeftBehind`, `stalledSocketReconnectsReplaysAudioAndEmitsAGap`, `bufferedSendReconnectsWhenCloseDoesNotWakeReceive`, `blockedSendAfterWatermarkStillReconnects`, and `handshakeTimeoutClosesParkedReceiveAndEmitsGap`.
  - A new reconnect test that only passes on `.friendly` is a review blocker.
  - This narrows the Linux/Mac gap. It does not close it, and the doc says so (§5).

**Code touched:** `grade.py`, `lib.sh`, all `p*_*.sh` (write/extend `harness_run.json`), `build-app.sh`, `project.yml`/`Info.plist` (plist key), `SessionPaths.swift`, `Pipeline.swift` L133, new `verdict.py`, `run.sh` (`verdict` subcommand), `Tests/GrokEngineTests/GrokEngineTests.swift`.

---

## 3. Class 2 — reconnect must be followed by live segs

### 3.1 Verifier and engine changes (small, additive)

- **`TransportHeartbeatCheck.swift`**: per-track state. Keep a `[AudioTrack: TrackTransport]` holding `connectingSince`, `ready`, `lastEventAt`, `degradedReasons`, `handshakeEmitted`, and `heartbeatEmitted`.
  - `degraded` is true while **any** track is degraded.
  - `resumed` is emitted when **that** track goes ready/streaming after being degraded, and does not clear the other track.
  - De-duplication is per track.
  - `tick(atMs:audioFlowingTracks:)` takes the set of tracks with sustained audio (see §4.1), so the heartbeat is per track too.
- **Ann detail text carries the track** for engine-originated `degraded`/`resumed`: `"<reason> track=<t>"` / `"transport resumed track=<t>"`. `detail` stays a string, so the **P5 key shape is unchanged**.
- **`GrokEngine.swift`**: when a reconnect reaches `streaming`, record `backlogMs = (replay.count + pending.count at new-socket open) / 32`, which is the audio the new socket must chew through before live audio. Surface it as `EngineState.streaming` context, or as a field the pipeline reads through `EngineDiagnostics.snapshot()`. The verifier appends ` backlogMs=<n>` to the `resumed` detail text. Stub and first-connect `streaming` report `backlogMs=0`.
- No change to `waitForPostResumeSegment`'s budget. The grader stops relying on that one final (below).

### 3.2 Harness changes (`p3_net_kill.sh`)

- `afplay` the fixture **in a loop** from launch until kill, so the system track has live speech before, during, and after the block.
- Write `pfOnWallMs` right after `pfctl -a catcher -f` returns, and `pfOffWallMs` right after `-F all`, into `harness_run.json`.
- Replace the manual `read` with a poll: wait up to `p3ResumeWithinMs` after `pf` off for a `resumed` ann on **system**. Parse `backlogMs`, then keep recording for `backlogMs + p3MinTailMs`, and only then kill. On poll timeout, kill and grade (the result is a fail with evidence).
- Keep `CATCHER_ALLOW_PF=1` and the root requirement.

### 3.3 `grade_p3` assertions (replace L297–310)

Convert `pfOn`/`pfOff` to session ms via `wall_to_session_ms`. For **track = system** (required), and for microphone when the mic shows a gap:

| # | Check | Rule |
|---|---|---|
| P3.a | premise: block was real | A `gap` ann with `detail.track == T` exists (else `fail`), and `detail.toMs − detail.fromMs ≥ p3MinGapSpanMs` (proposal: 10 000 for a 15 s block). If the span is shorter: `invalid` ("block shorter than expected; check `pfctl -a catcher -sr`"). |
| P3.b | degrade tied to the block | An engine `degraded` ann with `track=T` in its detail and `atMs ∈ [pfOn, pfOn + p3DegradeWithinMs]` (proposal: 12 000 = stall 5 s + handshake 5 s + 2 s slack). Earlier `degraded` rows (startup handshake, heartbeat) are ignored for chain selection. |
| P3.c | ordering | For that track, in file order: the chosen `degraded` < `gap` < `resumed(track=T)`. `gap.detail.fromMs ≤ pfOn + p3DegradeWithinMs` and `gap.detail.toMs ≥ pfOff − 1000`. |
| P3.d | resume only after unblock | `resumed.atMs` (engine clock) is in `[pfOff − 1000, pfOff + p3ResumeWithinMs]` (proposal: 45 000, from the backoff 1, 2, 4, 8, 16 s plus handshake). A `resumed` while `pf` was still on means the block was not real: `invalid`. |
| P3.e | **live** seg after resume | Let `liveFrom = resumed.atMs + backlogMs + p3LiveMarginMs` (margin proposal: 3 000). Require ≥ 1 system `seg` with `startMs ≥ liveFrom`, and ≥ `p3MinLiveWords` (proposal: 10) words across system segs with `startMs ≥ liveFrom`. A seg in `[resumed.atMs, liveFrom)` is reported as `backlog` in evidence and never satisfies this check. |
| P3.f | no relapse | After the chosen `resumed(track=T)`: no `degraded(track=T)` without a later `resumed(track=T)`, no second `gap` on T without a later `resumed`, and the session `end` (or the last row, after kill -9 recovery) is ≥ `liveFrom + p3MinTailMs − 5000`. |
| P3.g | other track | If the microphone has a `gap`, it needs its own `resumed(track=microphone)` (P3.c/d). Its live seg (P3.e) is required only if `microphone.pcm` shows sustained speech (§4.3 window test) after `liveFrom`. |

If `backlogMs` is missing from `resumed`, for example on an old build, set `liveFrom = resumed.atMs + (gap.toMs − gap.fromMs) + 30 000 + margin`. That is conservative, and the harness tail must cover it.

### 3.4 Unit tests (regression only)

- `VerifierTests`: a system reconnect does not clear microphone `degraded`, and each track writes its own `resumed` with `track=` in the detail. Identical reason text on two tracks writes two `degraded` rows.
- `GrokEngineTests` (both profiles): `resumed`/`streaming` reports `backlogMs ≥` the queued outage audio, and the first post-resume final's `startMs < origin + backlogMs`, which documents that it is backlog.
- `test_grade.py`: today's `95837a8` P3 shape (one backlog seg at `resumed.atMs`) is `fail` on P3.e. A startup-handshake `degraded` plus an unrelated gap is `fail` on P3.b. A relapse after resume is `fail` on P3.f. A resume while `pf` was on is `invalid`.

---

## 4. Class 3 — resting mic vs `noAudio`

### 4.1 Verifier changes

- **Clock origin.** `Pipeline.start` calls a new `verifier.captureStarted(atMs:)` right after `capture.start()` succeeds. `AudioFlowCheck.begin` moves there, so the never-loud silence clock and the `noFrames` clock both start at capture start, not at `beginSession(atMs: 0)`.
- **Emission time on the ann.** `noAudio` detail text becomes `"<detail> emittedAtMs=<nowMs at emission> observedFromMs=<capture start>"`. `atMs` keeps its meaning, the boundary `since + 10_000`, so existing tests and the P4 window semantics hold. `heartbeat`/`handshake` `degraded` get the same `emittedAtMs=` suffix, because they are also backdated (`TransportHeartbeatCheck` L101, L107).
- **Sustained, not instantaneous, flow.** `AudioFlowCheck` exposes `sustainedTracks` (tracks with `everLoud` whose `quietSince` is nil) and `audioFlowing = !sustainedTracks.isEmpty`. The heartbeat and sanity use that. `observeFrame` stops calling `sanity.setAudioFlowing(… rms > rmsEpsilon)` per frame (`Verifier.swift` L75).
- **Hold tolerates syllable dips.** In `AudioFlowCheck.observe`, a frame under the floor only clears `pendingLoudSince` after `speechDipMs` (proposal: 120 ms) of consecutive sub-floor frames. A single loud spike still cannot satisfy `speechHoldMs`, which keeps the `95837a8` spike fix.
- **Floor value.** Keep 0.05 until the Mac calibration check (§4.3 P6.m) produces data. Q3 decides whether to lower it or move to a noise-floor-relative rule.

### 4.2 Harness changes

- `p4_silence.sh` records `harness_run.json`. It still sleeps 15 s, but the recording must include ≥ 10 s of PCM after capture start, so extend the sleep to 16 s.
- `p6_two_track.sh`: the operator prompt says "speak at normal conversational volume, arm's length".
- `CATCHER_HARNESS=1` already writes both PCM files, and P4 now requires them.

### 4.3 Grader assertions

A new `pcm_windows_ac()` computes mean-removed RMS per 100 ms window. Both the P1 gap floor and the verifier floor come from `thresholds.json`. `sustained_speech(windows, floor, holdMs, dipMs)` mirrors the Swift rule for evidence.

**`grade_p4` (replace L313–320):**

| # | Check | Rule |
|---|---|---|
| P4.a | ann in window | A `noAudio` ann with `atMs ∈ [silence_at, silence_at + 10 000]` (unchanged). |
| P4.b | emitted in time | Parsed `emittedAtMs ≤ silence_at + 10 000 + noAudioEmitSlackMs`. Missing `emittedAtMs` gives `fail` ("cannot prove emission time"). |
| P4.c | capture was live | `system.pcm` and `microphone.pcm` both exist, each with ≥ `(emittedAtMs − observedFromMs − 1000)` ms of samples. The detail must not be `no frames for >10s`. A no-frames `noAudio` is `fail` for P4 ("detector not exercised; capture dead"), pending Q4. |
| P4.d | premise: it was quiet | In `[observedFromMs, emittedAtMs]`, neither PCM track has sustained speech at the verifier floor. System peak AC RMS ≤ `p1GapRmsFloor` (muted output is digital silence). If either fails: `invalid` ("operator not quiet / output not muted"). |
| P4.e | no contradiction | No `seg` with non-blank text and `startMs < emittedAtMs`. No `degraded` whose detail contains "audio is flowing" in `[0, emittedAtMs]`. |

**P1 and P6 negative controls (new checks in `grade_p1`, `grade_p6`):**

| # | Check | Rule |
|---|---|---|
| P1.n / P6.n | no `noAudio` over speech | For each `noAudio` ann, the 10 s window before its `atMs` must contain no sustained speech window (by `pcm_windows_ac`) on any track. Otherwise `fail` ("noAudio fired over speech; floor too high"). With the fixture playing, P1 should normally have no `noAudio` at all. |
| P1.g | gap floor is AC | `gap_evidence` switches to `pcm_windows_ac` with `p1GapRmsFloor`. This is stricter, not looser: DC offset no longer hides as speech, and the floor stays at 0.001 rather than rising to 0.05. |
| P6.m | mic speech clears the floor | The median AC RMS of the operator's sustained-speech windows in `microphone.pcm` (windows above `p1GapRmsFloor`, merged into ≥ 300 ms runs) must be ≥ `p6MicSpeechFloorRatio × verifierRmsFloor`. Otherwise `fail` ("normal speech is under the noAudio floor"). Evidence always prints p10/p50/p90 mic AC RMS, which is the calibration data for Q3. |

### 4.4 Unit tests (regression only)

- `VerifierTests`: capture starting at 4 s with a resting mic gives `noAudio.atMs == 14_000`, not 10 000. `emittedAtMs` is present and equals the tick time. Syllabic speech (a 250 ms burst, an 80 ms dip, then a 250 ms burst, repeated) at 0.08 is flowing, not `noAudio`. A single spike still trips at 10 s. One loud frame at a tick does not produce heartbeat `degraded` in a muted session. The existing `mutedOutputAndRestingMicEmitsNoAudioInsideTenSeconds` / `micDCOffsetIsSilenceNotFlowingAudio` / `aSingleLoudSpikeDoesNotPushNoAudioPastTenSeconds` stay green.
- `test_grade.py` fixtures:
  - A backdated `noAudio` (`atMs=10000`, `emittedAtMs=25000`) is `fail`.
  - A `no frames` `noAudio` is `fail`.
  - A PCM with speech at 0.04 plus `noAudio` is `invalid` for P4 and `fail` on P6.n/P1.n.
  - A mic p50 of 0.03 is `fail` on P6.m.
  - A DC-offset system PCM does not create a false P1 hole.

---

## 5. Doc contract edits (so the grader cannot soft-pass; Mac stays SoT)

**`docs/qa/v0-grading.md`**
- Top: add **Evidence tiers**.
  - Tier M: `v0-verdict.json` = GREEN for a SHA, produced on a Mac by `run.sh verdict`. This is the only v0 claim.
  - Tier G: a single-gate `grade.json` with `result: pass` and provenance.
  - Tier L: `swift test` (Linux VM or `macos-15` CI), `test_grade.py`, or scripted/fake transports. Regression only.
  - Tier L is never cited as P1–P6 evidence in a commit message, PR body, or status update. "Fixed P3" requires Tier G for P3 on that SHA.
- Result vocabulary (§1.1), stating that `unproven` and `invalid` are not passes.
- **Gates table rewrite:**
  - P3: `pf` window recorded, per-track chain, gap span, resume after unblock, **live** seg after `resumed + backlogMs`, no relapse, fixture looping.
  - P4: emission time, live capture (a no-frames `noAudio` fails), premise quiet (`invalid`), no contradicting seg/heartbeat, silence measured from capture start.
  - P1/P6: add the `noAudio`-over-speech control. P6: add the mic floor margin. P1/P3/P6: grok only. P5: stub vs same-SHA grok reference.
- Replace "v0 stays red until `grade.json` … all pass" with "until `v0-verdict.json` is GREEN for the SHA".
- Delete L59's hedge ("P4 passing does not show that system audio was captured"): P4.c now enforces it. Keep the `afplay` peak/RMS guidance.
- Document `harness_run.json` in the run-layout block and add `v0-verdict.json`.

**`docs/qa/v0-diagnostics.md`**
- Opening paragraph: point "v0 stays red until…" at `v0-verdict.json`.
- Last line: `degraded`/`resumed` now carry `track=` and `resumed` carries `backlogMs=`. Annotations carry `emittedAtMs=`. Still no stage line. `stages.log` is still never read by `grade.py`; provenance comes from `harness_run.json`, not from stage lines.

**`catcher/harness/README.md`**: add `run.sh verdict`, add that P3 loops the fixture and needs no enter, and add a pointer to the tiers.

**`catcher/README.md`** L56: repoint at the verdict.

**`.github/workflows/catcher-ci.yml`**: rename the job to `library-tests-not-p1-p6`. Add a `harness-grader` job (`ubuntu-latest`, `python3 -m unittest discover catcher/harness/tests`). Neither job name contains "grade", "P1", or "verdict" except as "not-p1-p6".

**`docs/plans/v0-catcher.md`** (plan-of-record, not an essay; minimal factual edits only): P4 row "60 s silence" → the harness's actual 16 s run and capture-start clock. P3 row: "resume" → "resume plus a live seg past backlog". §7 done-definition → `v0-verdict.json` GREEN.

**Knowledge essays: note only, no rewrite in this scope.** The prove contracts make these sentences inaccurate or overclaimed. The owner decides later:
- `docs/knowledge/08-capture-layer.md` L60 "the verifier exists so it's impossible in v0": after this plan, it is *detected and graded*, not impossible. A no-frames capture still emits `noAudio`, but P4 now calls it a failure of the silence detector's premise.
- `docs/knowledge/06-strategic-reads.md` L44 "binary pass/fail": the grader now has `invalid`/`unproven`. The product surface stays binary; the grader does not.

---

## 6. Files to change

| Path | Change | Class |
|---|---|---|
| `catcher/harness/grade.py` | result vocabulary, provenance, per-gate rewrites P1/P3/P4/P5/P6, AC PCM windows, thresholds load | 1, 2, 3 |
| `catcher/harness/thresholds.json` (new) | single threshold source | 2, 3 |
| `catcher/harness/verdict.py` (new) | six-gate, one-SHA GREEN/RED | 1 |
| `catcher/harness/tests/test_grade.py` (new) | synthetic-session fixtures for every rule | 1, 2, 3 |
| `catcher/harness/lib.sh` | `harness_run.json` writer, `append_harness_field` helper | 1 |
| `catcher/harness/run.sh` | `verdict` subcommand | 1 |
| `catcher/harness/p3_net_kill.sh` | loop fixture, pf timestamps, auto-wait on `resumed` + backlog + tail | 2 |
| `catcher/harness/p4_silence.sh` | provenance, 16 s | 3 |
| `catcher/harness/p1_known_audio.sh`, `p2_tcc_revoke.sh`, `p5_stub.sh`, `p6_two_track.sh` | provenance; P1 force `CATCHER_ENGINE=grok`; P6 prompt | 1, 3 |
| `catcher/scripts/build-app.sh`, `catcher/project.yml` / `Sources/CatcherApp/Info.plist` | `CatcherGitSHA` | 1 |
| `catcher/Sources/SessionStore/SessionPaths.swift` | `CatcherMetadata.buildSHA`, `appVersion` value | 1 |
| `catcher/Sources/Pipeline/Pipeline.swift` | header `app` value, `captureStarted` call, per-track sustained-flow plumb to tick, `backlogMs` read | 1, 2, 3 |
| `catcher/Sources/Verifier/Verifier.swift` | `captureStarted`, sustained flow wiring, track/backlog/emitted suffixes | 2, 3 |
| `catcher/Sources/Verifier/Checks/TransportHeartbeatCheck.swift` | per-track state, track in detail, `emittedAtMs` | 2 |
| `catcher/Sources/Verifier/Checks/AudioFlowCheck.swift` | capture-start clock, `sustainedTracks`, `speechDipMs`, `emittedAtMs` | 3 |
| `catcher/Sources/GrokEngine/GrokEngine.swift` | compute and expose `backlogMs` at resume (additive) | 2 |
| `catcher/Sources/TranscriptionEngine/EngineDiagnostics.swift` or `EngineState.swift` | carrier for `backlogMs` (pick one; Q2) | 2 |
| `catcher/Tests/VerifierTests/VerifierTests.swift` | per-track, clock-origin, syllabic, emitted, thresholds drift guard | 2, 3 |
| `catcher/Tests/GrokEngineTests/GrokEngineTests.swift` | `TransportProfile` parameterisation, `backlogMs` | 1, 2 |
| `catcher/Tests/PipelineTests/PipelineTests.swift` | `captureStarted` ordering, header `app` suffix, `resumed` detail carries track | 2, 3 |
| `.github/workflows/catcher-ci.yml` | job rename, `harness-grader` job | 1 |
| `docs/qa/v0-grading.md`, `docs/qa/v0-diagnostics.md`, `catcher/harness/README.md`, `catcher/README.md`, `docs/plans/v0-catcher.md` | §5 | all |

**Not touched:** the `events.jsonl` row types and top-level keys (P5), `transcript.txt`, `session.json` keys, `stages.log` grammar, `trace.py`, the capture layer, and TCC paths.

---

## 7. Risks and open questions

**Risks**
- **Mac goes RED on re-run.** That is expected and correct. The `95837a8` P3 is likely to fail P3.e (only backlog segs are proven). P4 may go `invalid` if the room is not quiet, and P6.m may fail on the 0.05 floor. Treat these as findings, not regressions of the harden work. Re-run all six on one SHA before claiming anything.
- **Clock domains.** `resumed.atMs`/seg `startMs` are the engine's rebased audio clock (`SessionClockAnchor` plus byte cursor). `pfOn`/`pfOff` are wall time mapped through `startedAt`, and `noAudio` is the host clock from `origin`. P3.b/P3.d mix wall and engine clocks. The slack values absorb drift across one outage, but a long backlog skews the engine clock later than wall time. P3.d uses `resumed.atMs`, which equals the new socket's origin (≥ wall time at creation), so the skew goes in the safe direction. Verify on the first Mac run and log both clocks in evidence.
- **`backlogMs` plumbing** touches `GrokEngine`, which has churned for five commits on reconnect. Keep it read-only (compute at resume from counts already on the actor). Do not change pump or replay logic in this climb.
- **Per-track transport check** changes when `resumed` is written. P3 today may have relied on the first track's `resumed`. The grader now requires per-track, so this is aligned, but P2/P3 UI banners may change timing.
- **Stricter hold (`speechDipMs`)** could let a noisy room count as speech and block `noAudio` in P4. P4.d would then call the run `invalid`, not pass, so the failure mode is loud.
- **Test runtime.** Parameterising reconnect tests doubles them. Keep `ManualClock`, so there are no real sleeps.
- **`harness_run.json` is writable by anyone** on the Mac. Provenance proves "ran through the harness on a Mac", not tamper-proofing. That is acceptable for v0; a signature is out of scope.

**Open questions (defaults IMPLEMENT should use unless Nate overrides)**
1. **P3 thresholds.** Default `p3MinGapSpanMs=10000`, `p3DegradeWithinMs=12000`, `p3ResumeWithinMs=45000`, `p3LiveMarginMs=3000`, `p3MinLiveWords=10`, `p3MinTailMs=20000`.
2. **`backlogMs` carrier.** Default: `EngineDiagnostics.snapshot()` field (`lastResumeBacklogMs`), read by the pipeline when it stamps `streaming`. This avoids changing the `EngineState` enum that the stub and tests switch over.
3. **Verifier floor.** Keep 0.05 in this climb and gather P6.m p10/p50/p90 on the Mac. The follow-up picks a fixed floor or a noise-relative one (for example, 6 dB over the first-second median). Changing it now without data trades one soft pass for another.
4. **No-frames `noAudio` in P4.** Default: `fail` for P4 (the gate proves the silence detector on live capture). The product still emits it, and the UI behaviour is unchanged. Alternative: a separate P4-capture check. Nate decides.
5. **P4 clock origin.** Default: the window is measured from capture start (`observedFromMs`), and `--silence-at-ms` defaults to it. Alternative: keep session start, which is stricter on user-visible latency but grades a partly blind window.
6. **Should `verdict.py` require all six within one time window** (for example, 24 h)? Default: no time bound; same SHA and cdhash is enough.

---

## 8. Out of scope

- `FEATURE_MAP` authorship of any kind.
- Rewriting `docs/knowledge/*` essays. §5 only lists the sentences the new contracts contradict.
- Any change to capture (SCK), TCC/permission flows, P2 semantics beyond provenance, the stage-diagnostics grammar, or `trace.py`.
- Changing reconnect/pump/replay behaviour in `GrokEngine` beyond exposing `backlogMs`.
- Picking a new RMS floor value (§7 Q3).
- CI running any P gate, or a Mac integration test against a real `pf` (possible later: GitHub macOS runners have sudo, but have no TCC or audio).
- Signing or tamper-proofing `harness_run.json` / `v0-verdict.json`.

---

## 9. IMPLEMENT outline (Cap GO, grok-4.7 `fast=false`)

One commit per step. Push after each. Linux `swift test` and `python3 -m unittest` are required to be green at every step, **and are not Mac evidence**.

1. **Thresholds and grader skeleton.** `thresholds.json`; `grade.py` result vocabulary, `checks` list, `--no-provenance`; `test_grade.py` scaffold with today's shapes; CI `harness-grader` job and job rename.
2. **Provenance.** `build-app.sh` plist SHA; `CatcherMetadata.buildSHA`; header `app` value; `lib.sh` `harness_run.json`; all gate scripts; `grade.py` provenance and engine checks (G1.1–G1.3); tests.
3. **Verdict.** `verdict.py` plus `run.sh verdict`; tests (mixed SHA gives RED, stub P1 gives RED).
4. **Class 3, verifier.** `captureStarted` clock origin; `sustainedTracks`; `speechDipMs`; `emittedAtMs` suffixes; Swift tests plus the thresholds drift guard.
5. **Class 3, grader and harness.** AC PCM windows; P4.a–e; P1.n/P1.g; P6.n/P6.m; `p4`/`p6` script tweaks; grader tests.
6. **Class 2, verifier and engine.** Per-track `TransportHeartbeatCheck`; `track=` in the detail; `backlogMs` via diagnostics; `resumed` detail; Swift tests.
7. **Class 1 hygiene.** `TransportProfile` parameterisation of the reconnect tests.
8. **Class 2, harness and grader.** `p3_net_kill.sh` loop/timestamps/auto-wait; P3.a–g; grader tests, including the `95837a8` backlog-only shape failing.
9. **Docs.** §5 edits in one commit. Knowledge essays are untouched.
10. **Mac run (operator).** Build at the tip, then preflight, P1–P6, `run.sh verdict`. Report `v0-verdict.json` verbatim. RED results are findings for the next climb, not blockers for merging the harden work.
