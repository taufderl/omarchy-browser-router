import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// The popup shown by browser-router's ask mode for a domain with no
// explicit route. bin/browser-router (bash) summons this via
// `omarchy-shell shell summon browser-router.ask <payloadJson>`, where
// payloadJson is `{host, browsers, selectionFile, doneFile}` -- browsers
// is the JSON array `browser-router-config installed` prints, so only
// browsers actually installed on this machine are ever offered.
//
// bash can't get a synchronous answer back from a QML popup (nothing here
// can block waiting for a click), so the answer goes out the same way
// Omarchy's own image picker solves this: write it to `selectionFile` and
// touch `doneFile`, which bash is polling for. See
// /usr/share/omarchy/shell/plugins/image-picker/ImagePicker.qml and
// /usr/share/omarchy/bin/omarchy-menu-images for the pattern this mirrors.
Item {
  id: root

  property bool opened: false
  // True while a request is being shown/answered -- isBusy() reports this
  // to bash so a second unmatched-domain link while this popup is open
  // falls back to default rather than clobbering the first dialog.
  property bool requestActive: false

  property string host: ""
  property var browserOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property string browserChoice: ""
  property string rememberChoice: "remember"

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", root.border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property string fontFamily: Style.font.menuFamily
  property int cardWidth: Math.min(Style.space(360), panel.width - Style.gapsOut * 2)

  // The done-file signal must not be a plain truncating write to a fixed
  // path: bash creates that path with mktemp, deletes it, then polls for
  // it to reappear (see bin/browser-router), so the path is briefly
  // unoccupied and its name is visible in this process's argv. Writing
  // straight to it (`: > doneFile`) would follow a symlink planted there
  // in that window. mktemp a fresh file (guaranteed not pre-existing) and
  // `mv` it into place instead -- rename(2) replaces whatever's at the
  // destination path without dereferencing it, symlink or not.
  function touchDoneFileCmd(doneFile) {
    return "t=$(mktemp); : > \"$t\"; mv -f \"$t\" " + Util.shellQuote(doneFile)
  }

  // Writes the answer for the CURRENTLY ACTIVE request (root.selectionFile
  // / root.doneFile) and touches its done-file. Quoted via Util.shellQuote,
  // not string-interpolated raw -- same rule this project applies to every
  // other shell-command construction.
  function resolveRequest(browser, remember) {
    var cmd = "printf '%s\\n%s\\n' " + Util.shellQuote(browser || "") + " " + Util.shellQuote(remember || "")
      + " > " + Util.shellQuote(root.selectionFile)
      + "; " + root.touchDoneFileCmd(root.doneFile)
    Quickshell.execDetached(["bash", "-c", cmd])
  }

  // Resolves an arbitrary (selectionFile, doneFile) pair as empty/cancelled
  // -- used both for the normal cancel path and for a request that arrives
  // while another is already showing (see open()).
  function resolveEmptyFor(selectionFile, doneFile) {
    if (!selectionFile || !doneFile) return
    var cmd = "> " + Util.shellQuote(selectionFile) + "; " + root.touchDoneFileCmd(doneFile)
    Quickshell.execDetached(["bash", "-c", cmd])
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    if (root.requestActive) {
      // bash checks isBusy() before summoning, but that check and this
      // summon aren't atomic. Don't disturb the dialog already showing --
      // just resolve the new request as empty so its caller falls back.
      root.resolveEmptyFor(payload.selectionFile || "", payload.doneFile || "")
      return
    }

    var browsers = payload.browsers || []
    root.host = payload.host || ""
    root.browserOptions = browsers.map(function(b) { return { value: b.id, label: b.label } })
    root.selectionFile = payload.selectionFile || ""
    root.doneFile = payload.doneFile || ""
    root.browserChoice = browsers.length > 0 ? browsers[0].id : ""
    root.rememberChoice = "remember"
    root.requestActive = true
    root.opened = true

    Qt.callLater(function() { if (browserGroup) browserGroup.forceActiveFocus() })
  }

  // Invoked by shell.hide() -- resolve as cancelled so a waiting bash poll
  // loop never hangs just because something external closed the panel.
  function close() {
    root.cancel()
  }

  function cancel() {
    if (root.requestActive) root.resolveEmptyFor(root.selectionFile, root.doneFile)
    root.opened = false
    root.requestActive = false
  }

  // Called by bash when its own wait times out, so a popup left open after
  // the caller gave up doesn't linger silently.
  function cancelAsk(_arg) {
    root.cancel()
  }

  function confirm() {
    if (!root.browserChoice) return
    root.resolveRequest(root.browserChoice, root.rememberChoice)
    root.opened = false
    root.requestActive = false
  }

  function isBusy() {
    return root.requestActive ? "true" : "false"
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "browser-router-ask"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(contentColumn.implicitHeight + root.contentMargin * 2, panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancel()
            event.accepted = true
          }
        }
      }

      Column {
        id: contentColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        Text {
          width: parent.width
          text: "New site: " + root.host
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          wrapMode: Text.WordWrap
        }

        Text {
          text: "Open with"
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ButtonGroup {
          id: browserGroup
          options: root.browserOptions
          value: root.browserChoice
          foreground: root.foreground
          onChanged: function(v) { root.browserChoice = v }
        }

        Text {
          text: "Remember this choice?"
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ButtonGroup {
          id: rememberGroup
          options: [{ value: "once", label: "Once" }, { value: "remember", label: "Remember" }]
          value: root.rememberChoice
          foreground: root.foreground
          onChanged: function(v) { root.rememberChoice = v }
        }

        Row {
          anchors.right: parent.right
          spacing: Style.spacing.md

          Button {
            text: "Cancel"
            focusable: true
            bordered: true
            foreground: root.foreground
            onClicked: root.cancel()
          }

          Button {
            text: "Open"
            focusable: true
            bordered: true
            foreground: root.foreground
            onClicked: root.confirm()
          }
        }
      }
    }
  }
}
