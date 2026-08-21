import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Binance price ticker marquee. Live last-traded price comes from a
// websocat-bridged WebSocket connection (combined @trade stream, piped
// through Quickshell's Process/SplitParser since Quickshell.Io has no
// native WS client) for instant updates. The percent change is computed
// against each symbol's UTC daily-open, refreshed periodically via a
// lightweight REST poll — Binance's own ticker UI shows change since the
// UTC daily-candle open (00:00 UTC), not the rolling 24h change that
// /ticker/24hr returns, and kline WebSocket streams (which would give
// this directly) turned out to be unreliable/throttled in practice, so
// the daily-open baseline is fetched via REST instead and combined with
// the live WS price locally. Scrolls the results continuously,
// news-ticker style, colored per-symbol green on the way up and red on
// the way down (configurable, one color pair per theme brightness — see
// colorPositiveDark/colorNegativeDark/colorPositiveLight/colorNegativeLight).
// Left-clicking opens a popup (Panel.qml) to edit and save the tracked
// symbol list; right-clicking focuses the installed TradingView PWA
// window, launching it if it isn't already open.
BarWidget {
  id: root
  moduleName: "io.github.devbrsa.crypto-marquee"

  readonly property var symbols: root.setting("symbols", ["BTCUSDT", "ETHUSDT"])
  // Only "GMT"/"UTC" is supported today (that's all the user asked for);
  // anything else falls back to the same UTC rendering rather than
  // silently ignoring the setting.
  readonly property string timezone: root.setting("timezone", "GMT")
  readonly property int viewportWidth: root.setting("viewportWidth", 150)
  readonly property real scrollSpeedPxPerSec: root.setting("scrollSpeedPxPerSec", 90)
  readonly property int dayOpenRefreshSec: root.setting("refreshIntervalSec", 5 * 60)
  readonly property int reconnectBaseMs: root.setting("reconnectBaseMs", 2000)
  readonly property int reconnectMaxMs: root.setting("reconnectMaxMs", 60000)

  property var tickers: ({})
  property var dayOpens: ({})
  property var lastPrices: ({})
  property int fetchIndex: 0
  property bool websocatMissing: false
  property int reconnectAttempt: 0
  property bool expectedStop: false
  property bool restartPending: false

  readonly property bool anyData: {
    for (var i = 0; i < symbols.length; i++) if (tickers[symbols[i]] && tickers[symbols[i]].haveData) return true
    return false
  }

  // A hardcoded green/red reads better here than the theme's own accent/
  // urgent tokens (some themes' "urgent" color is closer to olive than
  // red, and pastel greens tuned for dark surfaces lose contrast on light
  // ones), so up/down colors are their own settings, one pair per theme
  // brightness. Which pair applies is decided by a WCAG-luminance check on
  // Color.background — the same technique agents/Panel.qml uses for its
  // light/dark icon variants.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  readonly property bool isLightTheme: colorLuminance(Color.background) >= 0.5
  readonly property color colorPositiveDark: root.setting("colorPositiveDark", "#a6e3a1")
  readonly property color colorNegativeDark: root.setting("colorNegativeDark", "#e74c3c")
  readonly property color colorPositiveLight: root.setting("colorPositiveLight", "#1b5e20")
  readonly property color colorNegativeLight: root.setting("colorNegativeLight", "#c0392b")
  readonly property color upColor: isLightTheme ? colorPositiveLight : colorPositiveDark
  readonly property color downColor: isLightTheme ? colorNegativeLight : colorNegativeDark

  implicitWidth: viewportWidth
  implicitHeight: button.implicitHeight

  // Fixed 2-decimal formatting shows "0.00" for sub-cent altcoins (e.g.
  // JASMYUSDT at 0.00456), silently hiding the actual price. Scale decimal
  // places down as the value shrinks so small fractions stay visible.
  function formatPrice(value) {
    if (isNaN(value)) return "—"
    var decimals
    if (value >= 100) decimals = 0
    else if (value >= 1) decimals = 2
    else if (value >= 0.1) decimals = 4
    else if (value >= 0.01) decimals = 5
    else if (value >= 0.001) decimals = 6
    else if (value >= 0.0001) decimals = 7
    else decimals = 8
    var fixed = value.toFixed(decimals)
    var parts = fixed.split(".")
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return "$" + parts.join(".")
  }

  function formatPercent(value) {
    if (isNaN(value)) return "—"
    var sign = value >= 0 ? "+" : ""
    return sign + value.toFixed(2) + "%"
  }

  function pad2(n) {
    return (n < 10 ? "0" : "") + n
  }

  function tooltipFor() {
    if (websocatMissing) return "websocat not installed — run: omarchy pkg add websocat"
    if (!anyData) return "Fetching " + symbols.join(", ") + "…"
    var lines = []
    var latest = null
    for (var i = 0; i < symbols.length; i++) {
      var t = tickers[symbols[i]]
      if (!t || !t.haveData) continue
      lines.push(symbols[i] + "  " + formatPrice(t.lastPrice) + "  " + formatPercent(t.changePercent))
      if (!latest || t.lastUpdated > latest) latest = t.lastUpdated
    }
    if (latest) {
      var h = pad2(latest.getUTCHours())
      var m = pad2(latest.getUTCMinutes())
      lines.push("Updated " + h + ":" + m + " " + timezone)
    }
    return lines.join("\n")
  }

  // Recomputes tickers[sym] from the latest known trade price and daily
  // open, once both are known. Called whenever either input updates.
  function recompute(sym) {
    var open = root.dayOpens[sym]
    var price = root.lastPrices[sym]
    if (open === undefined || price === undefined || isNaN(open) || isNaN(price) || open === 0) return
    var next = {}
    for (var key in root.tickers) next[key] = root.tickers[key]
    next[sym] = { lastPrice: price, changePercent: (price - open) / open * 100, lastUpdated: new Date(), haveData: true }
    root.tickers = next
  }

  function applyTrade(sym, price) {
    if (root.symbols.indexOf(sym) === -1) return
    var next = {}
    for (var key in root.lastPrices) next[key] = root.lastPrices[key]
    next[sym] = price
    root.lastPrices = next
    root.recompute(sym)
  }

  function applyWsMessage(line) {
    // A real combined-stream trade message is a couple hundred bytes.
    // websocat/SplitParser has no built-in max-line-size to bound this
    // upstream, so reject anything implausibly large before it ever
    // reaches JSON.parse — defense against a compromised/spoofed endpoint.
    if (line.length > 8192) return
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    var data = msg && msg.data
    if (!data || data.e !== "trade") return
    var sym = String(data.s || "").toUpperCase()
    var price = parseFloat(data.p)
    if (isNaN(price)) return
    root.applyTrade(sym, price)
    root.reconnectAttempt = 0
  }

  function wsUrl() {
    var streams = root.symbols.map(function(s) { return s.toLowerCase() + "@trade" }).join("/")
    return "wss://stream.binance.com:9443/stream?streams=" + streams
  }

  function startWs() {
    if (root.websocatMissing || root.symbols.length === 0) return
    root.expectedStop = false
    wsProc.command = ["websocat", "-t", root.wsUrl()]
    wsProc.running = true
  }

  // Called when the configured symbol list changes (shell.json hot-reload)
  // so the already-running websocat process picks up the new subscription
  // list instead of quietly ignoring it until the next unrelated drop.
  function restartWs() {
    if (wsProc.running) {
      root.expectedStop = true
      root.restartPending = true
      wsProc.running = false
    } else {
      root.startWs()
    }
  }

  onSymbolsChanged: {
    root.tickers = {}
    root.dayOpens = {}
    root.lastPrices = {}
    if (!dayOpenFetch.running) root.startDayOpenFetchCycle()
    root.restartWs()
  }

  // Binance's own ticker UI shows change since the UTC daily-candle open
  // (00:00 UTC), not the rolling 24h change that /ticker/24hr returns —
  // those two numbers routinely disagree. Match the UI by reading the
  // current (still-forming) daily kline's open (index 1); the live price
  // itself comes from the WS trade stream, not this REST call.
  function applyDayOpenResponse(raw) {
    var sym = symbols[fetchIndex]
    // Defense in depth alongside curl's own --max-filesize: never hand an
    // implausibly large response to JSON.parse, regardless of why it got
    // this far (a real single-candle response is a few hundred bytes).
    if (raw.length > 16384) { fetchNextDayOpen(); return }
    var data
    try { data = JSON.parse(raw) } catch (e) { fetchNextDayOpen(); return }
    if (!Array.isArray(data) || data.length === 0) { fetchNextDayOpen(); return }
    var candle = data[0]
    var dayOpen = parseFloat(candle[1])
    if (isNaN(dayOpen) || dayOpen === 0) { fetchNextDayOpen(); return }

    var next = {}
    for (var key in root.dayOpens) next[key] = root.dayOpens[key]
    next[sym] = dayOpen
    root.dayOpens = next
    root.recompute(sym)
    fetchNextDayOpen()
  }

  // A single-candle kline response is a few hundred bytes; --max-filesize
  // makes curl abort rather than buffer an oversized response if the
  // endpoint were ever spoofed or compromised.
  function fetchNextDayOpen() {
    root.fetchIndex++
    if (root.fetchIndex >= root.symbols.length) return
    dayOpenFetch.command = ["curl", "-fsS", "--max-time", "5", "--max-filesize", "16384",
      "https://api.binance.com/api/v3/klines?symbol=" + root.symbols[root.fetchIndex] + "&interval=1d&limit=1"]
    dayOpenFetch.running = true
  }

  function startDayOpenFetchCycle() {
    if (root.symbols.length === 0) return
    root.fetchIndex = 0
    dayOpenFetch.command = ["curl", "-fsS", "--max-time", "5", "--max-filesize", "16384",
      "https://api.binance.com/api/v3/klines?symbol=" + root.symbols[0] + "&interval=1d&limit=1"]
    dayOpenFetch.running = true
  }

  // Detects websocat on PATH once at startup; the WS stream never starts
  // without it, and tooltipFor() surfaces an actionable message instead of
  // silently sitting on "Fetching…" forever.
  Process {
    id: websocatCheck
    command: ["sh", "-c", "command -v websocat"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.websocatMissing = text.trim() === ""
        if (!root.websocatMissing) root.startWs()
      }
    }
    running: true
  }

  Process {
    id: wsProc
    stdout: SplitParser { onRead: function(line) { root.applyWsMessage(line) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (root.expectedStop) {
        root.expectedStop = false
        if (root.restartPending) { root.restartPending = false; root.startWs() }
        return
      }
      root.reconnectAttempt++
      reconnectTimer.interval = Math.min(root.reconnectBaseMs * Math.pow(2, root.reconnectAttempt - 1), root.reconnectMaxMs)
      reconnectTimer.start()
    }
  }

  Timer {
    id: reconnectTimer
    repeat: false
    onTriggered: root.startWs()
  }

  Process {
    id: dayOpenFetch
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDayOpenResponse(text)
    }
  }

  Timer {
    id: dayOpenTimer
    interval: root.dayOpenRefreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!dayOpenFetch.running) root.startDayOpenFetchCycle()
    }
  }

  Component.onDestruction: {
    root.expectedStop = true
    wsProc.running = false
  }

  // Wires up the click-to-edit-symbols popup (Panel.qml). Mirrors the
  // Loader/injectPanel pattern every other panel-backed bar widget uses
  // (see e.g. weather/BarWidget.qml) — the manifest never declares the
  // panel; it's just a sibling QML file loaded by relative path.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle IPC routing (Bar.findPanelWidget
  // looks for open/close/opened on the bar-widget root, same as every other
  // panel-backed widget).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.anyData
    fixedWidth: root.viewportWidth
    tooltipText: root.tooltipFor()
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.bar) root.bar.run('omarchy-launch-or-focus-webapp "TradingView" https://www.tradingview.com/chart/')
      } else {
        root.togglePanel()
      }
    }
  }

  Item {
    id: viewport
    anchors.fill: button
    clip: true
    visible: button.hasVisualContent

    Row {
      id: track
      y: (viewport.height - height) / 2
      spacing: 24

      Row {
        id: copyA
        spacing: 12
        Repeater {
          model: root.symbols
          Row {
            id: seg
            required property string modelData
            readonly property var t: root.tickers[modelData]
            readonly property bool segUp: t ? t.changePercent >= 0 : true
            spacing: 4

            // Symbol name always uses the bar's own text color token — same
            // as every other widget's label, so it stays legible on
            // light-foreground themes too — regardless of direction. Only
            // the price/percent segment below carries the up/down color.
            Text {
              text: seg.modelData
              // Symbol names ultimately originate from Binance's API (the
              // search popup) or hand-edited shell.json; force plain text
              // so they're never interpreted as rich/HTML markup.
              textFormat: Text.PlainText
              color: root.bar ? root.bar.barForeground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            Text {
              text: seg.t && seg.t.haveData ? ((seg.segUp ? "▲ " : "▼ ") + root.formatPrice(seg.t.lastPrice) + " / " + root.formatPercent(seg.t.changePercent)) : "…"
              color: seg.t && seg.t.haveData ? (seg.segUp ? root.upColor : root.downColor) : (root.bar ? root.bar.barForeground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }
          }
        }
      }

      Row {
        spacing: 12
        Repeater {
          model: root.symbols
          Row {
            id: seg2
            required property string modelData
            readonly property var t: root.tickers[modelData]
            readonly property bool segUp: t ? t.changePercent >= 0 : true
            spacing: 4

            // Symbol name always uses the bar's own text color token — same
            // as every other widget's label, so it stays legible on
            // light-foreground themes too — regardless of direction. Only
            // the price/percent segment below carries the up/down color.
            Text {
              text: seg2.modelData
              // Symbol names ultimately originate from Binance's API (the
              // search popup) or hand-edited shell.json; force plain text
              // so they're never interpreted as rich/HTML markup.
              textFormat: Text.PlainText
              color: root.bar ? root.bar.barForeground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            Text {
              text: seg2.t && seg2.t.haveData ? ((seg2.segUp ? "▲ " : "▼ ") + root.formatPrice(seg2.t.lastPrice) + " / " + root.formatPercent(seg2.t.changePercent)) : "…"
              color: seg2.t && seg2.t.haveData ? (seg2.segUp ? root.upColor : root.downColor) : (root.bar ? root.bar.barForeground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }
          }
        }
      }

      NumberAnimation on x {
        from: 0
        to: -(copyA.width + track.spacing)
        duration: root.scrollSpeedPxPerSec > 0 ? (copyA.width + track.spacing) / root.scrollSpeedPxPerSec * 1000 : 8000
        loops: Animation.Infinite
        running: viewport.visible
      }
    }
  }
}
