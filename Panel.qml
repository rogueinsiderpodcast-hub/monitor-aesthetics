import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "FilterModel.js" as FilterModel

// The Screen FX lab: toggles, sliders and preset chips that compose a GLSL
// post-processing shader and push it to Hyprland's decoration:screen_shader.
//
// Pipeline guarantees:
//   - every generated shader passes glslangValidator before it is applied
//     (Hyprland fails silently on a bad screen shader, so we fail loudly)
//   - an `animated` stack (animated grain or CRT flicker) needs
//     debug:damage_tracking=0 to repaint; the previous value is remembered
//     and restored when the stack goes static or empty
//   - a foreign screen shader (some other tool's) is left untouched while we
//     are idle, and restored on "Clear all" instead of being lost
//   - `configreloaded` wipes eval-applied options, so the stack is re-applied
//     whenever Hyprland reloads its config
//
// State persists to ~/.local/state/screenfx/{state.json,current.frag}. The
// bar widgets on every monitor watch state.json to light their icon.
Panel {
  id: root
  moduleName: "fichte.screenfx"
  ipcTarget: "fichte.screenfx"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Model
  property var filterState: FilterModel.defaultState()
  property bool stateLoaded: false
  // Exact bytes we last wrote to state.json, so the FileView's own change echo
  // is not mistaken for an external edit.
  property string lastSaved: ""
  readonly property string presetId: FilterModel.matchingPreset(root.filterState)

  // ---- Keyboard cursor. Omarchy panels never hand Tab focus to individual
  //      controls (PanelKeyCatcher owns the keys), so the panel drives a
  //      cursor across its interactive rows instead.
  property bool cursorActive: false
  property int cursorIndex: 0
  property int groupCursorIndex: 0
  readonly property var effectBlocks: [grainBlock, aberrationBlock, keyspillBlock, scanlinesBlock, vignetteBlock, flickerBlock]

  // ---- Apply pipeline
  property bool fxApplied: false
  property string statusMessage: ""
  property string foreignShader: ""
  property var queuedEval: []
  property bool damageReading: false
  property bool damageEnsured: false
  property bool damageOwned: false
  // True once we have actually pushed our own shader into the slot. An inactive
  // apply must not clear a screen_shader we never set (which would wipe a
  // user-configured or foreign shader on every shell start).
  property bool slotOwned: false
  property real savedDamage: -1
  property string lastValidationError: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/screenfx/"
  readonly property string statePath: stateDir + "state.json"
  readonly property string shaderPath: stateDir + "current.frag"

  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Count of active effects for the summary line under the controls.
  readonly property int activeEffectCount: root.countActiveEffects()
  readonly property string appliedLabel: root.fxApplied
    ? (presetId !== "" ? String(presetId) : (activeEffectCount > 0 ? activeEffectCount + " effect" + (activeEffectCount > 1 ? "s" : "") : "on"))
    : "off"

  function countActiveEffects() {
    var n = 0
    for (var i = 0; i < FilterModel.EFFECT_KEYS.length; i++) {
      var key = FilterModel.EFFECT_KEYS[i]
      if (root.filterState[key] && root.filterState[key].on) n++
    }
    if (root.filterState.grade !== "none") n++
    return n
  }

  // ---------------------------------------------------------------- lifecycle

  function open() {
    root.cursorActive = false
    root.cursorIndex = 0
    // Re-read the shared state file: every monitor has its own panel instance,
    // and one opened here must not act on the snapshot it took at shell start.
    stateFile.reload()
    root.probeShader()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---------------------------------------------------------------- editing

  function setOn(key, on) {
    root.setParam(key, "on", on)
  }

  function setParam(key, param, value) {
    var next = {}
    for (var k in root.filterState) next[k] = root.filterState[k]
    if (param !== undefined && next[key] !== null && typeof next[key] === "object") {
      var effect = {}
      for (var p in next[key]) effect[p] = next[key][p]
      effect[param] = value
      next[key] = effect
    } else {
      next[key] = value
    }
    root.filterState = FilterModel.normalize(next)
    root.markChanged()
  }

  function applyPreset(id) {
    root.filterState = FilterModel.presetState(id)
    root.markChanged()
  }

  function clearAll() {
    root.filterState = FilterModel.defaultState()
    root.statusMessage = ""
    root.markChanged()
  }

  function percent(value) {
    return Math.round(Number(value) * 100) + "%"
  }

  // ---------------------------------------------------------------- keyboard cursor

  // Ordered list of interactive rows: preset chips, then each effect's toggle
  // plus (when on) its sliders and mode chips, then the grade chips, then the
  // Clear button. Rebuilt on demand so it follows toggles and visibility.
  function cursorRows() {
    var rows = [{ kind: "group", group: presetGroup }]
    for (var i = 0; i < root.effectBlocks.length; i++) {
      var b = root.effectBlocks[i]
      if (!b) continue
      rows.push({ kind: "toggle", block: b })
      if (b.state && b.state.on) {
        var kids = b.contentColumn.children
        for (var j = 0; j < kids.length; j++) {
          var c = kids[j]
          if (!c) continue
          if (c.options !== undefined) rows.push({ kind: "group", group: c })
          else if (c.label !== undefined) rows.push({ kind: "slider", row: c })
        }
      }
    }
    rows.push({ kind: "group", group: gradeGroup })
    rows.push({ kind: "button", button: clearButton })
    return rows
  }

  function cursorRowItem(active) {
    if (!active) return null
    if (active.kind === "toggle") return active.block.toggleControl
    if (active.kind === "slider") return active.row
    if (active.kind === "group") return active.group
    if (active.kind === "button") return active.button
    return null
  }

  function syncCursor() {
    var rows = root.cursorRows()
    if (root.cursorIndex > rows.length - 1) root.cursorIndex = rows.length - 1
    if (root.cursorIndex < 0) root.cursorIndex = 0

    presetGroup.cursorIndex = -1
    gradeGroup.cursorIndex = -1
    clearButton.hasCursor = false
    for (var i = 0; i < root.effectBlocks.length; i++) {
      var b = root.effectBlocks[i]
      if (!b) continue
      if (b.toggleControl) b.toggleControl.hasCursor = false
      var kids = b.contentColumn ? b.contentColumn.children : []
      for (var j = 0; j < kids.length; j++) {
        var c = kids[j]
        if (!c) continue
        if (c.options !== undefined) c.cursorIndex = -1
        else if (c.label !== undefined) c.hasCursor = false
      }
    }

    if (!root.cursorActive) return
    var active = rows[root.cursorIndex]
    if (!active) return
    if (active.kind === "group") active.group.cursorIndex = root.groupCursorIndex
    else if (active.kind === "toggle") active.block.toggleControl.hasCursor = true
    else if (active.kind === "slider") active.row.hasCursor = true
    else if (active.kind === "button") active.button.hasCursor = true

    var item = root.cursorRowItem(active)
    if (item && controlsFlickable) {
      var pos = item.mapToItem(controlsColumn, 0, 0)
      var margin = Style.space(28)
      var top = pos.y
      var bottom = top + item.height
      if (top < controlsFlickable.contentY + margin)
        controlsFlickable.contentY = Math.max(0, top - margin)
      else if (bottom > controlsFlickable.contentY + controlsFlickable.height - margin)
        controlsFlickable.contentY = Math.min(
          Math.max(0, controlsFlickable.contentHeight - controlsFlickable.height),
          bottom - controlsFlickable.height + margin)
    }
  }

  function moveCursor(dx, dy) {
    var rows = root.cursorRows()
    if (rows.length === 0) return
    var active = rows[root.cursorIndex]
    if (dx !== 0) {
      if (active.kind === "group") {
        root.groupCursorIndex = Math.max(0, Math.min(active.group.options.length - 1,
          root.groupCursorIndex + dx))
        root.syncCursor()
      } else if (active.kind === "slider") {
        var delta = dx * active.row.step
        var v = Math.max(active.row.minimum, Math.min(active.row.maximum, active.row.value + delta))
        if (active.row.integer) v = Math.round(v)
        active.row.moved(v)
        active.row.released(v)
      }
      return
    }
    if (dy !== 0) {
      root.cursorIndex = Math.max(0, Math.min(rows.length - 1, root.cursorIndex + dy))
      var now = rows[root.cursorIndex]
      if (now.kind === "group") {
        var sel = now.group.selectedOptionIndex()
        root.groupCursorIndex = sel < 0 ? 0 : sel
      }
      root.syncCursor()
    }
  }

  function activateCursor() {
    var rows = root.cursorRows()
    var active = rows[root.cursorIndex]
    if (!active) return
    if (active.kind === "toggle") {
      root.setOn(active.block.key, !active.block.state.on)
      Qt.callLater(root.syncCursor)
    } else if (active.kind === "group") {
      var idx = Math.max(0, Math.min(active.group.options.length - 1, root.groupCursorIndex))
      active.group.changed(active.group.optionValue(active.group.options[idx]))
      Qt.callLater(root.syncCursor)
    } else if (active.kind === "button") {
      active.button.clicked()
    }
  }

  // ---------------------------------------------------------------- persistence

  function markChanged() {
    root.persist()
    applyTimer.restart()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.ingestState(text())
    onLoadFailed: root.ingestState("")
    onFileChanged: reload()
  }

  FileView {
    id: shaderFile
    path: root.shaderPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: applyTimer
    interval: 120
    repeat: false
    onTriggered: root.applyNow()
  }

  Timer {
    id: saveTimer
    interval: 250
    repeat: false
    onTriggered: root.flushState()
  }

  function persist() {
    if (!root.stateLoaded) return
    saveTimer.restart()
  }

  // Adopt state from the shared file. Runs on first load and on external edits
  // (another monitor's panel, or the CLI), so every panel stays in sync; the
  // echo of our own write is ignored by comparing against lastSaved.
  function ingestState(raw) {
    if (root.stateLoaded && raw === root.lastSaved) return
    var parsed = null
    try { parsed = JSON.parse(raw || "{}") } catch (e) { parsed = null }
    root.filterState = parsed && parsed.state
      ? FilterModel.normalize(parsed.state)
      : FilterModel.defaultState()
    root.stateLoaded = true
    root.scheduleApply()
  }

  function flushState() {
    if (!root.stateLoaded) return
    var text = JSON.stringify({
      version: 1,
      active: FilterModel.isActive(root.filterState),
      state: root.filterState
    }, null, 2) + "\n"
    root.lastSaved = text
    stateFile.setText(text)
  }

  function scheduleApply() {
    if (!root.stateLoaded) return
    applyTimer.restart()
  }

  // ---------------------------------------------------------------- apply chain

  // Steps run through one serialized hyprctl Process so a burst of slider
  // updates can't interleave eval calls. Reads (damage_tracking, shader
  // option) stay separate Procesess and re-enter the queue from their
  // callbacks.
  Process {
    id: applyProc
    running: false
    onExited: {
      root.fxApplied = FilterModel.isActive(root.filterState)
      root.nextEval()
    }
  }

  function queueEval(expr) {
    root.queuedEval = root.queuedEval.concat([expr])
    if (!applyProc.running) root.nextEval()
  }

  function nextEval() {
    if (root.queuedEval.length === 0) return
    var expr = root.queuedEval[0]
    root.queuedEval = root.queuedEval.slice(1)
    applyProc.command = ["hyprctl", "eval", expr]
    applyProc.running = true
  }

  // Escape a value so it can be embedded inside a double-quoted Lua string in
  // an `hyprctl eval` chunk. Without this a crafted decoration:screen_shader
  // value would be executed as Lua when we restore it.
  function luaStr(s) {
    return String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/[\r\n]/g, " ")
  }

  function shaderExpr() {
    return "hl.config({ decoration = { screen_shader = \"" + root.luaStr(root.shaderPath) + "\" } })"
  }

  // Push our shader and record that we now own the slot, so a later inactive
  // apply does not clear a shader we never set.
  function applyOwnShader() {
    root.slotOwned = true
    root.queueEval(root.shaderExpr())
  }

  // Validate with glslangValidator and, only on success, apply.
  Process {
    id: validateProc
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastValidationError = text
    }
    onExited: function(code) {
      if (code !== 0) {
        root.statusMessage = "Shader rejected: " + String(root.lastValidationError || "validation failed").trim()
        root.fxApplied = false
        return
      }
      root.statusMessage = ""
      if (FilterModel.isAnimated(root.filterState)) {
        root.ensureDamageZero()
      } else {
        // Stack went static (or was never animated): give damage_tracking back
        // if we are the one who lowered it, then apply the static shader.
        if (root.damageOwned && root.savedDamage >= 0) {
          root.queueEval("hl.config({ debug = { damage_tracking = " + Math.round(root.savedDamage) + " } })")
          root.savedDamage = -1
        }
        root.damageOwned = false
        root.damageEnsured = false
        root.applyOwnShader()
      }
    }
  }

  // Reads debug:damage_tracking once, remembers the value only if it is not
  // already 0, then queues the set + apply in order.
  Process {
    id: damageReadProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onDamageRead(text)
    }
  }

  function ensureDamageZero() {
    if (root.damageEnsured || root.damageReading) {
      if (root.damageEnsured) root.applyOwnShader()
      return
    }
    root.damageReading = true
    damageReadProc.command = ["hyprctl", "-j", "getoption", "debug:damage_tracking"]
    damageReadProc.running = true
  }

  function onDamageRead(raw) {
    root.damageReading = false
    var value = 2
    try { value = JSON.parse(raw || "{}").int } catch (e) { value = 2 }
    if (value === 0) {
      root.damageEnsured = true
      root.applyOwnShader()
      return
    }
    if (root.savedDamage < 0) root.savedDamage = value >= 0 ? value : 2
    root.damageOwned = true
    root.damageEnsured = true
    root.queueEval("hl.config({ debug = { damage_tracking = 0 } })")
    root.applyOwnShader()
  }

  function applyNow() {
    if (!root.stateLoaded) return
    var composed = FilterModel.compose(root.filterState)
    if (!composed.active) {
      // Only release the slot if we are the ones who took it; never touch a
      // user-configured or foreign shader just because our stack is empty.
      if (root.slotOwned) root.clearShader()
      return
    }
    shaderFile.setText(composed.source)
    Qt.callLater(function() {
      validateProc.command = ["glslangValidator", root.shaderPath]
      validateProc.running = true
    })
  }

  // Empty stack: clear the slot and undo whatever damage_tracking / foreign
  // shader state we touched.
  function clearShader() {
    shaderFile.setText("")
    root.slotOwned = false
    root.queueEval("hl.config({ decoration = { screen_shader = \"\" } })")
    if (root.foreignShader !== "") {
      root.queueEval("hl.config({ decoration = { screen_shader = \"" + root.luaStr(root.foreignShader) + "\" } })")
      root.foreignShader = ""
    }
    if (root.savedDamage >= 0) {
      root.queueEval("hl.config({ debug = { damage_tracking = " + Math.round(root.savedDamage) + " } })")
      root.savedDamage = -1
    }
    root.damageOwned = false
    root.damageEnsured = false
    root.fxApplied = false
    root.statusMessage = "Effects off"
  }

  // ---------------------------------------------------------------- hybridland state

  Process {
    id: probeProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onProbe(text)
    }
  }

  function probeShader() {
    probeProc.command = ["hyprctl", "-j", "getoption", "decoration:screen_shader"]
    probeProc.running = true
  }

  function onProbe(raw) {
    var current = ""
    try { current = String(JSON.parse(raw || "{}").str || "") } catch (e) { current = "" }
    if (current === root.shaderPath) {
      // Leftover of ours from a previous session: we own the slot.
      root.slotOwned = true
    } else if (current !== "") {
      root.foreignShader = current
    }
    root.scheduleApply()
  }

  // Hyprland `configreloaded` wipes eval-applied options (screen_shader,
  // damage_tracking) back to the config file's values, so re-apply whatever
  // the stack wants.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") root.scheduleApply()
    }
  }

  // ---------------------------------------------------------------- ui

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(controlsColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          root.syncCursor()
          return
        }
        root.moveCursor(dx, dy)
      }

      onActivateRequested: function() {
        if (root.cursorActive) root.activateCursor()
      }

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: controlsFlickable
        anchors.fill: parent
        contentWidth: controlsColumn.width
        contentHeight: controlsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: controlsColumn
          width: controlsFlickable.width
          spacing: Style.space(8)

          // ---- Header
          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: "SCREEN FX"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              font.letterSpacing: 1
            }

            Rectangle {
              width: Style.space(7)
              height: Style.space(7)
              radius: height / 2
              anchors.verticalCenter: parent.verticalCenter
              color: root.fxApplied ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.6)
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.appliedLabel
              color: root.fxApplied ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Presets
          PanelSectionHeader {
            text: "PRESETS"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          ButtonGroup {
            id: presetGroup
            width: parent.width
            options: FilterModel.PRESETS
            value: root.presetId
            foreground: root.contentForeground
            background: Commons.Color.popups.background
            accent: Commons.Color.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { root.applyPreset(v) }
          }

          PanelSeparator {}
          PanelSectionHeader {
            text: "EFFECTS"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          // Each effect block owns its toggle and, when enabled, its params.
          EffectBlock {
            id: grainBlock
            key: "grain"
            label: "Film grain"
            description: "Per-cell hash noise, animated (dancing seed) or static."

            ParamRow {
              label: "Intensity"
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.filterState.grain.intensity
              formatter: function(v) { return root.percent(v) }
              onMoved: function(v) { root.setParam("grain", "intensity", v) }
              onReleased: function(v) { root.setParam("grain", "intensity", v) }
            }

            ParamRow {
              label: "Cell size"
              minimum: 1
              maximum: 8
              step: 1
              integer: true
              value: root.filterState.grain.size
              formatter: function(v) { return String(Math.round(v)) + "px" }
              onMoved: function(v) { root.setParam("grain", "size", v) }
              onReleased: function(v) { root.setParam("grain", "size", v) }
            }

            ButtonGroup {
              id: grainModeGroup
              width: parent.width
              options: [
                { value: "animated", label: "Animated" },
                { value: "static", label: "Static" }
              ]
              value: root.filterState.grain.mode
              foreground: root.contentForeground
              background: Commons.Color.popups.background
              accent: Commons.Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onChanged: function(v) { root.setParam("grain", "mode", v) }
            }
          }

          EffectBlock {
            id: aberrationBlock
            key: "aberration"
            label: "Chromatic aberration"
            description: "Radial split of the color channels toward the edges."

            ParamRow {
              label: "Strength"
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.filterState.aberration.strength
              formatter: function(v) { return root.percent(v) }
              onMoved: function(v) { root.setParam("aberration", "strength", v) }
              onReleased: function(v) { root.setParam("aberration", "strength", v) }
            }
          }

          EffectBlock {
            id: keyspillBlock
            key: "keyspill"
            label: "RGB keyspill"
            description: "Channels bleed past their lateral edges, VHS-style."

            ParamRow {
              label: "Bleed"
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.filterState.keyspill.bleed
              formatter: function(v) { return root.percent(v) }
              onMoved: function(v) { root.setParam("keyspill", "bleed", v) }
              onReleased: function(v) { root.setParam("keyspill", "bleed", v) }
            }
          }

          EffectBlock {
            id: scanlinesBlock
            key: "scanlines"
            label: "Scanlines"
            description: "Darkened rows across the framebuffer, pixel-aligned."

            ParamRow {
              label: "Opacity"
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.filterState.scanlines.opacity
              formatter: function(v) { return root.percent(v) }
              onMoved: function(v) { root.setParam("scanlines", "opacity", v) }
              onReleased: function(v) { root.setParam("scanlines", "opacity", v) }
            }

            ParamRow {
              label: "Density"
              minimum: 2
              maximum: 8
              step: 1
              integer: true
              value: root.filterState.scanlines.density
              formatter: function(v) { return String(Math.round(v)) + "px" }
              onMoved: function(v) { root.setParam("scanlines", "density", v) }
              onReleased: function(v) { root.setParam("scanlines", "density", v) }
            }
          }

          EffectBlock {
            id: vignetteBlock
            key: "vignette"
            label: "Vignette"
            description: "Falloff toward the screen corners."

            ParamRow {
              label: "Strength"
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.filterState.vignette.strength
              formatter: function(v) { return root.percent(v) }
              onMoved: function(v) { root.setParam("vignette", "strength", v) }
              onReleased: function(v) { root.setParam("vignette", "strength", v) }
            }
          }

          EffectBlock {
            id: flickerBlock
            key: "flicker"
            label: "CRT flicker"
            description: "Slow brightness wobble. Needs the animated damage scan."

            ParamRow {
              label: "Amount"
              minimum: 0
              maximum: 1
              step: 0.05
              value: root.filterState.flicker.amount
              formatter: function(v) { return root.percent(v) }
              onMoved: function(v) { root.setParam("flicker", "amount", v) }
              onReleased: function(v) { root.setParam("flicker", "amount", v) }
            }
          }

          PanelSeparator {}
          PanelSectionHeader {
            text: "COLOR GRADE"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          ButtonGroup {
            id: gradeGroup
            width: parent.width
            options: FilterModel.GRADES
            value: root.filterState.grade
            foreground: root.contentForeground
            background: Commons.Color.popups.background
            accent: Commons.Color.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { root.setParam("grade", undefined, v) }
          }

          PanelSeparator {}

          // ---- Warnings & status
          Text {
            visible: root.foreignShader !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: "Another shader was active: " + root.foreignShader + " — restoring it on Clear all."
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.statusMessage !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.statusMessage
            color: Commons.Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: activeEffectCount === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "Pick a preset, or switch effects on below. Everything applies to the whole desktop on the GPU, and survives restarts until you clear it."
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---- Footer
          Row {
            width: parent.width
            spacing: Style.space(10)

            Button {
              id: clearButton
              text: "Clear all"
              bordered: true
              focusable: true
              foreground: root.contentForeground
              background: Commons.Color.popups.background
              accent: Commons.Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.clearAll()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "works immediately"
              color: Qt.darker(root.contentForeground, 1.7)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- boot

  Process {
    id: mkdirProc
    running: false
    command: ["mkdir", "-p", root.stateDir]
    onExited: {
      Qt.callLater(function() {
        stateFile.reload()
      })
    }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    // Detect a leftover/foreign shader at boot so a stale stack of ours is
    // released, and a foreign shader is remembered for restore.
    root.probeShader()
  }

  Component.onDestruction: {
    root.flushState()
  }

  // ------------------------------------------------------------- components

  // A labeled on/off row whose parameter rows only appear while enabled.
  component EffectBlock: Column {
    id: eb
    required property string key
    required property string label
    required property string description
    width: parent.width
    spacing: Style.space(4)
    readonly property var state: root.filterState[eb.key]
    readonly property alias toggleControl: blockToggle
    readonly property alias contentColumn: paramColumn

    Toggle {
      id: blockToggle
      width: parent.width
      label: eb.label
      description: eb.description
      foreground: root.contentForeground
      accent: Commons.Color.accent
      fontFamily: root.contentFontFamily
      checked: eb.state.on
      onClicked: root.setOn(eb.key, !eb.state.on)
    }

    Column {
      id: paramColumn
      visible: eb.state.on
      width: parent.width
      spacing: Style.space(4)
    }

    default property alias content: paramColumn.children
  }

  // Label + PanelSlider + readout on one row.
  component ParamRow: Row {
    id: p
    required property string label
    property real minimum: 0
    property real maximum: 1
    property real step: 0.05
    property bool integer: false
    property real value: 0
    property var formatter: null
    property bool hasCursor: false
    signal moved(real v)
    signal released(real v)
    width: parent.width
    spacing: Style.spacing.md
    height: Math.max(Style.space(24), slider.implicitHeight)

    Text {
      id: pLabel
      width: Style.space(120)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: (p.hasCursor ? "\u25B8 " : "") + p.label
      color: p.hasCursor ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.5)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }

    PanelSlider {
      id: slider
      width: p.width - pLabel.width - pValue.width - p.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      bar: root.bar
      value: p.value
      minimum: p.minimum
      maximum: p.maximum
      step: p.step
      integer: p.integer
      onMoved: function(v) { p.moved(v) }
      onReleased: function(v) { p.released(v) }
    }

    Text {
      id: pValue
      width: Style.space(46)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: p.formatter ? p.formatter(p.value) : String(p.value)
      horizontalAlignment: Text.AlignRight
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

}
