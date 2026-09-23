# v1 Phase 3 — notes after stop (plan only)

**Status:** slices 1–5 are in the tree on this branch. Cap GO 2026-09-23. Slice 5 adds `b3_brief.sh`, `b3_grade.py`, `b3_bake.sh`, `pasteboard_probe.swift`, and `docs/qa/v1-b3-grading.md`. The B3 entry is `./catcher/harness/b3_brief.sh <dir>` because v0 `run.sh` and `thresholds.json` stay untouched. `briefModel` remains the provisional pin `grok-4.20-0309-non-reasoning`; the keyed bake has not run. Not a B3 pass.

**v1 one-liner:** Granola mechanics, instant, zero friction, cheap enough to leave on.

**Bar this phase owns:** **B3** — shareable notes ≤ 30 s after stop.

**Cap-calls (locked):**
- The brief is a Granola-style shareable summary made of copyable blocks.
- Trigger: session stop → notes. No ambient always-record. No Jev, no interjection.

**Out of scope:** ambient always-recording, Jev and interjection (v2), the Jev judgment brief (commitments/deadlines/decisions with calibrated confidence), cost metering, the start hotkey and orb UI, and Phase 1/2 work except naming the interfaces this phase consumes. `docs/briefs/v1-better.md` is Phase 1's source of truth; this doc does not create or restate it.

**v0 stays GREEN.** The v0 catcher (`b14e31a`, CDHash `57250034b55e54e3ad6798983edf6e62c1553653`) is the foundation. IMPLEMENT adds a new target and a few new files. It adds at most one call site to existing product code (section 8). It never rewrites capture, engine, verifier, store, or harness grading logic.

Source knowledge: [`../knowledge/02-granola.md`](../knowledge/02-granola.md) (enhance loop, gray AI text linked to the transcript moment), [`../knowledge/granola-baseline.md`](../knowledge/granola-baseline.md) (auto notes, shareable output), [`v0-catcher.md`](v0-catcher.md) (session format), [`../qa/v0-grading.md`](../qa/v0-grading.md) (evidence tiers and provenance B3 reuses).

---

## 1. Pipeline (stop → brief)

```
Stop (button today; Phase 1 hotkey later)
  │  stopRequestedWallMs captured before pipeline.stop()
  ▼
Pipeline.halt → drain (≤ 400 ms budget) → end row fsync → Assembler.write
  │  events.jsonl, transcript.txt, session.json on disk      (v0, unchanged)
  ▼
SessionEnded{id, directory, stopRequestedWallMs, assembledWallMs, clean, recovered, trigger}
  │  Phase 1 interface (section 6). Until it lands, a one-line adapter in CatcherModel.toggle().
  ▼
BriefRunner (actor, one in flight per session)
  1. read   JSONLReader.read(events.jsonl) → finals + ann rows        (read-only)
  2. gate   0 finals → skipped(noSpeech);  < 25 words → skipped(tooShort)   no LLM call
  3. input  BriefInput: "s12 [them S1] 00:41 text" lines + capture caveats (gap/noAudio/blocked)
  4. call   NotesEngine.write(input) → NotesDraft (structured JSON)   hard timeout, ≤ 1 retry
  5. check  BriefValidator: schema, cite resolution, empty-block pruning, length caps
  6. write  brief.json then brief.md (atomic, sibling files; events.jsonl never touched)
  7. show   UI state → ready; Copy enabled
```

