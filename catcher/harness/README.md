# P1–P6 harness

Run on a physical Mac after `catcher/scripts/build-app.sh`. The harness rejects an ad-hoc `Catcher.app` and a hardened one without `com.apple.security.device.audio-input`. It launches the app through LaunchServices (`NSWorkspace.openApplication` when `open` has no `--env`) so `com.catcher.app` is its own TCC responsible process and the harness environment still arrives. A direct exec from the shell would bill the microphone to Terminal and Catcher would never appear in the Microphone pane. The full checklist, artifact paths, and the meaning of each gate are in [`docs/qa/v0-grading.md`](../../docs/qa/v0-grading.md). A P1 session with no `system.pcm` means no system frames were emitted.

```bash
export CATCHER_APP=/path/to/Catcher.app
export XAI_API_KEY=...          # P1, P3, P6
./harness/run.sh p1 /tmp/catcher-p1
./harness/run.sh p2 /tmp/catcher-p2          # also CATCHER_ALLOW_TCC_RESET=1
./harness/run.sh p3 /tmp/catcher-p3          # root + CATCHER_ALLOW_PF=1; loops the fixture, no enter
./harness/run.sh p4 /tmp/catcher-p4
./harness/run.sh p5 /tmp/catcher-p5 /tmp/catcher-p1
./harness/run.sh p6 /tmp/catcher-p6
./harness/run.sh preflight /tmp/catcher-pre   # before P1; see docs/qa/v0-diagnostics.md
./harness/run.sh verdict /tmp/catcher-verdict \
  --p1 /tmp/catcher-p1 --p2 /tmp/catcher-p2 --p3 /tmp/catcher-p3 \
  --p4 /tmp/catcher-p4 --p5 /tmp/catcher-p5 --p6 /tmp/catcher-p6
```

Each gate script writes `harness_run.json` (host, macOS, codesign CDHash, the app's `CatcherGitSHA`) before launch. `grade.py` reports `pass`, `fail`, `invalid`, `unproven`, or `n/a` per gate; only `pass` counts, and off a Mac the best result is `unproven`. `verdict` re-grades all six roots and writes `v0-verdict.json`; it is `GREEN` only for six passes on one SHA and one CDHash, and it is the only v0 claim. Evidence tiers are in [`docs/qa/v0-grading.md`](../../docs/qa/v0-grading.md#evidence-tiers). `tests/` is Tier L grader regression (`python3 -m unittest discover -s catcher/harness/tests`), not gate evidence.

`grade.json` is written into the session directory the app created under the path you passed (`<path>/<uuid>/grade.json`).

`fixtures/known-60s.wav` is a 60 s 16 kHz mono PCM16 timing carrier so `afplay` has a file. It is not a recording of `known-60s.ref.txt`. Replace the wav with a clear reading of the reference before treating P1 WER as a measurement. Until then P1 is expected to fail WER, and that failure belongs to the fixture, not to a claim that the build is green.
