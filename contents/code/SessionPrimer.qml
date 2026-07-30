import QtQuick 2.15

// Decides when the next five-hour window should be opened.
//
// It fires on one thing only: a five-hour window this component watched while it
// was still running has now run out. Re-reading the file does not fire it,
// whether that read came from the refresh timer, the popup opening, or the
// Refresh button -- those change nothing this looks at. Priming spends usage, so
// "did anything just happen" is not good enough grounds; only the clock passing
// a known reset time is.
//
// The signal is all this does. Sending the message is the collector's job: it
// holds the token, and this holds no credentials at all. The handler has to call
// confirm() once the message is really on its way, so a collector that was not
// running yet cannot silently swallow the one prime a window gets.
Item {
    id: root
    visible: false

    // Deliberately not called "enabled": Item already has that property, and
    // shadowing it leaves two properties of the same name, only one of which is
    // visible from any given scope. Qt's own guidance is to pick a unique name.
    property bool active: false
    // The five-hour window's resetAt, exactly as the model reports it.
    property string resetAt: ""

    signal primeRequested()

    // How long past the reset a prime is still worth sending. Beyond this the
    // window has been running long enough that the user has almost certainly
    // opened it themselves, and a late message would spend for nothing. Also
    // what bounds the retry below: it cannot ask forever.
    readonly property int deliveryWindowMs: 600000

    // The reset time of a window seen while it still had time left, or 0 for
    // "nothing pending". Only such a sighting proves a window was really
    // running: a resetAt already in the past the first time it is seen says
    // nothing about whether it was primed already, which is the state a
    // plasmashell restart leaves behind.
    //
    // Back to 0 exactly twice: confirm(), and giving up. One window therefore
    // spends at most once, and nothing else needs remembering.
    property double _armedFor: 0

    // Wall clock, not the refresh cycle: the window expires on time whether or
    // not anything re-read the file. 30s keeps the prime within half a minute of
    // the reset without being a busy loop, and doubles as the retry cadence
    // while the collector is still coming up.
    Timer {
        interval: 30000
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: root.evaluate(Date.now())
    }

    // A new reset time is the other moment worth re-checking. It cannot fire on
    // its own: the checks below still have to hold.
    onResetAtChanged: root.evaluate(Date.now())

    // Switching off forgets the armed window, so switching back on does not fire
    // for an expiry that happened while it was off.
    onActiveChanged: if (!root.active) root._armedFor = 0

    // Called by whoever handled primeRequested, once the message has actually
    // gone out. Until then the window stays armed and the next tick asks again:
    // the only thing that can fail before this point is the local check that the
    // collector is running, so retrying costs nothing and rides out a collector
    // that is a few seconds behind plasmashell.
    function confirm() {
        root._armedFor = 0
    }

    // Takes the clock as an argument so tests/tst_primer.qml can drive it.
    function evaluate(nowMs) {
        if (!root.active) return

        var resetMs = root.resetAt ? new Date(root.resetAt).getTime() : NaN

        // Window still running: remember it and wait for it to end.
        if (!isNaN(resetMs) && resetMs > nowMs) {
            root._armedFor = resetMs
            return
        }

        if (root._armedFor <= 0 || nowMs < root._armedFor) return

        // Nobody could deliver it in time -- no collector, or none that would
        // take it. Give up rather than opening a window that is already well
        // under way.
        if (nowMs - root._armedFor > root.deliveryWindowMs) {
            root._armedFor = 0
            return
        }

        // Past the reset time of a window that was running when last seen. The
        // file may still hold that old reset time -- the collector has up to five
        // minutes to notice -- which is why the armed value is what decides,
        // not whatever the file currently says.
        root.primeRequested()
    }
}
