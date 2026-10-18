[![Built for Omarchy](https://raw.githubusercontent.com/tcballard/omarchy-badges/85f859029e236e784e7b05ada6dbe73506d07a91/badges/v1/built-for-omarchy.svg)](https://github.com/tcballard/omarchy-badges)

# Omacros (`gladimdim.omacros`)

Text and image macros for [Omarchy](https://omarchy.org/). Open the manager from the bar, record a key combo, type the text it should insert (or choose an image), save — done. The combo wires itself up at runtime, so pressing it anywhere pastes your text or image from the clipboard buffer into whatever window has focus. Macros also fire from the command line, no binding needed.

![Omacros preview](preview.png)

## How it works

1. **Record the combo.** Click **Record**, then press the combination you want — hold modifiers first, then the key (e.g. hold `SUPER`, tap `F3`). `Esc` cancels.
2. **Type the phrase — or pick an image.** Anything you want inserted: `SUPER DESKTOP`, an email signature, a code snippet preamble. Switch **Insert** to **Image** and press **Choose image…** to make the combo paste a picture instead (PNG, JPEG, GIF, WebP or BMP, up to 20 MB).
3. **Save.** That's it. Omacros registers the combo with the running Hyprland right away — no config files touched. After every Hyprland reload the service re-applies your combos automatically, so they keep working.

Under the hood the binding is runtime state: the service asks Hyprland via its Lua API

```lua
hl.bind("SUPER + F3", hl.dsp.exec_cmd("omarchy-shell gladimdim.omacros fire <id>"), { description = "Omacros: Greet" })
```

The bind calls the plugin's IPC handler in the running shell, which copies the phrase onto the clipboard (`wl-copy`, fed through stdin so the phrase never shows up in a process command line; Omarchy's clipboard history still records it) and then presses the paste chord Omarchy's own `SUPER+V` "Universal paste" uses — `Ctrl+V`, or `Ctrl+Shift+V` when the focused window is a terminal. Nothing is written to `~/.config/hypr`, nothing runs elevated, and combos already bound by you or another plugin are never overridden — Omacros notifies you and asks for a different combo instead.

Prefer a permanent binding in your own config? Run `omacros bind <id>` and paste the printed `o.bind(...)` line into `~/.config/hypr/bindings.lua`.

Image macros work the same way: the service puts the stored image on the clipboard with its own type (`wl-copy --type image/png < image`) and presses the same paste chord, so it lands in chat apps, browsers, editors — anything that accepts a pasted image. The picked file is copied into `~/.local/state/omarchy/omacros/images/` when you choose it, so the macro keeps working if the original is moved or deleted. Its type is checked from the file's contents, not its extension.

Phrases without a keybinding still work: press `Enter` on a selected row in the manager, or run `omacros paste <id>`.

## The manager window

Left-click the 󰌌 icon in the bar (center section by default) to open it — a detached, resizable window, not a popup pinned to the bar:

- Top form: name, combo recorder, **Insert: Text / Image** — a phrase, or **Choose image…** with a preview — and **Save macro**.
- Below: every saved macro as a table (image macros show a thumbnail). **Click a row to edit it** — its combo, name and text or image fill the form, Save turns into **Update macro**, and the combo re-wires itself when you change it. Clear/Cancel edit returns the form to new-macro mode.
- To insert without editing: double-click a row (or press Enter on a selected one) — the window closes and the phrase is pasted into whatever app you were working in.
- Keyboard: `↑ ↓` select  ·  `Enter` insert  ·  `Del` remove  ·  `Esc` close or cancel recording.
- Tooltips on the bar icon summarize your saved combos.

## Command line

```bash
omacros list              # every saved macro: id, keys, phrase or [image]
omacros keys <id>         # the recorded combo
omacros paste <id>        # insert now (paste text or image from the clipboard buffer)
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

Everything lives in `~/.local/state/omarchy/omacros/`, a folder only you can read (700, files 600): `omacros.json` (plain JSON — up to 50 macros, 512 characters each) and `images/` with the image macros' copies. Delete the folder to reset. Older versions kept these directly in `~/.local/state/omarchy/`; the service moves them on its first start.

## Notes & limits

- **Clipboard replaces**: firing puts the phrase or image on your clipboard (that's how the paste happens). Omarchy's clipboard history (SUPER+CTRL+V) can hand you anything it overwrote.
- Runtime binds are compositor state: Hyprland rebuilds them from your config on every reload, so the service re-registers your combos after each one. Removing the plugin also removes its binds.
- Recorded keys cover letters, digits, `F1`-`F12`, punctuation and navigation keys, with `SUPER`/`CTRL`/`ALT`/`SHIFT` modifiers. Combos already claimed by another binding are kept theirs — Omacros skips and notifies.
- Phrases are single-line and never start with a dash.
- Images paste wherever the focused app accepts a pasted image; terminals generally don't. Stored images no macro uses any more are cleaned up a day after they were picked.

## Files

| Path                 | Role                                                        |
|----------------------|-------------------------------------------------------------|
| `manifest.json`      | Plugin manifest (service + bar widget, keepLoaded)          |
| `Service.qml`        | State, runtime bind sync, IPC (`fire <id>`), pasting        |
| `BarWidget.qml`      | Bar icon + macro count badge + opens the manager window     |
| `MacrosWindow.qml`   | Detached manager: recorder form, image picker, saved list   |
| `Omacros.js`         | Shared state/sanitize/bind-plan logic (and test target)     |
| `scripts/omacros`    | CLI (`list`, `keys`, `paste`, `bind`, `path`)               |
| `tests/`             | `node tests/test-omacros.js`                                |

## Development

```bash
node tests/test-omacros.js
omakit verify . --json
omakit submit . --category Productivity --tags macros,text,typing --json --offline
```
