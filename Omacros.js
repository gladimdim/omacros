// Omacros — text macros for Omarchy. Shared logic for the shell plugin,
// the CLI and the tests: state parsing, sanitizing and keybind rendering.
//
// A macro is one saved phrase plus the key combo the user recorded for it.
// The combo is wired up automatically: the service registers a runtime
// keybind with the running Hyprland through its Lua API and re-applies it
// after every reload. Nothing is written to the user's hypr config and no
// command runs with elevated privileges; see runtimeBindLua below.

var maxMacros = 50
var maxLabel = 48
var maxPhrase = 512
var stateMaxBytes = 65536
var stateFileName = "omacros.json"
var ipcTarget = "gladimdim.omacros"
var fireMethod = "fire"
var applyRulesMethod = "applyRules"

// Modifier order for the recorded combo, matching Omarchy's o.bind style.
var modifierTokens = ["SUPER", "CTRL", "ALT", "SHIFT"]

// Whitelisted Hyprland keysym names a recording may produce. Everything the
// panel recorder maps lands here, so a saved state can never carry a name
// Hyprland would parse as something else.
var keyNames = [
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
  "space", "return", "tab", "escape", "backspace", "delete", "insert",
  "home", "end", "prior", "next", "left", "right", "up", "down",
  "minus", "equal", "comma", "period", "slash", "backslash",
  "semicolon", "apostrophe", "bracketleft", "bracketright", "grave",
  "less", "greater", "question", "exclam", "quotedbl", "colon",
  "ampersand", "asterisk", "parenleft", "parenright", "underscore",
  "plus", "braceleft", "braceright", "asciicircum", "asciitilde",
  "bar", "at", "dollar", "percent", "numbersign",
  "print", "menu", "caps_lock"
]

for (var f = 1; f <= 24; f++) keyNames.push("F" + f)

function stateDir(home, stateHome) {
  var base = String(stateHome || "")
  if (!base) base = String(home || "") + "/.local/state"
  return base + "/omarchy"
}

function statePath(home, stateHome) {
  return stateDir(home, stateHome) + "/" + stateFileName
}

function emptyState() {
  return { version: 1, macros: [] }
}

function newId(now) {
  now = now || new Date()
  return now.getTime().toString(36) + "-" + Math.floor(Math.random() * 1e9).toString(36)
}

function sanitizeId(value) {
  var id = String(value || "").slice(0, 64)
  if (!/^[A-Za-z0-9._-]+$/.test(id)) return ""
  return id
}

function sanitizeLabel(value) {
  var label = String(value || "").replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "")
  label = label.replace(/\s+/g, " ").trim()
  if (label.length > maxLabel) label = label.slice(0, maxLabel)
  return label
}

// Single-line phrases; the typing runs one wtype per macro.
function sanitizePhrase(value) {
  var phrase = String(value || "").replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "")
  phrase = phrase.replace(/\s+/g, " ").trim()
  if (phrase.length > maxPhrase) phrase = phrase.slice(0, maxPhrase)
  return phrase
}

function isModifierToken(value) {
  return modifierTokens.indexOf(String(value || "")) !== -1
}

function isKeyName(value) {
  return keyNames.indexOf(String(value || "")) !== -1
}

// A combo is modifiers first, then exactly one key name: ["SUPER", "F3"].
function sanitizeTokens(tokens) {
  if (!Array.isArray(tokens)) return null
  var clean = []
  var seen = {}
  for (var i = 0; i < tokens.length; i++) {
    var token = String(tokens[i] || "")
    if (isModifierToken(token)) {
      if (!seen[token]) { clean.push(token); seen[token] = true }
      continue
    }
    if (isKeyName(token)) { clean.push(token); continue }
    return null
  }
  // Must end with exactly one non-modifier key name.
  var count = 0
  for (var j = 0; j < clean.length; j++) {
    if (!isModifierToken(clean[j])) count++
  }
  if (count !== 1) return null
  if (count === 1 && !isModifierToken(clean[clean.length - 1])) return clean
  return null
}

function displayKeys(tokens) {
  var clean = sanitizeTokens(tokens)
  if (!clean) return ""
  return clean.join(" + ")
}

