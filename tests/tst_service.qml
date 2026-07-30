// Collector service detection and auto-start.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_service.qml
//
// The state parsing is checked against captured `systemctl show` output, and the
// live path is checked once against whatever kclaude.service is really doing.
import QtQuick
import QtTest
import org.kde.plasma.plasma5support 2.0 as Plasma5Support
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "ServiceControl"
    when: windowShown

    CodeModule.ServiceControl {
        id: service
    }

    function init() {
        service.serviceState = "unknown"
        service._pendingStart = false
        service._lastStartMs = 0
    }

    function test_01_parses_missing_unit() {
        // Real output for a unit that does not exist. Exit code is 0, so the
        // LoadState line is the only thing that reveals it.
        service._applyState("LoadState=not-found\nActiveState=inactive\n")
        compare(service.serviceState, "notinstalled")
    }

    function test_02_parses_states() {
        var cases = [
            ["LoadState=loaded\nActiveState=active\n", "active"],
            ["LoadState=loaded\nActiveState=inactive\n", "inactive"],
            ["LoadState=loaded\nActiveState=activating\n", "starting"],
            ["LoadState=loaded\nActiveState=failed\n", "failed"],
            ["LoadState=loaded\nActiveState=deactivating\n", "inactive"],
            ["LoadState=loaded\nActiveState=reloading\n", "active"],
            ["LoadState=masked\nActiveState=inactive\n", "notinstalled"],
            ["", "unknown"],
            ["garbage output", "unknown"],
            // Order must not matter: don't depend on systemd's field ordering.
            ["ActiveState=active\nLoadState=loaded\n", "active"]
        ]
        for (var i = 0; i < cases.length; i++) {
            service.serviceState = "unknown"
            service._applyState(cases[i][0])
            compare(service.serviceState, cases[i][1], "for " + JSON.stringify(cases[i][0]))
        }
    }

    function test_03_start_refused_when_not_installed() {
        service._applyState("LoadState=not-found\nActiveState=inactive\n")
        compare(service.start(), false, "must not run systemctl for a missing unit")
    }

    function test_04_start_cooldown() {
        service._applyState("LoadState=loaded\nActiveState=inactive\n")
        compare(service.start(), true, "first start should go through")
        compare(service.start(), false, "second start within the cooldown must be suppressed")
    }

    function test_05_becameActive_fires_once_per_transition() {
        var spy = signalSpy.createObject(testCase, { target: service, signalName: "becameActive" })
        service._applyState("LoadState=loaded\nActiveState=inactive\n")
        compare(spy.count, 0)
        service._applyState("LoadState=loaded\nActiveState=active\n")
        compare(spy.count, 1, "should fire on inactive -> active")
        service._applyState("LoadState=loaded\nActiveState=active\n")
        compare(spy.count, 1, "must not fire again while it stays active")
        spy.destroy()
    }

    Component {
        id: signalSpy
        SignalSpy {}
    }

    // Regression test for the auto-start reporting a false "inactive": querying
    // systemd in the start command's own callback reads the pre-start state.
    // Requires the unit to be installed; stops it, then starts it back via the
    // widget's own code path, so it ends up running either way.
    function test_07_autostart_brings_up_a_stopped_collector() {
        service.serviceState = "unknown"
        service.check()
        tryVerify(function() { return service.serviceState !== "unknown" }, 5000)
        if (service.serviceState === "notinstalled") {
            skip("kclaude.service is not installed on this machine")
            return
        }

        stopper.connectSource("systemctl --user stop " + service.unit)
        tryVerify(function() {
            service.check()
            return service.serviceState === "inactive"
        }, 10000, "could not get the collector into a stopped state")

        service._lastStartMs = 0
        service.startIfNeeded()
        tryVerify(function() { return service.serviceState === "active" }, 15000,
                  "auto-start left state at " + service.serviceState
                  + " (err=" + service.lastError + ")")
    }

    Plasma5Support.DataSource {
        id: stopper
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName) { disconnectSource(sourceName) }
    }

    function test_06_live_query_reports_something_real() {
        service.serviceState = "unknown"
        service.check()
        // Waits for the real systemctl call to come back.
        tryVerify(function() { return service.serviceState !== "unknown" }, 5000,
                  "live systemctl query never returned")
        var valid = ["notinstalled", "inactive", "starting", "active", "failed"]
        verify(valid.indexOf(service.serviceState) !== -1,
               "unexpected live state: " + service.serviceState)
        console.log("live kclaude.service state ->", service.serviceState)
    }
}
