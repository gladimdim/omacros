// Tests for Omacros.js — run with: node tests/test-omacros.js
"use strict"

var assert = require("assert")
var Om = require("../Omacros.js")

var failures = 0

function test(name, fn) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (e) {
    failures++
    console.log("FAIL " + name + " — " + e.message)
  }
}

function eq(actual, expected, label) {
  assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected), label + " → " + JSON.stringify(actual))
}

// ---------------------------------------------------------------- state

test("stateDir falls back to ~/.local/state", function() {
  eq(Om.stateDir("/home/u", ""), "/home/u/.local/state/omarchy")
  eq(Om.stateDir("/home/u", "/xdg"), "/xdg/omarchy")
})

test("statePath ends in omacros.json", function() {
  eq(Om.statePath("/home/u", ""), "/home/u/.local/state/omarchy/omacros.json")
})

test("emptyState shape", function() {
  eq(Om.emptyState(), { version: 1, macros: [] })
})

// ---------------------------------------------------------------- ids

test("sanitizeId allows safe ids only", function() {
  eq(Om.sanitizeId("abc-123_X.9"), "abc-123_X.9")
  eq(Om.sanitizeId("bad/id"), "")
  eq(Om.sanitizeId("../etc/passwd"), "")
  eq(Om.sanitizeId(""), "")
})

test("newId is unique and safe-shaped", function() {
  var a = Om.newId(new Date(1700000000000))
  var b = Om.newId(new Date(1700000000000))
  assert.notStrictEqual(a, b)
  assert.ok(Om.sanitizeId(a))
})

// ---------------------------------------------------------------- sanitizing

test("sanitizeLabel strips control chars and caps length", function() {
  eq(Om.sanitizeLabel("  Greet  team "), "Greet team")
  eq(Om.sanitizeLabel("<img src=x>"), "<img src=x>")
  eq(Om.sanitizeLabel("a\x01b"), "ab")
  eq(Om.sanitizeLabel("x".repeat(60)), "x".repeat(Om.maxLabel))
})

test("sanitizePhrase single-lines and caps length", function() {
  eq(Om.sanitizePhrase("SUPER DESKTOP"), "SUPER DESKTOP")
  eq(Om.sanitizePhrase("line\nbreak\ttab"), "line break tab")
  eq(Om.sanitizePhrase(""), "")
  eq(Om.sanitizePhrase("x".repeat(600)), "x".repeat(Om.maxPhrase))
})

test("notifySafeText guards leading dash", function() {
  eq(Om.notifySafeText("-flag"), " -flag")
  eq(Om.notifySafeText("ok"), "ok")
})

// ---------------------------------------------------------------- combos

test("sanitizeTokens accepts modifier order and one key", function() {
  eq(Om.sanitizeTokens(["SUPER", "F3"]), ["SUPER", "F3"])
  eq(Om.sanitizeTokens(["SUPER", "SHIFT", "a"]), ["SUPER", "SHIFT", "a"])
  // Duplicates and ordering normalize.
  eq(Om.sanitizeTokens(["SHIFT", "SHIFT", "a"]), ["SHIFT", "a"])
  eq(Om.sanitizeTokens(["super", "f3"]), null)
})

test("sanitizeTokens rejects combos without exactly one key", function() {
  eq(Om.sanitizeTokens(["SUPER"]), null)
  eq(Om.sanitizeTokens(["a", "b"]), null)
  eq(Om.sanitizeTokens([]), null)
  eq(Om.sanitizeTokens("nope"), null)
})

test("sanitizeTokens rejects unknown key names", function() {
  eq(Om.sanitizeTokens(["SUPER", "MAKE_MONEY_FAST"]), null)
  eq(Om.sanitizeTokens(["SUPER", "return; drop"]), null)
})

test("displayKeys joins with omarchy separators", function() {
  eq(Om.displayKeys(["SUPER", "F3"]), "SUPER + F3")
  eq(Om.displayKeys(["bad"]), "")
})

// ---------------------------------------------------------------- state ops

test("parseState rejects junk and oversized raw", function() {
  eq(Om.parseState("not json"), { version: 1, macros: [] })
  eq(Om.parseState("[]"), { version: 1, macros: [] })
  eq(Om.parseState("{\"version\":2,\"macros\":[]}"), { version: 1, macros: [] })
  eq(Om.parseState("x".repeat(Om.stateMaxBytes + 1)), { version: 1, macros: [] })
  eq(Om.parseState(""), { version: 1, macros: [] })
})

test("parseState keeps valid macros, drops broken ones", function() {
  var raw = JSON.stringify({
    version: 1,
    macros: [
      { id: "m1", label: "Greet", keys: "SUPER + F3", tokens: ["SUPER", "F3"], text: "SUPER DESKTOP", createdAt: 1 },
      { id: "bad/id", label: "", keys: "", tokens: [], text: "", createdAt: 0 },
      "nonsense"
    ]
  })
  var state = Om.parseState(raw)
  eq(state.macros.length, 1)
  eq(state.macros[0].id, "m1")
  eq(state.macros[0].keys, "SUPER + F3")
  eq(state.macros[0].text, "SUPER DESKTOP")
})

