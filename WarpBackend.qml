import QtQuick
import Quickshell.Io
import "model/Shared.js" as Shared
import "model/Warp.js" as Warp

// Cloudflare WARP backend, driven by `warp-cli` talking to `warp-svc`.
// Implements the backend contract documented in VpnController.qml.
//
// WARP routes through the nearest Cloudflare data centre and keeps the user's
// country as the exit location, so there is nothing to pick a place from. The
// targets are its tunnel modes instead.
//
// Every command runs without `--accept-tos`. Without a TTY, warp-cli refuses
// with one line and exit 1 until the terms were accepted once in a terminal —
// that is the user's agreement to make, so the widget reports it through
// `setupHint` rather than accepting on their behalf.
//
// warp-cli is a Rust binary that answers in milliseconds, so unlike Proton
// there is no reason to ration reads.
Item {
  id: root
  visible: false

  property var settings: ({})
  property string filter: ""

  readonly property string backendId: "warp"
  readonly property string label: "Cloudflare WARP"
  readonly property var installNames: ["Cloudflare WARP"]
  readonly property string glyph: Warp.GLYPH_WARP
  readonly property bool supportsFilter: false
  readonly property string filterPlaceholder: ""

  property var status: Warp.parseWarpStatus("")
  property var warpSettings: Warp.parseWarpSettings("")
  property var stats: Warp.parseWarpStats("")
  property var registration: Warp.parseWarpRegistration("")
  property string actionStatus: ""
  property string lastError: ""

  property bool _present: false
  property bool _probed: false
  // What the registration probe ran into, for `setupHint`. Kept apart from
  // `registration` so a failed probe after a good one does not unregister a
  // device that is plainly still connected.
  property bool _needsTos: false
  property bool _daemonDown: false

  // Installed is not enough: an unregistered client has no tunnel to bring up,
  // and one whose terms were never accepted refuses every command.
  readonly property bool detected: _present && registration.registered

  readonly property var _probe: ({
    present: _present,
    needsTos: _needsTos,
    daemonDown: _daemonDown,
    registered: registration.registered
  })
  readonly property string setupHint: Warp.warpSetupHint(_probe)
  // What the panel runs in a terminal when that hint is clicked.
  readonly property string setupCommand: Warp.warpSetupCommand(_probe)

  // Requested state is kept separate from observations; it never confirms a tunnel.
  property int _desired: -1
  property bool statusKnown: false
  property int statusGeneration: 0
  readonly property bool connectionPending: _desired !== -1
  readonly property bool mayBeConnected: status.connected || _desired === 1
  readonly property string connectionState: Shared.connectionState(statusKnown, status.connected, _desired)

  readonly property bool connected: connectionState === "connected"
  readonly property bool _working: commandProcess.running || chainTimer.running || _stage !== ""
  readonly property bool busy: _working || statusProcess.running
  readonly property string summary: Warp.warpSummary(status, stats, registration)
  readonly property var details: Warp.warpDetails(status, warpSettings, stats, registration)
  readonly property var targets: Warp.warpTargets()
  readonly property string currentKey: Warp.warpCurrentKey(status, warpSettings)
  readonly property string emptyText: ""

  // What connectTo() is in the middle of: "mode", then "connect".
  property string _stage: ""
  property var _pendingTarget: null

  function detect(force) {
    if (presenceProcess.running || registrationProcess.running) return
    if (_probed && force !== true) return
    presenceProcess.running = true
  }

  function refresh() {
    if (!detected || statusProcess.running) return
    statusProcess.running = true
    if (!settingsProcess.running) settingsProcess.running = true
  }

  function connectTo(target) {
    if (!detected || _working || !target) return

    settleTimer.stop()
    statusGeneration += 1
    statusKnown = false
    _desired = 1
    _pendingTarget = target
    lastError = ""
    actionStatus = "Connecting with " + target.label + "…"

    if (Warp.warpNeedsModeChange(warpSettings, target)) {
      runStage("mode", ["mode"].concat(target.args || []))
    } else {
      runStage("connect", ["connect"])
    }
  }

  function disconnect() {
    if (!detected || _working) return
    settleTimer.stop()
    statusGeneration += 1
    statusKnown = false
    _desired = 0
    lastError = ""
    actionStatus = "Disconnecting…"
    runStage("disconnect", ["disconnect"])
  }

  // WARP's own default: `connect` with whichever mode is already set.
  function toggleConnection() {
    if (mayBeConnected) {
      disconnect()
      return
    }
    if (!detected || _working) return

    settleTimer.stop()
    statusGeneration += 1
    statusKnown = false
    _desired = 1
    _pendingTarget = null
    lastError = ""
    actionStatus = "Connecting…"
    runStage("connect", ["connect"])
  }

  function runStage(stage, args) {
    root._stage = stage
    commandProcess.execCommand = ["warp-cli"].concat(args)
    commandProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Warp.parseWarpStatus(raw)
    // An answer that does not parse is not news. Keep the last reading, so a
    // hiccup cannot report a live tunnel as down.
    if (parsed.state === "") {
      root.statusKnown = false
      root.lastError = "Could not read WARP status"
      return false
    }
    root.status = parsed
    root.statusKnown = true
    if (!_working && _desired !== -1 && parsed.connected === (_desired === 1)) _desired = -1
    // Stats are only meaningful with a tunnel up; while down warp-cli answers
    // with an error object, which would only replace good numbers with none.
    if (parsed.connected && !statsProcess.running) statsProcess.running = true
    if (!parsed.connected) root.stats = Warp.parseWarpStats("")
    return true
  }

  // The service applies connect and disconnect a beat after the command
  // returns, and a MASQUE handshake runs through happy eyeballs and
  // connectivity checks first — about a second and a half here — so poll for a
  // little while before trusting the answer.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.refresh()
      if (settleTimer.ticks >= 10) {
        settleTimer.ticks = 0
        settleTimer.running = false
        root._desired = -1
      }
    }
  }

  // Starting the next command from inside onExited would re-enter the process
  // that is still finishing, so the chain hops through the event loop first.
  Timer {
    id: chainTimer
    interval: 0
    repeat: false
    onTriggered: root.runStage("connect", ["connect"])
  }

  VpnProcess {
    id: presenceProcess
    objectName: "presenceProcess"
    execCommand: ["omarchy-cmd-present", "warp-cli"]
    running: true
    onExited: function(exitCode) {
      root._present = exitCode === 0
      if (root._present) registrationProcess.running = true
      else root._probed = true
    }
  }

  // Answers "registered" and, on the way, whether the terms were ever accepted
  // and whether the service is up — the three things setupHint distinguishes.
  VpnProcess {
    id: registrationProcess
    objectName: "registrationProcess"
    running: false
    execCommand: ["warp-cli", "--json", "registration", "show"]
    stdout: StdioCollector { id: registrationStdout; waitForEnd: true }
    stderr: StdioCollector { id: registrationStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root._probed = true
      var probe = Warp.warpProbeResult(exitCode, registrationStdout.text, registrationStderr.text, root.registration)
      root._needsTos = probe.needsTos
      root._daemonDown = probe.daemonDown
      root.registration = probe.registration
      // One status read belongs to the probe, as Windscribe's does: the
      // controller's refresh() for this round already ran and returned while
      // `detected` was still false, so without it a live tunnel would read as
      // "Not connected" until the next poll. The backend cannot tell whether it
      // is hidden, so a hidden WARP pays this one read too — once per probe,
      // which is shell start and each reopen of the panel, never on the poll.
      // Not refresh(): the contract keeps detect() from falling through to it,
      // and it would read settings as well.
      if (root.detected && !statusProcess.running) statusProcess.running = true
    }
  }

  VpnProcess {
    id: statusProcess
    objectName: "statusProcess"
    property int requestGeneration: -1
    onStarted: requestGeneration = root.statusGeneration
    running: false
    execCommand: ["warp-cli", "--json", "status"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (statusProcess.requestGeneration !== root.statusGeneration) return
      var output = String(statusStdout.text || "") + "\n" + String(statusStderr.text || "")
      if (!Warp.warpCommandFailed(exitCode, output)) {
        if (root.applyStatus(String(statusStdout.text || "")) && root._stage === "") root.lastError = ""
        return
      }
      // Stale, not empty: say what went wrong and leave the last reading up.
      root.statusKnown = false
      root.lastError = Warp.describeWarpFailure(output, "Could not read WARP status")
    }
  }

  VpnProcess {
    id: settingsProcess
    objectName: "settingsProcess"
    running: false
    execCommand: ["warp-cli", "--json", "settings", "list"]
    stdout: StdioCollector { id: settingsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Warp.parseWarpSettings(String(settingsStdout.text || ""))
      if (parsed.loaded) root.warpSettings = parsed
    }
  }

  VpnProcess {
    id: statsProcess
    objectName: "statsProcess"
    running: false
    execCommand: ["warp-cli", "--json", "tunnel", "stats"]
    stdout: StdioCollector { id: statsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Warp.parseWarpStats(String(statsStdout.text || ""))
      if (parsed.loaded) root.stats = parsed
    }
  }

  VpnProcess {
    id: commandProcess
    objectName: "commandProcess"
    timeoutSeconds: 180
    running: false
    execCommand: []
    stdout: StdioCollector { id: commandStdout; waitForEnd: true }
    stderr: StdioCollector { id: commandStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var output = String(commandStderr.text || "") + "\n" + String(commandStdout.text || "")
      var failed = Warp.warpCommandFailed(exitCode, output)

      if (root._stage === "mode") {
        if (failed) {
          var name = root._pendingTarget ? root._pendingTarget.label : "that mode"
          root._desired = -1
          root._pendingTarget = null
          root._stage = ""
          root.actionStatus = ""
          root.lastError = Warp.describeWarpFailure(output, "WARP rejected " + name)
          return
        }
        root._stage = ""
        if (!settingsProcess.running) settingsProcess.running = true
        chainTimer.restart()
        return
      }

      if (failed) {
        root._desired = -1
        root.lastError = Warp.describeWarpFailure(output, "WARP command failed")
      } else {
        root.lastError = ""
      }

      root._stage = ""
      root._pendingTarget = null
      root.actionStatus = ""
      settleTimer.ticks = 0
      settleTimer.restart()
      root.refresh()
    }
  }
}
