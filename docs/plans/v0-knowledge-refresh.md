# v0 knowledge / docs refresh — plan (plan only)

**Status:** implemented. Base: `95837a8891a07f4169ecfa9b869a7a80c4545ad3`. The IMPLEMENT edits are the files listed in §3.

**Why now:** v0 (the transcript foundation) is green on a Mac. The knowledge docs still describe it as a proposal awaiting approval, and some of the capture facts they state are wrong for the shipped code. This refresh makes the docs describe what shipped, with evidence, and records the process lessons from the v0 climb. It does not describe anything not yet built as if it were done.

---

## 1. Facts the refresh may state (and where each comes from)

IMPLEMENT may write only facts from this table. A fact marked **Cap-reported** goes in with its evidence reference and is not reworded into something stronger.

| # | Fact | Source | Class |
|---|---|---|---|
| F1 | Mac run GREEN at `95837a8`: P1–P6 all `pass`, including P4 `noAudio` | Cap: board `/tmp/catcher-auto/95837a8-20260923-003139/board.json`, CDHash `62450598…` | Cap-reported (Mac artifact, not in git) |
| F2 | Grading ran without a human in the loop: `cua-driver` drove the Mac UI (grants, gate prompts), results collected into one `board.json` | Cap | Cap-reported; the driver and board schema are not in this repo |
| F3 | SCK captures two tracks, `.audio` (system, "them") and `.microphone` ("me"), kept separate end to end; 48 kHz stereo float from SCK, downmixed and resampled to 16 kHz mono PCM16 (`SampleBufferPCM`, `PCMFrame`); whole-display filter via `excludingApplications: []` on the awake display | `catcher/Sources/AudioCapture/*`, current `08-capture-layer.md` config block | Code |
| F4 | Reconnect path: socket stall → `degraded`, next socket opened without awaiting a parked `URLSession` close, backoff 1, 2, 4, 8, 16 s then capped at 30 s, `gap{fromMs,toMs}` on the new socket's origin, `resumed` only after a post-resume final is queued (or the catch-up budget ends), word times rebased by `originMs` | `GrokEngine/Reconnect.swift`, `GrokEngine/GrokEngine.swift`, commits `8f4b110`…`005264d` | Code + Mac P3 pass (F1) |
| F5 | `noAudio` uses AC RMS (DC removed), floor `rmsEpsilon = 0.05` (~−26 dBFS), 300 ms speech hold, 10 s limit; a resting mic (DC offset, room tone) counts as silence; fires even when zero frames arrived | `PCMFrame.swift` `PCMEnergy.acRMS`, `Verifier/Checks/AudioFlowCheck.swift`, commit `95837a8` | Code + Mac P4 pass (F1) |
| F6 | P4 passing does not prove system audio was captured; P1's `system.pcm` peak/RMS and system `seg` text do | `docs/qa/v0-grading.md` (already says this) | Existing doc |
| F7 | Linux VM `swift test` and `macos-15` CI (`swift build` + `swift test`) are not P1–P6 | `docs/qa/v0-grading.md`, commit `005264d` message | Existing doc |
| F8 | Grok 2.0 is the engine that passed v0. The Grok vs AssemblyAI bake-off has **not** run | `07-transcription.md`, no bake-off harness in repo | Existing doc |
| F9 | Not built: notes, Jev judgment in the pipeline, the judgment brief, interjection, context graph, v1, v2 | repo tree (`spike/` is the only Jev code, on HOLD) | Repo |

Process lessons (Cap-stated, recorded as rules, not as history):

- L1. One Cloud Agent climb at a time is the norm. Cap unlocked parallel agents for the v0 foundation lock only; that unlock does not carry forward.
- L2. One fix per QA cycle: each Mac run grades one change, so a red gate names one cause.
- L3. Fixtures (`catcher/harness/fixtures/*`) change only on Cap GO.
- L4. VM tests are not P1–P6. A Linux `swift test` pass is reported as such ("not a Mac P-gate pass"), never as green.

## 2. Inputs Cap must confirm before IMPLEMENT

IMPLEMENT stops and asks rather than guessing on these:

1. Full CDHash (only the `62450598` prefix is known), macOS version, and whether the run used `Catcher Development` or Apple Development signing.
2. Is `board.json` to be committed (e.g. `docs/qa/evidence/95837a8-board.json`) or only referenced by its `/tmp` path? `/tmp` does not survive a reboot. Committing an artifact needs Cap GO the same way a fixture does.
3. What to say about `cua-driver`: its name as Cap wants it written, where it lives (repo, machine, or tool), and whether its runbook belongs in this repo. Until confirmed, docs describe it only as "autonomous Mac grading driver, outside this repo."
4. Was `known-60s.wav` replaced with a real reading for the green P1, and if so, is that file in git? `v0-grading.md` says the committed file is only a carrier.

## 3. Files to change, with section outlines

### 3.1 `docs/product-vision.md`

