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
// everything decidable without a session: the surface, the parsing, and the
// paths that must refuse to run anything at all.
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

    // systemctl's output is untrusted text in a fixed format. Order of the two
    // properties must not matter, an unknown ActiveState is "inactive" rather
    // than a guess, and anything unrecognised is "unknown" rather than a lie.
    function test_01_parses_systemd_state() {
        var cases = [
            ["LoadState=loaded\nActiveState=active\n", "active"],
            ["LoadState=loaded\nActiveState=inactive\n", "inactive"],
            ["LoadState=loaded\nActiveState=activating\n", "starting"],
            ["LoadState=loaded\nActiveState=failed\n", "failed"],
            ["LoadState=loaded\nActiveState=deactivating\n", "inactive"],
            ["LoadState=loaded\nActiveState=reloading\n", "active"],
            ["LoadState=not-found\nActiveState=inactive\n", "notinstalled"],
            ["LoadState=masked\nActiveState=inactive\n", "notinstalled"],
            ["", "unknown"],
            ["garbage output", "unknown"],
            ["ActiveState=active\nLoadState=loaded\n", "active"]
        ]
        for (var i = 0; i < cases.length; i++) {
            service.serviceState = "unknown"
            service._applyState(cases[i][0])
            compare(service.serviceState, cases[i][1], "for " + JSON.stringify(cases[i][0]))
        }
    }

    // systemctl is not free, and onExpandedChanged can fire repeatedly. The
    // cooldown itself is asserted in tst_service.qml, because asserting it means
    // letting start() run.

    // Starting or even asking systemctl about a unit that is not installed is
    // not this widget's call: installing the collector reads the user's
    // credentials, and that stays an explicit install.sh decision. Both of
    // these must return before a process is spawned, which is what makes them
    // safe to run anywhere.
    function test_02_nothing_is_run_for_a_missing_unit() {
        service._applyState("LoadState=not-found\nActiveState=inactive\n")
        compare(service.start(), false, "must not run systemctl for a missing unit")
        // A prime without a running collector cannot be delivered anyway --
        // only the collector holds the token -- so it must not claim success.
        compare(service.requestPrime(), false, "a prime needs an active unit")
    }
}
