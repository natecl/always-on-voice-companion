# v0 stage diagnostics

A failed or empty take writes a checkpoint for each pipeline stage, then two `TRACE` lines naming the first failure and a probable fix. These files do not grade P1–P6. `grade.py` never reads them. v0 stays red until a Mac `v0-verdict.json` is `GREEN` for the SHA (see [`v0-grading.md`](v0-grading.md)).

**Last hardened GREEN:** `b14e31a` (`b14e31a99a431e5cac6a49669f5c1955de38a1d1`) on 2026-09-23. CDHash `57250034b55e54e3ad6798983edf6e62c1553653`. Board `/tmp/catcher-auto/b14e31a-20260923-055848/board.json` on the grading Mac (not in git). Preflight and P1–P6 pass under the hardened verifier (soft-pass killed). `MicrophoneGain` on the mic path (floor 0.05 unchanged); P6 p50 0.2039, micGainMax 16. See [v0 grading](v0-grading.md).

## Where the lines go

| File | When |
|---|---|
| `<session>/stages.log` | After the session directory exists. Append-only. Fsync on every FAIL and every checkpoint. |
| `<CATCHER_SESSION_ROOT>/launch-stages.log` | Launch probe and preflight, before a session directory exists. |
| `<CATCHER_SESSION_ROOT>/preflight.txt` | `run.sh preflight`. The shell writes the `signing` line; the app appends the rest and `PREFLIGHT RESULT`. |

The harness launches through LaunchServices, which detaches stdout and stderr, so the file is the source of truth. The same line is also sent to stderr and to `os_log` subsystem `com.catcher.app` category `stage`. The log header (timestamp and pid) is only on the `os_log` copy.

```bash
grep -E '^(STAGE|TRACE)' <uuid>/stages.log
log stream --predicate 'subsystem == "com.catcher.app" AND category == "stage"'
```

Count stages are written at a 10 s checkpoint and again at close. The last line for a stage is its verdict (`api-connect` keeps one line per `track=`). A stage that was never written is `not-reached`. A FAIL at `tcc-check`, `capture-start`, or `api-connect` means later stages are not written. `zeroEnergy` is informational and leaves `pcm-extract` at OK, because P4 is a legitimate silence run. `micGain` (latest) and `micGainMax` (session high) are the microphone gain factors from `MicrophoneGain`; `1.00` means the mic track was passed through unchanged.

## Line grammar

```text
STAGE <name> <OK|FAIL> [k=v ...]
TRACE last-ok=<name|none> first-fail=<name> error="<underlying>"
TRACE cause="<probable cause>" fix="<known fix>"
PREFLIGHT <check> <PASS|FAIL> [k=v ...]
PREFLIGHT RESULT <PASS|FAIL> failed=<n>
```

The first token is `STAGE`, `TRACE`, or `PREFLIGHT`. A value that contains a space, quote, backslash, newline, tab, or is empty, is double-quoted. `"` inside it becomes `\"`, and a newline becomes `\n`. The line is capped at 1 KB. A truncated error body ends in `…(+N bytes)`.

Stage names, in order: `tcc-check`, `capture-start`, `frames-received`, `pcm-extract`, `api-connect`, `api-stream`, `segments-received`, `transcript-write`.

## Sample

This is the silence case: system audio was captured as zeros, the microphone still produced finals, and `pcm-extract` stays OK.

