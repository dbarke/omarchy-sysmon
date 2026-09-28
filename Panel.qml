import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// CPU and memory in the bar.
//
// Everything on screen is a difference between two samples of `poll.sh`, not
// a reading taken once. That is the whole reason this widget exists rather
// than a command module printing a number: /proc gives out counters since
// boot, and a counter since boot is a constant that tells you nothing about
// now. The script stays dumb and emits raw counters; the arithmetic that
// turns them into "18%" happens here, where the previous sample lives.
//
// Two things here that a percentage alone does not give you:
//
//   Per-core bars. One pegged thread on a 16-core machine is 6% aggregate --
//   invisible in a single figure, obvious the moment the cores are drawn
//   separately, and usually the actual answer to "why is this slow".
//
//   Pressure. PSI reports the share of wall-clock time that something spent
//   *waiting* on a resource. Memory at 90% with no pressure is a healthy
//   machine with a warm page cache; memory at 70% with pressure climbing is a
//   machine about to thrash. The panel stays quiet until pressure is real.
Panel {
  id: root
  moduleName: "dbarke.sysmon"
  ipcTarget: "dbarke.sysmon"
  manageIpc: false

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent, urgent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool barVertical: bar ? bar.vertical : false

  // ------------------------------------------------------------- settings
  readonly property int intervalMs: Math.max(1, Number(setting("refreshIntervalSec", 2))) * 1000
  readonly property string readout: String(setting("display", "both"))
  readonly property bool showGraph: setting("showGraph", true) !== false
  readonly property int cpuWarnPercent: Number(setting("cpuWarnPercent", 85))
  readonly property int memWarnPercent: Number(setting("memWarnPercent", 85))
  readonly property bool showPerCore: setting("showPerCore", true) !== false
  readonly property int procRows: Math.max(0, Math.min(15, Number(setting("procRows", 5))))
  readonly property string monitorCommand: String(setting("monitorCommand", "omarchy-launch-or-focus-tui btop"))

  // c / m override this while the panel is open; it resets to the setting
  // when the panel closes, so the configured default is what you come back to.
  property string sortBy: String(setting("sortBy", "cpu"))

  // ------------------------------------------------------ previous sample
  // Null until the second poll lands. Every percentage below is undefined
  // before then, and the UI says "—" rather than inventing a zero.
  property var prevCpu: null           // { idle, total }
  property var prevCores: ({})         // index -> { idle, total }
  property var prevProcs: ({})         // pid -> jiffies
  property double prevProcMs: 0

  // --------------------------------------------------------- live readings
  property bool ready: false
  property string lastError: ""
  property double lastPollMs: 0
  property double nowMs: Date.now()

  property real cpuPercent: -1
  property var corePercents: []
  property int runningTasks: 0
  // Uninterruptible sleep. Nearly always zero; when it is not, something is
  // wedged on IO and no CPU or memory figure on this panel will explain it.
  property int blockedTasks: 0
  property int totalTasks: 0

  property real memTotalKb: 0
  property real memAvailKb: 0
  property real memFreeKb: 0
  property real memCacheKb: 0
  property real memShmemKb: 0
  property real swapTotalKb: 0
  property real swapFreeKb: 0

  property var loadAvg: [0, 0, 0]
  property real uptimeSec: 0
  property real tempMilli: -1
  property int cpuMhz: 0
  property string cpuModel: ""

  // resource -> { some, full }, as a share of the last 10 seconds.
  property var psi: ({})

  property var procs: []
  property int pageSize: 4096
  property int clockHz: 100

  // Sparkline trail, oldest first. In memory only and deliberately short:
  // this is "what just happened", not a history anyone would analyse.
  readonly property int graphSamples: 14
  property var cpuTrail: []

  // ------------------------------------------------------------- derived
  readonly property real memUsedKb: Math.max(0, memTotalKb - memAvailKb)
  readonly property real memPercent: memTotalKb > 0 ? (memUsedKb / memTotalKb) * 100 : -1
  readonly property real swapUsedKb: Math.max(0, swapTotalKb - swapFreeKb)
  readonly property real swapPercent: swapTotalKb > 0 ? (swapUsedKb / swapTotalKb) * 100 : 0
  readonly property int coreCount: corePercents.length

  readonly property bool cpuAlarming: cpuWarnPercent > 0 && cpuPercent >= cpuWarnPercent
  readonly property bool memAlarming: memWarnPercent > 0 && memPercent >= memWarnPercent
  readonly property bool alarming: cpuAlarming || memAlarming

  // ------------------------------------------------------------- helpers
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function formatKb(kb) {
    var value = Number(kb)
    if (!isFinite(value) || value < 0) return "—"
    var units = ["K", "M", "G", "T"]
    var i = 0
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
    return value.toFixed(value >= 100 || i === 0 ? 0 : 1).replace(/\.0$/, "") + units[i]
  }

  function formatPercent(value) {
    return value < 0 ? "—" : Math.round(value) + "%"
  }

  function formatUptime(seconds) {
    var minutes = Math.floor(seconds / 60)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return minutes + "m"
  }

  function psiValue(resource, kind) {
    var entry = psi[resource]
    if (!entry) return 0
    var value = Number(entry[kind])
    return isFinite(value) ? value : 0
  }

  // Below a tenth of a percent the figure is noise from a single scheduling
  // hiccup, and a line that is always on screen saying "0.0%" trains you to
  // stop reading it. Silence is the useful default state.
  function psiText(resource, kind, phrasing) {
    var value = psiValue(resource, kind)
    if (value < 0.1) return ""
    return phrasing + " " + value.toFixed(1) + "% of the last 10s"
  }

  // ---------------------------------------------------------------- colour
  // Severity is mixed from the theme rather than stepped through hardcoded
  // colours: an Omarchy palette has a foreground and an urgent and no amber
  // in between, so the in-between is made by tinting one toward the other.
  function loadColor(percent, threshold) {
    if (percent < 0) return dim
    if (threshold > 0 && percent >= threshold) return urgent
    var ceiling = threshold > 0 ? threshold : 100
    var severity = clamp(percent / ceiling, 0, 1)
    if (severity < 0.5) return foreground
    return Qt.tint(foreground, alpha(urgent, (severity - 0.5) * 1.1))
  }

  // -------------------------------------------------------------- sampling
  function refreshNow() {
    if (!pollProc.running) {
      // Walking /proc for ~500 processes costs about 30ms and is only worth
      // paying for while someone is looking at the table it feeds.
      pollProc.command = ["bash", root.scriptPath, (opened && procRows > 0) ? "full" : "brief"]
      pollProc.running = true
    }
  }

  readonly property string scriptPath: Qt.resolvedUrl("poll.sh").toString().replace(/^file:\/\//, "")

  function applyOutput(text) {
    var raw = String(text || "")
    if (raw.trim() === "") {
      lastError = "poll.sh produced no output"
      return
    }

    var lines = raw.split("\n")
    var nextCpu = null
    var nextCores = ({})
    var coreOrder = []
    var nextProcs = ({})
    var nextPsi = ({})
    var sawProcs = false
    var now = Date.now()

    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      switch (f[0]) {
      case "cpu":
        nextCpu = { idle: Number(f[1]), total: Number(f[2]) }
        break
      case "core":
        nextCores[Number(f[1])] = { idle: Number(f[2]), total: Number(f[3]) }
        coreOrder.push(Number(f[1]))
        break
      case "running":
        runningTasks = Number(f[1])
        break
      case "blocked":
        blockedTasks = Number(f[1])
        break
      case "mem":
        memTotalKb = Number(f[1]); memAvailKb = Number(f[2])
        memFreeKb = Number(f[3]); memCacheKb = Number(f[4]); memShmemKb = Number(f[5])
        break
      case "swap":
        swapTotalKb = Number(f[1]); swapFreeKb = Number(f[2])
        break
      case "load":
        loadAvg = [Number(f[1]), Number(f[2]), Number(f[3])]
        totalTasks = Number(f[4])
        break
      case "uptime":
        uptimeSec = Number(f[1])
        break
      case "psi":
        if (!nextPsi[f[1]]) nextPsi[f[1]] = ({})
        nextPsi[f[1]][f[2]] = Number(f[3])
        break
      case "temp":
        tempMilli = Number(f[1])
        break
      case "mhz":
        cpuMhz = Number(f[1])
        break
      case "model":
        // Trademark furniture is half the width of an Intel model string and
        // none of the information in it.
        cpuModel = String(f[1] || "").replace(/\((R|TM)\)/g, "").replace(/\s+/g, " ").trim()
        break
      case "pagesize":
        pageSize = Number(f[1]) || pageSize
        break
      case "hz":
        clockHz = Number(f[1]) || clockHz
        break
      case "proc":
        sawProcs = true
        nextProcs[f[1]] = {
          pid: f[1],
          jiffies: Number(f[2]),
          rssKb: (Number(f[3]) * pageSize) / 1024,
          threads: Number(f[4]),
          comm: String(f[5] || "")
        }
        break
      }
    }

    psi = nextPsi

    // ---- CPU, aggregate and per core
    if (nextCpu) {
      if (prevCpu) {
        var dTotal = nextCpu.total - prevCpu.total
        var dIdle = nextCpu.idle - prevCpu.idle
        // A counter that went backwards means a suspend/resume or a CPU
        // coming online: drop the delta rather than draw a spike that never
        // happened, and let the next pair of samples recover.
        if (dTotal > 0 && dIdle >= 0) {
          cpuPercent = clamp((1 - dIdle / dTotal) * 100, 0, 100)
          var trail = cpuTrail.slice()
          trail.push(cpuPercent)
          if (trail.length > graphSamples) trail = trail.slice(trail.length - graphSamples)
          cpuTrail = trail
        }
      }
      prevCpu = nextCpu
    }

    coreOrder.sort(function (a, b) { return a - b })
    var percents = []
    for (var c = 0; c < coreOrder.length; c++) {
      var index = coreOrder[c]
      var current = nextCores[index]
      var previous = prevCores[index]
      var percent = -1
      if (previous) {
        var coreTotal = current.total - previous.total
        var coreIdle = current.idle - previous.idle
        if (coreTotal > 0 && coreIdle >= 0)
          percent = clamp((1 - coreIdle / coreTotal) * 100, 0, 100)
      }
      // Hold the last known value over a bad delta so one skipped sample does
      // not knock a single bar to zero while its neighbours keep drawing.
      percents.push(percent < 0 && c < corePercents.length ? corePercents[c] : percent)
    }
    if (percents.length > 0) corePercents = percents
    prevCores = nextCores

    // ---- processes
    if (sawProcs) {
      if (prevProcMs > 0) {
        var elapsedSec = (now - prevProcMs) / 1000
        // Jiffies per second available to one core. Reporting against one
        // core rather than the whole machine is the top/htop convention: a
        // thread pinning a single core reads 100%, which is the number people
        // recognise, even though the machine is only 1/n busy.
        var capacity = elapsedSec * clockHz
        var list = []
        for (var pid in nextProcs) {
          var entry = nextProcs[pid]
          // prevProcs holds bare jiffy counts, not the sample objects.
          var before = prevProcs[pid]
          // A pid absent from the previous sample is either newly spawned or
          // a reused pid. Either way its lifetime total is not a delta, so it
          // gets no CPU figure until it has been seen twice. Tested against
          // undefined rather than for truthiness: a process that has used no
          // CPU at all stores a legitimate 0.
          var cpu = (before !== undefined && capacity > 0)
            ? clamp(((entry.jiffies - before) / capacity) * 100, 0, 100 * Math.max(1, coreCount))
            : -1
          list.push({
            pid: entry.pid,
            comm: entry.comm,
            threads: entry.threads,
            rssKb: entry.rssKb,
            cpu: cpu
          })
        }
        procs = list
      }
      var flattened = ({})
      for (var p in nextProcs) flattened[p] = nextProcs[p].jiffies
      prevProcs = flattened
      prevProcMs = now
    }

    lastError = ""
    lastPollMs = now
    nowMs = now
    ready = true
  }

  // Sorted and trimmed at read time rather than in applyOutput, so c and m
  // reorder the table instantly instead of at the next poll.
  readonly property var topProcs: {
    var list = procs.slice()
    var byCpu = sortBy !== "memory"
    list.sort(function (a, b) {
      var primary = byCpu ? b.cpu - a.cpu : b.rssKb - a.rssKb
      if (primary !== 0 && !isNaN(primary)) return primary
      return byCpu ? b.rssKb - a.rssKb : b.cpu - a.cpu
    })
    return list.slice(0, procRows)
  }

  // ------------------------------------------------------------------ bar
  readonly property string barTooltip: {
    if (!ready) return "Sampling…"
    if (lastError !== "") return lastError
    var lines = []
    lines.push("CPU " + formatPercent(cpuPercent)
      + (coreCount > 0 ? " over " + coreCount + " cores" : "")
      + (tempMilli >= 0 ? " · " + Math.round(tempMilli / 1000) + "°C" : ""))
    lines.push("Load " + loadAvg[0].toFixed(2) + " " + loadAvg[1].toFixed(2) + " " + loadAvg[2].toFixed(2))
    lines.push("Memory " + formatKb(memUsedKb) + " of " + formatKb(memTotalKb)
      + " · " + formatKb(memAvailKb) + " available")
    if (swapTotalKb > 0)
      lines.push("Swap " + formatKb(swapUsedKb) + " of " + formatKb(swapTotalKb))
    var stalls = []
    if (psiValue("cpu", "some") >= 0.1) stalls.push("cpu " + psiValue("cpu", "some").toFixed(1) + "%")
    if (psiValue("memory", "some") >= 0.1) stalls.push("memory " + psiValue("memory", "some").toFixed(1) + "%")
    if (psiValue("io", "some") >= 0.1) stalls.push("io " + psiValue("io", "some").toFixed(1) + "%")
    if (stalls.length > 0) lines.push("Waiting on " + stalls.join(" · "))
    lines.push("Up " + formatUptime(uptimeSec) + " · " + totalTasks + " tasks")
    return lines.join("\n")
  }

  // --------------------------------------------------------------- wiring
  Timer {
    // The panel pins itself to one second because the process table is a
    // delta too, and a five-second-old ranking of what is busy is not a
    // ranking of what is busy.
    interval: root.opened ? Math.min(1000, root.intervalMs) : root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  Process {
    id: pollProc
    running: false
    command: ["bash", root.scriptPath, "brief"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "")
        console.warn("sysmon/poll", String(text).trim())
    }

    onExited: function (exitCode) {
      if (exitCode !== 0) root.lastError = "poll.sh exited " + exitCode
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      refreshNow()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      // Deltas taken across a closed panel would span minutes and read as a
      // flat average of nothing in particular.
      prevProcs = ({})
      prevProcMs = 0
      procs = []
      sortBy = String(setting("sortBy", "cpu"))
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.alarming
    horizontalMargin: 8.75
    tooltipText: root.barTooltip
    fixedWidth: root.barVertical ? -1 : barRow.implicitWidth + button.scaledHorizontalMargin * 2

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshNow()
      else if (buttonCode === Qt.MiddleButton) root.openMonitor()
      else root.toggle()
    }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(7)

      // nf-md-cpu-64-bit. Written as escapes so the file survives any editor
      // or transport that mangles astral-plane characters.
      BarGlyph {
        visible: root.readout !== "memory"
        glyph: root.cpuAlarming ? "\uf071" : "\udb83\udee0"
        alarming: root.cpuAlarming
      }

      BarFigure {
        visible: root.readout !== "memory"
        text: root.formatPercent(root.cpuPercent)
        color: root.loadColor(root.cpuPercent, root.cpuWarnPercent)
      }

      Sparkline {
        visible: root.showGraph && !root.barVertical && root.readout !== "memory"
        anchors.verticalCenter: parent.verticalCenter
      }

      // A RAM stick (nf-dev-memory), not the Material "memory" glyph, which
      // is another chip and sits indistinguishable from the CPU one at 13px.
      BarGlyph {
        visible: root.readout !== "cpu"
        glyph: root.memAlarming ? "\uf071" : "\ue266"
        alarming: root.memAlarming
      }

      BarFigure {
        visible: root.readout !== "cpu"
        text: root.formatPercent(root.memPercent)
        color: root.loadColor(root.memPercent, root.memWarnPercent)
      }
    }
  }

  function openMonitor() {
    if (bar && monitorCommand.trim() !== "") bar.run(monitorCommand)
    close()
  }

  component BarGlyph: Text {
    property string glyph: ""
    property bool alarming: false

    textFormat: Text.PlainText
    text: glyph
    color: alarming ? root.urgent
      : (button.active && button.useActiveColor ? button.activeColor : button.foreground)
    font.family: button.fontFamily
    font.pixelSize: Style.bar.iconFont
    renderType: Text.NativeRendering
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
  }

  // A vertical bar has no room for figures; it keeps the glyphs and the
  // numbers stay in the panel.
  component BarFigure: Text {
    visible: !root.barVertical
    textFormat: Text.PlainText
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    renderType: Text.NativeRendering
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
  }

  // The last few samples as columns. Deliberately unlabelled and unscaled
  // against anything but 100%: it exists to show shape -- flat, climbing,
  // one spike -- not to be read off.
  component Sparkline: Row {
    // Columns touch. With a gap between them an idle machine draws every
    // column one pixel high and the strip reads as a dashed underline rather
    // than as a flat graph; butted together the same samples read as the low
    // continuous line they are, and still separate visibly once they rise.
    spacing: 0
    height: Math.round(Style.bar.iconFont * 0.85)

    Repeater {
      model: root.graphSamples

      Item {
        required property int index
        readonly property real sample: {
          // Right-aligned: the newest column is always the rightmost, and a
          // partly-filled trail leaves blanks on the left rather than sliding.
          var offset = root.graphSamples - root.cpuTrail.length
          return index < offset ? -1 : root.cpuTrail[index - offset]
        }

        width: Math.max(2, Style.space(2))
        height: parent.height

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: parent.sample < 0 ? 0 : Math.max(1, parent.height * (parent.sample / 100))
          color: root.loadColor(parent.sample, root.cpuWarnPercent)
          opacity: 0.85

          Behavior on height {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = t.toLowerCase()
        if (key === "r") root.refreshNow()
        else if (key === "b") root.openMonitor()
        else if (key === "c") root.sortBy = "cpu"
        else if (key === "m") root.sortBy = "memory"
      }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // -------------------------------------------------------- CPU
          Item {
            width: parent.width
            implicitHeight: Math.max(cpuHeader.implicitHeight, tempText.implicitHeight)

            PanelSectionHeader {
              id: cpuHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "PROCESSOR"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              id: tempText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.tempMilli >= 0
              textFormat: Text.PlainText
              // nf-md-thermometer
              text: "\udb81\udd0f " + Math.round(root.tempMilli / 1000) + "°C"
              // 90°C is where a laptop package starts throttling; the colour
              // ramp is anchored there rather than at some absolute maximum.
              color: root.loadColor((root.tempMilli / 1000 / 90) * 100, 100)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          BigReading {
            width: parent.width
            percent: root.cpuPercent
            threshold: root.cpuWarnPercent
            detail: {
              var parts = []
              if (root.coreCount > 0) parts.push(root.coreCount + " cores")
              if (root.cpuMhz > 0) parts.push((root.cpuMhz / 1000).toFixed(2) + " GHz")
              parts.push("load " + root.loadAvg[0].toFixed(2) + " "
                + root.loadAvg[1].toFixed(2) + " " + root.loadAvg[2].toFixed(2))
              return parts.join(" · ")
            }
          }

          // One column per logical CPU. The single most useful thing in this
          // panel: it distinguishes "busy" from "one runaway thread", and the
          // aggregate percentage above cannot.
          Item {
            width: parent.width
            visible: root.showPerCore && root.coreCount > 0
            implicitHeight: Style.space(30)

            Row {
              anchors.fill: parent
              spacing: Math.max(1, Style.space(2))

              Repeater {
                model: root.corePercents

                Item {
                  required property var modelData
                  width: (parent.width - (root.coreCount - 1) * Math.max(1, Style.space(2))) / root.coreCount
                  height: parent.height

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(2)
                    color: root.track
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    radius: Style.space(2)
                    height: parent.modelData < 0 ? 0
                      : Math.max(parent.modelData > 0 ? 1 : 0, parent.height * (parent.modelData / 100))
                    color: root.loadColor(parent.modelData, root.cpuWarnPercent)

                    Behavior on height {
                      NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                    }
                  }
                }
              }
            }
          }

          StallLine {
            width: parent.width
            text: root.psiText("cpu", "some", "Waiting for a core")
          }

          PanelSeparator { width: parent.width }

          // ----------------------------------------------------- memory
          PanelSectionHeader {
            width: parent.width
            text: "MEMORY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          BigReading {
            width: parent.width
            percent: root.memPercent
            threshold: root.memWarnPercent
            detail: root.formatKb(root.memUsedKb) + " of " + root.formatKb(root.memTotalKb)
              + " · " + root.formatKb(root.memAvailKb) + " available"
          }

          // Page cache is not "used" in any sense that should worry you --
          // the kernel hands it back the moment something needs it -- but it
          // is also not free, and leaving it out of the picture is why people
          // think a healthy Linux box is out of memory.
          Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.formatKb(root.memCacheKb) + " cache · " + root.formatKb(root.memFreeKb) + " untouched"
              + (root.memShmemKb > 0 ? " · " + root.formatKb(root.memShmemKb) + " shared" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          StallLine {
            width: parent.width
            text: root.psiText("memory", "some", "Stalled on memory")
          }

          Column {
            width: parent.width
            visible: root.swapTotalKb > 0
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: swapLabel.implicitHeight

              Text {
                id: swapLabel
                anchors.left: parent.left
                textFormat: Text.PlainText
                text: "Swap"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: root.formatKb(root.swapUsedKb) + " of " + root.formatKb(root.swapTotalKb)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Meter {
              width: parent.width
              value: root.swapPercent / 100
              // Any swap in use on a machine with memory to spare means
              // something was paged out under pressure that has since passed.
              // Worth seeing, not worth alarming about until it is most of it.
              barColor: root.loadColor(root.swapPercent, 90)
            }
          }

          StallLine {
            width: parent.width
            text: root.psiText("io", "full", "Blocked on disk")
          }

          // -------------------------------------------------- processes
          PanelSeparator {
            width: parent.width
            visible: root.procRows > 0
          }

          Item {
            width: parent.width
            visible: root.procRows > 0
            implicitHeight: Math.max(procHeader.implicitHeight, sortHint.implicitHeight)

            PanelSectionHeader {
              id: procHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.sortBy === "memory" ? "TOP BY MEMORY" : "TOP BY CPU"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              id: sortHint
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.sortBy === "memory" ? "m · c for cpu" : "c · m for memory"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: root.procRows > 0 && root.topProcs.length === 0
            textFormat: Text.PlainText
            text: "Measuring…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.procRows > 0 ? root.topProcs : []

            ProcRow {
              required property var modelData
              width: column.width
              entry: modelData
            }
          }

          // --------------------------------------------------- footer
          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            visible: root.ready || root.lastError !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: {
              if (root.lastError !== "") return root.lastError
              var age = Math.max(0, Math.round((root.nowMs - root.lastPollMs) / 1000))
              var tasks = root.totalTasks + " tasks, " + root.runningTasks + " running"
              if (root.blockedTasks > 0) tasks += ", " + root.blockedTasks + " blocked"
              return (root.cpuModel !== "" ? root.cpuModel + "\n" : "")
                + "Up " + root.formatUptime(root.uptimeSec) + " · " + tasks
                + " · " + (age < 2 ? "live" : age + "s ago")
                + "\nr re-sample · b full monitor"
            }
            color: root.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // A headline percentage, a meter, and the numbers behind it.
  component BigReading: Column {
    id: reading
    property real percent: -1
    property int threshold: 0
    property string detail: ""

    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: figure.implicitHeight

      Text {
        id: figure
        anchors.left: parent.left
        textFormat: Text.PlainText
        text: root.formatPercent(reading.percent)
        color: root.loadColor(reading.percent, reading.threshold)
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Text {
        anchors.right: parent.right
        anchors.baseline: figure.baseline
        width: parent.width - figure.width - Style.space(10)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: reading.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Meter {
      width: parent.width
      value: reading.percent < 0 ? 0 : reading.percent / 100
      barColor: root.loadColor(reading.percent, reading.threshold)
    }
  }

  // One process: name, CPU, memory. Rendered from the delta, so a process
  // that has only been seen once shows "—" rather than its lifetime average.
  component ProcRow: Item {
    id: procRow
    property var entry: null

    implicitHeight: Math.max(nameText.implicitHeight, cpuText.implicitHeight)

    Text {
      id: nameText
      anchors.left: parent.left
      anchors.right: cpuText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: procRow.entry ? procRow.entry.comm : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: cpuText
      anchors.right: memText.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(46)
      textFormat: Text.PlainText
      // Written as "not >= 0" rather than "< 0" so a NaN that ever escapes
      // the delta reads as "no figure yet" instead of printing itself.
      text: (!procRow.entry || !(procRow.entry.cpu >= 0))
        ? "—" : procRow.entry.cpu.toFixed(procRow.entry.cpu < 10 ? 1 : 0) + "%"
      color: procRow.entry && procRow.entry.cpu >= 0
        ? root.loadColor(procRow.entry.cpu, 100) : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: memText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(46)
      textFormat: Text.PlainText
      text: procRow.entry ? root.formatKb(procRow.entry.rssKb) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // Only present when there is something to say -- see psiText().
  component StallLine: Text {
    visible: text !== ""
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: Qt.tint(root.foreground, root.alpha(root.urgent, 0.5))
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Meter: Item {
    id: meter
    property real value: 0
    property color barColor: root.foreground
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.barColor

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}