// Hyprland binding for a macro, ready to paste into ~/.config/hypr/bindings.lua.
// Kept as a manual fallback for setups where the runtime wiring can't run.
// o.bind splits on " + ", so the label must carry no unescaped quotes.
function bindLineFor(macro) {
  if (!macro) return ""
  var keys = String(macro.keys || "")
  if (!keys) return ""
  var label = String(macro.label || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  var title = label ? "Omacros: " + label : "Omacros"
  return 'o.bind("' + keys + '", "' + title + '", "omarchy-shell ' + ipcTarget + " " + fireMethod + " " + String(macro.id || "") + '")'
}

// ---- Runtime keybind wiring -------------------------------------------------
// The service asks the running Hyprland, over hyprctl eval, to bind recorded
// combos with its Lua API. One macro equals one line like:
//   hl.bind("SUPER + F2", hl.dsp.exec_cmd("omarchy-shell gladimdim.omacros fire <id>"),
//           { description = "Omacros: SUPER DESKTOP" })
// This is purely runtime state: no hypr config files are read or written, and
// nothing is escalated. Hyprland forgets runtime binds on config reload, so
// the service applies them again on every shell start and whenever it sees a
// reload event.

// Description marker lets the service recognize its own binds and never
// touch, overwrite or unbind anything the user bound themselves.
var bindDescPrefix = "Omacros:"

// Modifier bitfield hyprctl binds -j reports (Hyprland MOD_* bits).
var hyprMaskBits = { SUPER: 64, CTRL: 4, ALT: 8, SHIFT: 1 }

function hyprMask(tokens) {
  var clean = sanitizeTokens(tokens)
  if (!clean) return 0
  var mask = 0
  for (var i = 0; i < clean.length; i++) {
    if (isModifierToken(clean[i])) mask |= hyprMaskBits[clean[i]]
  }
  return mask
}

// hyprctl binds -j reports keys uppercased ("J", "F2"), so compare in that form.
function hyprMainKey(tokens) {
  var clean = sanitizeTokens(tokens)
  if (!clean) return ""
  var token = clean[clean.length - 1]
  if (isModifierToken(token)) return ""
  return token.toUpperCase()
}

function comboId(tokens) {
  if (!sanitizeTokens(tokens)) return ""
  return hyprMask(tokens) + "|" + hyprMainKey(tokens)
}

function fireCommandFor(macro) {
  if (!macro) return ""
  return "omarchy-shell " + ipcTarget + " " + fireMethod + " " + String(macro.id || "")
}

function luaEscape(value) {
  return String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

function bindTitleFor(macro) {
  if (!macro) return ""
  var label = String(macro.label || "")
  return label ? bindDescPrefix + " " + label : bindDescPrefix.slice(0, -1)
}

function runtimeBindLua(macro) {
  if (!macro) return ""
  var keys = displayKeys(macro.tokens)
  if (!keys) return ""
  var cmd = fireCommandFor(macro)
  if (!cmd) return ""
  return 'hl.bind("' + keys + '", hl.dsp.exec_cmd("' + luaEscape(cmd) + '"), { description = "' + luaEscape(bindTitleFor(macro)) + '" })'
}

function runtimeUnbindLua(keys) {
  var clean = displayKeys(String(keys || "").split(" + "))
  if (!clean) return ""
  return 'hl.unbind("' + clean + '")'
}

// evalLua takes the plan bindDiff produced and renders one hyprctl eval Lua
// chunk: unbinds first (fresh combos get their slot cleared) then binds.
// Returns "" when there is nothing to do.
function evalLua(bindList, unbindList) {
  var binds = Array.isArray(bindList) ? bindList : []
  var unbinds = Array.isArray(unbindList) ? unbindList : []
  var lines = []
  for (var i = 0; i < unbinds.length; i++) {
    var unbind = runtimeUnbindLua(unbinds[i])
    if (unbind) lines.push(unbind)
  }
  for (var j = 0; j < binds.length; j++) {
    var bind = runtimeBindLua(binds[j])
    if (bind) lines.push(bind)
  }
  return lines.join("\n")
}

// hyprctl binds -j -> map of "modmask|KEY" -> { description }.
function parseBinds(raw) {
  var out = {}
  if (!raw) return out
  try {
    var items = JSON.parse(raw)
    if (!Array.isArray(items)) return out
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (!item || typeof item !== "object") continue
      var mask = Number(item.modmask)
      var key = String(item.key || "")
      if (!isFinite(mask) || mask < 0 || mask > 0xFFF || !key || key.indexOf("mouse") === 0) continue
      out[mask + "|" + key.toUpperCase()] = { description: String(item.description || "") }
    }
  } catch (e) {
    return {}
  }
  return out
}

// The service remembers what it applied so a sync only touches what changed.
function appliedFor(macros) {
  var items = Array.isArray(macros) ? macros : []
  var applied = []
  for (var i = 0; i < items.length; i++) {
    var macro = items[i]
    if (!macro) continue
    var tokens = sanitizeTokens(macro.tokens)
    if (!tokens) continue
    applied.push({ id: String(macro.id || ""), keys: displayKeys(tokens) })
  }
  return applied
}

function appliedLookup(applied) {
  var out = {}
  var list = Array.isArray(applied) ? applied : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id) out[list[i].id] = list[i]
  }
  return out
}

