[![Built for Omarchy](https://raw.githubusercontent.com/tcballard/omarchy-badges/85f859029e236e784e7b05ada6dbe73506d07a91/badges/v1/built-for-omarchy.svg)](https://github.com/tcballard/omarchy-badges)

# Omacros (`gladimdim.omacros`)

Text macros (saved phrases) for [Omarchy](https://omarchy.org/). Open the manager from the bar, record a key combo, type the text it should insert, save — done. The combo wires itself up at runtime, so pressing it anywhere types your text into whatever window has focus. Phrases also fire from the command line, no binding needed.

![Omacros preview](preview.png)

## How it works

1. **Record the combo.** Click **Record**, then press the combination you want — hold modifiers first, then the key (e.g. hold `SUPER`, tap `F3`). `Esc` cancels.
2. **Type the phrase.** Anything you want inserted: `SUPER DESKTOP`, an email signature, a code snippet preamble.
3. **Save.** That's it. Omacros registers the combo with the running Hyprland right away — no config files touched. After every Hyprland reload the service re-applies your combos automatically, so they keep working.

Under the hood the binding is runtime state: the service asks Hyprland via its Lua API

```lua
hl.bind("SUPER + F3", hl.dsp.exec_cmd("omarchy-shell gladimdim.omacros fire <id>"), { description = "Omacros: Greet" })
```

The bind calls the plugin's IPC handler in the running shell, which types the phrase with `wtype` (Wayland virtual keyboard). Nothing is written to `~/.config/hypr`, nothing runs elevated, and combos already bound by you or another plugin are never overridden — Omacros notifies you and asks for a different combo instead.

Prefer a permanent binding in your own config? Run `omacros bind <id>` and paste the printed `o.bind(...)` line into `~/.config/hypr/bindings.lua`.

Phrases without a keybinding still work: press `Enter` on a selected row in the manager, or run `omacros paste <id>`.

## The manager window

Left-click the 󰌌 icon in the bar (center section by default) to open it — a detached, resizable window, not a popup pinned to the bar:

- Left column: name, combo recorder, phrase, **Save macro**.
- Below: every saved macro as a table. Click a row to select it, double-click to insert its phrase right now.
- Keyboard: `↑ ↓` select  ·  `Enter` insert  ·  `Del` remove  ·  `Esc` close or cancel recording.
- To insert, the window closes first so the text types into the app you were working in.
- Tooltips on the bar icon summarize your saved combos.

## Command line

```bash
omacros list              # every saved macro: id, keys, phrase
omacros keys <id>         # the recorded combo
omacros paste <id>        # insert now (types with wtype)
omacros bind <id>         # print a permanent o.bind line for bindings.lua (optional)
omacros path              # state file path
```

If `omacros` is not on `PATH`, call it from the plugin directory: `~/.config/omarchy/plugins/gladimdim.omacros/scripts/omacros`.

## Install

```bash
omarchy plugin add https://github.com/gladimdim/omacros.git --enable --yes
```

Move the icon to taste:

```bash
omarchy bar move gladimdim.omacros --section center --after omarchy.clock
```

## Remove

```bash
omarchy plugin remove gladimdim.omacros --yes
```

State lives at `~/.local/state/omarchy/omacros.json` (plain JSON — up to 50 macros, 512 characters each). Delete the file to reset.

## Notes & limits

- **wtype required** (installed by default on Omarchy). If typing silently fails, check `wtype` runs in your session.
- Runtime binds are compositor state: Hyprland rebuilds them from your config on every reload, so the service re-registers your combos after each one. Removing the plugin also removes its binds.
- Recorded keys cover letters, digits, `F1`-`F12`, punctuation and navigation keys, with `SUPER`/`CTRL`/`ALT`/`SHIFT` modifiers. Combos already claimed by another binding are kept theirs — Omacros skips and notifies.
- Phrases are single-line; `wtype` types them character by character, so a fired macro never corrupts your clipboard.

## Files

| Path                 | Role                                                        |
|----------------------|-------------------------------------------------------------|
| `manifest.json`      | Plugin manifest (service + bar widget, keepLoaded)          |
| `Service.qml`        | State, runtime bind sync, IPC (`fire <id>`), `wtype` typing  |
| `BarWidget.qml`      | Bar icon + macro count badge + opens the manager window     |
| `MacrosWindow.qml`   | Detached manager: recorder form + saved audit list          |
| `Omacros.js`         | Shared state/sanitize/bind-plan logic (and test target)     |
| `scripts/omacros`    | CLI (`list`, `keys`, `paste`, `bind`, `path`)               |
| `tests/`             | `node tests/test-omacros.js`                                |

## Development

```bash
node tests/test-omacros.js
omakit verify . --json
omakit submit . --category Productivity --tags macros,text,typing --json --offline
```
