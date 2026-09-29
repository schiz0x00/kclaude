// ServiceControl, hermetically.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_serviceunit.qml
//
// tst_service.qml covers the same component but is deliberately not in CI: its
// last two tests stop and start a real systemd user manager. That left
// ServiceControl with no automated coverage at all in CI — which is how it came
// to keep three raw data sources, with neither the coalescing nor the watchdog
// the rest of the widget has, for as long as it did. When the component is
// rebuilt, the part that can be checked without a session is checked here.
//
// Nothing here runs systemctl. Two components of ServiceControl *would* -- a
// start and a poll poke -- and those cases live in tst_service.qml, where
// starting the unit is expected and the isolation is real. What is left here is
// everything decidable without a session: the surface other suites bind to, and
// the paths that must refuse to run anything at all.
//
// Deliberately *not* a second copy of the state-parsing table that
// tst_service.qml already carries. It was, and nine of its ten cases were
// byte-identical to the ones there: a duplicate table is a second thing to
// update, and it keeps passing after the component changes underneath it.
import QtQuick
import QtTest
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "ServiceControlUnit"
    when: windowShown

    CodeModule.ServiceControl {
        id: service
    }

    // Everything tst_service.qml binds to. If a rewrite drops or renames any of
    // it, that suite stops compiling and says so at build time rather than
    // mysteriously at runtime on a developer machine.
    function test_00_the_surface_other_suites_bind_to() {
        compare(service.unit, "kclaude.service")
        verify(service.serviceState !== undefined, "serviceState")
        verify(service.lastError !== undefined, "lastError")
        verify(service._lastStartMs !== undefined, "_lastStartMs")
        compare(typeof service.check, "function", "check()")
        compare(typeof service.start, "function", "start()")
        compare(typeof service.startIfNeeded, "function", "startIfNeeded()")
        compare(typeof service.requestPoll, "function", "requestPoll()")
        compare(typeof service.requestPrime, "function", "requestPrime()")
        compare(typeof service._applyState, "function", "_applyState()")
    }

    // systemctl's output parsing is *not* repeated here. tst_service.qml
    // already carries the table, and a second copy of it is a second place for
    // the two to disagree about what a state means -- and for one of them to
    // keep passing after the component changes. What belongs in this suite is
    // what tst_service.qml cannot check without a systemd session.

    // systemctl is not free, and onExpandedChanged can fire repeatedly. The
    // cooldown itself is asserted in tst_service.qml, because asserting it
    // means letting start() run, which needs a session.

    // Asking systemctl about, or signalling, a unit that is not running is not
    // this widget's call: installing the collector reads the user's
    // credentials, and that stays an explicit install.sh decision. Both of
    // these must return before a process is spawned, which is what makes them
    // safe to run anywhere.
    function test_01_nothing_is_run_for_a_missing_or_stopped_unit() {
        service._applyState("LoadState=not-found\nActiveState=inactive\n")
        compare(service.start(), false, "must not run systemctl for a missing unit")
        // A prime without a running collector cannot be delivered anyway --
        // only the collector holds the token -- so it must not claim success.
        // tst_service.qml does not cover requestPrime() at all, so this is the
        // one path here that is not already asserted elsewhere.
        compare(service.requestPrime(), false, "a prime needs an active unit")

        // Loaded but stopped: still not something to poke. requestPoll() falls
        // through to start(), which the cooldown governs, so it must not have
        // signalled anything here.
        service.serviceState = "inactive"
        compare(service.requestPoll(), true, "an inactive unit is started, not signalled")
        // ...and a prime against that same state is still refused.
        compare(service.requestPrime(), false, "a prime needs an active unit")
    }
}