- **Status line:** keep "vision spec — the north star." Add one sentence: v0's transcript foundation is shipped and graded (link to `knowledge/09-v0-shipped.md`); nothing above it is built.
- **How it works:** mark step 1 (always-on audio → streaming transcription) as partially real: v0 does per-session Mac capture of system + mic → Grok streaming → verified transcript. Change "Whisper-class, on-device where possible" to name the shipped engine and keep on-device as an open question. Steps 2–5 unchanged.
- **Phases:** split v0 into:
  - *v0 foundation — shipped.* System audio + mic → verified transcript on disk; loud on every failure (blocked, degraded/gap/resumed, noAudio); P1–P6 green at `95837a8`.
  - *v0 catcher — next, not built.* Jev judges every utterance → 2-second judgment brief. The test is unchanged: is the brief the heat?
  - v1 / v2 text unchanged. No new dates, features, or claims.
- **Open questions:** privacy bullet adds what v0 actually stores (session dir with `events.jsonl`, `transcript.txt`, `session.json`; raw PCM only in harness mode). Platform bullet notes v0 is desktop (macOS 15+), and phone is still open.
- Everything else (problem, product, why Jev, moats, what it's not) unchanged.

### 3.2 `docs/knowledge/08-capture-layer.md`

- **Title/date:** add "updated at `95837a8`, shipped v0."
- **Verdict:** replace the claim that SCK already emits the engine's PCM layout with F3: SCK delivers 48 kHz stereo float; the app does the conversion. Keep "the OS plumbing is the actual build."
- **The v0 pipeline:** keep the diagram. Add the verifier tap (annotations into the same JSONL) and the per-track engine stream, as in `docs/plans/v0-catcher.md` §1.
- **ScreenCaptureKit config:** keep the block; it already matches code. Add the dual-track rule as a heading ("Two tracks, shipped") with one line on how `[me]` / `[them]` show up in `transcript.txt` and the `track` field.
- **New section — Reconnect path (shipped):** F4 as a short numbered sequence, plus the two bugs that blocked P3 as gotchas: a pf-dropped `URLSessionWebSocketTask` never finishes `cancel()`, so reconnect must not wait for it; receive must be armed before replaying buffered audio, or the post-resume final is lost.
- **New section — noAudio detection (shipped):** F5. Why AC RMS: a resting mic's DC offset and room tone kept the plain-RMS silence clock resetting, so `noAudio` never landed inside 10 s. Include F6 so nobody reads P4 as capture proof.
- **Permission UX:** unchanged except a link to `../qa/v0-grading.md` setup step 3 instead of repeating it.
- **Failure modes table:** add a column "Graded by" (P2 / P3 / P4 / none). Rows stay the same. The table does not restate pass thresholds; it links to the gate table in `v0-grading.md`.
- **Gotchas for Cap:** keep 1–3. Add: 4. `Data.removeFirst` / `insert(at: 0)` on a slice traps once reconnect runs; rebuild buffers. 5. Keep the Grok socket's unfair lock out of async contexts (`f3a68b4`).
- **Full brief link:** keep the `~/workspace/...` path, marked "(local, not in repo)."

### 3.3 `docs/knowledge/07-transcription.md`

- **Decision line:** "Grok Voice Transcribe 2.0 is the v0 engine and passed P1–P6 on the Mac (F1)." Keep "not the locked default until the bake-off" unchanged, because F8.
- **The bake-off:** add one sentence: harness-mode `system.pcm` / `microphone.pcm` is the audio the bake-off will replay; the bake-off itself is not built.
- **v0 wiring:** add that endpointing=800 is asserted in `GrokEngineTests`; point reconnect details to 08.
- No change to the vendor field ranking.

### 3.4 `docs/knowledge/06-strategic-reads.md`

- **The sequence (locked):** step 2 becomes "Build the proven base — v0 transcript foundation GREEN (`95837a8`); notes and judgment brief next." Steps 1 and 3 unchanged.
- **The v0 slice:** change the approval-wait status to past tense: approved 2026-09-22, built, graded green. Link `09-v0-shipped.md`.
- **The 5 open gaps:** gap 1 (capture reliability) gets a status sub-bullet: capture health checks and loud failures shipped in v0; encrypted retention and file import not built.
- Everything else unchanged.

### 3.5 `docs/knowledge/09-v0-shipped.md` (new)

The one page that records what v0 is and how it was proven. Short.

- **What shipped:** F3, F4, F5 in three bullets, each linking to its 08 section. F9 as a "not built" list.
- **Evidence:** F1, F2, the confirmed inputs from §2, and the rule that only a Mac `grade.json` / board with P1–P6 `pass` counts.
- **How it was graded:** narrative only. LaunchServices-launched signed app → harness gates → `grade.py` → `grade.json` per gate → `cua-driver` collects the board. Links to `../qa/v0-grading.md` for how to run it; nothing about thresholds.
- **Process rules (L1–L4):** stated as rules going forward, each with a one-line reason from the v0 climb (for example, L2: the P3 reconnect fixes `8f4b110` → `005264d` landed one per commit, so each red Mac run pointed at one change). Cap confirms each reason before it is written.
- **Future link:** one line, "Feature map: TBD (FEATURE_MAP, not authored here)." No link target until it exists.

### 3.6 `docs/knowledge/00-product-one-liner.md`

- One line under "The 10x lever" or at the end: v0 transcript foundation shipped; Jev is not yet in the pipeline (the spike result stands on its own). Nothing else.

### 3.7 `docs/qa/v0-grading.md` (narrative only)

- **Intro:** keep "v0 stays red until…" as the rule. Add a "Last green run" line: `95837a8`, date, CDHash, board path or committed evidence path (per §2). Any later code change needs a new Mac run.
- **New short section — Autonomous grading:** `cua-driver` can drive the six gates end to end and write `board.json`; the per-gate `grade.json` is still the verdict. Describe only what §2 confirms.
- **P3 row text:** fix the operator note to match F4 (backoff 1, 2, 4, 8, 16 s, capped at 30 s). The pass condition column does not change.
- **What a pass is not:** add L4 in words: a Linux VM `swift test` or a VM-only harness run is not P1–P6.
- Not touched: the gate table's pass column, `grade.py` behavior, the run layout, the setup steps.

### 3.8 `docs/qa/v0-diagnostics.md`

- Intro: same "Last green run" pointer as 3.7 (one line).
- Cause table: no row changes. If Cap confirms, add one row for a P4 failure caused by a resting-mic DC offset on a pre-`95837a8` build ("upgrade; fixed by AC RMS"). Otherwise leave it.

### 3.9 `docs/proven-better-new.md`

- **What we're testing, in order:** item 2 splits the same way as the vision: "2a. Can we capture reliably and loudly? DONE — v0 foundation green. 2b. Is the 2-second judgment brief the heat? (v0 catcher, next.)" Items 1, 3, 4 unchanged.
- **Our PBN / Better:** add "loud capture — never a silent blank session" as a shipped Better item, since it is the anti-Granola property v0 proves. No other changes.

### 3.10 `README.md` (repo map only)

- Add `docs/qa/v0-diagnostics.md`, `docs/knowledge/08-capture-layer.md`, `docs/knowledge/09-v0-shipped.md`, and `docs/plans/`. Add one status line: "v0 transcript foundation: green on Mac at `95837a8`."

### 3.11 Not changed (reviewed, nothing catcher-relevant)

`01-consumer-wedge.md`, `02-granola.md`, `03-jev.md`, `04-always-on-space.md`, `05-wispr-flow-notetaker.md`, `granola-baseline.md`, `jev.md`, `pincus-tan-takeaways.md`, `pincus-tan-transcript.md`, `docs/plans/v0-catcher.md`, `docs/plans/v0-stage-diagnostics.md` (historical plans, left as written).

## 4. Risks

- **Overclaiming v0.** The vision's old v0 included Jev and the brief. If the split in 3.1 / 3.9 is worded loosely, readers will think the brief exists. Every "shipped" sentence names the transcript foundation.
- **Evidence that disappears.** The board lives in `/tmp` on one Mac. If §2.2 says "reference only," the docs cite a path that will vanish. Record the full SHA, CDHash, and date either way.
- **Docs taking over the gates.** Restating thresholds in 08 or 09 creates a second source that drifts from `grade.py`. Only `v0-grading.md`'s gate table states pass conditions; everything else links to it.
- **Unconfirmed `cua-driver` details.** Nothing about it is in git. Writing more than §2.3 confirms would be invented.
- **P4 misread as capture proof.** Keep F6 next to every mention of the P4 pass.
- **Stale local paths.** `~/workspace/...` briefs and research notes are not in the repo; label them, don't delete them.
- **Green is per-SHA.** Any later catcher commit is un-graded until the next Mac run; the "Last green run" line says so.

## 5. Out of scope

- Any change under `catcher/` (verifier, engine, harness, `grade.py`, `trace.py`, `run.sh`, fixtures).
- Changing any gate definition or pass threshold.
- Authoring FEATURE_MAP (09 gets a "TBD" line only).
- Describing v1, v2, notes, Jev integration, or the brief beyond "not built."
- Committing `board.json` or fixture files without Cap GO.
- Rewriting market research docs (01–05) or the transcript.

## 6. IMPLEMENT done-check

1. `git diff --stat 95837a8` touches only the files in §3.1–§3.10 plus this plan.
2. The pre-refresh capture verdict and the pre-refresh approval-wait status are gone from the refreshed docs.
3. `rg -n "1, 2, 4, 8 s" docs/qa/` returns nothing, and the P3 pass column is byte-identical to `95837a8`.
4. Every relative link in the changed files resolves (`rg -o '\]\(([^)#]+)' docs README.md` checked against the tree).
5. `rg -n -i "v1|v2" <changed files>` shows no new claims beyond the existing phase lines.
6. One commit per file group (vision + PBN, knowledge, QA, README) so Cap can review or revert each.
