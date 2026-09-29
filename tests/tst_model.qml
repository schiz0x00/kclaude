// UsageModel: the turn from "a file was read" into "what the panel shows".
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_model.qml
//
// UsageModel had no suite of its own, which is how the status roll-up below went
// wrong for so long: it is the only place that decides severity, and
// tst_provider.qml stops at the provider, so a bug in the grading was invisible
// to every other suite.
//
// Driven through a real file read rather than by calling _applyUsage() with a
// literal. That distinction is the whole point: the bug was in the *caller*,
// which passed isStale where the parameter meant isOffline, and a suite that
// calls _applyUsage() directly cannot see it -- verified by reverting the fix
// and watching this suite stay green. It also has to be a real file, because
// "stale" is a property of what is on disk, not something a test can assert.
import QtQuick
import QtTest
import org.kde.plasma.plasma5support 2.0 as Plasma5Support
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "UsageModel"
    when: windowShown

    readonly property string scratch: "/tmp/kclaude-tst-model"

    // The same mechanism the widget reads files with, used only to build the
    // fixture. Every path is a literal above, never input.
    Plasma5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []
        property int finished: 0
        onNewData: function(name, data) {
            shell.disconnectSource(name)
            shell.finished++
        }
    }

    function sh(cmd) {
        shell.finished = 0
        shell.connectSource(cmd)
        var spins = 0
        while (shell.finished === 0 && spins < 150) {
            wait(20)
            spins++
        }
    }

    CodeModule.UsageModel {
        id: model
        filePath: testCase.scratch + "/usage.json"
    }

    // Writes a usage file holding one window at `utilization`, stamped
    // `ageMinutes` old, then reads it back through the model. The age is what
    // separates a stale-but-readable file from a fresh one, so it is the one
    // thing this suite is really about. A reset an hour out keeps
    // _quietUntilReset() from being the reason for any answer here.
    function _read(utilization, ageMinutes) {
        var stamp = new Date(Date.now() - ageMinutes * 60 * 1000).toISOString()
        var reset = new Date(Date.now() + 3600 * 1000).toISOString()
        _write(JSON.stringify({
            windows: { five_hour: { utilization: utilization, resetAt: reset } },
            updatedAt: stamp
        }))
        model.refresh()
        wait(700)
    }

    // printf '%s' with the payload as an argument rather than as the format,
    // the same rule Shell.writeFile() follows: a "%" anywhere in the document
    // would otherwise be read as a format specifier. Deliberately not python --
    // the qml CI job installs only the Qt and Plasma packages, so a fixture
    // written with an interpreter that may not be there fails as "every case
    // timed out" rather than as "the test needs a dependency it never declared".
    function _write(doc) {
        sh("mkdir -p " + testCase.scratch
           + " && printf '%s' " + quote(doc) + " > " + quote(model.filePath))
    }

    // POSIX single-quoting, as in Shell.js. Every interpolated value here is a
    // path or a document this suite built, so this is about correctness, not
    // about defending against a caller.
    function quote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // Used directly by the limiting-window case, which needs two windows.
    function _readDoc(doc) {
        _write(doc)
        model.refresh()
        wait(700)
    }

    function init() {
        sh("rm -f " + model.filePath)
        model._hasGoodState = false
        model._lastGoodState = null
        model.status = "unknown"
        model.windows = []
        model.limitingWindow = ""
    }

    // The grading, for a fresh file. Thresholds are the config defaults, so
    // these are the boundaries the settings page shows.
    function test_01_utilization_decides_severity() {
        _read(0.1, 0)
        compare(model.status, "active")
        _read(0.75, 0)
        compare(model.status, "warning", "at the warning threshold")
        _read(0.89, 0)
        compare(model.status, "warning", "just below critical")
        _read(0.9, 0)
        compare(model.status, "critical", "at the critical threshold")
        _read(1.0, 0)
        compare(model.status, "limit_reached", "a spent window is not merely critical")
    }

    // The bug. "Stale" and "unreadable" are different claims about a file, and
    // conflating them made the severity of a stale file unreachable: the roll-up
    // short-circuited into the offline branch and getStatus() never ran. A user
    // whose collector had stopped at 99% was told it was merely "waiting for a
    // limit to reset", and a red bar rendered blue.
    function test_02_a_stale_but_readable_file_still_reports_its_severity() {
        _read(0.99, 20)
        compare(model.status, "critical", "a stale 99% is still a critical 99%")
        compare(model.readError, "Usage data is stale", "but it must still say it is not live")
    }

    function test_03_a_stale_low_window_is_not_reported_as_sleeping() {
        _read(0.5, 20)
        compare(model.status, "active",
                "a stale 50% is not sleeping just because the file is old")
    }

    // The distinction pinned from the other side: a file that genuinely cannot
    // be read must not be graded as if it were merely old. This is the
    // documented sleeping/offline behaviour, and it is reachable only by a
    // real unreadable file.
    function test_04_an_unreadable_file_is_not_graded_from_its_last_numbers() {
        _read(0.5, 0)
        compare(model.status, "active")
        sh("rm -f " + model.filePath)
        model.refresh()
        wait(700)
        compare(model.status, "sleeping",
                "an unreadable file whose window resets later is the collector waiting, not crashing")
        verify(model.readError.length > 0, "and it must say it could not read the file")
    }

    // The limiting window drives the panel's countdown and the "Limit resets
    // in" line, so it has to be the highest-utilization window and not merely
    // the first one in the file.
    function test_05_the_limiting_window_is_the_highest() {
        var reset = new Date(Date.now() + 3600 * 1000).toISOString()
        _readDoc(JSON.stringify({
            windows: {
                five_hour: { utilization: 0.2, resetAt: reset },
                seven_day: { utilization: 0.95, resetAt: reset }
            },
            updatedAt: new Date().toISOString()
        }))
        compare(model.limitingWindow, "seven_day")
        compare(model.status, "critical")
    }

    function cleanupTestCase() {
        sh("rm -rf " + testCase.scratch)
    }
}
