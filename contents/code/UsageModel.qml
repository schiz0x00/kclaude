import QtQuick 2.15
import "../code/TimeUtils.js" as TimeUtils

Item {
    id: root
    visible: false

    property string provider: "claude"
    property string status: "unknown"
    property var windows: []
    property string limitingWindow: ""
    property date lastUpdated: new Date(0)
    property string lastUpdatedRelative: ""
    // Collector-reported problem only the user can fix (expired login).
    // Empty when everything is fine.
    readonly property string dataError: _provider.fileError

    // Why *this widget* could not read the file, as distinct from the collector
    // reporting a problem. FileUsageProvider classifies seven different faults
    // here -- no path, unreadable, timed out, bad JSON, missing windows, empty,
    // wrong account -- and every one of them used to stop at
    // FileUsageProvider.errorMessage, which nothing read. So a mistyped path in
    // the settings and a collector that has not written yet were the same grey
    // dot with no explanation anywhere.
    readonly property string readError: _provider.errorMessage

    // Which account these numbers belong to. Not read from the usage file: the
    // collector writes one file per account and the widget is the thing that
    // knows which is which, so the label travels alongside the read rather than
    // inside it.
    property string accountId: ""
    property string accountLabel: ""

    property string filePath: "~/.local/state/kclaude/usage.json"
    property real warningThreshold: 0.75
    property real criticalThreshold: 0.9

    // The subscription type, from the collector (see FileUsageProvider.plan).
    // Empty when the file does not carry one, which is the case for a
    // hand-written usage file.
    readonly property string plan: _provider.plan

    property var _lastGoodState: null
    property bool _hasGoodState: false

    // Whether the popup is on screen. Set by main.qml from the applet item's
    // `expanded`; the model has no way to know on its own, and the timer below
    // has no reason to run when nothing shows what it feeds.
    property bool popupOpen: false

    FileUsageProvider {
        id: _provider
        filePath: root.filePath
        // So a file that is briefly somebody else's -- which a reorder in the
        // settings page can make it, since the filename follows the account's
        // position -- is refused rather than drawn under this account's name.
        expectedAccount: root.accountId
    }

    Connections {
        target: _provider
        function onUsageUpdated() {
            root._onProviderUpdated()
        }
    }

    Timer {
        id: _relativeTimer
        interval: 10000
        // Only while the popup is open, because that is the only thing this
        // updates. One of these per account, forever, for a string no closed
        // popup shows, is a cost with no reader at all.
        running: root.popupOpen
        repeat: true
        onTriggered: root._updateRelativeTime()
    }

    function refresh() {
        _provider.refresh()
    }

    function _onProviderUpdated() {
        if (!_provider.isOffline && _provider.lastUsage && _provider.lastUsage.windows) {
            // An error-only payload (auth died before the first ever poll) has
            // zero windows; showing it must not overwrite the last good numbers.
            if (_provider.lastUsage.windows.length > 0) {
                root._hasGoodState = true
                root._lastGoodState = {
                    provider: _provider.lastUsage.provider || "claude",
                    windows: _provider.lastUsage.windows,
                    lastUpdated: _provider.lastUsage.lastUpdated
                }
            }
            // Readable but stale means the collector stopped updating: show the
            // numbers, but flag them as not live.
            root._applyUsage(_provider.lastUsage, _provider.isStale)
        } else if (_provider.isOffline && root._hasGoodState) {
            // A file that cannot be read at all also cannot clear a plan: the
            // collector is the only writer of that field, so an account whose
            // file went missing keeps the badge it last proved rather than
            // flickering to no badge and back.
            root._applyUsage(root._lastGoodState, true)
        } else if (_provider.isOffline && !root._hasGoodState) {
            root.status = "unknown"
            root.windows = []
            root.limitingWindow = ""
            root.lastUpdated = new Date(0)
            root.lastUpdatedRelative = ""
        }
    }

    function _applyUsage(data, isOffline) {
        root.provider = data.provider || "claude"
        root.windows = data.windows || []
        if (data.lastUpdated) {
            root.lastUpdated = data.lastUpdated
        }
        root._updateRelativeTime()

        var maxUtil = -1
        var limitingId = ""
        var wins = root.windows
        for (var i = 0; i < wins.length; i++) {
            if (wins[i].utilization > maxUtil) {
                maxUtil = wins[i].utilization
                limitingId = wins[i].id
            }
        }
        root.limitingWindow = limitingId

        if (isOffline) {
            root.status = _quietUntilReset() ? "sleeping" : "offline"
        } else if (maxUtil >= 0) {
            root.status = TimeUtils.getStatus(maxUtil, root.warningThreshold, root.criticalThreshold)
        } else {
            root.status = "unknown"
        }

    }

    // Whether the collector is plausibly waiting for a window to turn over
    // rather than having died.
    //
    // Two decisions that are each correct on their own and contradict each
    // other: the collector deliberately stops polling an account whose window is
    // spent, and the widget calls anything older than fifteen minutes "offline".
    // So a collector doing exactly what it was built to do produced the one
    // signal that means "the collector crashed", and the grey dot was the only
    // feedback a user got. The reset time is already in the file, so the two
    // cases can be told apart; before this they could not.
    function _quietUntilReset() {
        var wins = root.windows
        for (var i = 0; i < wins.length; i++) {
            var ms = new Date(wins[i].resetAt || "").getTime()
            if (!isNaN(ms) && ms > Date.now()) return true
        }
        return false
    }

    function _updateRelativeTime() {
        if (root.lastUpdated && root.lastUpdated.getTime && root.lastUpdated.getTime() > 0) {
            root.lastUpdatedRelative = TimeUtils.formatRelativeTime(root.lastUpdated)
        }
    }
}