// hyprctl binds -j uppercases keys ("J", "F2"); canonical token names are
// lowercase for letters ("j") and title-cased F-keys ("F2"). Rebuild the
// readable combo from the mask bits and a bound key name.
function tokensFromBound(bits, key) {
  var out = []
  for (var s = 0; s < modifierTokens.length; s++) {
    if (bits & hyprMaskBits[modifierTokens[s]]) out.push(modifierTokens[s])
  }
  var token = String(key || "")
  if (!token) return []
  if (keyNames.indexOf(token) >= 0) { out.push(token); return out }
  if (keyNames.indexOf(token.toLowerCase()) >= 0) { out.push(token.toLowerCase()); return out }
  if (keyNames.indexOf(token.toUpperCase()) >= 0) { out.push(token.toUpperCase()); return out }
  return [] // unknown key name: leave the bind alone
}

// Compares what the user saved, what Hyprland currently has bound, and what
// the service last applied. Returns:
//   bind    — macros needing a runtime bind
//   unbind  — combo key strings to clear first (orphaned or re-bound combos)
//   taken   — combos already bound to something that is not ours: reported,
//             never overridden
function bindDiff(macros, existing, applied) {
  var diff = { bind: [], unbind: [], taken: [] }
  var current = parseBinds("")
  if (typeof existing === "object" && existing) current = existing
  var lookup = appliedLookup(applied)

  var desired = []
  var desiredByCombo = {}
  var items = Array.isArray(macros) ? macros : []
  for (var i = 0; i < items.length; i++) {
    var macro = items[i]
    if (!macro) continue
    var tokens = sanitizeTokens(macro.tokens)
    if (!tokens) continue
    var entry = { macro: macro, keys: displayKeys(tokens), combo: comboId(tokens) }
    if (!entry.keys || !entry.combo) continue
    if (desiredByCombo[entry.combo]) continue // first macro on a combo wins
    desiredByCombo[entry.combo] = entry
    desired.push(entry)
  }

  for (var j = 0; j < desired.length; j++) {
    var want = desired[j]
    var existingInfo = current[want.combo]
    var isOurs = existingInfo && String(existingInfo.description || "").indexOf(bindDescPrefix) === 0
    var matches = isOurs
      && String(existingInfo.description) === bindTitleFor(want.macro)
      && lookup[want.macro.id]
      && lookup[want.macro.id].keys === want.keys
    if (matches) continue
    if (existingInfo && !isOurs) {
      diff.taken.push({ keys: want.keys, owner: String(existingInfo.description || "") })
      continue
    }
    // Re-binding an owned combo: clear the old line first so the command and
    // title update atomically instead of layering duplicate binds.
    if (isOurs) diff.unbind.push(want.keys)
    diff.bind.push(want.macro)
  }

  // Deleting or re-comboing a macro leaves its old combo orphaned. Only
  // binds Hyprland still reports as ours (description prefix) are eligible,
  // because hl.unbind clears an entire combo: it must never touch another
  // author's bind by mistake. The mask bits reconstruct the readable combo.
  for (var combo2 in current) {
    var owned = current[combo2]
    if (String(owned.description || "").indexOf(bindDescPrefix) !== 0) continue
    if (desiredByCombo[combo2]) continue
    var parts = combo2.split("|")
    var tokens2 = tokensFromBound(Number(parts[0]), parts.slice(1).join("|"))
    var readable = displayKeys(tokens2)
    if (readable) diff.unbind.push(readable)
  }
  diff.unbind = uniq(diff.unbind)

  return diff
}

function uniq(list) {
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    var value = String(list[i] || "")
    if (!value || seen[value]) continue
    seen[value] = true
    out.push(value)
  }
  return out
}

