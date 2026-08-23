import Quickshell
import QtQuick

// Phase-1 smoke test stand-in for the real popup. Confirms the
// shell.summon/call IPC mechanism works for a local (non-built-in) plugin
// before any UI is built -- see TODO.md / the ask-mode plan for context.
Item {
  id: root

  property bool opened: false

  function open(payloadJson) {
    root.opened = true
    Quickshell.execDetached(["bash", "-c", "echo opened:" + Qt.btoa(payloadJson || "") + " >> /tmp/browser-router-ask-smoketest.log"])
  }

  function close() {
    root.opened = false
    Quickshell.execDetached(["bash", "-c", "echo closed >> /tmp/browser-router-ask-smoketest.log"])
  }

  function isBusy() {
    return root.opened ? "true" : "false"
  }
}
