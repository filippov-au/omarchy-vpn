import QtQuick
QtObject {
  property var command: []
  property bool running: false
  property var stdout: null
  property var stderr: null
  default property list<QtObject> resources
  signal started()
  signal exited(int exitCode, int exitStatus)
  onRunningChanged: if (running) started()
  function finish(code, out, err) {
    if (stdout) stdout.text = out || ""
    if (stderr) stderr.text = err || ""
    running = false
    exited(code, 0)
  }
}
