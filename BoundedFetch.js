.pragma library

// Builds a `curl | head -c` argv array that hard-caps how many response
// bytes ever reach our process, regardless of the server's Content-Length
// or transfer encoding. curl's own --max-filesize is kept as a first-line
// defense (it aborts early when a Content-Length is present and honest),
// but per curl's own docs it has no effect for a chunked-encoded response
// with no upfront size — piping through `head -c` is what actually bounds
// consumption in that case: once the byte cap is reached, head exits and
// closes the pipe, which fails curl's next write (SIGPIPE/EPIPE) rather
// than letting it keep buffering an unbounded body.
//
// url is passed as a positional shell argument ($1), never interpolated
// into the script text, so this stays safe regardless of its content.
function command(url, maxBytes, timeoutSec) {
  var n = String(maxBytes)
  var t = String(timeoutSec)
  var script = 'curl -fsS --max-time ' + t + ' --max-filesize ' + n + ' "$1" | head -c ' + n
  return ["sh", "-c", script, "sh", url]
}
