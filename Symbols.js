.pragma library

// The single point of validation for the `symbols` setting, shared by
// Widget.qml (root.symbols) and Panel.qml (pendingSymbols init). It's a
// persisted, hand-editable shell.json value, not just something built
// through the search popup's own regex-validated add flow, so it can't be
// trusted as-is: a huge or malformed list would fan out unbounded into the
// tooltip, both marquee Repeater trees, the WebSocket URL, and one REST
// request per entry, and a non-string entry would throw repeatedly in a
// long-lived shell process every time it's touched (toLowerCase(), Repeater
// binding to `required property string modelData`, etc).
var MAX_SYMBOLS = 50
var SYMBOL_PATTERN = /^[A-Z0-9]{1,20}$/
var DEFAULT_SYMBOLS = ["BTCUSDT", "ETHUSDT"]

function sanitize(raw) {
  if (!Array.isArray(raw)) return DEFAULT_SYMBOLS.slice()
  var seen = ({})
  var result = []
  for (var i = 0; i < raw.length && result.length < MAX_SYMBOLS; i++) {
    var entry = raw[i]
    if (typeof entry !== "string") continue
    var sym = entry.trim().toUpperCase()
    if (!SYMBOL_PATTERN.test(sym)) continue
    if (seen[sym]) continue
    seen[sym] = true
    result.push(sym)
  }
  return result.length > 0 ? result : DEFAULT_SYMBOLS.slice()
}
