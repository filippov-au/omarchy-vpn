pragma Singleton
import QtQuick
QtObject {
  function shellQuote(text) { return "'" + String(text).replace(/'/g, "'\\''") + "'" }
}