Rules:
- The brief reads v0 artifacts and never writes to them. `events.jsonl`, `transcript.txt`, and `session.json` are byte-identical before and after the brief runs. P5 compares `events.jsonl` row shapes, so a brief row in that file would break a GREEN gate.
- Only finals feed the brief. Partials are never written, so nothing else exists anyway.
- Failure is loud and never looks like success: a failed brief shows `Notes failed: <reason>` with Retry, writes `brief-error.json`, and never renders an empty notes panel as if it were done. This is the same "a blank session cannot be edited" rule the v0 verifier enforces.
- Auto-run happens for every in-process session end with ≥ 1 final, including `clean:false` ends such as a mid-session TCC revoke. In that case the notes carry a caveat such as "Recording stopped early: permission revoked". Sessions recovered at launch (`Recovery.scan`) get a **Make notes** button, not auto-run, so a launch never fires N LLM calls.
- Harness mode (`CATCHER_HARNESS=1`) disables the brief unless `CATCHER_BRIEF=1`. The v0 gates (preflight, P1–P6) therefore run the same code path they graded. Outside the harness the brief is on by default; `CATCHER_BRIEF=0` turns it off.

## 2. Summary block shape

Granola's enhanced note is a title, a short summary, topic sections of bullets, and next steps. Every AI sentence links back to the transcript. We copy that, with the v0 me/them split and no named speakers (Granola desktop is Me/Them only too).

### `brief.json` (schema `catcher.brief/1`)

```jsonc
{
  "schema": "catcher.brief/1",
  "sessionId": "…",                        // session header id
  "createdAt": "2026-09-23T11:02:07.412Z",
  "source": {
    "eventsSha256": "…",                    // hash of events.jsonl when read; grader checks it did not change
    "segmentCount": 214, "wordCount": 8120, "durationMs": 3541000,
    "clean": true, "recovered": false
  },
  "engine": { "name": "grok-notes", "model": "<pinned id>", "promptVersion": "brief-v1" },
  "latency": {                              // app-side diagnostics; the grader uses harness wall clock (section 5)
    "stopRequestedWallMs": 0, "assembledWallMs": 0, "requestStartWallMs": 0,
    "responseWallMs": 0, "writtenWallMs": 0, "attempts": 1
  },
  "usage": { "inputTokens": 11890, "outputTokens": 742 },   // copied verbatim from the API response; Phase 2 prices it
  "cost": null,                             // reserved for Phase 2; Phase 3 never fills it
  "title": "Q4 pricing review with Acme",
  "blocks": [
    { "id": "summary",   "kind": "summary",     "heading": "Summary",
      "items": [ { "text": "Acme will pilot the Team plan in October.", "cites": [41, 57] } ] },
    { "id": "topic-1",   "kind": "topic",       "heading": "Pricing",
      "items": [ { "text": "…", "cites": [12, 14] } ] },
    { "id": "decisions", "kind": "decisions",   "heading": "Decisions",
      "items": [ { "text": "…", "cites": [88] } ] },
    { "id": "next",      "kind": "actionItems", "heading": "Next steps",
      "items": [ { "text": "Send the pilot contract", "owner": "me", "due": "Friday", "cites": [201] } ] }
  ],
  "caveats": [ "Transcript gap 00:41–00:47 (network)." ]
}
```

| Field | Rule |
|---|---|
| `title` | ≤ 8 words. No names unless said in the transcript. |
| `summary` block | Always present when notes are `ready`. 1–3 items. |
| `topic` blocks | 1–6, in transcript order. Each 1–5 items, each item ≤ 30 words. |
| `decisions` | Omitted when empty. Only things stated as decided. |
| `actionItems` | Omitted when empty. `owner` is `me`, `them`, or `null`. `due` is copied from the transcript or `null`, never inferred. |
| `cites` | Segment `seq` numbers from `events.jsonl`. The validator drops any cite that does not resolve and logs the count. An item that ends with no valid cite is kept, rendered without a link, and counted in `brief.log` as `uncited`. |
| `caveats` | Built by code from `ann` rows (`gap`, `noAudio`, `blocked`, `recovered`, `clean:false`), not by the model. |

This is **not** the Jev judgment brief. There are no confidence scores and no judgment claims. "Decisions" and "Next steps" are ordinary LLM extraction, the same thing Granola ships. Calibrated judgment stays v2.

### `brief.md`

`brief.md` is the exact plain-text clipboard payload (section 3), written next to `brief.json`. Its existence is the on-disk proof that the notes are shareable, and B3 reads it.

