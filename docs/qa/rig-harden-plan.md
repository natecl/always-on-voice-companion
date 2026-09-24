# QA rig hardening plan (v1 Recovery Brief §5)

**Status:** IMPLEMENTED on this branch. The Mac self-test on `b14e31a` has not been run. Procedure: [rig-self-test.md](rig-self-test.md).

**Base:** `main` @ `10db5451909ea3ed8f27a4b9ebe6b18df7f62159` (frozen). Not built on PR #14 (`cursor/p3-pfctl-sudo-n-54bb` / `eb9a396`); nothing is cherry-picked from it. Its harness ideas (packet-count fail-gate, durable obs files, `sudo -n` for pfctl) are redone below from `main`. Its five product files are dropped (Nathan veto).

**Goal:** a board of the known-good tip `b14e31a` (`b14e31a99a431e5cac6a49669f5c1955de38a1d1`, CDHash `57250034b55e54e3ad6798983edf6e62c1553653`) run by the hardened rig goes GREEN (preflight + P1–P6), and the rig's fail-closed properties are shown by what it wrote to disk. No product tip is graded before that.

**Scope:** `catcher/harness/**` and `docs/qa/**` only. `catcher/Sources/**`, `catcher/Tests/**`, `Package.swift`, `project.yml`, and `.github/**` are not touched. The scope check before every GO:

```bash
git diff --name-only 10db5451909ea3ed8f27a4b9ebe6b18df7f62159...HEAD \
  | grep -vE '^(catcher/harness/|docs/qa/)'   # must print nothing
```

## What the rig is today

The harness and product sources at `main` are byte-identical to `b14e31a` (only README lines differ), so today's harness is exactly the one that graded the known-good tip. The failures in the brief map to these lines:

| Failure (brief §0) | Where it is at `main` |
|---|---|
| Gates ran after a red preflight | There is no board runner in the repo. `run.sh` runs one gate per call and never checks preflight; `/tmp/catcher-auto/…/board.json` was written by an out-of-repo script. `verdict.py` does not read `preflight.txt` at all. |
| `afplay` fired with Catcher dead | `p1_known_audio.sh:12-13` (`sleep 2; afplay`), `p5_stub.sh:12`, `p6_two_track.sh:12`, `p3_net_kill.sh:33` loop. `launch_catcher` only waits for `catcher.pid`, which the app writes in `init` before any window exists. |
| Interactive stdin | `p2_tcc_revoke.sh:32` and `p4_silence.sh:10` (`read -r _`); `preflight.sh:43` (`open -n -W`). |
| Orphan CatcherApp | Nothing kills stale instances. P1/P4/P6 send `kill` (SIGTERM) and move on; `HarnessShutdown` then keeps recording up to 30 s, so the next gate's launch overlaps it. |
| pf never loaded, 0 states killed, VALID with 0 gap | `p3_net_kill.sh:60` loads into top-level anchor `catcher`, which stock `pf.conf` never evaluates; pf may be disabled; `pfctl -k 0.0.0.0/0 -k <ip>` kills nothing on Darwin; kills are backgrounded and errors are dropped (`>/dev/null 2>&1`); nothing proves a packet was dropped. `grade.py` P3 grades gaps without any rig-side evidence the block was real. |
| Obs truncated on cleanup | P3 evidence is stdout only; `trace.py` output goes to the terminal; nothing is written that a board can paste. |

## Design choices

