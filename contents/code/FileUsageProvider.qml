import QtQuick 2.15
import org.kde.plasma.plasma5support 2.0 as Plasma5Support
import "Shell.js" as Shell

Item {
    id: root
    visible: false

    property string filePath: "~/.local/state/kclaude/usage.json"

    // Data older than this means the collector is presumably dead.
    property int staleAfterMs: 15 * 60 * 1000

    // The file is machine-written, but its path is user-configurable, so treat
    // its contents as untrusted: cap how much of it can reach the panel.
    readonly property int maxWindows: 8
    readonly property int maxNameLength: 32

    property var lastUsage: null
    property date lastUpdated: new Date(0)
    property bool isOffline: true
    property bool isStale: false
    property string errorMessage: ""
    // The collector's own "error" key (e.g. "run 'claude' and sign in again").
    // Distinct from errorMessage, which means this widget could not read the
    // file at all.
    property string fileError: ""

    signal usageUpdated()

    // Reading a file's contents from pure QML has no better option in Plasma 6:
    // XMLHttpRequest refuses file:// unless QML_XHR_ALLOW_FILE_READ=1 (not set in
    // a Plasma session), and no data engine returns file content. Hence `cat`.
    // Everything interpolated into the command goes through Shell.path(), which
    // tests/shell-quote.test.js checks against a real bash.
    Plasma5Support.DataSource {
        id: _exec
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var raw = data.stdout
            var code = data.exitCode !== undefined ? data.exitCode : data["exit code"]
            disconnectSource(sourceName)
            if (code === 0 && raw && raw.length > 0) {
                root._parseResponse(raw)
            } else {
                root._handleError("Cannot read usage file")
            }
        }
    }

    function getUsage() {
        return root.lastUsage
    }

    function refresh() {
        var path = String(root.filePath || "").trim()
        if (path.length === 0) {
            root._handleError("No file path configured")
            return
        }
        _exec.connectSource("cat " + Shell.path(path) + " 2>/dev/null")
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

            var windowList = []
            var ids = Object.keys(windows)

            for (var i = 0; i < ids.length && windowList.length < root.maxWindows; i++) {
                var id = ids[i]
                var win = windows[id]
                if (!win || typeof win !== "object") continue
                if (typeof win.utilization !== "number" || !isFinite(win.utilization)) continue

                windowList.push({
                    id: id,
                    name: root._windowName(id),
                    utilization: Math.max(0, win.utilization),
                    resetAt: root._sanitize(win.resetAt || "", 40)
                })
            }

            // The collector writes this when only the user can fix something
            // (expired login). It may arrive with the last good windows, or
            // with none at all on a first run that never authenticated.
            var fileError = root._sanitize(raw.error || "", 160)

            if (windowList.length === 0 && !fileError) {
                root._handleError("No valid window entries")
                return
            }

            var collectedAt = raw.updatedAt ? new Date(raw.updatedAt) : new Date()
            if (isNaN(collectedAt.getTime())) collectedAt = new Date()

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
        }
        // Fallback: "core_seven_day" -> "Core Seven Day"
        var pretty = String(id).split("_").filter(function(p) { return p.length > 0 })
                       .map(function(p) { return p.charAt(0).toUpperCase() + p.substring(1) })
                       .join(" ")
        return root._sanitize(pretty, root.maxNameLength)
    }
}