```markdown
# Q4 pricing review with Acme
Sep 23, 2026 · 59 min

## Summary
- Acme will pilot the Team plan in October.

## Pricing
- …

## Decisions
- …

## Next steps
- [ ] Send the pilot contract (me, Friday)

Notes by Catcher
```

## 3. Copy UX

The notes sit above the transcript in the session detail pane. The session that just stopped is auto-selected, so the notes appear where the user is already looking.

| State | UI | Copy |
|---|---|---|
| `writing` | "Writing notes…" with elapsed seconds | disabled |
| `ready` | Rendered blocks. Body text is gray, per Granola. Clicking a bullet scrolls the transcript to its first cited segment. | enabled |
| `failed(reason)` | Red line `Notes failed: <reason>` and **Retry** | **Copy transcript** instead |
| `skipped(noSpeech \| tooShort)` | "No speech captured" / "Too short for notes" | **Copy transcript** |
| recovered session | **Make notes** button | after ready |

- **Copy notes** (button `copyNotesButton`, ⌘⇧C) writes two pasteboard flavors in one `NSPasteboard` write. `public.utf8-plain-text` is the `brief.md` Markdown. `public.html` is the same blocks as `<h1>/<h2>/<ul>`, so Slack, Gmail, Google Docs, and Notion paste real headings and bullets.
- **Per-block copy:** a copy icon beside each heading copies that one block in the same two flavors.
- The copy payload contains no cite markers, no transcript, no capture caveats, and no cost line. Caveats stay in the UI and `brief.json`, and are shown only to the recorder.
- There is a one-line footer, `Notes by Catcher`: plain text, no link, no tracking. It is the in-product distribution hook (see [`../proven-better-new.md`](../proven-better-new.md), distribution). Cap locked it on by default (section 9). `BriefRenderer` includes it unless the caller passes `footer: false`.
- After a copy the button reads "Copied" for 1.5 s. There is no modal and no share sheet in v1.

## 4. ≤ 30 s latency budget

t0 is `stopRequestedWallMs`: the moment the user stops, taken before `pipeline.stop()`. Done is `brief.md` renamed into place with Copy enabled.

| Stage | Budget (p95) | Hard limit | Notes |
|---|---|---|---|
| halt → drain → `end` fsync → assemble | 1.0 s | — | v0 code. The drain is already bounded at 400 ms. |
| read JSONL + build input | 0.2 s | — | A 60-min session is ≈ 9k words, ≈ 12k input tokens. |
| NotesEngine request | 15 s | 22 s timeout | Output capped at 1,200 tokens. Output length, not input, drives latency. |
| retry (transport error or invalid JSON only) | — | only if ≤ 10 s elapsed since t0 | At most one retry, with the remaining budget as its timeout. |
| validate + render + atomic write | 0.3 s | — | |
| UI update | 0.3 s | — | |
| **Total** | **≈ 17 s** | **30 s** | About 13 s of headroom at p95. |

Engine choices that keep this cheap and fast:
- **Model:** xAI chat completions (`https://api.x.ai/v1/chat/completions`) with the existing `XAI_API_KEY`. This adds no new secret or vendor, and preflight already checks that key's reach and auth. Use a fast non-reasoning Grok model with structured output (`response_format` JSON schema) at temperature 0.2. IMPLEMENT pins `briefModel` and records it in `brief.json`. Before pinning, it runs a small bake-off of up to 3 candidate ids on the 60-min transcript and picks the fastest one that passes the validator 5/5. This climb pins the id on `NotesService.briefModel` and leaves v0 `thresholds.json` untouched.
- **No streaming in v1.** B3 grades total time, and whole-JSON parsing keeps the copy format reliable. Streaming blocks into the UI is a follow-up for perceived speed.
- **Long sessions:** single call up to 60k input tokens (≈ 5 h). Above that, map chunks of ≈ 30k tokens in parallel, then run one reduce call. B3 measures up to 60 min; the chunked path gets unit tests only.
- **Cost:** order of 12k input + 0.8k output tokens per meeting hour, which is cheap enough to leave on. Phase 3 records `usage` only; pricing is Phase 2's.