// ---- Paste-on-fire ----------------------------------------------------------
// Firing pastes the phrase from the clipboard instead of typing it
// character by character: safer around terminals (a typed phrase can be
// executed by a shell prompt) and faster for long phrases. Two Omarchy
// mechanisms chain up:
//   1. `omarchy clipboard paste text --copy-only <phrase>` sets the
//      clipboard through Omarchy's own helper, so the phrase also lands
//      in the clipboard manager history.
//   2. One hyprctl eval chunk re-sends the paste chord Omarchy's own
//      SUPER+V "Universal paste" binding uses: CTRL+V, or CTRL+SHIFT+V
//      when the focused window carries Omarchy's "terminal" tag. It goes
//      through the compositor (send_key_state), so it reaches layer-shell
//      surfaces too, and virtual keyboards cannot fake it.

function pasteCopyCommand(macro) {
  if (!macro) return null
  var text = String(macro.text || "")
  if (!text) return null
  return ["omarchy-clipboard-paste-text", "--copy-only", text]
}

// Mirrors default/hypr/bindings/clipboard.lua universal_clipboard_shortcut:
// the down/up split works around send_shortcut leaving synthetic state stuck,
// and the 150ms lead time matches the helper's own clipboard-settle pause.
function pasteEvalLua() {
  return [
    "local window = hl.get_active_window()",
    "local is_terminal = false",
    "for _, tag in ipairs((window and window.tags) or {}) do",
    '  if (tag:gsub("%*$", "")) == "terminal" then is_terminal = true end',
    "end",
    'local mods = is_terminal and "CTRL SHIFT" or "CTRL"',
    "hl.timer(function()",
    '  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "V", state = "down" }))',
    "  hl.timer(function()",
    '    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "V", state = "up" }))',
    "  end, { timeout = 50, type = \"oneshot\" })",
    "end, { timeout = 150, type = \"oneshot\" })"
  ].join("\n")
}


// Notification text when a recorded combo already belongs to another bind.
// Omacros never overrides; it asks for a different combo instead.
function takenNotice(taken) {
  var entries = Array.isArray(taken) ? taken : []
  if (entries.length === 0) return ""
  var first = entries[0]
  var owner = String(first.owner || "").replace(/\s+/g, " ").trim()
  if (owner.length > 60) owner = owner.slice(0, 57) + "…"
  var text = first.keys + " is already bound to \"" + owner + "\" — pick another combo"
  if (entries.length > 1) text += " (" + (entries.length - 1) + " more combo" + (entries.length > 2 ? "s" : "") + " rejected)"
  return text
}

function notifySafeText(value) {
  var text = String(value || "")
  if (text.charAt(0) === "-") return " " + text
  return text
}

function sanitizeMacro(item, now) {
  if (!item || typeof item !== "object") return null
  var id = sanitizeId(item.id)
  var tokens = sanitizeTokens(item.tokens)
  var label = sanitizeLabel(item.label)
  var phrase = sanitizePhrase(item.text)
  if (!id || !tokens || !phrase) return null
  var createdAt = Number(item.createdAt)
  if (!isFinite(createdAt) || createdAt <= 0) createdAt = (now || new Date()).getTime()
  return {
    id: id,
    label: label,
    keys: displayKeys(tokens),
    tokens: tokens,
    text: phrase,
    createdAt: createdAt
  }
}

function parseState(raw) {
  if (!raw) return emptyState()
  if (typeof raw === "string" && raw.length > stateMaxBytes) return emptyState()
  try {
    var parsed = typeof raw === "string" ? JSON.parse(raw) : raw
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || parsed.version !== 1) return emptyState()
    var items = Array.isArray(parsed.macros) ? parsed.macros : []
    var macros = []
    for (var i = 0; i < items.length && macros.length < maxMacros; i++) {
      var macro = sanitizeMacro(items[i])
      if (macro) macros.push(macro)
    }
    return { version: 1, macros: macros }
  } catch (e) {
    return emptyState()
  }
}

function findMacro(macros, id) {
  var wanted = sanitizeId(id)
  if (!wanted) return null
  var items = Array.isArray(macros) ? macros : []
  for (var i = 0; i < items.length; i++) {
    if (items[i] && items[i].id === wanted) return items[i]
  }
  return null
}