test("parseState caps macro count", function() {
  var macros = []
  for (var i = 0; i < Om.maxMacros + 10; i++) {
    macros.push({ id: "m" + i, label: "", keys: "a", tokens: ["a"], text: "t" + i, createdAt: 1 })
  }
  var state = Om.parseState(JSON.stringify({ version: 1, macros: macros }))
  eq(state.macros.length, Om.maxMacros)
})

test("addMacro validates, stores and caps", function() {
  var bad = Om.addMacro("", { tokens: ["SUPER", "F3"], text: "" })
  eq(bad.ok, false)
  var combo = Om.addMacro("", { tokens: ["BOGUS"], text: "hello" })
  eq(combo.ok, false)

  var r = Om.addMacro("", { label: "Greet", tokens: ["SUPER", "F3"], text: "SUPER DESKTOP" })
  eq(r.ok, true)
  eq(r.macro.tokens, ["SUPER", "F3"])
  eq(r.macro.keys, "SUPER + F3")

  var full = { version: 1, macros: [] }
  for (var i = 0; i < Om.maxMacros; i++) {
    full.macros.push({ id: "m" + i, label: "", keys: "a", tokens: ["a"], text: "t", createdAt: 1 })
  }
  var capped = Om.addMacro(JSON.stringify(full), { tokens: ["a"], text: "hi" })
  eq(capped.ok, false)
})

test("addMacro rejects phrases starting with a dash (wtype argv safety)", function() {
  var r = Om.addMacro("", { tokens: ["a"], text: "--help" })
  eq(r.ok, false)
})

test("removeMacro removes only the target", function() {
  var r1 = Om.addMacro("", { tokens: ["a"], text: "one" })
  var r2 = Om.addMacro(Om.encode(r1.state), { tokens: ["b"], text: "two" })
  var del = Om.removeMacro(Om.encode(r2.state), r2.macro.id)
  eq(del.ok, true)
  var state = Om.parseState(Om.encode(del.state))
  eq(state.macros.length, 1)
  eq(state.macros[0].text, "one")
  eq(Om.removeMacro(Om.encode(del.state), "nope").ok, false)
})

test("findMacro matches sanitized ids only", function() {
  var r = Om.addMacro("", { tokens: ["a"], text: "one" })
  var macros = Om.parseState(Om.encode(r.state)).macros
  assert.ok(Om.findMacro(macros, r.macro.id))
  eq(Om.findMacro(macros, "../bad"), null)
})

test("round-trips through encode", function() {
  var r = Om.addMacro("", { label: "Greet", tokens: ["SUPER", "F3"], text: "SUPER DESKTOP" })
  var again = Om.parseState(Om.encode(r.state))
  eq(again.macros.length, 1)
  eq(again.macros[0].keys, "SUPER + F3")
})

// ---------------------------------------------------------------- bind line

test("bindLineFor renders the o.bind line", function() {
  var line = Om.bindLineFor({
    id: "abc123",
    label: "Greet",
    keys: "SUPER + F3"
  })
  eq(line, 'o.bind("SUPER + F3", "Omacros: Greet", "omarchy-shell gladimdim.omacros fire abc123")')
})

test("bindLineFor escapes quotes and backslashes in the label", function() {
  var line = Om.bindLineFor({
    id: "abc123",
    label: 'He said "hi" \\ now',
    keys: "a"
  })
  eq(line, 'o.bind("a", "Omacros: He said \\"hi\\" \\\\ now", "omarchy-shell gladimdim.omacros fire abc123")')
})

test("bindLineFor handles missing label and keys", function() {
  eq(Om.bindLineFor({ id: "abc", label: "", keys: "a" }), 'o.bind("a", "Omacros", "omarchy-shell gladimdim.omacros fire abc")')
  eq(Om.bindLineFor({ id: "abc", label: "x", keys: "" }), "")
  eq(Om.bindLineFor(null), "")
})

// ---------------------------------------------------------------- lists

test("tooltipFor summarizes safely", function() {
  eq(Om.tooltipFor([]), "Omacros — no macros yet")
  var tip = Om.tooltipFor([
    { id: "1", keys: "SUPER + F3", text: "SUPER DESKTOP" },
    { id: "2", keys: "", text: "only text" }
  ])
  eq(tip, "SUPER + F3  SUPER DESKTOP\nonly text")
})

test("listFor renders the CLI table", function() {
  eq(Om.listFor([]), "no macros")
  var out = Om.listFor([{ id: "1", keys: "a", text: "one" }])
  eq(out, "1\ta\tone")
})

// ---------------------------------------------------------------- done

console.log("")
if (failures > 0) {
  console.log(failures + " failing")
  process.exit(1)
} else {
  console.log("all passing")
}
