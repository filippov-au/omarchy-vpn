import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "VpnHardening"

  function backend(file) {
    var component = Qt.createComponent("../../" + file + "Backend.qml")
    compare(component.status, Component.Ready, component.errorString())
    return createTemporaryObject(component, this)
  }

  function test_observed_state_data() {
    return ["Proton", "Mullvad", "Warp", "Windscribe", "NetworkManager", "AmneziaWg"].map(function(name) {
      return { tag: name, file: name }
    })
  }

  function test_observed_state(data) {
    var b = backend(data.file)
    verify(b !== null)
    b._desired = 1
    compare(b.connected, false)
    compare(b.connectionState, "connecting")
    b._desired = -1
    compare(b.connectionState, "unknown")
    if (data.file === "NetworkManager" || data.file === "AmneziaWg") return
    b.status = { connected: true, loggedIn: true }
    b.statusKnown = true
    compare(b.connected, true)
    b.statusKnown = false
    compare(b.connected, false)
    compare(b.mayBeConnected, true)
    compare(b.connectionState, "unknown")
  }

  function test_proton_action_needs_status_confirmation() {
    var b = backend("Proton")
    b.detected = true
    b.connectTo({ label: "fastest", args: [] })
    compare(b.connectionState, "connecting")
    compare(b.connected, false)
    findChild(b, "connectProcess").finish(0, "Connected to NL#42", "")
    compare(b.connected, false)
    wait(5)
    var status = findChild(b, "statusProcess")
    status.finish(0, "Status: Connected\nServer: NL#42", "")
    compare(b.connected, true)
    status.finish(1, "", "CLI unavailable")
    compare(b.connected, false)
    compare(b.mayBeConnected, true)
    compare(b.connectionState, "unknown")
  }

  function test_stale_status_cannot_confirm_a_new_request() {
    var b = backend("Proton")
    b.detected = true
    var status = findChild(b, "statusProcess")
    status.running = true
    b.connectTo({ label: "fastest", args: [] })
    status.finish(0, "Status: Connected\nServer: old-server", "")
    compare(b.connected, false)
    compare(b.statusKnown, false)
    compare(b.connectionState, "connecting")
  }

  function test_status_failure_data() {
    return [
      { tag: "Mullvad", file: "Mullvad", reply: '{"state":"connected"}' },
      { tag: "Warp", file: "Warp", reply: '{"status":"Connected","reason":"NetworkHealthy"}' },
      { tag: "Windscribe", file: "Windscribe", reply: 'Login state: Logged in\nConnect state: Connected: Zurich - Alphorn\nFirewall state: On' }
    ]
  }

  function test_status_failure(data) {
    var b = backend(data.file)
    b.applyStatus(data.reply)
    compare(b.connected, true)
    if (data.file === "Windscribe") b.finishStatus(1, "", "unavailable")
    else {
      var process = findChild(b, "statusProcess")
      process.running = true
      process.finish(1, "", "unavailable")
    }
    compare(b.connected, false)
    compare(b.connectionState, "unknown")
    compare(b.mayBeConnected, true)
  }

  function test_networkmanager_handover_aborts_on_failed_teardown() {
    var b = backend("NetworkManager")
    b._nmcliPresent = true
    b._wireguardPresent = true
    b.applyProfiles([{ uuid: "old", name: "old", kind: "wireguard", active: true }])
    b.connectTo({ uuid: "new", label: "new", kind: "wireguard", args: ["connection", "up", "uuid", "new"] })
    var process = findChild(b, "connectProcess")
    process.finish(1, "", "cannot disconnect")
    wait(5)
    verify(!process.running)
    compare(b._pendingTarget, null)
    compare(b._stage, "")
    verify(b.lastError.indexOf("cannot disconnect") !== -1)
  }

  function test_poll_cannot_finish_a_connection_command_still_running() {
    var b = backend("Mullvad")
    b.detected = true
    b.applyStatus('{"state":"connected"}')
    b.connectTo({ label: "new location", args: ["nl"] })
    verify(findChild(b, "commandProcess").running)
    b.applyStatus('{"state":"connected"}')
    compare(b.connectionState, "connecting")
    compare(b.connected, false)
  }

  function test_handover_failure_never_starts_the_next_vpn() {
    var controller = createTemporaryObject(controllerComponent, this)
    verify(controller !== null)
    var old = controller.backends[0]
    var next = controller.backends[1]
    old.detected = true
    old.status = { connected: true }
    old.statusKnown = true
    next.detected = true
    next.statusKnown = true
    var called = false
    controller.runExclusive(next, function() { called = true })
    verify(!called)
    var timer = findChild(controller, "exclusiveWait")
    timer.interval = 1
    timer.ticks = 14
    wait(20)
    verify(!called)
    verify(controller.notice.indexOf("cancelled") !== -1)
  }

  function test_handover_waits_for_a_confirmed_disconnect() {
    var controller = createTemporaryObject(controllerComponent, this)
    var old = controller.backends[0]
    var next = controller.backends[1]
    old.detected = true
    old.status = { connected: true }
    old.statusKnown = true
    next.detected = true
    next.statusKnown = true
    var called = false
    controller.runExclusive(next, function() { called = true })
    verify(!called)
    old.status = { connected: false }
    old.statusKnown = true
    old._desired = -1
    findChild(controller, "exclusiveWait").interval = 1
    wait(20)
    verify(called)
  }

  function test_public_ip_disabled_by_default() {
    var controller = createTemporaryObject(controllerComponent, this)
    verify(controller !== null)
    compare(controller.publicIpLookup, false)
    controller.refreshPublicIp()
    compare(controller.ipFetching, false)
  }

  function test_public_ip_discards_results_after_opt_out_and_clears_failures() {
    var controller = createTemporaryObject(controllerComponent, this)
    controller.settings = { publicIpLookup: "on" }
    controller.refreshPublicIp()
    var process = findChild(controller, "ipProcess")
    verify(process.running)
    controller.settings = { publicIpLookup: "off" }
    process.finish(0, "203.0.113.1", "")
    compare(controller.publicIp, "")
    controller.settings = { publicIpLookup: "on" }
    controller.refreshPublicIp()
    process.finish(0, "203.0.113.2", "")
    compare(controller.publicIp, "203.0.113.2")
    controller.refreshPublicIp()
    process.finish(1, "", "unavailable")
    compare(controller.publicIp, "")
    compare(controller.ipFailed, true)
  }

  Component { id: controllerComponent; Plugin.VpnController {} }
}