// input: { keys?, tokens?, label, text } — tokens win over keys.
function addMacro(raw, input, now) {
  now = now || new Date()
  var phrase = sanitizePhrase(input && input.text)
  if (!phrase) return { ok: false, error: "Type the text this macro should insert" }
  // wtype has no end-of-options marker; a phrase starting with "-" would be
  // read as one.
  if (phrase.charAt(0) === "-") return { ok: false, error: "Phrases can't start with a dash" }

  var tokens = sanitizeTokens(input && input.tokens)
  if (!tokens) return { ok: false, error: "Record a key combo first" }

  var current = parseState(raw)
  if (current.macros.length >= maxMacros) {
    return { ok: false, error: "Enough macros — delete one first" }
  }

  // One combo can only fire one phrase, and the runtime wiring would replace
  // the older bind's command silently; treat it as a conflict.
  for (var i = 0; i < current.macros.length; i++) {
    if (comboId(current.macros[i].tokens) === comboId(tokens)) {
      return { ok: false, error: displayKeys(tokens) + " is already saved for another macro" }
    }
  }

  var label = sanitizeLabel(input && input.label)
  var macro = {
    id: newId(now),
    label: label,
    keys: displayKeys(tokens),
    tokens: tokens,
    text: phrase,
    createdAt: now.getTime()
  }
  current.macros.push(macro)
  return { ok: true, state: current, macro: macro }
}

function removeMacro(raw, id) {
  var current = parseState(raw)
  var next = []
  var removed = null
  for (var i = 0; i < current.macros.length; i++) {
    if (current.macros[i].id === String(id || "")) {
      removed = current.macros[i]
      continue
    }
    next.push(current.macros[i])
  }
  current.macros = next
  return { ok: !!removed, state: current, macro: removed }
}

function encode(state) {
  return JSON.stringify(parseState(state), null, 2) + "\n"
}

function tooltipFor(macros) {
  var items = Array.isArray(macros) ? macros : []
  if (items.length === 0) return "Omacros — no macros yet"
  var lines = []
  for (var i = 0; i < items.length && lines.length < 10; i++) {
    var m = items[i]
    if (!m) continue
    var keys = String(m.keys || "")
    var phrase = String(m.text || "")
    if (keys && phrase) lines.push(keys + "  " + phrase)
    else lines.push(phrase || keys)
  }
  if (items.length > 10) lines.push("… and " + (items.length - 10) + " more")
  return lines.length ? lines.join("\n") : "Omacros"
}

function listFor(macros) {
  var items = Array.isArray(macros) ? macros : []
  if (items.length === 0) return "no macros"
  var lines = []
  for (var i = 0; i < items.length; i++) {
    var m = items[i]
    if (!m) continue
    lines.push(String(m.id) + "\t" + String(m.keys || "") + "\t" + String(m.text || ""))
  }
  return lines.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    maxMacros: maxMacros,
    maxLabel: maxLabel,
    maxPhrase: maxPhrase,
    stateMaxBytes: stateMaxBytes,
    stateFileName: stateFileName,
    ipcTarget: ipcTarget,
    fireMethod: fireMethod,
    applyRulesMethod: applyRulesMethod,
    modifierTokens: modifierTokens,
    keyNames: keyNames,
    bindDescPrefix: bindDescPrefix,
    hyprMaskBits: hyprMaskBits,
    statePath: statePath,
    stateDir: stateDir,
    emptyState: emptyState,
    newId: newId,
    sanitizeId: sanitizeId,
    sanitizeLabel: sanitizeLabel,
    sanitizePhrase: sanitizePhrase,
    sanitizeTokens: sanitizeTokens,
    displayKeys: displayKeys,
    bindLineFor: bindLineFor,
    hyprMask: hyprMask,
    hyprMainKey: hyprMainKey,
    comboId: comboId,
    fireCommandFor: fireCommandFor,
    luaEscape: luaEscape,
    bindTitleFor: bindTitleFor,
    runtimeBindLua: runtimeBindLua,
    runtimeUnbindLua: runtimeUnbindLua,
    evalLua: evalLua,
    pasteCopyCommand: pasteCopyCommand,
    pasteEvalLua: pasteEvalLua,
    parseBinds: parseBinds,
    appliedFor: appliedFor,
    appliedLookup: appliedLookup,
    bindDiff: bindDiff,
    takenNotice: takenNotice,
    notifySafeText: notifySafeText,
    sanitizeMacro: sanitizeMacro,
    parseState: parseState,
    findMacro: findMacro,
    addMacro: addMacro,
    removeMacro: removeMacro,
    encode: encode,
    tooltipFor: tooltipFor,
    listFor: listFor
  }
}
