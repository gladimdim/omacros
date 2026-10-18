# Omacros (`gladimdim.omacros`) — developer notes

Text-macro plugin for Omarchy. Not yet listed on the marketplace — new, unverified.

## Model

- kinds: `service` + `bar-widget`, `keepLoaded: true`. The service owns IPC
  (`omarchy-shell gladimdim.omacros fire <id>`) and the paste chain (`wl-copy`
  fed through stdin, then a hyprctl eval universal paste); the bar widget owns the icon and the detached `MacrosWindow.qml`.
  Both watch `~/.local/state/omarchy/omacros.json`.
- Firing: runtime keybind → omarchy-shell IPC → service → clipboard copy +
  paste chord. Image macros (`kind: "image"`) copy their stored file with
  `wl-copy --type <mime>`.
- Image import: the window copies a picked file into
  `~/.local/state/omarchy/omacros-images/<id>.<ext>`; the type comes from
  magic bytes (od), not the extension. State only stores the generated
  name (`sanitizeImageName`), never a path. The service prunes
  unreferenced images older than a day, once per start, and only when the
  state file parsed cleanly (`stateIsValid`). The CLI `paste` path prefers the same IPC route and falls
  back to the helper's Shift+Insert when the shell is not running.
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
- No network, no curl. Write surface: the plugin's own state file under
  `~/.local/state/omarchy/` (via `FileView` atomic writes) and its own
  `omacros-images/` folder next to it (import copies, prune deletes —
  nothing outside that folder). Paths and mime types reach `sh -c` scripts
  only as positional arguments.
- All user text renders with `textFormat: Text.PlainText`.
- Macro text never travels in argv (readable by any local user via
  `/proc/<pid>/cmdline`): the service writes it to wl-copy's stdin and the
  CLI fallback pipes it from the `printf` builtin. Stored images live in a
  700 folder with 600 files (`umask 077` in the import script).
- Phrases starting with a dash are still rejected (kept for compatibility
  with older tooling).
