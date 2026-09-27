import QtQuick 2.15
import org.kde.plasma.plasma5support 2.0 as Plasma5Support

// Runs one shell command and reports its stdout exactly once.
//
// Extracted from FileUsageProvider, which was the only caller, because the
// account list needs the same guarantees and a second copy of this is a second
// place for the wedge to be un-fixed. The rules it exists to enforce:
//
//   * The executable dataengine keys its sources by name, and connectSource() on
//     a name it already considers connected returns without running anything.
//     Measured against the real engine (tests/tst_refresh.qml): a second
//     connectSource while the first `cat` is in flight runs the process zero
//     extra times, and a source left connected blocks that name forever, so no
//     later run can ever read anything again.
//   * So this never connects while a read is in flight. run() records that one
//     was asked for, and exactly one trailing read runs when the current one
//     lands. That loses nothing: a file is read when the process runs, so one
//     read after a burst is the same data N reads during it would have got.
//   * The watchdog is the other half -- the only thing that can undo a source
//     the engine still thinks is running.
//
// The command must already be quoted by Shell.js; this never sees raw input.
Item {
    id: root
    visible: false

    // The full command line to run.
    property string command: ""

    // Generous: a `cat` of a small file takes single-digit milliseconds. This
    // only has to be short enough that a lost callback is not a lost widget.
    property int timeoutMs: 15000

    readonly property bool busy: _reading
    // A run was asked for while one was in flight, and is owed.
    readonly property bool queued: _readQueued
    // The name currently connected, so the watchdog can force it loose.
    readonly property string sourceName: _sourceName

    // When false, a zero exit is a success even with empty stdout -- which is
    // what a command that writes a file and prints nothing looks like. When true
    // (the default) empty output is a failure, because for a read that means the
    // file was empty or missing and there is nothing to hand back.
    property bool expectOutput: true

    signal completed(string stdout)
    // Carries a reason because the two failures are not the same thing to a
    // caller: a non-zero exit means the file was not there, and a timeout means
    // the engine lost the callback. Both leave the caller with nothing to show.
    signal failed(string reason)

    property bool _reading: false
    property bool _readQueued: false
    property string _sourceName: ""

    Plasma5Support.DataSource {
        id: _exec
        engine: "executable"
        connectedSources: []
        onNewData: function(name, data) {
            var raw = data.stdout
            var code = data.exitCode !== undefined ? data.exitCode : data["exit code"]
            _exec.disconnectSource(name)
            // Cleared before anything is emitted, and the owed flag read out
            // first, so a handler that calls run() does not re-enter believing a
            // read is still running.
            root._reading = false
            var owed = root._readQueued
            root._readQueued = false
            if (code === 0 && (root.expectOutput === false || (raw && raw.length > 0))) {
                root.completed(raw || "")
            } else {
                root.failed("exited " + code + (raw && raw.length > 0 ? "" : " with no output"))
            }
            // The run that arrived mid-read is honoured now, from the file as it
            // is now rather than as it was a millisecond ago.
            if (owed) root.run()
        }
    }

    Timer {
        id: _watchdog
        interval: root.timeoutMs
        running: root._reading
        repeat: true
        onTriggered: {
            // onNewData never arrived, so the engine is still holding a source
            // name that will refuse every future connect. Force it loose and say
            // so, rather than leaving the caller frozen on stale data with no
            // indication that anything is wrong.
            if (root._sourceName.length > 0) _exec.disconnectSource(root._sourceName)
            root._reading = false
            var owed = root._readQueued
            root._readQueued = false
            root.failed("timed out after " + root.timeoutMs + "ms")
            if (owed) root.run()
        }
    }

    function run() {
        if (root._reading) {
            root._readQueued = true
            return
        }
        var cmd = String(root.command || "").trim()
        if (cmd.length === 0) {
            root.failed("no command")
            return
        }
        root._reading = true
        root._readQueued = false
        root._sourceName = cmd
        _exec.connectSource(cmd)
    }

    // Give up on anything in flight, for a caller that is about to change what it
    // would be reading. Used by tests; the watchdog covers the real wedge.
    function cancel() {
        if (root._sourceName.length > 0) _exec.disconnectSource(root._sourceName)
        root._reading = false
        root._readQueued = false
        root._sourceName = ""
    }
}
