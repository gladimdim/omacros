// Omacros — text macros for Omarchy. Shared logic for the shell plugin,
// the CLI and the tests: state parsing, sanitizing and keybind rendering.
//
// A macro is one saved phrase plus the key combo the user recorded for it.
// The combo is a hint the panel hands back as a ready-to-paste o.bind line;
// firing goes through the plugin IPC (omarchy-shell gladimdim.omacros fire <id>).

var maxMacros = 50
var maxLabel = 48
var maxPhrase = 512
var stateMaxBytes = 65536
var stateFileName = "omacros.json"
var ipcTarget = "gladimdim.omacros"
var fireMethod = "fire"

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
// o.bind splits on " + ", so the label must carry no unescaped quotes.
function bindLineFor(macro) {
  if (!macro) return ""
  var keys = String(macro.keys || "")
  if (!keys) return ""
  var label = String(macro.label || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  var title = label ? "Omacros: " + label : "Omacros"
  return 'o.bind("' + keys + '", "' + title + '", "omarchy-shell ' + ipcTarget + " " + fireMethod + " " + String(macro.id || "") + '")'
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
    modifierTokens: modifierTokens,
    keyNames: keyNames,
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