```text
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

On a gate failure, `run.sh` prints those two `TRACE` lines and keeps the gate's exit status. After `kill -9`, the app may not have written a trace; recompute it with:

```bash
python3 catcher/harness/trace.py /tmp/catcher-p1
```

## Preflight

Run this before P1, after `CATCHER_APP` points at the bundle from `scripts/build-app.sh`.

```bash
export CATCHER_APP="$PWD/build/Build/Products/Debug/Catcher.app"
export XAI_API_KEY=...
./catcher/harness/run.sh preflight /tmp/catcher-pre
```

Preflight runs inside `Catcher.app` launched through LaunchServices (`open -n` when `open` has `--env`, otherwise the same `NSWorkspace` helper as the gates). It does not use `open -W`. It never calls `tccutil` and never prompts. `open` does not pass the app's exit status, so `preflight.txt` is the verdict. The script exits 0 only when the last line is `PREFLIGHT RESULT PASS`. If that line is still missing 40s after launch, the harness kills that preflight process and appends `PREFLIGHT preflight-finish FAIL error=hang-after-signing` and `PREFLIGHT RESULT FAIL`. The app also starts `--preflight` without waiting for its window and writes the same line if the checks have not returned in 30s.

| Check | PASS when |
|---|---|
| `signing` | Not ad-hoc, bundle id `com.catcher.app`, audio-input present if hardened. Written by the shell. |
| `tcc-screen` | `CGPreflightScreenCaptureAccess()` is true. No prompt. |
| `tcc-mic` | `authorized`, `owns=true`, `entitlement=true`. |
| `mic-device` | A default audio input exists. Detail is `uniqueID` and name. |
| `capture-display` | A display is chosen. |
| `capture-probe` | Only when both TCC checks pass. Start and stop capture for about 1 s. |
| `api-key` | `XAI_API_KEY` is non-empty. Detail is the length, never the key. |
| `api-reach` | HEAD `https://api.x.ai/` succeeds within 3 s. |
| `api-auth` | HTTPS GET with the bearer returns 2xx. On FAIL, `http=` and a truncated `body=`. |
| `api-stt` | The STT socket receives `transcript.created` within 5 s. |

When `CATCHER_ENGINE=stub`, the four API checks print `PASS skipped=stub`.

Do not start P1 on a FAIL line. The autonomous entry is `run.sh cycle <run-dir>`. A preflight result other than `PREFLIGHT RESULT PASS` writes `<run-dir>/board.json` (`verdict` `RED`, `gatesLaunched` false, `afplay` false) and returns. P1–P6 are not launched and `afplay` does not start.

`PREFLIGHT tcc-screen FAIL` with `screen recording access denied` is a host wall (`hostWall` `screen-tcc` on that board). Cap re-arms the meta re-prove after Nathan re-grants Screen & System Audio Recording for `com.catcher.app`. The cycle does not soft-pass a Screen TCC deny. `capture-display` `no display` on the same report is recorded with it and does not start the gates.

`error=hang-after-signing` is not that wall. Screen Recording on this Mac is already granted. The board field `hangAfterSigning` is true, `hostWall` stays empty, and the cycle still stops with `gatesLaunched` false and `afplay` false. Do not read the hang as a Screen TCC deny.

Each gate launch raises the content window before it continues, and each gate that plays the fixture checks again. Audio starts only when `catcher.pid` is alive and Catcher is frontmost with its content window on screen. Under `--harness`, the app stays running until the gate stops it (it does not quit when the last window closes) and rewrites `window_front` about four times a second while that window is key, on a screen, and the app is active. The raise helper is not Catcher. A window list is not a pass. It trusts a fresh `window_front` for this pid plus `NSWorkspace` frontmost. A missing or dead pid writes `raise=NO_PROCESS`. A live pid whose window never becomes key writes `raise=NOT_VISIBLE` and `window_front=missing` (or `stale`). Both land in `raise.txt` and `blocked.json` (`result` `blocked`) and the gate exits. That is not a pass. A preflight `tcc-screen PASS` does not set `hostWall`.

The cause table below is the next action for a session trace. A preflight FAIL names the check in `preflight.txt`.

## Cause table

First match wins. `TRACE error=` is the underlying error (domain and code, OSStatus, HTTP status and body, or the xAI message), not a summary. The silence error is built from the zero-energy track, the bytes sent, and the final count.

