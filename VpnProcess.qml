import Quickshell.Io
import "model/Shared.js" as Shared

// timeout owns a process group, so a stalled shell/flock and its children are
// stopped together. Killing only the wrapper can leave a CLI holding its lock.
Process {
  property var execCommand: []
  property int timeoutSeconds: 30
  command: Shared.boundedCommand(execCommand, timeoutSeconds)
}
