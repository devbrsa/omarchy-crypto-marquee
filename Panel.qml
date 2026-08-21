import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Popup opened by clicking the marquee: search Binance's own symbol list
// (fetched once from GET /api/v3/ticker/price, ~2500 symbols, ~150KB — no
// auth needed) and pick matches rather than typing them, so a typo can't
// silently produce a symbol that never resolves. Each picked symbol becomes
// its own row with an "x" to remove it; Save writes the built list back to
// this widget's shell.json entry. Closing without saving discards edits.
Panel {
  id: root
  moduleName: "io.github.devbrsa.crypto-marquee"

  property var anchorItem: null
  // The bar tracks the widget mounted in its slot — Widget.qml — not this
  // nested panel, so anything the bar identifies a panel by (the popout
  // coordinator, switchPanelFrom) has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property string errorText: ""

  // ---- Binance's tradeable symbol universe, fetched once and kept for the
  //      life of this panel instance (i.e. until the plugin reloads).
  property var allSymbols: []
  property bool symbolsLoading: false
  property bool symbolsLoadFailed: false

  property var pendingSymbols: []
  property var suggestions: []
  property int suggestionIndex: -1

  // ---- Display sliders (speed, width). These apply immediately on
  //      release, independent of the Save button, which only ever commits
  //      pendingSymbols.
  property real scrollSpeedValue: 90
  property real viewportWidthValue: 150

  function open() {
    errorText = ""
    pendingSymbols = (root.setting("symbols", ["BTCUSDT", "ETHUSDT"])).slice()
    suggestions = []
    suggestionIndex = -1
    scrollSpeedValue = root.setting("scrollSpeedPxPerSec", 90)
    viewportWidthValue = root.setting("viewportWidth", 150)
    if (allSymbols.length === 0 && !symbolsLoading) fetchAllSymbols()
    root.controller.show()
    Qt.callLater(function() {
      searchField.text = ""
      searchField.forceActiveFocus()
    })
  }

  function applyScrollSpeed(v) {
    scrollSpeedValue = v
    persistSettings({ scrollSpeedPxPerSec: v })
  }

  function applyViewportWidth(v) {
    viewportWidthValue = v
    persistSettings({ viewportWidth: v })
  }

  function fetchAllSymbols() {
    symbolsLoading = true
    symbolsLoadFailed = false
    symbolsProc.running = true
  }

  function updateSuggestions(query) {
    var q = String(query).trim().toUpperCase()
    if (q === "" || allSymbols.length === 0) {
      suggestions = []
      suggestionIndex = -1
      return
    }
    var starts = []
    var contains = []
    for (var i = 0; i < allSymbols.length; i++) {
      var sym = allSymbols[i]
      if (pendingSymbols.indexOf(sym) !== -1) continue
      var idx = sym.indexOf(q)
      if (idx === 0) starts.push(sym)
      else if (idx > 0) contains.push(sym)
      if (starts.length >= 8) break
    }
    suggestions = starts.concat(contains).slice(0, 8)
    suggestionIndex = suggestions.length > 0 ? 0 : -1
  }

  function addSymbol(sym) {
    if (!sym || pendingSymbols.indexOf(sym) !== -1) return
    pendingSymbols = pendingSymbols.concat([sym])
    errorText = ""
    searchField.text = ""
    suggestions = []
    suggestionIndex = -1
  }

  function removeSymbol(sym) {
    pendingSymbols = pendingSymbols.filter(function(s) { return s !== sym })
  }

  function addHighlightedSuggestion() {
    if (suggestionIndex < 0 || suggestionIndex >= suggestions.length) return
    addSymbol(suggestions[suggestionIndex])
  }

  function save() {
    if (pendingSymbols.length === 0) {
      errorText = "Add at least one symbol first"
      return
    }
    persistSettings({ symbols: pendingSymbols })
    errorText = ""
    root.close()
  }

  // Merges the new keys into this widget's shell.json entry and writes it
  // back (mirrors clock/Panel.qml's persistSettings), applying locally to
  // settings/hostWidget.settings too so the marquee reacts immediately
  // instead of waiting on the file watcher to notice its own write.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The full ticker/price list is ~150-160KB today; --max-filesize gives
  // generous headroom while still bounding it, so curl aborts rather than
  // buffer an oversized response if the endpoint were ever spoofed or
  // compromised.
  Process {
    id: symbolsProc
    command: ["curl", "-fsS", "--max-time", "10", "--max-filesize", "2097152", "https://api.binance.com/api/v3/ticker/price"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.symbolsLoading = false
        // Defense in depth alongside curl's own --max-filesize: never hand
        // an implausibly large response to JSON.parse regardless of why it
        // got this far.
        if (text.length > 2097152) { root.symbolsLoadFailed = true; return }
        var data
        try { data = JSON.parse(text) } catch (e) { root.symbolsLoadFailed = true; return }
        if (!Array.isArray(data) || data.length === 0) { root.symbolsLoadFailed = true; return }
        var list = []
        for (var i = 0; i < data.length; i++) if (data[i] && data[i].symbol) list.push(data[i].symbol)
        list.sort()
        root.allSymbols = list
        root.symbolsLoadFailed = list.length === 0
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.allSymbols.length === 0) { root.symbolsLoading = false; root.symbolsLoadFailed = true }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(Math.min(column.implicitHeight, Style.space(520)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns all key handling here — there's no read-only
      // view to navigate, unlike weather/clock's edit-a-field-within-a-
      // bigger-panel case.
      blocked: true

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: panelScroll.width
          spacing: Style.space(10)

          Text {
            text: "SEARCH SYMBOL"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "e.g. BTC"
            foreground: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family

            onTextChanged: root.updateSuggestions(text)

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                if (root.suggestionIndex < root.suggestions.length - 1) root.suggestionIndex++
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                if (root.suggestionIndex > 0) root.suggestionIndex--
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.addHighlightedSuggestion()
                event.accepted = true
              }
            }
          }

          Text {
            visible: root.symbolsLoading
            text: "Loading symbol list…"
            color: Qt.darker(root.barForeground, 1.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Row {
            visible: root.symbolsLoadFailed
            spacing: Style.space(6)

            Text {
              text: "Couldn't load symbol list,"
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              text: "retry"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.underline: true

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.fetchAllSymbols()
              }
            }
          }

          // ---- Suggestion dropdown: only Binance's own symbol names ever
          //      land in pendingSymbols, never raw typed text.
          Column {
            width: parent.width
            spacing: 0
            visible: root.suggestions.length > 0

            Repeater {
              model: root.suggestions

              Rectangle {
                required property string modelData
                required property int index
                width: parent.width
                height: suggestionLabel.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"

                Text {
                  id: suggestionLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData
                  // modelData is a Binance-supplied symbol string; force
                  // plain text so it's never interpreted as rich/HTML
                  // markup (Text's default AutoText would auto-detect and
                  // render it as such if it ever looked HTML-ish).
                  textFormat: Text.PlainText
                  color: index === root.suggestionIndex ? Style.hoverStateColor(root.barForeground, Color.accent) : root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.addSymbol(modelData)
                }
              }
            }
          }

          Rectangle {
            visible: root.pendingSymbols.length > 0
            width: parent.width
            height: Style.spacing.hairline
            color: root.barForeground
            opacity: 0.12
          }

          // ---- Picked symbols: one row each, "x" removes it. This is what
          //      actually gets saved, not the search field's contents.
          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.pendingSymbols

              Item {
                required property string modelData
                width: column.width
                height: Math.max(rowLabel.implicitHeight, removeButton.height)

                Text {
                  id: rowLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - removeButton.width - Style.space(8)
                  text: modelData
                  // Same reasoning as suggestionLabel above: this symbol
                  // string is Binance-supplied (or hand-edited shell.json),
                  // never trust it to AutoText's rich-text detection.
                  textFormat: Text.PlainText
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                Rectangle {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(20)
                  height: Style.space(20)
                  radius: Style.cornerRadius
                  color: removeArea.containsMouse ? (root.bar ? root.bar.urgent : Color.urgent) : "transparent"
                  opacity: removeArea.containsMouse ? 0.2 : 1

                  Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: removeArea.containsMouse ? (root.bar ? root.bar.urgent : Color.urgent) : Qt.darker(root.barForeground, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: removeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeSymbol(modelData)
                  }
                }
              }
            }
          }

          Text {
            visible: root.errorText !== ""
            text: root.errorText
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Row {
            width: parent.width
            layoutDirection: Qt.RightToLeft

            Rectangle {
              id: saveButton
              width: saveLabel.implicitWidth + Style.space(20)
              height: saveLabel.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: saveArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.darker(root.barForeground, 1.4)

              Text {
                id: saveLabel
                anchors.centerIn: parent
                text: "Save"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: saveArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.save()
              }
            }
          }

          Text {
            text: "↑/↓ + Enter to add a match · Esc to close"
            color: Qt.darker(root.barForeground, 1.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.italic: true
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.barForeground
            opacity: 0.12
          }

          // ---- Speed and width: applied immediately on slider release,
          //      unlike symbols above, which only commit on Save.
          Text {
            text: "SPEED"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            PanelSlider {
              id: speedSlider
              bar: root.bar
              width: parent.width - speedValueLabel.width - Style.space(10)
              height: Style.space(20)
              minimum: 10
              maximum: 200
              step: 5
              integer: true
              value: root.scrollSpeedValue
              onMoved: function(v) { root.scrollSpeedValue = v }
              onReleased: function(v) { root.applyScrollSpeed(v) }
            }

            Text {
              id: speedValueLabel
              anchors.verticalCenter: speedSlider.verticalCenter
              text: Math.round(root.scrollSpeedValue) + " px/s"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            text: "WIDTH"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            PanelSlider {
              id: widthSlider
              bar: root.bar
              width: parent.width - widthValueLabel.width - Style.space(10)
              height: Style.space(20)
              minimum: 80
              maximum: 400
              step: 5
              integer: true
              value: root.viewportWidthValue
              onMoved: function(v) { root.viewportWidthValue = v }
              onReleased: function(v) { root.applyViewportWidth(v) }
            }

            Text {
              id: widthValueLabel
              anchors.verticalCenter: widthSlider.verticalCenter
              text: Math.round(root.viewportWidthValue) + "px"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }
}
