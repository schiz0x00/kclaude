import QtQuick 2.15
import "Shell.js" as Shell

Item {
    id: root
    visible: false

    property string filePath: "~/.local/state/kclaude/usage.json"

    // The account this file is supposed to hold. Empty means "do not check",
    // which is what a hand-written usage file, or one read by a caller with no
    // account concept, gets.
    //
    // The collector names the account inside the file as well as in the
    // filename, because the filename is derived from the account's position in
    // the list: reorder the settings page and the *name* moves between accounts
    // for a poll interval. Comparing the two is what stops that interval from
    // being drawn as if it were real -- the failure being that one account's
    // percentage appears under another account's name, in the panel, the
    // tooltip and the popup, with nothing to say so.
    property string expectedAccount: ""

    // Data older than this means the collector is presumably dead.
    property int staleAfterMs: 15 * 60 * 1000

    // A window can also lag the file around it: the collector reads some of them
    // off the scarce usage endpoint rather than the poll, so they arrive with
    // their own updatedAt. Only a gap big enough to mislead gets flagged -- the
    // same number a minute or two apart is not worth a label.
    property int windowSkewMs: 5 * 60 * 1000

    // The file is machine-written, but its path is user-configurable, so treat
    // its contents as untrusted: cap how much of it can reach the panel.
    readonly property int maxWindows: 8
    readonly property int maxNameLength: 32
    // The id cap, which is a filename limit rather than a display one. It is
    // deliberately not maxNameLength: the collector's own slug is 64
    // characters, so truncating an id to 32 here would make every id past that
    // compare unequal to itself and the account would be refused for ever.
    // Kept in step with MAX_ID_LENGTH in the collector and Accounts.js.
    readonly property int maxAccountIdLength: 64

    property var lastUsage: null
    property date lastUpdated: new Date(0)
    property bool isOffline: true
    property bool isStale: false
    property string errorMessage: ""
    // The collector's own "error" key (e.g. "run 'claude' and sign in again").
    // Distinct from errorMessage, which means this widget could not read the
    // file at all.
    property string fileError: ""
    // The subscription type, published by the collector because it is the only
    // thing that can read the credentials. Optional: a hand-written usage file
    // need not carry one, and an unknown plan is shown as no badge at all.
    property string plan: ""

    signal usageUpdated()

    // --- Scheduling ---------------------------------------------------------
    //
    // All of it lives in OneShotReader now; see the comments there for why a
    // read has to be coalesced and needs a watchdog. This provider only decides
    // what to read and what to do with the result, and exposes exactly two
    // things about the scheduling: how long to wait before calling it a wedge,
    // and a way to abandon a read. tests/tst_refresh.qml drives both.
    property bool _reading: fileReader.busy
    property bool _readQueued: fileReader.queued

    // A plain property that writes through, rather than a binding onto the reader.
    // Assigning to a property that has a binding *removes* that binding, so a
    // caller setting this -- which tests/tst_refresh.qml does, to make the wedge
    // arrive quickly -- would silently stop the reader from ever hearing about it
    // again, and the watchdog would keep waiting the full 15s. The direction of
    // the dependency is the whole point here: the provider owns the knob.
    property int readTimeoutMs: 15000
    onReadTimeoutMsChanged: fileReader.timeoutMs = readTimeoutMs

    Component.onCompleted: fileReader.timeoutMs = readTimeoutMs

    // Abandon a read in flight and forget anything owed behind it.
    //
    // The watchdog covers the case that actually happens -- a callback that never
    // arrives. This is for the other one: filePath changed while a read of the
    // old file was in flight, and the answer that is coming belongs to a file
    // nobody is watching any more.
    function cancelRead() {
        fileReader.cancel()
    }

    OneShotReader {
        id: fileReader
        timeoutMs: 15000
        // One of only two callers that really is reading a document: an empty
        // read here means the file is missing or empty, and there is nothing to
        // parse. The other is AccountList's reader.
        expectOutput: true
        onCompleted: function(stdout) { root._parseResponse(stdout) }
        // A non-zero exit is the ordinary "file is not there" case and gets the
        // plain message; a timeout says the engine lost the callback, which is a
        // different fault and worth distinguishing in the popup and the journal.
        onFailed: function(reason) {
            root._handleError(reason.indexOf("timed out") === 0
                              ? "Timed out reading usage file"
                              : "Cannot read usage file")
        }
    }

    // Reading a file's contents from pure QML has no better option in Plasma 6:
    // XMLHttpRequest refuses file:// unless QML_XHR_ALLOW_FILE_READ=1 (not set in
    // a Plasma session), and no data engine returns file content. Hence `cat`.
    // Everything interpolated into the command goes through Shell.path(), which
    // tests/shell-quote.test.js checks against a real bash.
    function getUsage() {
        return root.lastUsage
    }

    // Coalesces onto the read in flight, if there is one. Never loses the
    // request, never runs two cats at once.
    function refresh() {
        root._startRead()
    }

    function _startRead() {
        var path = String(root.filePath || "").trim()
        if (path.length === 0) {
            root._handleError("No file path configured")
            return
        }
        // The command is rebuilt every time rather than bound, because filePath is
        // configurable and a binding would go stale against a name the engine has
        // already released.
        //
        // `--` because Shell.path makes the path inert to the *shell* but not to
        // the program: a configured path of "-n" is quoted perfectly and then
        // read by cat as "number the lines of stdin", which blocks until the
        // watchdog fires. A path is a path, so say where options end.
        fileReader.command = "cat -- " + Shell.path(path) + " 2>/dev/null"
        fileReader.run()
    }

    function _parseResponse(text) {
        try {
            var raw = JSON.parse(text)
            if (!raw || typeof raw !== "object") {
                root._handleError("Invalid JSON structure")
                return
            }

            var windows = raw.windows
            if (!windows || typeof windows !== "object") {
                root._handleError("Missing or invalid 'windows' field")
                return
            }

            // Only when the collector said which account this is. A file with no
            // `account` key -- hand-written, or from a collector predating the
            // key -- is taken at its word, so this stays backward safe in both
            // directions.
            var owner = root._sanitize(raw.account || "", root.maxAccountIdLength)
            if (root.expectedAccount.length > 0 && owner.length > 0
                    && owner !== root.expectedAccount) {
                root._handleError("These numbers are for a different account")
                return
            }

            var windowList = []
            var ids = Object.keys(windows)

            var collectedAt = raw.updatedAt ? new Date(raw.updatedAt) : new Date()
            if (isNaN(collectedAt.getTime())) collectedAt = new Date()

            for (var i = 0; i < ids.length && windowList.length < root.maxWindows; i++) {
                var id = ids[i]
                var win = windows[id]
                if (!win || typeof win !== "object") continue
                if (typeof win.utilization !== "number" || !isFinite(win.utilization)) continue

                windowList.push({
                    id: id,
                    name: root._windowName(id),
                    // Clamped at both ends, not just the low one. The contract
                    // says 0.0-1.0 and UsageBar clamps its own width, so an
                    // over-range value used to draw a full bar beside a label
                    // reading "550%" -- the two of them disagreeing on screen
                    // with nothing to say which is right.
                    utilization: Math.max(0, Math.min(1, win.utilization)),
                    resetAt: root._sanitize(win.resetAt || "", 40),
                    // How far behind the rest of the file this window is, if the
                    // collector says. Undefined means "same age as the file",
                    // which is the case for every window the poll reports.
                    behind: root._behindMs(win.updatedAt, collectedAt)
                })
            }

            // The collector writes this when only the user can fix something
            // (expired login). It may arrive with the last good windows, or
            // with none at all on a first run that never authenticated.
            var fileError = root._sanitize(raw.error || "", 160)

            // An allowlist of four words, because it is drawn next to the account
            // name. Anything else is dropped rather than shown, and dropped
            // rather than escaped: this is the one string in the file that was
            // never ours to write. Held in a local so a payload rejected below
            // cannot leave a plan from a file we decided not to trust.
            var plan = /^(max|pro|team|enterprise)$/.test(String(raw.plan || "").toLowerCase())
                ? String(raw.plan).toLowerCase() : ""

            if (windowList.length === 0 && !fileError) {
                root._handleError("No valid window entries")
                return
            }

            root.plan = plan
            root.lastUsage = {
                provider: "claude",
                windows: windowList,
                lastUpdated: collectedAt
            }
            root.lastUpdated = new Date()
            root.isStale = (Date.now() - collectedAt.getTime()) > root.staleAfterMs
            root.isOffline = false
            root.errorMessage = root.isStale ? "Usage data is stale" : ""
            root.fileError = fileError
            root.usageUpdated()
        } catch (e) {
            root._handleError("Parse error: " + e.message)
        }
    }

    function _handleError(msg) {
        root.errorMessage = msg
        root.isOffline = true
        // An unreadable file says nothing about auth; do not keep a stale
        // "sign in again" banner up.
        root.fileError = ""
        root.usageUpdated()
    }

    // Milliseconds this window trails the rest of the file, or 0 when it is the
    // same age as everything else. A window with no updatedAt of its own is
    // exactly as fresh as the file, so it reports 0 rather than "unknown".
    function _behindMs(own, fileTime) {
        if (!own) return 0
        var at = new Date(own)
        if (isNaN(at.getTime())) return 0
        var gap = fileTime.getTime() - at.getTime()
        return gap > root.windowSkewMs ? gap : 0
    }

    // Labels default to Text.AutoText, which renders anything HTML-ish as rich
    // text -- including <img src="http://...">, which would fetch a remote URL
    // from inside plasmashell. The labels also set textFormat: Text.PlainText;
    // stripping the angle brackets here kills the class at the source, which
    // covers the Plasma tooltip too.
    function _sanitize(str, limit) {
        return String(str).replace(/[<>]/g, "").substring(0, limit)
    }

    // tests/tst_provider.qml drives _parseResponse under qmltestrunner, where
    // there is no KLocalizedContext: a bare i18n() would throw inside the parse
    // try/catch and turn every payload into a parse error. In plasmashell the
    // real i18n is on the scope chain and wins. xgettext: -k_tr:1.
    function _tr(text) {
        return (typeof i18n === "function") ? i18n(text) : text // qmllint disable unqualified
    }

    function _windowName(id) {
        switch (id) {
            case "five_hour": return root._tr("5-hour")
            case "seven_day": return root._tr("Weekly")
            case "thirty_day": return root._tr("Monthly")
            // Only on plans that have one (Max, as of 2026-09), and only when the
            // collector reports it: an account without it never sends the
            // window, so this label is simply never reached.
            case "fable": return root._tr("Fable Weekly")
        }
        // Fallback: "core_seven_day" -> "Core Seven Day"
        var pretty = String(id).split("_").filter(function(p) { return p.length > 0 })
                       .map(function(p) { return p.charAt(0).toUpperCase() + p.substring(1) })
                       .join(" ")
        return root._sanitize(pretty, root.maxNameLength)
    }
}
