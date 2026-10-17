# Omacros (`gladimdim.omacros`) — developer notes

Text-macro plugin for Omarchy. Not yet listed on the marketplace — new, unverified.

## Model

- kinds: `service` + `bar-widget`, `keepLoaded: true`. The service owns IPC
  (`omarchy-shell gladimdim.omacros fire <id>`) and the `wtype` Process; the
  bar widget owns the icon and the detached `MacrosWindow.qml`. Both watch
  `~/.local/state/omarchy/omacros.json`.
- Firing: runtime keybind → omarchy-shell IPC → service →
  `timeout 15 wtype <phrase>`. The CLI `paste` path bypasses the shell and
  runs wtype directly.
- Recording captures a combo (modifiers + one key); the service binds it
  over hyprctl eval (`hl.bind`) — runtime state, no config files — and
  re-applies it after every Hyprland reload.
- The window opener asks Hyprland to float/center/pin the window with a
  runtime `hl.window_rule` line via IPC `applyRules` and re-applies it
  before every open.

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