## 5. Mac prove for B3

B3 follows the v0 evidence rules. A B3 pass is a Mac harness run with provenance (`harness_run.json`, signed app, `CatcherGitSHA`, CDHash) and a real engine. `swift test`, CI, and stub-engine runs are Tier L and never B3 evidence ([`../qa/v0-grading.md`](../qa/v0-grading.md), evidence tiers).

### Gate B3

`run.sh b3 <dir>` with `CATCHER_BRIEF=1`, `CATCHER_ENGINE=grok`, `CATCHER_NOTES_ENGINE=grok`, and `XAI_API_KEY`.

**B3a — live stop → notes, 3 sessions:**
1. Launch through LaunchServices as v0 does. Auto-record, play `known-60s.wav`.
2. Stop without quitting. The primary trigger is `cua-driver` clicking `recordButton`, the real user path (or Phase 1's stop hotkey once it exists). The scripted fallback is `SIGUSR1`, which means "stop recording, stay up" in harness mode only. The harness writes `stopSentWallMs` right before it sends the stop.
3. The harness polls the session directory every 100 ms for `brief.md` and records `observedWallMs`.
4. `cua-driver` clicks `copyNotesButton`. The harness reads the plain-text flavor with `pbpaste` and the flavor list with a compiled `pasteboard_probe.swift` (the same pattern as `launch_services.swift`).
5. Repeat for 3 sessions in one app run, then SIGTERM.

**B3b — long transcript, brief stage only, 3 runs:** a `brief-bench` executable target runs `BriefRunner` with `GrokNotesEngine` against a committed 60-min `events.jsonl` fixture on the same Mac and build. It records per-run stage time. This needs a new fixture, which needs Cap GO under L3 (section 9).

**Pass (every check, per session):**

| Check | Condition |
|---|---|
| `latency` | `observedWallMs − stopSentWallMs ≤ 30000` for all 3 B3a sessions (grade the max, report p50). |
| `long` | `max(B3b stage) + max(B3a stopSent→assembledWallMs) ≤ 30000`. |
| `schema` | `brief.json` parses as `catcher.brief/1`; `summary` block present; ≥ 1 item total. |
| `cites` | ≥ 1 item with a cite; every stored cite resolves to a `seg.seq` in `events.jsonl`. |
| `shareable` | `brief.md` non-empty and equal to `render(brief.json)` (`b3_grade.py` re-renders with the reference renderer). |
| `copy` | `pbpaste` output == `brief.md`; `public.html` present on the pasteboard. |
| `untouched` | `sha256(events.jsonl) == source.eventsSha256`; `session.json` and `transcript.txt` unchanged from the moment `end` was written (hashes taken by the harness at `assembledWallMs`). |
| `engine` | Notes engine is not `stub`, since a stub cannot prove B3. The transcript header engine is Grok. |
| `provenance` | Same rules as v0 `grade.py`: Mac, macOS ≥ 15, signed, SHA and CDHash match, session newer than the harness start. |

Results use the v0 vocabulary: `pass` / `fail` / `invalid` / `unproven`. If the network is down at stop, the result is `invalid` (re-run), not a product fail. The app must still show `Notes failed` loudly; the grader checks for `brief-error.json` in that case.

**v0 regression:** the IMPLEMENT PR also re-runs preflight and P1–P6 (`run.sh verdict`) on the same SHA and CDHash as B3. v0 GREEN on the new SHA plus B3 `pass` is the only claim that lets FEATURE_MAP flip a Phase 3 row.

### Tier L (regression only, runs in CI)

- `Tests/BriefTests`: input builder (seq, me/them, gap caveats), validator (bad cites dropped, empty blocks pruned, caps), renderer golden files (Markdown and HTML), runner with a fake engine (timeout, one retry, no retry after 10 s, skip rules, single-flight), `StubNotesEngine` determinism, and "never writes `events.jsonl`" using a read-only session directory.
- `catcher/harness/tests/test_b3_grade.py` runs synthetic sessions through every B3 check, pass and fail.

## 6. Interfaces

### Phase 1 → Phase 3: session end (consumed; Phase 1 owns it)

Phase 3 needs exactly this from Phase 1. If Phase 1 names it differently, Phase 3 adapts; the fields are the contract.

```swift
public enum StopTrigger: String, Sendable { case button, hotkey, harness, blocked, failure }

public struct SessionEnded: Sendable, Equatable {
    public let sessionID: String
    public let directory: URL          // events.jsonl, transcript.txt, session.json already written
    public let stopRequestedWallMs: Int
    public let assembledWallMs: Int
    public let clean: Bool
    public let recovered: Bool
    public let trigger: StopTrigger
}
// Emitted once per session, after `end` is fsync'd and Assembler.write returns.
// Not emitted when the session never opened (store/engine/permission gating failure).
```

Until Phase 1 lands, a temporary adapter lives in `CatcherModel.toggle()`. It captures `stopRequestedWallMs` before `pipeline.stop()`, then builds `SessionEnded` from `pipeline.sessionDirectory` and `session.json` once `stop()` returns. It misses verifier-initiated halts (blocked, store failure), which do not go through `toggle()`. That gap is acceptable until Phase 1 provides the real event. Phase 1 owns stop semantics, including any flush grace for the last utterance (see risks).

### Phase 3 → Phase 2: cost footnote (named only; not implemented)

- `brief.json.usage` holds `{inputTokens, outputTokens}` copied from the API response, plus `engine.model`. That is everything Phase 2 needs to price a brief.
- `brief.json.cost` is reserved and always `null` from Phase 3.
- The renderer takes an optional `BriefFootnote?`. It is `nil` in Phase 3 and nothing renders. Phase 2 decides whether a cost line appears in the UI; the copy payload never includes it.

## 7. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Last utterance cut at stop (400 ms drain; final arrives ≈ 800 ms after speech, `endpointing=800`) | Notes miss the closing "so I'll send it Friday" | Phase 1 owns stop semantics. Phase 3 records `wordCount` so a truncation is measurable. Do not change `Pipeline` drain in this phase. |
| LLM invents facts or owners | Shareable notes carry false claims | Cites required; validator drops unresolvable cites; owner limited to me/them/null; `due` copied, never inferred; temperature 0.2; prompt forbids names not in the transcript. |
| Model latency variance or outage | B3 fails; blank notes | 22 s timeout, one bounded retry, loud `Notes failed` + Retry + Copy transcript. Network-down is `invalid` in grading, but the loud path is still checked. |
| Pinned model id deprecated | Brief breaks silently after an xAI change | Model id in `thresholds.json` and `brief.json`; HTTP 4xx on model is a loud failure; preflight gains a notes-model reach check in IMPLEMENT. |
| Touching v0 owner paths | v0 rows go stale | New `Brief` target; `SessionPaths` extended from inside `Brief`, not edited; one call site in `CatcherApp.swift`; no edits to `Pipeline`, `SessionStore`, `Verifier`, engines, `grade.py`, `verdict.py`. Full v0 verdict re-run on the IMPLEMENT SHA. |
| Brief writes into the session and breaks P5 shape | v0 regression | Brief never writes `events.jsonl`; B3 `untouched` check; Tier L read-only-directory test. |
| Harness exit races the brief | B3 measures nothing | B3 stops with the button or `SIGUSR1` (stay up); SIGTERM only after the last `brief.md`. v0 gates run with the brief off. |
| Privacy: transcript text leaves the Mac | Contradicts the training-off / local-first front door | Same vendor that already receives the audio; `CATCHER_BRIEF=0` kill switch; IMPLEMENT records xAI API data-retention and training terms in `docs/knowledge/`. Local notes models are a later bake-off. |
| Clipboard HTML differs per paste target | Headings flatten in some apps | Plain-text Markdown is always present; HTML uses only `h1/h2/ul/li/p`; manual paste check into Slack, Gmail, Docs, Notion recorded once (not a gate). |
| Long-transcript fixture needs Cap GO (L3) | B3b blocked | Ask up front (section 9). B3a can grade without it, but B3 cannot be `pass` without B3b. |

## 8. File map for IMPLEMENT (proposed)

New code only, except the one call site noted.

```
catcher/
  Package.swift                          # + target Brief (deps: SessionStore, Diagnostics), + BriefTests, + brief-bench executable
  project.yml                            # CatcherApp links Brief
  Sources/Brief/
    BriefModel.swift                     # Codable Brief / Block / Item / Usage — schema catcher.brief/1
    BriefInput.swift                     # rows → numbered me/them lines + caveats from ann rows
    BriefPrompt.swift                    # system prompt + JSON schema, promptVersion "brief-v1"
    NotesEngine.swift                    # protocol: write(BriefInput, timeout:) async throws -> NotesDraft
    GrokNotesEngine.swift                # xAI chat completions, structured output, XAI_API_KEY
    StubNotesEngine.swift                # deterministic blocks with valid cites; Tier L only
    NotesEngineFactory.swift             # CATCHER_NOTES_ENGINE=grok|stub; the only place engines are named
    BriefValidator.swift                 # schema, cite resolution, pruning, caps
    BriefRenderer.swift                  # Brief → Markdown and HTML; one renderer for disk, clipboard, grader golden
    BriefPaths.swift                     # extension SessionPaths: brief.json, brief.md, brief-error.json, brief.log
    BriefWriter.swift                    # atomic writes; brief.md last; never opens events.jsonl for writing
    BriefRunner.swift                    # actor: SessionEnded → state stream; budget, retry, single-flight, skip rules
    SessionEnded.swift                   # only if Phase 1 has not landed; moves to Phase 1's module when it does
  Sources/BriefBench/main.swift          # B3b: runs BriefRunner on a fixture events.jsonl, prints stage ms as JSON
  Sources/CatcherApp/
    Views/NotesView.swift                # states from section 3, Copy, per-block copy, Retry, Make notes
    Clipboard.swift                      # one NSPasteboard write, plain + HTML
    CatcherApp.swift                     # the one call site: SessionEnded adapter in toggle(), select stopped session,
                                         #   harness SIGUSR1 = stop and stay up (only with CATCHER_HARNESS=1 and CATCHER_BRIEF=1)
    Views/SessionListView.swift          # hosts NotesView above the transcript
  Tests/BriefTests/                      # section 5, Tier L
  harness/
    b3_brief.sh                          # B3a flow; stopSentWallMs, observedWallMs, hashes, pbpaste
    pasteboard_probe.swift               # prints pasteboard types as JSON
    b3_grade.py                          # B3 checks → grade.json {B3: …}; imports load_harness_run/provenance_checks from
                                         #   grade.py; if its Gate type will not take B3, copy the checks, do not edit grade.py
    tests/test_b3_grade.py
    run.sh                               # + b3 case (additive)
    thresholds.json                      # + b3LatencyMs 30000, briefTimeoutMs 22000, briefRetryCutoffMs 10000, briefModel
docs/
  qa/v1-b3-grading.md                    # how QA runs B3; gate table is the source of truth for B3 pass conditions
  FEATURE_MAP.md                         # flip Phase 3 rows only with B3 pass + v0 verdict GREEN on one SHA/CDHash
```

Build order (one change per Mac QA cycle, per L2):
1. `Brief` model, input, validator, renderer, stub engine, and Tier L tests. No app wiring.
2. `GrokNotesEngine` and the model bake-off. Pin `briefModel`.
3. `BriefRunner`, writer, and paths. `brief-bench` against the long fixture (B3b).
4. App wiring: adapter, NotesView, Clipboard, SIGUSR1 harness stop.
5. `b3_brief.sh`, `b3_grade.py`, and the grading doc. Mac run: B3 plus the full v0 verdict on one SHA.

## 9. Cap decisions (locked 2026-09-23)

1. **Long fixture.** Synthetic `catcher/harness/fixtures/known-60min.events.jsonl`, generated by `generate_known_60min.py` (seed 20260923). Not a real recording.
2. **Footer on.** `BriefContract.footer` is `Notes by Catcher`. The copy renderer includes it by default.
3. **Caveats out of the copy.** They live on `BriefInput.caveats` and `brief.json`. Markdown and HTML omit them.
4. **Recovered sessions are manual.** `BriefLaunchPolicy.runMode(recoveredAtLaunch:)` is `.manual` for a launch recovery. No auto-run.
5. **Vendor is xAI.** `NotesService.completionsURL` is `https://api.x.ai/v1/chat/completions`, key `XAI_API_KEY`. No new secret. `GrokNotesEngine` is that client. `briefModel` is pinned on `NotesService`, not in v0 `thresholds.json`.

`BriefLaunchPolicy.notesEnabled` is false when `CATCHER_HARNESS=1` unless `CATCHER_BRIEF=1`. The app does not call it yet. Slice 4 wires it, so v0 gates stay on today's path. `brief-bench` also refuses to run unless `CATCHER_BRIEF=1`.

### Bake-off status (slice 2)

Candidates, at most three:

1. `grok-4.20-0309-non-reasoning` — pinned on `NotesService.briefModel`. It is the only model on the xAI price list (2026-09-23) documented as non-reasoning.
2. `grok-4-fast-non-reasoning` — not called. The current docs alias this name to reasoning `grok-4.3`.
3. `grok-4-1-fast-non-reasoning` — not called, for the same reason.

A live 5× timing run did not happen: this environment has no `XAI_API_KEY`. `brief-bench bake` exits `missingAPIKey`. With a key: `CATCHER_BRIEF=1 brief-bench bake catcher/harness/fixtures/known-60min.events.jsonl --out <dir> --runs 5`. The selector keeps the fastest model that passes the validator on every run, and drops a response whose model id is `grok-4.3` or otherwise reasoning.

A stub-engine pass of the same fixture on this Linux VM (not B3 evidence) reported stage times of read 62 ms, request 4 ms, validate 1 ms, write 36 ms, total 103 ms. The fixture file was not modified.

Slice 4 is in the tree: `NotesView`, the clipboard payload (`public.utf8-plain-text` and `public.html` in one declare), the `toggle()` adapter, and SIGUSR1 (stop and stay up, only when `CATCHER_HARNESS=1` and `CATCHER_BRIEF=1`). SIGTERM is unchanged. None of this is Mac-graded.

Slice 5 is in the tree: `b3_brief.sh` (the B3 entry; v0 `run.sh` is not extended), `b3_grade.py` (the 30000 ms bar lives here, not in `thresholds.json`), `pasteboard_probe.swift`, `b3_bake.sh` (keyed 5× bake; refuses without `XAI_API_KEY` and does not change the pin), and `docs/qa/v1-b3-grading.md`. None of this is Mac-graded. The keyed bake-off is still required before Cap arms B3. This environment has no `XAI_API_KEY`, so `b3_bake.sh` exits 2 and the pin stays provisional.

## 10. Done-check for this plan's IMPLEMENT climb

IMPLEMENT is done when all of the following hold:
- One Mac run at one SHA and CDHash produces a B3 `grade.json` with `result: pass` and a `v0-verdict.json` `GREEN`.
- `docs/qa/v1-b3-grading.md` lets QA reproduce the B3 run without the builder.
- The Phase 3 rows in [`../FEATURE_MAP.md`](../FEATURE_MAP.md) carry that SHA, CDHash, and board.

Until then B3 is ungraded and v1 Phase 3 is not shipped.
