// Shell argument quoting for the one command this widget runs.
//
// Deliberately plain JS with no `.pragma library` and no `.import`, so
// tests/shell-quote.test.js can eval it under node and check every case against
// a real bash. This is the only place user-supplied text reaches a shell.

// POSIX single-quoting: everything inside '...' is literal, and an embedded
// quote is closed, backslash-escaped, then reopened.
function quote(str) {
    return "'" + String(str).replace(/'/g, "'\\''") + "'"
}

// A leading "~/" has to stay OUTSIDE the quotes or the shell never expands it.
// Quoting only the remainder keeps spaces and metacharacters inert.
function path(p) {
    p = String(p)
    if (p === "~") return "~"
    if (p.indexOf("~/") === 0) return "~/" + quote(p.substring(2))
    return quote(p)
}
