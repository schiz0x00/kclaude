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

// The directory part of a path, for a command that has to create it first.
// Returns "" for a bare filename, where there is nothing to create.
function dirName(p) {
    p = String(p)
    var cut = p.lastIndexOf("/")
    if (cut < 0) return ""
    return cut === 0 ? "/" : p.substring(0, cut)
}

// Write `contents` to `filePath`, creating the directory if it is missing.
//
// printf '%s' with the payload as an *argument*, not as the format string: the
// settings page writes JSON, and a "%" in a label the user typed would otherwise
// be a format specifier. This is the only command here that writes, and the only
// place widget-supplied text becomes a command's output rather than its input.
//
// chmod rather than umask, and after the write rather than before: a umask only
// applies to files the shell *creates*, so re-saving an existing accounts.json
// would leave whatever mode it already had. The file holds no tokens, but it
// does say which Claude config directories the user has, and that should not
// depend on the umask the config dialog happened to start under.
function writeFile(filePath, contents) {
    var dir = dirName(filePath)
    var mkdir = dir.length > 0 ? "mkdir -p " + path(dir) + " && " : ""
    return mkdir + "printf '%s' " + quote(String(contents)) +
        " > " + path(filePath) + " && chmod 600 " + path(filePath)
}

// Directories under `home` whose name looks like a Claude config directory, for
// the "scan" button in the settings page.
//
// find rather than a glob: a glob would need its result filtered for "is a
// directory", and there is no way to ask that from QML without a second command.
// The pattern is quoted so the shell cannot expand it and find() has to do the
// matching itself.
function findConfigDirs(home, maxDepth) {
    var depth = maxDepth > 0 ? maxDepth : 1
    return "find " + path(home) + " -maxdepth " + depth +
        " -type d -name " + quote(".claude*") + " 2>/dev/null"
}

// Whether `dir` holds a Claude Code credentials file. Existence only.
//
// Deliberately `test -f` and not `cat`: the file holds a live OAuth access and
// refresh token, and a config dialog has no business pulling one into its own
// process to answer a question about a directory. This says "there is something
// here worth adding"; the collector is what reads it, and it is the only thing
// that reports whether the login actually works.
function hasCredentials(dir) {
    return "test -f " + path(dir + "/.credentials.json")
}
