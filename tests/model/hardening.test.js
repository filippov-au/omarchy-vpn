const { test, eq, Shared, Proton } = require("../harness.js")
const { spawnSync } = require("node:child_process")
const fs = require("node:fs")
const path = require("node:path")

test("plugin-owned Text sinks require plain text for markup-shaped values", () => {
  const panel = fs.readFileSync(path.join(__dirname, "../../Panel.qml"), "utf8")
  const sinks = [...panel.matchAll(/\bText\s*\{([^\n]*\n[^\n]*)/g)]
  eq(sinks.length > 0, true)
  for (const sink of sinks) eq(/textFormat:\s*Text\.PlainText/.test(sink[1]), true)
})

test("requested and stale connections never confirm a tunnel", () => {
  eq(Shared.connectionState(true, false, 1), "connecting")
  eq(Shared.connectionState(true, true, 0), "disconnecting")
  eq(Shared.connectionState(false, true, -1), "unknown")
  eq(Shared.connectionState(true, true, -1), "connected")
  eq(Shared.connectionState(true, false, -1), "disconnected")
})

test("exclusive switching needs a confirmed disconnected state", () => {
  const down = { statusKnown: true, connected: false, connectionPending: false }
  eq(Shared.canStartExclusive([]), true)
  eq(Shared.canStartExclusive([down]), true)
  eq(Shared.canStartExclusive([{ ...down, statusKnown: false }]), false)
  eq(Shared.canStartExclusive([{ ...down, connected: true }]), false)
  eq(Shared.canStartExclusive([{ ...down, connectionPending: true }]), false)
})

test("public IP requests are explicitly opted in and discard obsolete results", () => {
  for (const value of [undefined, false, true, "off", "true", ""]) {
    eq(Shared.publicIpEnabled(value), false)
  }
  eq(Shared.publicIpEnabled("on"), true)
  eq(Shared.acceptPublicIpResult(false, "a", "a"), false)
  eq(Shared.acceptPublicIpResult(true, "a", "b"), false)
  eq(Shared.acceptPublicIpResult(true, "a", "a"), true)
})

test("empty and malformed successful Proton replies are not observations", () => {
  for (const raw of ["", "garbage", "Server: NL#42", "Status: Connected-ish"]) {
    eq(Proton.protonStatusReadable(raw), false)
  }
  for (const raw of ["Status: Connected", "Status: Disconnected", "Status: Connecting", "Connected to NL#42"]) {
    eq(Proton.protonStatusReadable(raw), true)
  }
})

test("command deadlines preserve literal arguments and bound stalled children", () => {
  const literal = "$(touch /tmp/should-never-run); ' <img src=x>"
  const command = Shared.boundedCommand(["printf", "%s", literal], 1)
  const printed = spawnSync(command[0], command.slice(1), { encoding: "utf8" })
  eq(printed.status, 0)
  eq(printed.stdout, literal)
  const stalled = Shared.boundedCommand(["sh", "-c", "sleep 10 & wait"], 1)
  const result = spawnSync(stalled[0], stalled.slice(1), { encoding: "utf8", timeout: 4000 })
  eq(result.status, 124)
  eq(Shared.boundedCommand([], 30), [])
  eq(Shared.boundedCommand(["interactive-auth"], 0), ["interactive-auth"])
})
