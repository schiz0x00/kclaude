// Refresh scheduling, against the real executable dataengine.
//
// Everything else in tests/ drives the parser with no file and no process. This
// one exists because the scheduling is not a detail: the dataengine keys its
// sources by name, and connectSource() on a name it already holds returns
// without running anything. Measured on this engine, that means a refresh
// arriving while a `cat` is in flight is silently dropped, and a source left
// connected refuses that name forever.
//
// So both failure modes are reproduced here for real: a fifo with no writer
// makes `cat` block in open() so onNewData never arrives, which is the wedge;
// and a synchronous burst is the dropped request.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_refresh.qml
import QtQuick
import QtTest
import org.kde.plasma.plasma5support 2.0 as Plasma5Support
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "FileUsageProvider refresh"
    when: windowShown

    // A writable scratch dir for the fifo. /tmp because the widget only runs on
    // Linux, and because leaving a fifo inside the checkout would dirty it; both
    // are undone in cleanupTestCase.
    readonly property string scratch: "/tmp/kclaude-tst-refresh"

    // Resolved from this file's own URL so the suite does not depend on the
    // working directory it was invoked from.
    readonly property string fixtureDir: Qt.resolvedUrl("fixtures").toString().replace("file://", "")

    property int updates: 0
    property string lastError: ""

    // Same mechanism the widget reads files with, used here to build the
    // fixture the test needs. Every path is a literal above, never input.
    Plasma5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []
        property int finished: 0
        property int exitCode: 0
        onNewData: function(name, data) {
            shell.exitCode = data.exitCode !== undefined ? data.exitCode : data["exit code"]
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
        return shell.exitCode
    }

    CodeModule.FileUsageProvider {
        id: provider
        filePath: testCase.fixtureDir + "/usage.json"
        onUsageUpdated: testCase.updates++
        onErrorMessageChanged: testCase.lastError = provider.errorMessage

    }

    // A `cat` of a small file is single-digit milliseconds, so these waits are
    // generous rather than tight; a test that flakes here would be worse than
    // one that is slow.
    function settle() {
        wait(600)
    }

    function init() {
        updates = 0
        lastError = ""
        provider.lastUsage = null
        provider.isOffline = true
        provider.isStale = false
        provider.errorMessage = ""
        provider.fileError = ""
        // The scheduling state lives in the shared reader now; cancelRead() is
        // the supported way to drop anything in flight between cases.
        provider.cancelRead()
    }

    function test_00_scratch_exists() {
        // The fifo is made by a separate process; without it every later test
        // would be testing nothing. Kept as its own test so a setup failure is
        // reported as such instead of as a mysterious timeout.
        var mk = "'" + testCase.scratch + "/pipe'"
        sh("rm -f " + mk)
        compare(sh("mkdir -p '" + testCase.scratch + "'"), 0, "could not make the scratch dir")
        compare(sh("mkfifo " + mk), 0, "could not make the scratch fifo")
        // test -p, not a mere existence check: what the wedge test needs is
        // specifically a fifo, since that is what makes `cat` block.
        compare(sh("test -p " + mk), 0, "not a fifo: " + mk)
    }

    function test_01_a_refresh_reads_the_file() {
        provider.refresh()
        verify(provider._reading, "a read should be in flight immediately")
        settle()
        compare(provider._reading, false, "the read must finish")
        compare(provider.isOffline, false, "got: " + lastError)
        verify(provider.lastUsage, "no usage parsed")
        compare(provider.lastUsage.windows.length, 2)
        compare(provider.lastUsage.windows[0].utilization, 0.68)
        compare(updates, 1)
    }

    // The dropped request. Five refreshes in one tick: the first starts a read,
    // the other four arrive while it is in flight. Exactly one trailing read is
    // owed, so exactly two reads land -- not one (the old behaviour, the other
    // four silently dropped) and not five (no coalescing at all).
    function test_02_a_burst_is_coalesced_and_never_dropped() {
        provider.refresh()
        for (var i = 0; i < 4; i++) provider.refresh()
        compare(provider._readQueued, true, "a refresh during a read must be remembered")
        settle()
        compare(provider._reading, false)
        compare(updates, 2, "one read in flight plus exactly one trailing read")
        compare(provider._readQueued, false, "the queue must not stay owed")
        verify(provider.lastUsage, "the trailing read must have produced data")
        compare(provider.lastUsage.windows.length, 2)
    }

    // Refreshes spaced further apart than a read takes are each honoured.
    function test_03_spaced_refreshes_all_land() {
        provider.refresh()
        settle()
        provider.refresh()
        settle()
        provider.refresh()
        settle()
        compare(updates, 3, "no coalescing should happen between spaced refreshes")
    }

    // The wedge, reproduced: `cat` on a fifo with no writer blocks in open(), so
    // onNewData never arrives and the source name is never released. Before the
    // watchdog this left the widget on its last numbers for good.
    function test_04_a_wedged_read_is_recovered() {
        provider.readTimeoutMs = 400
        provider.filePath = testCase.scratch + "/pipe"
        provider.refresh()
        verify(provider._reading, "the blocking read should be in flight")

        wait(1500)
        compare(provider._reading, false, "the watchdog must let the read go")
        compare(provider.isOffline, true)
        verify(lastError.indexOf("Timed out") !== -1, "got: " + lastError)

        // The part that matters: the name is free again, so a real read works.
        // Without the forced disconnectSource this hangs here forever.
        provider.readTimeoutMs = 15000
        provider.filePath = testCase.fixtureDir + "/usage.json"
        provider.refresh()
        settle()
        verify(provider.lastUsage, "the widget must still be able to read")
        compare(provider.lastUsage.windows.length, 2)
    }

    // A read that fails is not a wedge: it must not leave the source stuck, or
    // every later refresh is lost too.
    function test_05_a_failed_read_does_not_wedge() {
        provider.filePath = testCase.scratch + "/does-not-exist.json"
        provider.refresh()
        settle()
        compare(provider._reading, false)
        compare(provider.isOffline, true)
        compare(lastError, "Cannot read usage file")
        compare(provider._readQueued, false)

        provider.filePath = testCase.fixtureDir + "/usage.json"
        provider.refresh()
        settle()
        verify(provider.lastUsage, "a failure must not cost the next read")
        compare(provider.lastUsage.windows.length, 2)
    }

    // An empty path never reaches a shell at all.
    function test_06_empty_path_is_refused_without_connecting() {
        provider.filePath = "   "
        provider.refresh()
        compare(provider._reading, false, "nothing should be in flight")
        compare(lastError, "No file path configured")
    }

    function cleanupTestCase() {
        sh("rm -rf '" + testCase.scratch + "'")
    }
}
