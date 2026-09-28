// The account list's shared vocabulary: turning a folder into an id, and an id
// into the filename the collector will write.
//
// Plain JS with no `.pragma library` and no `.import`, for the same reason
// Shell.js is: tests/accounts.test.js can eval it under node, so the rules that
// have to match the collector are checked rather than assumed.
//
// The id rule is duplicated in account_id() in daemon/kclaude-daemon, and the
// two have to agree: the id is part of a filename on both sides, so if they
// diverge the widget watches a file the collector never writes. Both are pinned
// by their own tests, and this comment is the other half of that.

// "Claude Dad" -> "claude_dad". Empty for anything with nothing usable in it,
// which the callers treat as "drop this entry" rather than defaulting, because
// two accounts both called "" would share every state file they have.
//
// This is a second implementation of account_id() in the collector, and the
// two must agree character for character. They did not: this regex is
// ASCII-only and Python's str.isalnum() is not, so "café" became "caf" here
// and "café" there -- the collector wrote one filename and the panel watched
// another, and that account showed nothing for ever. Anything Python's rule
// accepts and this one does not is a silent, unfixable-from-the-panel split, so
// both are pinned to the same table of cases in tests/accounts.test.js and in
// the collector's --selftest.
var MAX_ID_LENGTH = 64

function slug(raw) {
    // A non-string is not coerced. String(42) would invent the id "42" out of a
    // number the collector, which requires a string, drops -- so the two halves
    // would disagree about a row the settings page still shows.
    if (typeof raw !== "string") return ""
    var out = raw
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "_")
        .replace(/^_+|_+$/g, "")
    // Capped for the same reason the collector caps it: the id is part of a
    // filename, and an over-long one overflows NAME_MAX, after which every
    // write for that account fails and it silently never updates again.
    if (out.length > MAX_ID_LENGTH) {
        out = out.substring(0, MAX_ID_LENGTH).replace(/_+$/g, "")
    }
    return out
}

// The label a newly added account gets when the user has not named it: the
// folder's own name, minus the leading dot. "~/.claude" -> "claude",
// "~/.claude-dad" -> "claude-dad".
function defaultLabel(dir) {
    if (!dir) return ""
    var parts = String(dir).replace(/\/+$/, "").split("/")
    var last = parts.length > 0 ? parts[parts.length - 1] : ""
    return last.replace(/^\.+/, "")
}

// Where this account's usage file lives.
//
// The first account keeps the configured path unchanged, so an install that
// points filePath at a collector it wrote itself goes on working untouched, and
// the historical usage.json keeps its name. Every other account is a sibling
// named after its id -- which is the same suffix the collector derives, so the
// two agree without either of them being told the other's list.
function usageFile(basePath, id, index) {
    var base = String(basePath || "")
    if (index === 0) return base
    var cut = base.lastIndexOf("/")
    var dir = cut < 0 ? "" : (cut === 0 ? "/" : base.substring(0, cut))
    // "/" is already the separator, so it does not get another one: a base of
    // "/usage.json" has to produce "/usage-x.json", not "//usage-x.json".
    return (dir === "/" ? "" : dir) + "/usage-" + slug(id) + ".json"
}
