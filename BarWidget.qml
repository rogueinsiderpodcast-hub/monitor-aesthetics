import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon for Screen FX: a wand-sparkle that lights up in the accent color
// while a filter stack is live, and the parameterized host for the panel
// popup. The active flag lives in the shared state file
// (~/.local/state/screenfx/state.json), watched here so every monitor's icon
// reflects the same truth without any cross-instance IPC.
BarWidget {
  id: root
  moduleName: "fichte.screenfx"

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/screenfx/"
  readonly property string statePath: stateDir + "state.json"

  // Whether a filter stack is currently applied. Mirrors the state file's
  // `active` flag; the panel owns the file, every bar icon only reads it.
  property bool fxActive: false

  // ---- Panel popup. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Headless control surface: every panel action is reachable over the
  // omarchy-shell IPC channel (omarchy-shell fichte.screenfx <verb>). ShellIpc
  // forwards CLI args as strings, so every parameter is typed `string` and
  // coerced here.
  function applyPreset(id) {
    if (panelLoader.item) panelLoader.item.applyPreset(String(id))
  }

  function clearAll() {
    if (panelLoader.item) panelLoader.item.clearAll()
  }

  function setParam(key, param, value) {
    if (!panelLoader.item) return
    var v = Number(value)
    if (!isFinite(v) || String(value).trim() === "") v = value
    panelLoader.item.setParam(String(key), String(param), v)
  }

  function setGrade(id) {
    if (panelLoader.item) panelLoader.item.setParam("grade", undefined, String(id))
  }

  function setEffect(key, on) {
    if (panelLoader.item) panelLoader.item.setOn(String(key), on === "true" || on === "1" || on === true)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  ShellIpc {
    target: "fichte.screenfx"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function preset(id: string): void { root.applyPreset(id) }
    function clear(): void { root.clearAll() }
    function setEffect(key: string, on: string): void { root.setEffect(key, on) }
    function setParam(key: string, param: string, value: string): void { root.setParam(key, param, value) }
    function grade(id: string): void { root.setGrade(id) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // fa-wand_sparkles (U+EF15) — present in the JetBrains Mono Nerd Font cmap.
    text: "\uEF15"
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    fontSize: Style.font.icon
    // A glyph, so monospace figure metrics say nothing about the em.
    centerFigures: false
    foreground: root.fxActive
      ? Commons.Color.accent
      : (root.bar ? root.bar.barForeground : Commons.Color.foreground)
    tooltipText: root.fxActive ? "Screen FX active — click to edit" : "Screen FX — whole-screen retro filters"

    onPressed: function(buttonPressed) {
      if (buttonPressed === Qt.LeftButton) root.togglePanel()
    }
  }

  // Authoritative state lives in the file, so the bar icon stays honest
  // across monitors and shell restarts without owning any of the apply
  // pipeline.
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyActiveFlag(text())
    onLoadFailed: root.fxActive = false
  }

  function applyActiveFlag(raw) {
    var active = false
    try {
      var parsed = JSON.parse(raw || "{}")
      active = !!(parsed && parsed.active === true)
    } catch (e) {
      active = false
    }
    root.fxActive = active
  }
}
