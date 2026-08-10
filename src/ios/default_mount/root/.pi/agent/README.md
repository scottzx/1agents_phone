# ~/.pi/agent (app-managed pi runtime config)

This directory seeds the `pi` agent runtime configuration inside the iSH guest.

- `settings.json` — pi runtime settings (steering/follow-up queue modes, auto
  compaction/retry, update checks). Overwritten from the app bundle on every
  boot; the app bridge re-applies session settings at launch.
- `models.json` — provider/model registry. The app bridge regenerates this
  from the user's configured providers on each session launch (credentials are
  injected via process environment, not persisted here).
- `system_prompt.md` — written by the app bridge at launch with the app's full
  base system prompt, passed to pi via `--system-prompt`.
- `sessions/` — pi's own session transcripts (JSONL/SQLite). Persists across
  boots; NOT managed by the overlay.

Do not edit these files by hand in the guest — changes are overwritten.
