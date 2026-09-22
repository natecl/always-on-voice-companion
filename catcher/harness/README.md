# P1–P6 harness

Run on a physical Mac after building `Catcher.app`. The full checklist, artifact paths, and the meaning of each gate are in [`docs/qa/v0-grading.md`](../../docs/qa/v0-grading.md).

```bash
export CATCHER_APP=/path/to/Catcher.app
export XAI_API_KEY=...          # P1, P3, P6
./harness/run.sh p1 /tmp/catcher-p1
./harness/run.sh p2 /tmp/catcher-p2          # also CATCHER_ALLOW_TCC_RESET=1
./harness/run.sh p3 /tmp/catcher-p3          # root + CATCHER_ALLOW_PF=1
./harness/run.sh p4 /tmp/catcher-p4
./harness/run.sh p5 /tmp/catcher-p5 /tmp/catcher-p1
./harness/run.sh p6 /tmp/catcher-p6
```

`grade.json` is written into the session directory the app created under the path you passed (`<path>/<uuid>/grade.json`).

`fixtures/known-60s.wav` is a 60 s 16 kHz mono PCM16 timing carrier so `afplay` has a file. It is not a recording of `known-60s.ref.txt`. Replace the wav with a clear reading of the reference before treating P1 WER as a measurement. Until then P1 is expected to fail WER, and that failure belongs to the fixture, not to a claim that the build is green.
