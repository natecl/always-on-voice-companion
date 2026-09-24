# P1–P6 harness

Run on a physical Mac after `catcher/scripts/build-app.sh`. The harness rejects an ad-hoc `Catcher.app` and a hardened one without `com.apple.security.device.audio-input`. It launches the app through LaunchServices (`NSWorkspace.openApplication` when `open` has no `--env`) so `com.catcher.app` is its own TCC responsible process and the harness environment still arrives. A direct exec from the shell would bill the microphone to Terminal and Catcher would never appear in the Microphone pane. The full checklist, artifact paths, and the meaning of each gate are in [`docs/qa/v0-grading.md`](../../docs/qa/v0-grading.md). A P1 session with no `system.pcm` means no system frames were emitted.

```bash
export CATCHER_APP=/path/to/Catcher.app
export XAI_API_KEY=...          # P1, P3, P6
./harness/run.sh preflight /tmp/catcher-pre   # before any gate; see docs/qa/v0-diagnostics.md
./harness/run.sh board /tmp/catcher-auto      # preflight first; a FAIL writes the board and stops
# self-test of the known-good tip, after CATCHER_APP points at that build:
./harness/run.sh board --self-test \
  --expect-sha b14e31a99a431e5cac6a49669f5c1955de38a1d1 \
  --expect-cdhash 57250034b55e54e3ad6798983edf6e62c1553653 \
  /tmp/catcher-auto
```

A single gate still runs with `run.sh p1 <dir>` (and p2–p6 the same way). It refuses to start unless `CATCHER_PREFLIGHT_REPORT` names a `preflight.txt` whose last line is `PREFLIGHT RESULT PASS` and, when `CATCHER_PREFLIGHT_CDHASH` is set, that file's `preflight_cdhash.txt` matches. `CATCHER_NO_PREFLIGHT=1` skips the check and the board will not call the run GREEN. P2 also needs `CATCHER_ALLOW_TCC_RESET=1`. P3 needs `CATCHER_ALLOW_PF=1` and calls `sudo -n /sbin/pfctl` (or `/sbin/pfctl` when already root). Nothing in the harness reads stdin.

`board` is the run that writes `board.json`. It sweeps orphan `CatcherApp` processes first, stops on a red preflight before creating a gate directory or playing audio, then runs P1, P5, P3, P6, P4, P2. P4 mutes output and restores it. P2 revokes Screen Recording and does not wait for a re-grant; the next preflight stays red until that grant is restored by hand. Fixture audio goes through `play_fixture`, which plays only after `window_probe` prints `RAISE OK`.

Each gate script writes `harness_run.json` (host, macOS, codesign CDHash, the app's `CatcherGitSHA`) before launch, and `rig_obs.json` with what the rig itself observed. `grade.py` reports `pass`, `fail`, `invalid`, `unproven`, or `n/a` per gate; only `pass` counts, and off a Mac the best result is `unproven`. A missing `rig_obs.json`, or one whose `tag` is not `ok`, is `invalid`. `verdict` re-grades all six roots and writes `v0-verdict.json`; it is `GREEN` only for six passes on one SHA and one CDHash, and with `--preflight` only when that preflight passed. The board is GREEN only when the verdict is GREEN and the obs files agree. Evidence tiers are in [`docs/qa/v0-grading.md`](../../docs/qa/v0-grading.md#evidence-tiers). The self-test procedure is in [`docs/qa/rig-self-test.md`](../../docs/qa/rig-self-test.md). `tests/` is Tier L grader regression (`python3 -m unittest discover -s catcher/harness/tests`), not gate evidence.

Last hardened GREEN: `b14e31a` (`b14e31a99a431e5cac6a49669f5c1955de38a1d1`), CDHash `57250034b55e54e3ad6798983edf6e62c1553653`, board `/tmp/catcher-auto/b14e31a-20260923-055848/board.json`. Preflight and P1–P6 pass under this verifier (soft-pass killed). `MicrophoneGain` on the mic path; floor 0.05 unchanged; P6 p50 0.2039, micGainMax 16. Rows: [`docs/FEATURE_MAP.md`](../../docs/FEATURE_MAP.md).

`grade.json` is written into the session directory the app created under the path you passed (`<path>/<uuid>/grade.json`).

`fixtures/known-60s.wav` is a 60 s 16 kHz mono PCM16 timing carrier so `afplay` has a file. It is not a recording of `known-60s.ref.txt`. Replace the wav with a clear reading of the reference before treating P1 WER as a measurement. Until then P1 is expected to fail WER, and that failure belongs to the fixture, not to a claim that the build is green.
