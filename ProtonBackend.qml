import QtQuick
import Quickshell.Io
import "model/Shared.js" as Shared
import "model/Proton.js" as Proton

// Proton VPN backend, driven by the `protonvpn` CLI. Implements the backend
// contract documented in VpnController.qml.
Item {
  id: root
  visible: false

  property var settings: ({})
  property string filter: ""

  readonly property string backendId: "proton"
  readonly property string label: "Proton VPN"
  // What a user would go and install to make this backend useful, which is not
  // always the label: nobody installs "NetworkManager" to get a VPN.
  readonly property var installNames: ["Proton VPN"]
  readonly property string glyph: Shared.GLYPH_VPN
  readonly property bool supportsFilter: true
  readonly property string filterPlaceholder: "Filter countries — press / to search"

  property bool detected: false
  property var status: Proton.parseProtonStatus("")
  property var countries: []
  property bool countriesLoaded: false
  property var config: Proton.parseProtonConfig("")
  // Same meaning as countriesLoaded: asked and answered, not answered well.
  property bool _configLoaded: false
  // Set the first time a subcommand is refused for want of an account, and the
  // reason this backend stops asking. See noteAuth().
  property bool signedOut: false
  property string actionStatus: ""
  property string lastError: ""

  // Switches the panel draws under the detail rows. Values come from
  // `protonvpn config list`; the widget stores none of them.
  readonly property var toggles: Shared.applyPendingToggles(Proton.protonToggles(config), _pendingToggles)
  property var _pendingToggles: ({})
  // Which switch is in flight, so a refusal rolls back the right one.
  property string _toggleKey: ""
  // Last non-off value seen for the settings that have modes rather than an
  // on position: { "netshield": "malware-only", … }
  property var _lastModes: ({})

  // Requested state is kept separate from observations; it never confirms a tunnel.
  property int _desired: -1
  property bool statusKnown: false
  property int statusGeneration: 0
  readonly property bool connectionPending: _desired !== -1
  readonly property bool mayBeConnected: status.connected || _desired === 1
  readonly property string connectionState: Shared.connectionState(statusKnown, status.connected, _desired)

  readonly property bool connected: connectionState === "connected"
  readonly property bool busy: connectProcess.running || statusProcess.running
  readonly property string summary: Proton.protonSummary(status)
  readonly property var details: Proton.protonDetails(status)
  readonly property var favorites: Shared.favoriteCodes(setting("favoriteCountries", "CH,NL,US"))
  readonly property string emptyText: signedOut
    ? Proton.PROTON_SIGNIN_HINT
    : (countriesLoaded ? "No countries match." : "Loading countries…")
  // Server names carry their country: "NL#42" is the Netherlands row.
  readonly property string currentKey: {
    if (!connected) return ""
    var match = String(status.server || "").match(/^([A-Za-z]{2})#/)
    return match ? "country:" + match[1].toUpperCase() : ""
  }
  readonly property var targets: filter === ""
    ? Proton.protonQuickTargets().concat(Proton.protonCountryTargets(countries, favorites, ""))
    : Proton.protonCountryTargets(countries, favorites, filter)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Asked once. `force` is the user asking again, which is the only time the
  // answer could have changed — see refreshAll() in VpnController.
  property bool _probed: false

  function detect(force) {
    if (detectProcess.running) return
    // `force` is the user asking again — opening the panel, pressing r — which
    // is the one moment the answers below could have changed in a way they can
    // see: they signed in at a terminal, or changed a setting from the CLI.
    // Nothing else re-asks, because every one of these costs a Python start.
    if (force === true) {
      root._statusDue = true
      root._lastTunnel = undefined
      root.signedOut = false
      root.countriesLoaded = false
      root._configLoaded = false
    }
    if (_probed && force !== true) return
    detectProcess.running = true
  }

  // Whether the status needs reading is asked of NetworkManager, not of the CLI,
  // because a `protonvpn` on every tick crashes gnome-keyring-daemon — see
  // protonProbe(). The probe is nmcli, which touches neither the keyring nor
  // the lock. `_lastTunnel` is what it said last time, or one of the markers
  // protonProbe() documents; undefined at startup, since a read is due anyway.
  property var _lastTunnel: undefined
  // Ticks since the last status read, for the once-a-minute retry.
  property int _sinceStatus: 0
  // Ask on the next refresh whatever the probe says. True at startup because
  // the first thing a probe wants is an answer.
  property bool _statusDue: true

  // Anything this backend runs, including the user's connects and toggles.
  // Every one of them queues behind the same lock, so the useful question is
  // never "is this process free" but "is this instance already holding a slot".
  readonly property bool _cliBusy: statusProcess.running || configProcess.running
    || countriesProcess.running || connectProcess.running || toggleProcess.running

  // Every non-hidden backend is polled on the interval whether or not the panel
  // is open, and `protonvpn` is Python: each invocation costs the best part of a
  // CPU-second before it does any work, and a trip through the keyring. So the
  // poll asks for the status alone once the other two have been answered, and
  // asks for that only when the probe says the tunnel changed.
  function refresh() {
    if (!detected) return

    _sinceStatus += 1
    // Signed out, nothing connects until somebody signs in, which is a forced
    // refresh away; there is nothing for the probe to catch.
    if (!signedOut && !tunnelProcess.running) tunnelProcess.running = true

    _pump()
  }

  // Starts the one read the poll owes next, if this instance has nothing out.
  // Every read ends by asking again, so the tick's work drains as a chain; the
  // controller's next refresh() is only what restarts a chain that ended.
  function _pump() {
    if (!detected) return

    var next = Proton.protonNextRead({
      busy: _cliBusy,
      statusDue: _statusDue,
      signedOut: signedOut,
      configLoaded: _configLoaded,
      countriesLoaded: countriesLoaded
    })

    if (next === "status") {
      _statusDue = false
      _sinceStatus = 0
      statusProcess.running = true
    } else if (next === "config") {
      configProcess.running = true
    } else if (next === "countries") {
      countriesProcess.running = true
    }
  }

  // For the paths that have just changed something and need to see it land. The
  // probe is for the idle case; a settling action is not one. These reads are
  // what report the change, so the probe records it rather than asking again.
  function refreshNow() {
    _statusDue = true
    _lastTunnel = undefined
    pumpTimer.restart()
  }

  // Latches the signed-out state from a refusal, and answers "was that a
  // refusal" so callers can skip their success path. The CLI keeps refusing for
  // as long as nobody signs in, and `protonvpn status` exits 0 throughout, so
  // nothing else in the poll would ever notice.
  function noteAuth(exitCode, out, err) {
    if (exitCode === 0) {
      root.signedOut = false
      return false
    }
    if (!Proton.protonAuthRequired(String(err || "") + "\n" + String(out || ""))) return false
    root.signedOut = true
    root.lastError = Proton.PROTON_SIGNIN_HINT
    return true
  }

  function setToggle(key, value) {
    if (!detected || toggleProcess.running) return

    var args = Proton.protonToggleArgs(key, value, _lastModes[key])
    if (args.length === 0) return

    var pending = {}
    for (var name in _pendingToggles) pending[name] = _pendingToggles[name]
    pending[key] = value
    _pendingToggles = pending

    lastError = ""
    _toggleKey = key
    toggleProcess.execCommand = Proton.protonCli(args)
    toggleProcess.running = true
    pendingTimer.restart()
  }

  function applyConfig(raw) {
    var parsed = Proton.parseProtonConfig(raw)
    root.config = parsed
    // Remember the mode behind each on/off switch, so turning one back on
    // restores what was there instead of the default.
    root._lastModes = Proton.protonModes(parsed, root._lastModes)

    // "on" is not one value here — kill switch and NetShield each have modes —
    // so agreement is checked against the switch positions, not the raw text.
    var current = Proton.protonToggles(parsed)
    var pending = {}
    var changed = false
    for (var key in _pendingToggles) {
      var agreed = false
      for (var i = 0; i < current.length; i++) {
        if (current[i].key === key && current[i].value === _pendingToggles[key]) agreed = true
      }
      if (agreed) changed = true
      else pending[key] = _pendingToggles[key]
    }
    if (changed) _pendingToggles = pending
  }

  function clearPending(key) {
    var pending = {}
    for (var name in _pendingToggles) {
      if (name !== key) pending[name] = _pendingToggles[name]
    }
    _pendingToggles = pending
  }

  function connectTo(target) {
    if (!detected || connectProcess.running || !target) return
    settleTimer.stop()
    statusGeneration += 1
    statusKnown = false
    _desired = 1
    lastError = ""
    actionStatus = "Connecting to " + target.label + "…"
    connectProcess.execCommand = Proton.protonCli(["connect"].concat(target.args || []))
    connectProcess.running = true
  }

  function disconnect() {
    if (!detected || connectProcess.running) return
    settleTimer.stop()
    statusGeneration += 1
    statusKnown = false
    _desired = 0
    lastError = ""
    actionStatus = "Disconnecting…"
    connectProcess.execCommand = Proton.protonCli(["disconnect"])
    connectProcess.running = true
  }

  function toggleConnection() {
    if (mayBeConnected) disconnect()
    else connectTo({ label: "the fastest server", args: [] })
  }

  function applyStatus(raw) {
    if (!Proton.protonStatusReadable(raw)) {
      root.statusKnown = false
      root.lastError = "Could not read Proton VPN status"
      return false
    }
    var parsed = Proton.parseProtonStatus(raw)
    root.status = parsed
    root.statusKnown = true
    // Reality caught up with the pending connect/disconnect — stop overriding.
    if (!connectProcess.running && _desired !== -1 && parsed.connected === (_desired === 1)) _desired = -1
    return true
  }

  // A command that exits clean but does not take — the CLI accepts it and then
  // lists the old value — would otherwise leave the switch showing the position
  // the user asked for, marked busy, for as long as the panel is open. Optimism
  // gets a deadline.
  Timer {
    id: pendingTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (Object.keys(root._pendingToggles).length === 0) return
      root._pendingToggles = ({})
      root.lastError = "Proton VPN did not apply that setting."
    }
  }

  // Nothing may start a `protonvpn` from inside another one's onExited: that
  // process is still running as far as `running` is concerned, so _pump would
  // read the instance as busy and drop the rest of the chain until the next
  // tick. One turn of the event loop later it has settled, and two exits
  // landing together collapse into one decision rather than two.
  Timer {
    id: pumpTimer
    interval: 0
    repeat: false
    onTriggered: root._pump()
  }

  // The CLI reports the new state a beat after the command returns, so re-poll
  // a few times instead of waiting out the controller's refresh interval.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.refreshNow()
      if (settleTimer.ticks >= 4) {
        settleTimer.ticks = 0
        settleTimer.running = false
        root._desired = -1
      }
    }
  }

  VpnProcess {
    id: detectProcess
    objectName: "detectProcess"
    execCommand: ["omarchy-cmd-present", "protonvpn"]
    running: true
    onExited: function(exitCode) {
      root._probed = true
      root.detected = exitCode === 0
      if (root.detected) root.refresh()
    }
  }

  VpnProcess {
    id: tunnelProcess
    objectName: "tunnelProcess"
    running: false
    // Through a shell, so a missing nmcli is exit 127 and the retry path in
    // protonProbe() rather than a process that never starts and never exits.
    execCommand: ["sh", "-c", "exec nmcli -t -f NAME,STATE connection show --active"]
    stdout: StdioCollector { id: tunnelStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var verdict = Proton.protonProbe({
        signedOut: root.signedOut,
        exitCode: exitCode,
        raw: String(tunnelStdout.text || ""),
        lastTunnel: root._lastTunnel,
        sinceStatus: root._sinceStatus
      })
      root._lastTunnel = verdict.lastTunnel
      if (verdict.statusDue) {
        root._statusDue = true
        pumpTimer.restart()
      }
    }
  }

  VpnProcess {
    id: statusProcess
    objectName: "statusProcess"
    property int requestGeneration: -1
    onStarted: requestGeneration = root.statusGeneration
    running: false
    execCommand: Proton.protonCli(["status"])
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (statusProcess.requestGeneration !== root.statusGeneration) return
      if (exitCode === 0) {
        var accepted = root.applyStatus(String(statusStdout.text || ""))
        // Status succeeds while signed out, so clearing unconditionally would
        // wipe the one line telling the user why the panel is empty.
        if (accepted) root.lastError = root.signedOut ? Proton.PROTON_SIGNIN_HINT : ""
      } else {
        root.statusKnown = false
        root.lastError = Shared.elide(String(statusStderr.text || statusStdout.text || "") || "Could not read Proton VPN status", 140)
        // Unanswered: the probe retries on its slow clock even if nothing moved.
        root._lastTunnel = null
      }
      pumpTimer.restart()
    }
  }

  VpnProcess {
    id: connectProcess
    objectName: "connectProcess"
    timeoutSeconds: 180
    running: false
    execCommand: []
    stdout: StdioCollector { id: connectStdout; waitForEnd: true }
    stderr: StdioCollector { id: connectStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var connectOut = String(connectStdout.text || "")
      var connectErr = String(connectStderr.text || "")
      var refused = root.noteAuth(exitCode, connectOut, connectErr)
      if (exitCode !== 0) {
        root._desired = -1
        if (!refused) {
          root.lastError = Shared.elide(connectErr || connectOut || "Proton VPN command failed", 140)
        }
      } else {
        root.lastError = ""
      }
      root.actionStatus = ""
      settleTimer.ticks = 0
      settleTimer.restart()
      root.refreshNow()
    }
  }

  VpnProcess {
    id: configProcess
    objectName: "configProcess"
    running: false
    execCommand: Proton.protonCli(["config", "list"])
    stdout: StdioCollector { id: configStdout; waitForEnd: true }
    stderr: StdioCollector { id: configStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(configStdout.text || "")
      var refusedConfig = root.noteAuth(exitCode, out, String(configStderr.text || ""))
      // Answered either way: a table this parser cannot read is a reason to show
      // no switches, not to re-read it on every poll for the life of the shell.
      if (!refusedConfig) root._configLoaded = true
      if (exitCode === 0) root.applyConfig(out)
      pumpTimer.restart()
    }
  }

  VpnProcess {
    id: toggleProcess
    objectName: "toggleProcess"
    running: false
    execCommand: []
    stdout: StdioCollector { id: toggleStdout; waitForEnd: true }
    stderr: StdioCollector { id: toggleStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = Shared.elide(
          String(toggleStderr.text || toggleStdout.text || "") || "Proton VPN refused that setting", 140)
        root.clearPending(root._toggleKey)
      }
      root._toggleKey = ""
      // Re-read the switches: the tool's answer is the only one this backend
      // shows. Through the chain, so it queues rather than racing the poll.
      root._configLoaded = false
      pumpTimer.restart()
    }
  }

  // "Loaded" means asked and answered. A table this parser cannot read is a
  // reason to say so once, not to re-fetch the list on every poll for as long
  // as the shell runs.
  VpnProcess {
    id: countriesProcess
    objectName: "countriesProcess"
    running: false
    execCommand: Proton.protonCli(["countries", "list"])
    stdout: StdioCollector { id: countriesStdout; waitForEnd: true }
    stderr: StdioCollector { id: countriesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(countriesStdout.text || "")
      var err = String(countriesStderr.text || "")
      if (root.noteAuth(exitCode, out, err)) {
        pumpTimer.restart()
        return
      }

      var unreadable = "Could not read the country list. Check: protonvpn countries list"
      root.countriesLoaded = true
      if (exitCode !== 0) {
        root.lastError = Shared.elide(err || out || unreadable, 140)
      } else {
        root.countries = Proton.parseProtonCountries(out)
        if (root.countries.length === 0) root.lastError = unreadable
      }
      pumpTimer.restart()
    }
  }
}
