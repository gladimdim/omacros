# Omacros (`gladimdim.omacros`) — developer notes

Text-macro plugin for Omarchy. Not yet listed on the marketplace — new, unverified.

## Model

- kinds: `service` + `bar-widget`, `keepLoaded: true`. The service owns IPC
  (`omarchy-shell gladimdim.omacros fire <id>`) and the `wtype` Process; the
  bar widget owns the panel. Both watch `~/.local/state/omarchy/omacros.json`.
- Firing: Hyprland binding (generated `o.bind(...)` line) → omarchy-shell IPC →
  service → `timeout 15 wtype <phrase>`. The CLI `paste` path bypasses the
  shell and runs wtype directly.
- Recording only captures a combo (modifiers + one key); persistent bindings
  are the user's one-line paste into `~/.config/hypr/bindings.lua`.

## Checks

```bash
node tests/test-omacros.js
omakit verify . --json
omakit inspect . --json
omakit submit . --category Productivity --tags Bar,Quickshell --json --offline
```

## Review notes (for the eventual submission)

- Every Process follows the alive patterns: fixed or state-derived argv
  wrapped in `timeout` (no naked long-lived children), `StdioCollector`
  with `waitForEnd`, explicit `onExited` handling.
- No network, no curl. One write surface: the plugin's own state file under
  `~/.local/state/omarchy/`, via `FileView` atomic writes.
- All user text renders with `textFormat: Text.PlainText`.
- Phrases starting with a dash are rejected (`wtype` has no `--` separator).
