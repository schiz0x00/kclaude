import QtQuick 2.15
import org.kde.plasma.plasma5support 2.0 as Plasma5Support

// Queries and starts the collector's systemd user unit.
//
// It deliberately does NOT install anything. Installing the collector drops an
// executable and a unit file that read ~/.claude/.credentials.json, so that stays
// an explicit `install.sh --with-daemon` decision by the user. When the unit is
// missing, this reports that and the popup shows the command.
//
// Every command is a fixed string built from `unit`, which is a readonly literal:
// no user-supplied text reaches a shell here.
Item {
    id: root
    visible: false

    readonly property string unit: "kclaude.service"

    // unknown | notinstalled | inactive | starting | active | failed
    property string serviceState: "unknown"
    property string lastError: ""

    // systemctl is not free, and onExpandedChanged can fire repeatedly.
    readonly property int startCooldownMs: 15000
    // Matches the daemon's MIN_POLL_GAP: the endpoint 429s faster than this.
    readonly property int pollCooldownMs: 30000
    property double _lastStartMs: 0
    property double _lastPollMs: 0
    property bool _pendingStart: false

    signal becameActive()
    // The collector was asked to poll; the file will change shortly.
    signal pollRequested()

    Plasma5Support.DataSource {
        id: _query
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
            root._applyState(String(data.stdout || ""))
        }
    }

    Plasma5Support.DataSource {
        id: _starter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
            root.lastError = String(data.stderr || "").trim()
            // Ask systemd what actually happened rather than trusting the exit
            // code -- but not immediately. Querying in this handler reads the
            // state from before the unit came up and reports a false "inactive".
            _settleTimer.ticks = 0
            _settleTimer.restart()
        }
    }

    Plasma5Support.DataSource {
        id: _poller
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
            root.lastError = String(data.stderr || "").trim()
            root.pollRequested()
        }
    }

    // Polls briefly after a start until the state settles. Bounded, and
    // _applyState stops it as soon as the answer is final.
    Timer {
        id: _settleTimer
        interval: 500
        repeat: true
        property int ticks: 0
        onTriggered: {
            ticks++
            if (ticks > 6) {
                stop()
                return
            }
            root.check()
        }
    }

    function check() {
        _query.connectSource("systemctl --user show -p LoadState -p ActiveState " + root.unit)
    }

    function start() {
        if (root.serviceState === "notinstalled") return false
        var nowMs = Date.now()
        if (nowMs - root._lastStartMs < root.startCooldownMs) return false
        root._lastStartMs = nowMs
        root.serviceState = "starting"
        _starter.connectSource("systemctl --user start " + root.unit)
        return true
    }

    // Check before starting: never invoke systemctl for a unit that is not
    // installed, and never restart one that is already running.
    function startIfNeeded() {
        root._pendingStart = true
        check()
    }

    // Refresh means "get fresh numbers", not "re-read the same file". SIGUSR1
    // cuts the daemon's sleep short so it polls immediately -- no restart, no
    // killed in-flight request. If the collector is down, starting it achieves
    // the same thing.
    function requestPoll() {
        if (root.serviceState !== "active") {
            return start()
        }
        var nowMs = Date.now()
        if (nowMs - root._lastPollMs < root.pollCooldownMs) return false
        root._lastPollMs = nowMs
        _poller.connectSource("systemctl --user kill -s USR1 " + root.unit)
        return true
    }

    // Opens a new five-hour window: SIGUSR2 makes the collector send one small
    // message. Distinct signal from the poll above on purpose -- a refresh must
    // never be able to spend usage -- and only SessionPrimer calls this.
    //
    // Nothing to do if the collector is not running: it holds the token, so
    // there is no other way to send anything, and starting it would not prime.
    function requestPrime() {
        if (root.serviceState !== "active") return false
        _poller.connectSource("systemctl --user kill -s USR2 " + root.unit)
        return true
    }

    function _applyState(out) {
        var load = /LoadState=(\S+)/.exec(out)
        var active = /ActiveState=(\S+)/.exec(out)
        var loadState = load ? load[1] : ""
        var activeState = active ? active[1] : ""
        var previous = root.serviceState

        if (loadState === "") {
            root.serviceState = "unknown"
        } else if (loadState === "not-found" || loadState === "masked") {
            root.serviceState = "notinstalled"
        } else if (activeState === "active" || activeState === "reloading") {
            root.serviceState = "active"
        } else if (activeState === "activating") {
            root.serviceState = "starting"
        } else if (activeState === "failed") {
            root.serviceState = "failed"
        } else {
            root.serviceState = "inactive"
        }

        if (root._pendingStart) {
            root._pendingStart = false
            if (root.serviceState === "inactive" || root.serviceState === "failed") {
                start()
            }
        }

        // A final answer: no point polling further.
        if (root.serviceState === "active" || root.serviceState === "failed"
                || root.serviceState === "notinstalled") {
            _settleTimer.stop()
        }

        if (root.serviceState === "active" && previous !== "active") {
            root.becameActive()
        }
    }
}
