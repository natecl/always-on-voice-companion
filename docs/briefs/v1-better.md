# v1 Better — Cap-approved brief (2026-09-23)

**One-liner:** Granola mechanics, instant, zero friction, cheap enough to leave on.

**Bars (binary):**
- B1 ≤$0.25/session-hr metered over 60m
- B2 partials ≤2s behind speech
- B3 shareable notes ≤30s after stop
- B4 cold→capturing ≤5s and ≤2 clicks (tap/hotkey/orb only — NEVER ambient always-record)
- B5 60s non-meeting audio WER≤15% + brief
- B6 v0 P1–P6 still green

**Cap-calls LOCKED:** (1) brief = Granola-style shareable summary blocks, copyable; (2) meter = per-session rollup + per-minute streaming components logged underneath for B1 audit; (3) start = both global hotkey AND orb click.

**Out of scope:** ambient always-recording, Jev/interjection, memory/cross-session, iOS/Windows, UI beyond orb states + live transcript + session list/briefs + cost meter readout.

**Build:** one component per slice; Mac grade closes every loop; parallel tracks on separate branches; Cap merges serially when Mac green. Phase 4 (B5+B6) only after phases 1–3 Mac-green.

**Base:** main @ 10db545; protect v0 foundation; judgment resequenced to v2.