| First FAIL | Match | Cause | Fix |
|---|---|---|---|
| `tcc-check` | `entitlement=false` | hardened build without audio-input | rebuild with `scripts/build-app.sh` |
| `tcc-check` | `owns=false` | started from a shell; TCC bills Terminal/Cursor | launch with `open -n "$CATCHER_APP"` |
| `tcc-check` | `mic=denied` | denied row for com.catcher.app | Privacy → Microphone toggle |
| `tcc-check` | `mic=notDetermined` | Allow never answered | Request microphone with Catcher frontmost; quit Zoom |
| `tcc-check` | `screen=denied` | Screen & System Audio Recording missing | grant it to com.catcher.app, relaunch |
| `capture-start` | `code=-3801` | user declined screen capture | grant Screen & System Audio Recording |
| `capture-start` | other | SCStream failed to start | copy the `domain`/`code` line into the report |
| `frames-received` | `system=0` and `microphone>0` | no system buffers on the chosen display | play audio on the captured display; check the display choice |
| `frames-received` | `microphone=0` | mic device missing or not delivered | check the default input device (preflight `mic-device`) |
| `pcm-extract` | `osstatus=-12737` | retained-block-buffer variant used | regression in `SampleBufferPCM.extract` |
| `pcm-extract` | `failed>0` and `unsupportedFormat` | SCK format changed | the `mBytesPerFrame`/format detail names it |
| `api-connect` | `missing XAI_API_KEY` | key not forwarded | `export XAI_API_KEY`; the harness forwards it |
| `api-connect` | `http=401` or `http=403` | key rejected | rotate the key; body shows the xAI reason |
| `api-connect` | `handshakeTimeout` | socket open but no `transcript.created` | check the `model=` query and xAI status |
| `api-connect` | NSURLError `-1003`, `-1009`, or `-1004` | DNS / offline / refused | network, VPN, or a leftover P3 `pf` rule (`pfctl -sr`) |
| `api-stream` | `system=0` while `pcm-extract` is OK | pump never ran (`ready=false`) | engine state bug; include the snapshot |
| `segments-received` | `apiErrors>0` | xAI returned errors mid-stream | the first error body is in `error=` |
| `segments-received` | zero-energy track and bytes sent | system track captured digital silence | nothing was playing on the captured display, or the mixdown cancelled; check `system.pcm` peak/RMS and the chosen display |
| `segments-received` | `blankDropped>0` and `system=0` | only endpoint spam came back | audio too quiet or not speech |
| `transcript-write` | `error=` present | assemble/end failed | the error names the path and errno |
| `transcript-write` | `bytes=0` and `segments=0` | nothing to write | the trace points upstream; this is a symptom |

## P3 packet filter

`catcher/harness/p3_net_kill.sh` loads and clears the `catcher` anchor only when `CATCHER_ALLOW_PF=1`. Every `pfctl` invocation in that script is `sudo -n /sbin/pfctl` (absolute path). `-n` exits when the sudoers rule is missing, so the script does not wait for a password. Those calls are required when the script is not root. In a root session they still run, and pfctl is root.

Preferred Mac invoke:

```bash
sudo -n env CATCHER_APP=… CATCHER_ALLOW_PF=1 XAI_API_KEY=… \
  ./catcher/harness/run.sh p3 <session>
```

Nathan installs a wrapper binary or script at `/usr/local/bin/catcher-p3-gate` and `/etc/sudoers.d/catcher-p3`. Sudoers allows that gate and `/sbin/pfctl`. `/usr/bin/env` is not a sudoers command: NOPASSWD on `env` can run any program.

```
n.chinlue ALL=(root) NOPASSWD: /sbin/pfctl
n.chinlue ALL=(root) NOPASSWD: /usr/local/bin/catcher-p3-gate
```

The `/sbin/pfctl` path must match the script. A different pfctl path does not match NOPASSWD. The gate path is the narrow root entry for the preferred invoke above.

Mid-session Screen Recording revoke and socket reconnect are graded from `blocked`, `degraded`, `gap`, and `resumed` annotations. They do not add a stage line. `degraded` and `resumed` detail text ends in `track=<t>`, and `resumed` carries `backlogMs=<n>` (audio the new socket replays before live). `noAudio` and heartbeat/handshake `degraded` carry `emittedAtMs=`; `noAudio` also carries `observedFromMs=` (capture start). `stages.log` is still never read by `grade.py`; provenance comes from `harness_run.json`, not from stage lines.
