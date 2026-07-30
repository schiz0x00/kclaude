// When the widget asks the collector to open a new five-hour window -- and, more
// importantly, when it must not. Every case here spends real subscription usage
// if it regresses, so the "does nothing" cases matter as much as the firing one.
//
// evaluate() takes the clock as an argument, so this drives time by hand instead
// of waiting out a 30s timer. `deliver` stands in for the collector: the real
// handler calls confirm() only when the message actually went out, so setting it
// false is what a collector that is not running yet looks like.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_primer.qml
import QtQuick
import QtTest
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "SessionPrimer"

    property int fired: 0
    // Whether the stand-in collector accepts the prime.
    property bool deliver: true

    CodeModule.SessionPrimer {
        id: primer
        onPrimeRequested: {
            testCase.fired++
            if (testCase.deliver) primer.confirm()
        }
    }

    // Anchored to the real clock, not to fixed dates: assigning resetAt makes the
    // component evaluate against Date.now(), so hardcoded timestamps would make
    // these tests pass or fail depending on the time of day CI ran them.
    readonly property double t0: Date.now()
    readonly property double resetMs: t0 + 5 * 3600 * 1000
    readonly property string resetIso: new Date(resetMs).toISOString()
    // A window that had already ended before this component ever saw it.
    readonly property string expiredIso: new Date(t0 - 3600 * 1000).toISOString()

    function init() {
        testCase.fired = 0
        testCase.deliver = true
        primer.active = false
        primer.resetAt = ""
        primer._armedFor = 0
        primer.active = true
    }

    // The one the feature is for.
    function test_01_fires_once_when_the_window_expires() {
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)
        compare(testCase.fired, 0, "must not fire while the window is running")

        primer.evaluate(testCase.resetMs)
        compare(testCase.fired, 1)
    }

    // Re-reading the file is not grounds to spend anything, however often it
    // happens: refresh timer, popup opening, Refresh button, all land here.
    function test_02_refresh_never_primes() {
        primer.resetAt = testCase.resetIso
        for (var i = 0; i < 50; i++) {
            // Same value re-assigned, then a fresh parse of it, then time moving
            // on inside the window: nothing a refresh does may fire.
            primer.resetAt = testCase.resetIso
            primer.evaluate(testCase.t0 + i * 60000)
        }
        compare(testCase.fired, 0)
    }

    // A collector that has not polled yet still reports the old reset time after
    // the window ends. That must fire exactly one prime, not one per re-read.
    function test_03_stale_reset_time_fires_only_once() {
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)
        for (var i = 0; i < 20; i++) {
            primer.evaluate(testCase.resetMs + i * 30000)
        }
        compare(testCase.fired, 1)
    }

    // The prime opens a new window, whose later reset must arm again.
    function test_04_next_window_arms_and_fires() {
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)
        primer.evaluate(testCase.resetMs)
        compare(testCase.fired, 1)

        var second = testCase.resetMs + 5 * 3600 * 1000
        primer.resetAt = new Date(second).toISOString()
        primer.evaluate(testCase.resetMs + 1000)
        compare(testCase.fired, 1, "still inside the new window")

        primer.evaluate(second)
        compare(testCase.fired, 2)
    }

    // plasmashell restarting mid-window leaves a reset time that is already past
    // the first time it is seen. Whether that window was primed is unknowable, so
    // the answer is to do nothing.
    function test_05_expired_on_first_sighting_does_nothing() {
        primer.resetAt = testCase.expiredIso
        primer.evaluate(testCase.t0)
        primer.evaluate(testCase.t0 + 3600 * 1000)
        compare(testCase.fired, 0)
    }

    function test_06_inactive_never_fires() {
        primer.active = false
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)
        primer.evaluate(testCase.resetMs)
        compare(testCase.fired, 0)
    }

    // Turning the setting on must not settle an expiry that happened while it
    // was off: that window is gone, and its prime would be pointless usage.
    function test_07_reactivating_does_not_fire_retroactively() {
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)
        primer.active = false
        primer.evaluate(testCase.resetMs)
        primer.active = true
        primer.evaluate(testCase.resetMs + 1000)
        compare(testCase.fired, 0)
    }

    // Garbage in the file must not be read as "the window ended".
    function test_08_unparseable_reset_time_alone_does_nothing() {
        primer.resetAt = "not a timestamp"
        primer.evaluate(testCase.t0)
        primer.evaluate(testCase.resetMs)
        compare(testCase.fired, 0)
    }

    // The collector is not up yet, so the message never goes out. The window
    // stays armed and the next tick asks again -- asking costs nothing, and
    // settling it here would cost the user the whole window.
    function test_09_undelivered_prime_is_retried_then_settles() {
        testCase.deliver = false
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)

        primer.evaluate(testCase.resetMs)
        compare(testCase.fired, 1)
        primer.evaluate(testCase.resetMs + 30000)
        compare(testCase.fired, 2, "still armed while nothing has accepted it")

        // The collector comes up.
        testCase.deliver = true
        primer.evaluate(testCase.resetMs + 60000)
        compare(testCase.fired, 3)

        // And that is the end of it: no second spend on the same window.
        primer.evaluate(testCase.resetMs + 90000)
        primer.evaluate(testCase.resetMs + 120000)
        compare(testCase.fired, 3)
    }

    // Retrying is bounded. Past the delivery window the user has almost
    // certainly opened the window themselves, so a late prime spends for
    // nothing -- and an unreachable collector must not mean asking forever.
    function test_10_gives_up_after_the_delivery_window() {
        testCase.deliver = false
        primer.resetAt = testCase.resetIso
        primer.evaluate(testCase.t0)

        primer.evaluate(testCase.resetMs + primer.deliveryWindowMs - 1000)
        compare(testCase.fired, 1, "still inside the delivery window")

        primer.evaluate(testCase.resetMs + primer.deliveryWindowMs + 1)
        compare(testCase.fired, 1, "past it: give up rather than spend late")

        // Disarmed for good, even once a collector shows up.
        testCase.deliver = true
        primer.evaluate(testCase.resetMs + primer.deliveryWindowMs + 30000)
        compare(testCase.fired, 1)
    }
}
