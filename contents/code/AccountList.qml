import QtQuick 2.15
import "Shell.js" as Shell
import "Accounts.js" as Accounts

// The list of Claude accounts to watch, and the file the settings page writes it
// to. The collector reads the same file, so this is the one place the two agree
// on, and neither of them owns it.
//
// The format is deliberately not a Plasma config key: kcfg has no string-list
// type, and a list of arbitrary paths each with its own label has no kcfg
// representation at all. See docs/architecture.md.
//
// A missing file is not an error. It is what every install that predates
// multiple accounts looks like, and it resolves to the single account this
// widget has always shown, so nothing has to be configured to keep working.
Item {
    id: root
    visible: false

    // Must agree with ACCOUNTS_FILE in the collector. Both default to ~/.config
    // because a QML context has no way to read XDG_CONFIG_HOME; a session that
    // sets it has to point both at the same file by hand.
    property string filePath: "~/.config/kclaude/accounts.json"

    // [{id, label, path}], in the order the settings page lists them. The first
    // one is the primary account: it is the one whose state files are unsuffixed,
    // and the one the panel's single-account behaviour falls back to.
    property var accounts: []

    // Set when the file is there but unreadable or unusable. An absent file is
    // not this: it is the default account, quietly.
    property string errorMessage: ""

    // How many to keep, matching the collector's own cap. A list longer than
    // this is a hand-edited file, and the collector truncates it too -- so
    // truncating here means the widget does not show rows for accounts that will
    // never be polled.
    readonly property int maxAccounts: 8

    // No accountsChanged signal of its own: the `accounts` property already emits
    // one, and declaring a second by hand is the duplicated-name qmllint warns
    // about -- two signals with one name, only one of which anything can hear.

    OneShotReader {
        id: reader
        timeoutMs: 15000
        // Reading a document, like FileUsageProvider's reader: an absent file is
        // reported as the single default account below, not as an empty list.
        expectOutput: true
        onCompleted: function(stdout) { root._applyText(stdout) }
        onFailed: function(reason) {
            // "No such file" is the normal case on a single-account install, and
            // is not something to put in front of the user.
            root.errorMessage = ""
            root._setAccounts(root.defaultAccounts())
        }
    }

    function defaultAccounts() {
        return [{ id: "claude", label: "", path: "~/.claude", isDefault: true }]
    }

    function refresh() {
        // `--` so a configured path that begins with a dash is read as a path
        // rather than as an option to cat. See FileUsageProvider._startRead.
        reader.command = "cat -- " + Shell.path(String(root.filePath || "").trim()) + " 2>/dev/null"
        reader.run()
    }

    function _applyText(text) {
        var parsed
        try {
            parsed = JSON.parse(text)
        } catch (e) {
            // Unparseable is the same situation as absent as far as the widget is
            // concerned -- there is nothing to show and nothing the user can do
            // about it from here -- but the collector is the one that complains,
            // since it reads the file too and says so in the journal.
            root.errorMessage = ""
            root._setAccounts(root.defaultAccounts())
            return
        }
        root._setAccounts(root.parse(parsed))
    }

    // The file's shape -> the list. Every field is treated as untrusted and every
    // unusable entry is dropped rather than rendered, because this list decides
    // which paths the collector will read and which labels go on the panel.
    //
    // A label is only ever displayed, so an empty one falls back to the id. A
    // path is not: a missing one would send the collector at ~/.claude, so an
    // entry without one is dropped instead of defaulting.
    function parse(raw) {
        if (!raw || typeof raw !== "object") return root.defaultAccounts()
        var entries = raw.accounts
        if (!(entries instanceof Array) || entries.length === 0) {
            return root.defaultAccounts()
        }
        var out = []
        var seen = {}
        for (var i = 0; i < entries.length && out.length < root.maxAccounts; i++) {
            var entry = entries[i]
            if (!entry || typeof entry !== "object") continue
            // A path must be a string with something in it. Coercing a number would
            // invent a relative path, and defaulting a missing one would show the
            // default account's numbers under this entry's name -- so both are
            // dropped, which is what the collector does with them too.
            if (typeof entry.path !== "string") continue
            var path = entry.path.trim()
            if (path.length === 0) continue
            // Accounts.slug, so the id here is the same string the collector
            // derives from the same entry -- see the note in Accounts.js.
            var id = Accounts.slug(entry.id)
            if (id.length === 0) continue
            if (seen[id]) continue
            seen[id] = true
            var label = typeof entry.label === "string" ? entry.label.trim() : ""
            out.push({
                id: id,
                label: root._sanitize(label.length > 0 ? label : id, 40),
                path: path.substring(0, 4096),
                isDefault: false
            })
        }
        if (out.length === 0) return root.defaultAccounts()
        out[0].isDefault = true
        return out
    }

    // Where this account's numbers are, given the configured base path. On the
    // model rather than free in the representations, so the panel, the popup and
    // the settings page cannot each derive a different answer.
    function usageFileFor(basePath, id, index) {
        return Accounts.usageFile(basePath, id, index)
    }

    // Assign only when something really changed. `accounts` is a property, so
    // handing it a fresh array fires accountsChanged, which rebuilds every
    // UsageModel delegate and repaints the panel. That used to be harmless
    // because the read happened once at startup; the list is now re-read on the
    // popup and on its own slow timer, so a re-read that finds the same file
    // has to cost nothing at all.
    //
    // Compared field by field rather than serialised, so a path the reader
    // normalises identically still compares equal.
    function _setAccounts(next) {
        var current = root.accounts
        if (current instanceof Array && current.length === next.length) {
            var same = true
            for (var i = 0; i < next.length; i++) {
                if (current[i].id !== next[i].id
                        || current[i].label !== next[i].label
                        || current[i].path !== next[i].path) {
                    same = false
                    break
                }
            }
            if (same) return
        }
        root.accounts = next
    }

    // Angle brackets out, because these labels are rendered as Text and the
    // Plasma tooltip, and Text.AutoText would fetch a remote URL from inside
    // plasmashell for anything HTML-ish. Same reason as _sanitize in
    // FileUsageProvider.
    function _sanitize(str, limit) {
        return String(str).replace(/[<>]/g, "").substring(0, limit)
    }
}