1. **One in-repo board runner.** New `board.sh` is the only entry that can produce a board. It owns the run dir `/tmp/catcher-auto/<short-sha>-<yyyymmdd-hhmmss>/`, the gate order, stdin, timeouts, and the final `board.json` / `board.md`. `run.sh <gate>` stays for single-gate debugging but refuses to run without a passing preflight from the same CDHash (override `CATCHER_NO_PREFLIGHT=1`, which marks the run not GREEN-eligible).
2. **The window gate is observed from outside the app.** At this base the product writes no window stamp, and adding one is product scope (that was #14's `CatcherApp.swift` change). A harness helper reads the window server instead: `CGWindowListCopyWindowInfo` returns owner pid, layer, alpha, on-screen flag, and bounds without Screen Recording (only `kCGWindowName` needs it), and `NSWorkspace.frontmostApplication` gives the front pid. The harness writes `window_front` itself, with `source=harness-cgwindowlist`, so a reader can tell it apart from an app stamp.
3. **Every gate gets a rig-evidence premise.** Each gate root gets `rig_obs.json`. `grade.py` adds one premise check per gate that reads it; missing file or a non-`ok` tag makes the gate `invalid`, never `pass`. Existing product checks and thresholds do not change, so on `b14e31a` the only new ways to lose a pass are "the rig did not observe the premise".
4. **Parsers are Python modules, not heredocs.** pfctl / lsof / states parsing moves into `pf_obs.py` so the Linux CI job (`harness-grader`, auto-discovers `tests/test_*.py`) can test it on captured text. No workflow change is needed.
5. **Gate order puts destructive gates last:** preflight → P1 → P5 (uses P1 as shape reference) → P3 → P6 → P4 → P2. P4 mutes output after P6 has used the speakers; P2 revokes Screen Recording, so nothing that captures runs after it.

## §5 property → files

### 1. Red preflight stops the run immediately

- `board.sh`: orphan sweep, then `run.sh preflight <run>/preflight`. If the last line of `preflight.txt` is not `PREFLIGHT RESULT PASS`, call `board.py compose --stopped preflight` and exit 1. No gate dir is created and `play_fixture` is never reachable.
- `preflight.sh`: drop `-W` (see property 4). Bounded wait (40 s) for the RESULT line; on timeout, SIGKILL only the preflight instance (match executable + `--preflight` + this session root) and append `PREFLIGHT preflight-finish FAIL error=no-result source=harness`. Lines the harness writes carry `source=harness`; lines the app writes do not, so the board can say which is which.
- `lib.sh`: `require_preflight_pass <report> <cdhash>` used by every `pN` script (and by `run.sh`), so a hand-run gate cannot skip it either.
- `verdict.py`: optional `--preflight <dir>`; when given, anything but PASS makes the verdict RED with reason `preflight <result>`. `board.sh` always passes it.
- `board.py`: stopped-at-preflight board carries the preflight lines verbatim, `gatesLaunched` counted from gate dirs on disk, and `afplayLaunched` counted from the afplay ledger (property 2), not constants.

### 2. afplay hard-gate (live, visible, front content window)

- New `window_probe.swift` (harness helper, compiled with `swiftc` into `$TMPDIR` like `launch_services.swift`; not part of `Package.swift` or the app). `window_probe <pid> <session> [--raise]`:
  - pid alive (`NSRunningApplication`, not terminated);
  - raise: `activate(options: .activateAllWindows)`; if still not front after 1 s, `NSWorkspace.openApplication(at: CATCHER_APP, createsNewApplicationInstance: false, activates: true)` (the LaunchServices activation path `launch_services.swift` already uses at launch; whether it wins focus on this macOS is part of what the self-test proves). Refuse the fallback if more than one Catcher instance is running;
  - visible: at least one on-screen window owned by the pid with layer 0, alpha > 0, bounds at least the content minimum (`thresholds.json` `rigWindowMinWidth` 720 / `rigWindowMinHeight` 520, from `ContentView.frame(minWidth:minHeight:)`);
  - front: `frontmostApplication.processIdentifier == pid`.
  - Writes `<session>/window_front` (JSON: pid, frontmost, window count, bounds, raise method, wall ms, `source`) and prints one token: `RAISE OK`, `NO_PROCESS`, `NOT_VISIBLE`, `NOT_FRONTMOST`, `MULTI_INSTANCE`.
- `lib.sh`:
  - `play_fixture <session> [--loop-guard]` is the only way to start `afplay`. Order: `wait_for_recording` (live_session or events.jsonl; the product starts recording from the content view's `.task`, so this also proves the view appeared) → `window_probe --raise` must print `RAISE OK` → append one line to `<run>/obs/afplay.log` (gate, pid, wall ms, token) → `afplay`. Any other token writes `rig_obs.json` `{"tag": "<token>"}`, and the gate exits non-zero without playing.
  - Records output volume and mute (`osascript -e 'get volume settings'`, a Standard Additions call that sends no Apple Event to another app, so no Automation prompt) in the afplay ledger line.
- `p1_known_audio.sh`, `p5_stub.sh`, `p6_two_track.sh`: replace the raw `afplay` with `play_fixture`. P1 also checks the pid is still alive after playback before `kill -9`, and records `catcherDiedDuringFixture` if it is not.
- `p3_net_kill.sh`: the loop becomes `while play_fixture "$SESSION" --loop-guard; do :; done`; the guard re-probes (no re-raise) before each pass, so the loop stops if Catcher dies.

### 3. No VALID with zero evidence

Generic: `lib.sh` `rig_obs_write <root> <json>` (write to temp, fsync, rename). `grade.py` adds `rig:evidence` as a `PREMISE_CHECK` to every gate: `<root>/rig_obs.json` must exist and its `tag` must be `ok`. Per gate, the "effect happened" the obs must show:

| Gate | Effect the rig must observe before `tag=ok` |
|---|---|
| P1 | `afplay` exit 0 with wall duration ≥ 55 s; Catcher alive at the end of playback; `kill -9` hit that pid; relaunch wrote a new `catcher.pid`. |
| P2 | `tccutil reset` exit 0; the `blocked` ann observed on the pinned live session within the grader's window (polled, not assumed). |
| P3 | Block tag `ok` (below). |
| P4 | Output mute read back as `true` for the whole hold; no `afplay` ledger line for P4. |
| P5 | Same as P1 playback, engine `stub` in the header. |
| P6 | `afplay` exit 0; output not muted and volume > 0 at start (the mic path relies on the speakers). |

P3 in `p3_net_kill.sh`, with parsing in new `pf_obs.py`:

1. Every pfctl call is `sudo -n /sbin/pfctl` via `lib.sh` `pfctl_run` (property 4). stderr is appended to `p3-pfctl.log`, never discarded.
2. `pfctl -E` (keep the token; `-X <token>` in cleanup, so a host that already had pf on stays on). Then `pfctl -s info` must say `Status: Enabled`.
3. Classify the main ruleset (`pfctl -sr`): `com.apple` (has `anchor "com.apple/*"`) → anchor `com.apple/catcher`; `catcher` (has `anchor "catcher"`) → anchor `catcher`; `empty` → load `/etc/pf.conf`, remember it, flush main rules on cleanup; anything else → tag `ruleset-foreign`, stop.
4. Peers: `lsof -nP -a -p <pid>` for TCP and UDP :443 → at least one live peer, else `no-live-peer`. Table = live peers ∪ `dig api.x.ai A/AAAA`.
5. Load the two block rules into the chosen anchor; `pfctl -a <anchor> -sr` must list both and `-t catcher_xai -T show` must list every live peer, else `rule-not-loaded`. Stamp `pfOnWallMs`.
6. Kill states per concrete pair, both directions (`-k <local> -k <remote>`), in the foreground. Record `killed N states` totals. A zero count is observability, not a failure: pf enabled mid-connection has no state to kill. The gate is `pfctl -s states` after the kills: no state left for a live peer on :443, else `state-survived`.
7. Mid-hold samples at pfOn + 2 s, + 8 s, + 14 s (`thresholds.json` `rigP3SampleMs`): anchor rules still present (else `rules-vanished`), block-drop packet totals from `-vsr` (in + out, all protos), and `lsof` :443 peers of the pid. First sample must show drops > 0 (else `no-drops`). Any ESTABLISHED :443 peer not in the table at any sample is `peer-leak`.
8. Flush rules, stamp `pfOffWallMs`, then the existing resume wait.
9. One block tag, first failure wins: `ok | sudo-denied | pf-enable-failed | ruleset-foreign | no-live-peer | rule-not-loaded | state-survived | no-drops | rules-vanished | peer-leak`. It goes in `rig_obs.json` with ruleset class, anchor, table IPs, kill counts, the three samples, and peers. The cleanup trap writes it if the script dies before step 9 (tag = the step it died in, never `ok`).
10. `grade.py` P3: the `rig:evidence` premise above, plus `rig:drops-cover-gap`: the observed drop window (first to last sample with drops) must fall inside the graded gap's `fromMs`–`toMs` mapped through `startedAt`. A gap that the rig never saw drops for is `invalid`.

### 4. Non-interactive

- `board.sh` runs every gate with `</dev/null` and through `board.py exec-gate --timeout <s>` (Python `subprocess` with a process group; macOS has no `timeout(1)`). A timeout kills the group and writes `rig_obs.json` `{"tag": "timeout"}`. Budgets in `thresholds.json` `rigGateTimeoutS`.
- `p2_tcc_revoke.sh`: remove `read`. After `tccutil reset`, poll the pinned session for the `blocked` ann (bounded, 10 s), then `stop_catcher` and grade. Record `regrantRequired: true`. The grant cannot be restored from a script (TCC.db is SIP-protected), so every full board ends with one manual re-grant; see call-outs.
- `p4_silence.sh`: remove `read`. Save `output muted`, `set volume output muted true`, read back, restore in the EXIT trap. The "stay quiet" premise is already graded (`invalid` on sustained audio).
- `p6_two_track.sh`: remove the "Speak…" prompt. The mic hears the fixture from the speakers; the grader already fails P6 if mic speech is missing.
- `preflight.sh`: `open -n` without `-W`, bounded poll (property 1).
- `pfctl_run`: `sudo -n /sbin/pfctl` unless already root. `sudo -n` exits instead of prompting; that exit is tag `sudo-denied`. `/usr/local/bin/catcher-p3-gate` is not used.

### 5. Orphan cleanup

- `lib.sh` `kill_orphans <obs-file>`: every process whose executable ends in `/Contents/MacOS/CatcherApp` (any build) and every `afplay` whose argv holds `fixtures/known-60s.wav`. SIGKILL, wait up to 5 s, re-list. Survivors → non-zero and tag `orphan-survived`. Writes pids, commands, and counts.
- `board.sh` calls it before preflight and before each gate; each call appends to `<run>/obs/orphans.jsonl`.
- `lib.sh` `stop_catcher <session>`: SIGTERM, wait up to 35 s (covers `HarnessShutdown`'s 30 s live tail), then SIGKILL; records `exited|killed` in the gate's obs. P1, P4, P5, P6, P2 use it instead of a bare `kill`. P3 already waits; it switches to the same helper.

### 6. Durable observability

- Layout under the run dir: `obs/` (board-level: `orphans.jsonl`, `afplay.log`, `board-env.json` with harness SHA, app path, CDHash, macOS), `<gate>/rig_obs.json`, `<gate>/gate.log` (full stdout+stderr via `tee`, including `trace.py`), P3's `p3-*.txt` raw captures. No cleanup path deletes anything under the run dir; the only file removed is the temp pf rule file.
- `board.py compose` embeds each `rig_obs.json` verbatim and, for every log it cites, byte length and sha256, so a truncated paste is detectable.
- P3 fields named in the brief, all in `p3/rig_obs.json` and in the board: `ruleset`, `anchor`, `statesKilled`, `statesLeft`, `samples[].dropsIn/dropsOut`, `samples[].peers443`, `block` (the one tag).

### 7. Scoreboards report what was observed

- New `board.py`. Every board field is `{"value": …, "source": "<path relative to run dir>"}`. A missing or unparsable source is `"not-observed"`, and any `not-observed` field in a gate row makes that row not `pass`.
- `board.json` verdict is GREEN only when: preflight PASS (from `preflight.txt`), `verdict.py` GREEN (re-grade, not `grade.json`), every `rig_obs.json` tag `ok`, zero orphan survivors, and the afplay ledger shows no launch that was not preceded by `RAISE OK`.
- `board.md` is the paste-ready table (gate, result, block/rig tag, key obs, source path). It is generated from `board.json` only.
- `--self-test` mode: `--expect-sha b14e31a99a431e5cac6a49669f5c1955de38a1d1 --expect-cdhash 57250034b55e54e3ad6798983edf6e62c1553653`. A different build is `invalid (wrong build)`, not RED or GREEN. The board also records `harnessGitSHA` so the rig revision is part of the claim.

## Declared file list for IMPLEMENT

Modified:

- `catcher/harness/lib.sh`: `kill_orphans`, `stop_catcher`, `play_fixture`, `rig_obs_write`, `pfctl_run`, `require_preflight_pass`.
- `catcher/harness/run.sh`: `board` subcommand; preflight guard for `pN`; stdin from `/dev/null`.
- `catcher/harness/preflight.sh`: no `-W`, bounded wait, targeted kill, `source=harness` lines.
- `catcher/harness/p1_known_audio.sh`, `p5_stub.sh`, `p6_two_track.sh`: `play_fixture`, `stop_catcher`, obs.
- `catcher/harness/p2_tcc_revoke.sh`: no `read`; bounded blocked-ann poll; obs.
- `catcher/harness/p3_net_kill.sh`: steps 1–9 above.
- `catcher/harness/p4_silence.sh`: no `read`; mute save/set/verify/restore; obs.
- `catcher/harness/grade.py`: `rig:evidence` premise on every gate; P3 `rig:drops-cover-gap`.
- `catcher/harness/verdict.py`: `--preflight`; carry `rig_obs` into gate entries.
- `catcher/harness/thresholds.json`: `rigWindowMinWidth`, `rigWindowMinHeight`, `rigP3SampleMs`, `rigGateTimeoutS`, `rigPreflightTimeoutS`.
- `catcher/harness/README.md`: `board` entry point, self-test, non-root P3.
- `catcher/harness/tests/test_grade.py`, `tests/test_verdict.py`: synthetic sessions gain a `rig_obs.json` (existing pass cases stay pass); new cases for missing/non-`ok` obs → `invalid`, preflight → RED.
- `docs/qa/v0-grading.md`, `docs/qa/v0-diagnostics.md`: gate table and preflight section point at the board runner; P3 section describes anchor choice, `sudo -n`, tags.

New:

- `catcher/harness/board.sh`: the run.
- `catcher/harness/board.py`: `exec-gate` (timeout, process group) and `compose` (board.json / board.md).
- `catcher/harness/window_probe.swift`: raise / visible / front probe.
- `catcher/harness/pf_obs.py`: parsers for `pfctl -sr`, `-vsr`, `-s states`, `-s info`, `-k` output, `lsof -F`.
- `catcher/harness/tests/test_pf_obs.py`, `tests/test_board.py`: parser cases from captured macOS text; board composition (stopped-at-preflight, not-observed, wrong build, truncated log).
- `docs/qa/rig-self-test.md`: the self-test procedure and board format.

Planned commits, one logical change each, Linux tests green at every step: (1) orphan sweep + `stop_catcher`; (2) preflight bounded wait + board runner stopping on red preflight; (3) non-interactive P2/P4/P6 + gate timeouts; (4) window probe + `play_fixture`; (5) P3 pf hardening + `pf_obs.py`; (6) rig-evidence premises in `grade.py` / `verdict.py`; (7) `board.py compose` + docs.

## Self-test procedure (IMPLEMENT, one Mac arm)

1. `git worktree add /tmp/catcher-b14e31a b14e31a99a431e5cac6a49669f5c1955de38a1d1`; `catcher/scripts/build-app.sh` there. Confirm `CatcherGitSHA` and CDHash before anything runs.
2. From the IMPLEMENT branch: `CATCHER_APP=<that build> ./catcher/harness/run.sh board --self-test --expect-sha … --expect-cdhash … /tmp/catcher-auto`.
3. Expect GREEN. Paste `board.md`.
4. Fail-closed proofs, cheapest first, each its own short run with a harness-only fault switch (`CATCHER_RIG_FAULT`): `bad-preflight` (board stops, 0 gate dirs, 0 ledger lines), `stray-instance` (orphan killed and counted), `kill-before-play` (`NO_PROCESS`, no afplay), `wrong-anchor` (rules into an unevaluated anchor → `no-drops`, P3 `invalid`). Cap decides how many of these to spend Mac time on; the Linux tests cover the same logic offline.
5. Re-run step 2 after every later rig change (brief §5).

## Call-outs

**Product or Swift scope required: none, on the evidence at this base.** Stop and report instead of widening scope if any of these turns out to be true on the Mac:

- **Window not observable on `b14e31a`.** If `window_probe` cannot see an on-screen layer-0 window of the content size for Catcher's pid, or LaunchServices activation cannot make it frontmost, the fix is in `CatcherApp.swift` (what #14 did). HALT; that is product scope.
- **App-emitted `window_front` required.** This plan stamps `window_front` from the harness. If Nathan requires the app itself to stamp it, that is product scope. HALT for his call.
- **P3 red once the block is real.** If `b14e31a` fails P3 with block tag `ok` (drops observed, gap too short, or no resume), that is a product finding about the old GREEN, not a rig bug. The self-test cannot go GREEN without product work. HALT and report; do not tune thresholds to pass.

**Harness Swift, flagged for veto:** `window_probe.swift` is Swift under `catcher/harness/`, compiled standalone like `launch_services.swift`. It is not product Swift and never enters `Package.swift` or the app. If Cap reads "any product Swift" to cover harness helpers, the same probe can be written in JXA (`osascript -l JavaScript` with `ObjC.import('CoreGraphics')`).

**Host facts outside the repo (not product, but they block a non-interactive GREEN):**

- **P2 costs one manual re-grant per board.** `tccutil reset ScreenCapture com.catcher.app` removes the grant and no script can restore it. P2 runs last and the board records `regrantRequired`; the next board's preflight `tcc-screen` fails closed until Nathan re-grants.
- **P6 without a human speaker.** Non-interactive P6 relies on the fixture reaching the mic through the speakers. If that is below the grader's mic bar on this Mac, P6 needs a person talking or a hardware loopback. That is Nathan's call; the grader stays as is.
- **CDHash of a rebuilt `b14e31a`.** If the build from step 1 does not reproduce CDHash `57250034…` (same source, same cert, not guaranteed byte-identical), the self-test is `invalid (wrong build)`. Options for Nathan: the original binary if it is still on the Mac, or accept the new CDHash for the same SHA as the self-test baseline.
- **`/usr/local/bin/catcher-p3-gate`** is not in the repo and its contract is unknown. This plan does not call it; `sudo -n /sbin/pfctl` under the existing NOPASSWD rule is enough.
