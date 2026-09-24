# QA rig self-test

The rig grades a product tip only after this self-test is GREEN on the known-good build. Re-run it after every rig change.

Known-good tip: `b14e31a` (`b14e31a99a431e5cac6a49669f5c1955de38a1d1`), CDHash `57250034b55e54e3ad6798983edf6e62c1553653`.

## Run

On the grading Mac, from the harness branch:

```bash
git worktree add /tmp/catcher-b14e31a b14e31a99a431e5cac6a49669f5c1955de38a1d1
( cd /tmp/catcher-b14e31a/catcher && ./scripts/build-app.sh )
# Confirm CatcherGitSHA and CDHash before anything is graded.
export CATCHER_APP=/tmp/catcher-b14e31a/catcher/build/Build/Products/Debug/Catcher.app
export XAI_API_KEY=...
export CATCHER_ALLOW_PF=1
export CATCHER_ALLOW_TCC_RESET=1
./catcher/harness/run.sh board --self-test \
  --expect-sha b14e31a99a431e5cac6a49669f5c1955de38a1d1 \
  --expect-cdhash 57250034b55e54e3ad6798983edf6e62c1553653 \
  /tmp/catcher-auto
```

The command prints the run directory. Paste that directory's `board.md`.

GREEN requires a passing preflight, `v0-verdict.json` GREEN, every `rig_obs.json` tag `ok`, no orphan survivor, and no `afplay` line whose token is not `RAISE OK`. A build whose SHA or CDHash does not match the `--expect-*` values is `invalid (wrong build)`, which is neither RED nor GREEN. A rebuilt tree of `b14e31a` may not reproduce CDHash `57250034`; the original binary, if it is still on the Mac, is the baseline that matches the recorded grade.

P2 runs last and revokes Screen Recording. The script cannot restore it. The board's P2 obs records `regrantRequired`. The next preflight stays red until Screen & System Audio Recording is granted again for `com.catcher.app`.

P6 plays the fixture through the speakers and does not ask anyone to talk. If the microphone does not hear the speakers on this Mac, P6 fails the existing mic bar. That is a host fact, not a threshold change.

## What the board quotes

`board.json` fields are `{"value", "source"}`. A missing source is `not-observed`. `board.md` is generated from `board.json`. P3's row carries `ruleset`, `anchor`, `statesKilled`, `statesLeft`, the mid-hold `samples` (`dropsIn`, `dropsOut`, `peers443`), and the one `block` tag. Each cited log is stored with its byte length and sha256.

## Fault switches

`CATCHER_RIG_FAULT` is harness-only. Each value is its own short run:

| Value | What it shows |
|---|---|
| `bad-preflight` | The board appends a harness FAIL line, writes the board, and creates no gate directory. |
| `stray-instance` | The opening sweep must have killed at least one orphan, or the board stops. |
| `kill-before-play` | The gate kills Catcher after launch and before `afplay`. The probe writes `NO_PROCESS` and the ledger gains no `action=play` line. |
| `wrong-anchor` | P3 loads the block into `catcher-unevaluated`, which the main ruleset does not evaluate. The tag is `no-drops` and P3 is `invalid`. |

Linux `python3 -m unittest discover -s catcher/harness/tests` covers the grader, the pf text parsers, orphan matching, and board composition. It is not the self-test.
