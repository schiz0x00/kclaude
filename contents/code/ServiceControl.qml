import QtQuick 2.15
import "." as CodeModule

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
    // Matches the daemon's MIN_POLL_GAP, which is the floor it will let a
    // manual poll through at, so a held-down Refresh cannot become a way round
    // its pacing.
    //
    // This said the endpoint 429s below this, which was true when a poll *was*
    // a call to the usage endpoint. It is not one any more: the poll is a
    // /v1/messages ping, and the scarce endpoint is only reached now for the
    // Fable weekly budget, on its own half-hourly interval. The number is
    // still the right one and is still enforced independently on the daemon
    // side -- but it is a floor this widget shares, not a rate it is defending
    // against, and the two are only in step by hand.
    readonly property int pollCooldownMs: 30000
    property double _lastStartMs: 0
    property double _lastPollMs: 0
    property bool _pendingStart: false

    signal becameActive()
    // The collector was asked to poll; the file will change shortly.
    signal pollRequested()

    // Every command below goes through OneShotReader rather than a raw
    // DataSource, which is not tidiness. The executable engine keys its sources
    // by name and refuses to run a name it still believes is connected, so a
    // single lost onNewData left each of these three names held for the rest of
    // the session: serviceState froze at whatever it last was, requestPoll and
    // requestPrime went on returning true as though the signal had been
    // delivered -- permanently disarming the session primer -- and nothing said
    // so. OneShotReader exists for exactly this and carries a 15s watchdog.
    //
    // The refresh poke and the prime get *separate* readers, not one shared
    // reader with a flag, because they are separate actions on purpose: a
    // refresh must never be able to spend usage. Sharing a reader would let
    // OneShotReader's coalescing drop one of the two.
    CodeModule.OneShotReader {
        id: _query
        onCompleted: function(stdout) { root._applyState(stdout) }
        onFailed: function() {
            // A failed or timed-out query leaves the state unknown rather than
            // stale: we do not know, and saying "inactive" would start a unit
            // that may well be running.
            root.lastError = _query.lastStderr
            root._applyState("")
        }
    }

    CodeModule.OneShotReader {
        id: _starter
        onCompleted: function() { root._afterStartAttempt() }
        onFailed: function() { root._afterStartAttempt() }
    }

    CodeModule.OneShotReader {
        id: _pollPoke
        onCompleted: function() {
            root.lastError = _pollPoke.lastStderr
            root.pollRequested()
        }
    }

    CodeModule.OneShotReader {
        id: _primePoke
        onCompleted: function() {
            root.lastError = _primePoke.lastStderr
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
        _query.command = "systemctl --user show -p LoadState -p ActiveState " + root.unit
        _query.run()
    }

    function start() {
        if (root.serviceState === "notinstalled") return false
        var nowMs = Date.now()
        if (nowMs - root._lastStartMs < root.startCooldownMs) return false
        root._lastStartMs = nowMs
        root.serviceState = "starting"
        _starter.command = "systemctl --user start " + root.unit
        _starter.run()
        return true
    }

    // Whatever the start attempt returned, ask systemd what actually happened
    // rather than trusting the exit code -- but not immediately. Querying in the
    // completion handler reads the state from before the unit came up and
    // reports a false "inactive". Identical on both outcomes, because a start
    // that failed is exactly as much in need of confirming as one that worked.
    function _afterStartAttempt() {
        root.lastError = _starter.lastStderr
        _settleTimer.ticks = 0
        _settleTimer.restart()
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
        _pollPoke.command = "systemctl --user kill -s USR1 " + root.unit
        _pollPoke.run()
        return true
    }

    // Opens a new five-hour window: SIGUSR2 makes the collector send one small
    // message. Distinct signal from the poll above on purpose -- a refresh must
    // never be able to spend usage -- and only SessionPrimer calls this. Hence
    // its own reader above: sharing one would let a coalesced trailing run
    // deliver the wrong signal.
    //
    // Nothing to do if the collector is not running: it holds the token, so
    // there is no other way to send anything, and starting it would not prime.
    function requestPrime() {
        if (root.serviceState !== "active") return false
        _primePoke.command = "systemctl --user kill -s USR2 " + root.unit
        _primePoke.run()
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
