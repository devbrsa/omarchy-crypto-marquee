.pragma library

// Shared symbol validation for Widget.qml (root.symbols), Panel.qml
// (pendingSymbols init, addSymbol) and the fetched Binance catalog
// (Panel.qml's allSymbols). Both the persisted `symbols` setting and the
// live ticker/price response are untrusted input: a huge or malformed
// value would fan out unbounded into the tooltip, both marquee Repeater
// trees, the WebSocket URL, one REST request per entry, or (for the
// catalog) the popup's own suggestion/pending-row Repeaters, and a
// non-string entry would throw repeatedly in a long-lived shell process
// every time it's touched.
var MAX_SYMBOLS = 50            // cap for the tracked/persisted symbols list
var MAX_CATALOG_SYMBOLS = 5000  // cap for Binance's fetched tradeable-symbol catalog (real count is ~2500-3000)
var SYMBOL_PATTERN = /^[A-Z0-9]{1,20}$/
var DEFAULT_SYMBOLS = ["BTCUSDT", "ETHUSDT"]

function isValidSymbol(entry) {
  return typeof entry === "string" && SYMBOL_PATTERN.test(entry.trim().toUpperCase())
}

// Used for the persisted `symbols` setting. Bounds two things
// independently: how many raw array entries are ever examined (so a huge
// array of mostly-invalid entries can't force an unbounded scan even
// though only MAX_SYMBOLS survive) and how many valid entries are kept.
// Falls back to DEFAULT_SYMBOLS if nothing valid survives.
function sanitize(raw) {
  if (!Array.isArray(raw)) return DEFAULT_SYMBOLS.slice()
  var seen = ({})
  var result = []
  var scanLimit = Math.min(raw.length, MAX_SYMBOLS * 10)
  for (var i = 0; i < scanLimit && result.length < MAX_SYMBOLS; i++) {
    var entry = raw[i]
    if (!isValidSymbol(entry)) continue
    var sym = entry.trim().toUpperCase()
    if (seen[sym]) continue
    seen[sym] = true
    result.push(sym)
  }
  return result.length > 0 ? result : DEFAULT_SYMBOLS.slice()
}

// Used for Binance's fetched ticker/price catalog (an array of {symbol,
// price} objects): extracts and validates the `symbol` field the same
// way, but capped much higher since this holds the real symbol universe,
// and an empty/short result is meaningful on its own (the caller's
// existing symbolsLoadFailed handling covers that) rather than a
// fallback to a default list.
function extractCatalogSymbols(data) {
  if (!Array.isArray(data)) return []
  var seen = ({})
  var result = []
  var scanLimit = Math.min(data.length, MAX_CATALOG_SYMBOLS * 4)
  for (var i = 0; i < scanLimit && result.length < MAX_CATALOG_SYMBOLS; i++) {
    var entry = data[i]
    var raw = entry && entry.symbol
    if (!isValidSymbol(raw)) continue
    var sym = raw.trim().toUpperCase()
    if (seen[sym]) continue
    seen[sym] = true
    result.push(sym)
  }
  return result
}
