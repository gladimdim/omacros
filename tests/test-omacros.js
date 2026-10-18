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

function ok(condition) {
  assert.ok(condition, "expected truthy")
}

// ---------------------------------------------------------------- state

test("stateDir falls back to ~/.local/state", function() {
  eq(Om.stateDir("/home/u", ""), "/home/u/.local/state/omarchy")
  eq(Om.stateDir("/home/u", "/xdg"), "/xdg/omarchy")
})

test("statePath sits in the private omacros folder", function() {
  eq(Om.privateDir("/home/u", ""), "/home/u/.local/state/omarchy/omacros")
  eq(Om.statePath("/home/u", ""), "/home/u/.local/state/omarchy/omacros/omacros.json")
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

// ---------------------------------------------------------------- runtime binds

test("hyprMask/hyprMainKey/comboId map tokens to hyprctl fields", function() {
  eq(Om.hyprMask(["SUPER", "F2"]), 64)
  eq(Om.hyprMask(["CTRL", "ALT", "SHIFT", "j"]), 4 | 8 | 1)
  eq(Om.hyprMask(null), 0)
  eq(Om.hyprMainKey(["SUPER", "F2"]), "F2")
  eq(Om.hyprMainKey(["SUPER", "j"]), "J")
  eq(Om.hyprMainKey(["SUPER"]), "")
  eq(Om.comboId(["SUPER", "F2"]), "64|F2")
  eq(Om.comboId(["junk", "garbage"]), "")
})

test("runtimeBindLua renders one eval line per macro", function() {
  eq(Om.runtimeBindLua({
    id: "abc-1",
    label: 'Said "hi" \\ now',
    tokens: ["SUPER", "F2"]
  }), 'hl.bind("SUPER + F2", hl.dsp.exec_cmd("omarchy-shell gladimdim.omacros fire abc-1"), { description = "Omacros: Said \\"hi\\" \\\\ now" })')
  eq(Om.runtimeBindLua({ id: "x", label: "", tokens: ["CTRL", "j"] }),
    'hl.bind("CTRL + j", hl.dsp.exec_cmd("omarchy-shell gladimdim.omacros fire x"), { description = "Omacros" })')
  eq(Om.runtimeBindLua(null), "")
  eq(Om.runtimeBindLua({ id: "x", tokens: ["SUPER"] }), "")
})

test("runtimeUnbindLua renders hl.unbind for readable combos", function() {
  eq(Om.runtimeUnbindLua("SUPER + F2"), 'hl.unbind("SUPER + F2")')
  eq(Om.runtimeUnbindLua(""), "")
})

test("evalLua orders unbinds before binds and skips empties", function() {
  var macro = { id: "abc-1", label: "", tokens: ["SUPER", "F2"], keys: "SUPER + F2" }
  eq(Om.evalLua([], []), "")
  eq(Om.evalLua([macro], ["SUPER + F3"]),
    'hl.unbind("SUPER + F3")\n' +
    'hl.bind("SUPER + F2", hl.dsp.exec_cmd("omarchy-shell gladimdim.omacros fire abc-1"), { description = "Omacros" })')
})

test("parseBinds keeps modmask|KEY with descriptions", function() {
  var binds = Om.parseBinds(JSON.stringify([
    { modmask: 64, key: "F2", description: "screenshot" },
    { modmask: 64, key: "J", description: "Omacros: x" },
    { modmask: 64, key: "mouse:272", description: "click" }
  ]))
  eq(Object.keys(binds).length, 2)
  eq(binds["64|F2"].description, "screenshot")
  eq(binds["64|J"].description, "Omacros: x")
  eq(Object.keys(Om.parseBinds("not json")).length, 0)
  eq(Object.keys(Om.parseBinds("")).length, 0)
})

test("bindDiff binds fresh combos and skips already-applied ones", function() {
  var macro = { id: "abc-1", label: "Thing", tokens: ["SUPER", "F2"], keys: "SUPER + F2" }
  var plan = Om.bindDiff([macro], Om.parseBinds(""), Om.appliedFor([]))
  eq(plan.bind.length, 1)
  eq(plan.unbind.length, 0)
  eq(plan.taken.length, 0)

  var appliedPlan = Om.bindDiff([macro], { "64|F2": { description: "Omacros: Thing" } }, Om.appliedFor([macro]))
  eq(appliedPlan.bind.length, 0)
  eq(appliedPlan.unbind.length, 0)
})

test("bindDiff refuses combos owned by other binds", function() {
  var macro = { id: "abc-1", label: "Thing", tokens: ["SUPER", "F2"], keys: "SUPER + F2" }
  var plan = Om.bindDiff([macro], { "64|F2": { description: "screenshot tool" } }, Om.appliedFor([]))
  eq(plan.bind.length, 0)
  eq(plan.taken.length, 1)
  eq(plan.taken[0].keys, "SUPER + F2")
  eq(plan.taken[0].owner, "screenshot tool")
  eq(Om.takenNotice(plan.taken), 'SUPER + F2 is already bound to "screenshot tool" — pick another combo')
})

test("takenNotice keeps the text short and single", function() {
  eq(Om.takenNotice([]), "")
  var many = Om.takenNotice([
    { keys: "SUPER + F2", owner: "x" },
    { keys: "SUPER + F3", owner: "y" },
    { keys: "SUPER + F4", owner: "z" }
  ])
  eq(many, 'SUPER + F2 is already bound to "x" — pick another combo (2 more combos rejected)')
})

test("bindDiff rebinds when the applied command id changed", function() {
  var macro = { id: "new-id", label: "Thing", tokens: ["SUPER", "F2"], keys: "SUPER + F2" }
  var plan = Om.bindDiff([macro], { "64|F2": { description: "Omacros: Thing" } }, [{ id: "old-id", keys: "SUPER + F2" }])
  eq(plan.bind.length, 1)
  eq(plan.bind[0].id, "new-id")
  eq(plan.unbind.length, 1)
  eq(plan.unbind[0], "SUPER + F2")
})

test("bindDiff unbinds only combos Omacros owns when a macro is deleted", function() {
  var plan = Om.bindDiff([], {
    "64|F2": { description: "Omacros: gone" },
    "64|F3": { description: "user macro from bindings.lua" }
  }, Om.appliedFor([]))
  eq(plan.unbind.length, 1)
  eq(plan.unbind[0], "SUPER + F2")
  eq(plan.bind.length, 0)
})

test("addMacro refuses a second macro on the same combo", function() {
  var raw = Om.encode(Om.parseState(""))
  var first = Om.addMacro(raw, { tokens: ["SUPER", "F2"], text: "one" })
  eq(first.ok, true)
  var dup = Om.addMacro(first.state, { tokens: ["SUPER", "F2"], text: "two" })
  eq(dup.ok, false)
  eq(dup.error, "SUPER + F2 is already saved for another macro")
  var variant = Om.addMacro(first.state, { tokens: ["CTRL", "F2"], text: "two" })
  eq(variant.ok, true)
})

test("pasteCopyCommand keeps the phrase out of argv", function() {
  eq(Om.pasteCopyCommand(null), null)
  eq(Om.pasteCopyCommand({ text: "" }), null)
  var argv = Om.pasteCopyCommand({ text: "secret phrase" })
  eq(argv, ["timeout", "5", "wl-copy"])
  ok(argv.join(" ").indexOf("secret") === -1)
  eq(Om.pasteStdinFor({ text: "secret phrase" }), "secret phrase")
  eq(Om.pasteStdinFor({ kind: "image", image: "a.png", mime: "image/png" }), "")
  eq(Om.pasteStdinFor(null), "")
})

test("pasteEvalLua mirrors the universal paste chord", function() {
  var lua = Om.pasteEvalLua()
  ok(lua.indexOf('hl.dsp.send_key_state({ mods = mods, key = "V", state = "down" })') !== -1)
  ok(lua.indexOf('state = "up" })') !== -1)
  ok(lua.indexOf('mods = is_terminal and "CTRL SHIFT" or "CTRL"') !== -1)
  // The chord waits for the clipboard to settle, then splits down/up.
  ok(lua.indexOf("{ timeout = 150") !== -1)
  ok(lua.indexOf("{ timeout = 50") !== -1)
})

test("updateMacro edits an existing macro in place", function() {
  var raw = Om.encode(Om.parseState(""))
  var added = Om.addMacro(raw, { tokens: ["SUPER", "F2"], label: "Greet", text: "ZOPA" })
  eq(added.ok, true)
  var macro = added.macro

  var updated = Om.updateMacro(added.state, macro.id, {
    tokens: ["CTRL", "F3"],
    label: "Renamed",
    text: "New text here"
  })
  eq(updated.ok, true)
  eq(updated.macro.id, macro.id, "id survives edits")
  eq(updated.macro.createdAt, macro.createdAt, "createdAt survives edits")
  eq(updated.macro.keys, "CTRL + F3")
  eq(updated.macro.label, "Renamed")
  eq(updated.macro.text, "New text here")
  // Round-trips: the state file carries the edit and parseState agrees.
  var reloaded = Om.parseState(Om.encode(updated.state)).macros
  eq(reloaded.length, 1)
  eq(reloaded[0].keys, "CTRL + F3")
  eq(reloaded[0].text, "New text here")
})

test("updateMacro keeps a macro's own combo and rejects others' combos", function() {
  var raw = Om.encode(Om.parseState(""))
  var first = Om.addMacro(raw, { tokens: ["SUPER", "F2"], text: "one" })
  var second = Om.addMacro(first.state, { tokens: ["CTRL", "F2"], text: "two" })

  // Re-saving the same combo for the same macro is not a conflict.
  var keep = Om.updateMacro(second.state, first.macro.id, { tokens: ["SUPER", "F2"], text: "one" })
  eq(keep.ok, true)

  // Taking another macro's combo is.
  var steal = Om.updateMacro(second.state, first.macro.id, { tokens: ["CTRL", "F2"], text: "one" })
  eq(steal.ok, false)
  eq(steal.error, "CTRL + F2 is already saved for another macro")
})

test("updateMacro re-runs every sanitize rule", function() {
  var raw = Om.encode(Om.parseState(""))
  var added = Om.addMacro(raw, { tokens: ["SUPER", "F2"], text: "old" })
  var id = added.macro.id
  var state = Om.encode(added.state)

  eq(Om.updateMacro(state, id, { tokens: ["SUPER", "F2"], text: "" }).ok, false)
  eq(Om.updateMacro(state, id, { tokens: ["SUPER", "F2"], text: "-dash" }).ok, false)
  eq(Om.updateMacro(state, id, { tokens: ["SUPER"], text: "text" }).ok, false, "no main key")
  eq(Om.updateMacro(state, "", { tokens: ["SUPER", "F2"], text: "text" }).ok, false, "no id")
  eq(Om.updateMacro(state, "gone", { tokens: ["SUPER", "F2"], text: "text" }).ok, false, "unknown id")

  // Labels and phrases are still clamped and cleaned.
  var long = ""
  for (var i = 0; i < Om.maxLabel + 12; i++) long += "x"
  var veryLong = ""
  for (var j = 0; j < Om.maxPhrase + 8; j++) veryLong += "y"
  var updated = Om.updateMacro(state, id, { tokens: ["SUPER", "F2"], label: long, text: veryLong })
  eq(updated.ok, true)
  eq(updated.macro.label.length, Om.maxLabel)
  eq(updated.macro.text.length, Om.maxPhrase)
})

// ---------------------------------------------------------------- images

var fs = require("fs")
var os = require("os")
var path = require("path")
var childProcess = require("child_process")

function runArgv(argv) {
  var r = childProcess.spawnSync(argv[0], argv.slice(1), { encoding: "utf8" })
  return { code: r.status, stdout: r.stdout }
}

var pngBytes = Buffer.from("89504e470d0a1a0a0000000d49484452", "hex")

test("imagesDir sits next to the state file", function() {
  eq(Om.imagesDir("/home/u", ""), "/home/u/.local/state/omarchy/omacros/images")
})

test("sanitizeImageName only accepts generated names", function() {
  eq(Om.sanitizeImageName("abc-1.png"), "abc-1.png")
  eq(Om.sanitizeImageName("abc_1.webp"), "abc_1.webp")
  eq(Om.sanitizeImageName("../x.png"), "")
  eq(Om.sanitizeImageName("/tmp/x.png"), "")
  eq(Om.sanitizeImageName("x.svg"), "")
  eq(Om.sanitizeImageName("x.jpeg"), "")
  eq(Om.imagePathFor("/d/", "a.png"), "/d/a.png")
  eq(Om.imagePathFor("/d", "../a.png"), "")
})

test("localPathFromUrl decodes file URLs", function() {
  eq(Om.localPathFromUrl("file:///home/u/My%20Pics/a.png"), "/home/u/My Pics/a.png")
  eq(Om.localPathFromUrl("/plain/path.png"), "/plain/path.png")
  eq(Om.localPathFromUrl("https://example.com/a.png"), "")
  eq(Om.localPathFromUrl("file:///bad%E0%A4%A"), "")
})

test("addMacro stores an image macro without text", function() {
  var result = Om.addMacro("", { tokens: ["SUPER", "F4"], kind: "image", image: "pic-1.png", mime: "image/png", text: "ignored" })
  eq(result.ok, true)
  eq(result.macro.kind, "image")
  eq(result.macro.image, "pic-1.png")
  eq(result.macro.mime, "image/png")
  eq(result.macro.text, "")
  var parsed = Om.parseState(Om.encode(result.state))
  eq(parsed.macros[0].image, "pic-1.png")
})

test("image macros need a stored image with a matching type", function() {
  eq(Om.addMacro("", { tokens: ["SUPER", "F4"], kind: "image" }).error, "Choose an image first")
  eq(Om.addMacro("", { tokens: ["SUPER", "F4"], kind: "image", image: "a.png", mime: "image/jpeg" }).ok, false)
  eq(Om.addMacro("", { tokens: ["SUPER", "F4"], kind: "image", image: "../a.png", mime: "image/png" }).ok, false)
  eq(Om.addMacro("", { tokens: ["SUPER", "F4"], kind: "image", image: "a.png", mime: "text/html" }).ok, false)
})

test("updateMacro switches a macro between text and image", function() {
  var first = Om.addMacro("", { tokens: ["SUPER", "F4"], text: "hello" })
  var id = first.macro.id
  var toImage = Om.updateMacro(Om.encode(first.state), id, { tokens: ["SUPER", "F4"], kind: "image", image: "p.gif", mime: "image/gif" })
  eq(toImage.ok, true)
  eq([toImage.macro.kind, toImage.macro.image, toImage.macro.text], ["image", "p.gif", ""])
  var toText = Om.updateMacro(Om.encode(toImage.state), id, { tokens: ["SUPER", "F4"], kind: "text", text: "back" })
  eq(toText.ok, true)
  eq([toText.macro.kind, toText.macro.text, toText.macro.image], ["text", "back", undefined])
})

test("legacy text macros parse as kind text", function() {
  var raw = JSON.stringify({ version: 1, macros: [{ id: "a1", tokens: ["SUPER", "F2"], text: "hi", createdAt: 1 }] })
  eq(Om.parseState(raw).macros[0].kind, "text")
})

test("summaryFor, tooltip and list describe images", function() {
  var img = { id: "i1", keys: "SUPER + F4", kind: "image", image: "i1.png", mime: "image/png" }
  eq(Om.summaryFor(img), "[image] i1.png")
  eq(Om.summaryFor({ text: "hi" }), "hi")
  eq(Om.listFor([img]), "i1\tSUPER + F4\t[image] i1.png")
  eq(Om.tooltipFor([img]), "SUPER + F4  [image] i1.png")
})

test("pasteCopyCommand copies a stored image with its type", function() {
  var argv = Om.pasteCopyCommand({ kind: "image", image: "i1.png", mime: "image/png" }, "/s/omacros-images")
  eq(argv.slice(0, 4), ["timeout", "5", "sh", "-c"])
  eq(argv.slice(5), ["omacros-copy", "image/png", "/s/omacros-images/i1.png"])
  eq(Om.pasteCopyCommand({ kind: "image", image: "../i1.png", mime: "image/png" }, "/s"), null)
  eq(Om.pasteCopyCommand({ kind: "image", image: "i1.png", mime: "image/svg+xml" }, "/s"), null)
})

test("import script copies real images and rejects the rest", function() {
  var dir = fs.mkdtempSync(path.join(os.tmpdir(), "omacros-test-"))
  try {
    var src = path.join(dir, "my pic.png")
    fs.writeFileSync(src, pngBytes)
    var store = path.join(dir, "images")
    var run = runArgv(Om.importCommand(src, store, "abc-1"))
    var result = Om.parseImport(run.code, run.stdout)
    eq(result, { ok: true, mime: "image/png", image: "abc-1.png" })
    ok(fs.readFileSync(path.join(store, "abc-1.png")).equals(pngBytes))
    eq((fs.statSync(store).mode & 0o777).toString(8), "700")
    eq((fs.statSync(path.join(store, "abc-1.png")).mode & 0o777).toString(8), "600")

    var fake = path.join(dir, "fake.png")
    fs.writeFileSync(fake, "not an image")
    var bad = runArgv(Om.importCommand(fake, store, "abc-2"))
    eq(Om.parseImport(bad.code, bad.stdout).ok, false)
    eq(bad.code, 4)
    eq(Om.parseImport(runArgv(Om.importCommand(path.join(dir, "missing.png"), store, "abc-3")).code, "").error, "Can't read that file")
    eq(Om.importCommand("relative.png", store, "x"), null)
    eq(Om.importCommand(src, store, "bad/id"), null)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("prune removes only old unreferenced images", function() {
  var dir = fs.mkdtempSync(path.join(os.tmpdir(), "omacros-test-"))
  try {
    var old = new Date(Date.now() - 3 * 86400000)
    ;["kept.png", "orphan.png", "fresh.png"].forEach(function(name) {
      fs.writeFileSync(path.join(dir, name), pngBytes)
    })
    fs.utimesSync(path.join(dir, "kept.png"), old, old)
    fs.utimesSync(path.join(dir, "orphan.png"), old, old)
    var argv = Om.pruneCommand(dir, [{ kind: "image", image: "kept.png" }, { kind: "text", text: "x" }])
    eq(runArgv(argv).code, 0)
    eq(fs.readdirSync(dir).sort(), ["fresh.png", "kept.png"])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("stateIsValid only trusts state that parsed", function() {
  eq(Om.stateIsValid(""), false)
  eq(Om.stateIsValid("{broken"), false)
  eq(Om.stateIsValid(JSON.stringify({ version: 2, macros: [] })), false)
  eq(Om.stateIsValid(JSON.stringify({ version: 1, macros: [] })), true)
})

test("prepare makes the folder private and migrates old files", function() {
  var home = fs.mkdtempSync(path.join(os.tmpdir(), "omacros-test-"))
  try {
    var base = path.join(home, ".local/state/omarchy")
    fs.mkdirSync(path.join(base, "omacros-images"), { recursive: true })
    fs.writeFileSync(path.join(base, "omacros.json"), "{}", { mode: 0o644 })
    fs.writeFileSync(path.join(base, "omacros-images", "a.png"), pngBytes, { mode: 0o644 })
    fs.writeFileSync(path.join(base, "other.json"), "keep")
    var baseMode = fs.statSync(base).mode
    eq(runArgv(Om.prepareCommand(home, "")).code, 0)
    var dir = Om.privateDir(home, "")
    function mode(p) { return (fs.statSync(p).mode & 0o777).toString(8) }
    eq(mode(dir), "700")
    eq(mode(Om.statePath(home, "")), "600")
    eq(mode(Om.imagesDir(home, "")), "700")
    eq(mode(path.join(Om.imagesDir(home, ""), "a.png")), "600")
    eq(fs.existsSync(path.join(base, "omacros.json")), false)
    eq(fs.existsSync(path.join(base, "omacros-images")), false)
    eq(fs.readFileSync(path.join(base, "other.json"), "utf8"), "keep")
    eq(fs.statSync(base).mode, baseMode)

    // A second run is a no-op that keeps the migrated files.
    eq(runArgv(Om.prepareCommand(home, "")).code, 0)
    eq(fs.readFileSync(Om.statePath(home, ""), "utf8"), "{}")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

// ---------------------------------------------------------------- done

console.log("")
if (failures > 0) {
  console.log(failures + " failing")
  process.exit(1)
} else {
  console.log("all passing")
}
