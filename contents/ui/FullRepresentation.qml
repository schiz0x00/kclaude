pragma ComponentBehavior: Bound
import QtQuick 2.15
import QtQuick.Controls as QQC2
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "../code/TimeUtils.js" as TimeUtils

Item {
    id: root

    // One entry per configured account. The popup is the only place that shows
    // all of them at once, which is the point: two accounts have two sets of
    // windows on two different clocks, and there is no honest way to fold them
    // into one row.
    property var usageModels: []

    property var collector: null

    // The worst status across accounts, from main.qml.
    property string aggregateStatus: "unknown"

    readonly property string _collectorState: collector ? collector.serviceState : "unknown"

    // A clock, because nothing else here has one.
    //
    // TimeUtils.formatResetTime() reads new Date() inside a plain JS function, so
    // QML cannot see the clock as a binding dependency: every "Resets in ..." in
    // this file used to be computed once per model update and then frozen until
    // the next one, which is up to a full refresh interval later. A reset that
    // had already passed kept counting down at its last value. A binding only
    // re-evaluates when a dependency changes, so something has to change _now --
    // and it has to tick at the resolution the text is rendered at, hence 1s
    // rather than the 10s the coarse "updated" stamp needs.
    readonly property int _now: nowTick

    // Bumped by the timer below; the bindings below only care that it changed.
    property int nowTick: 0

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.nowTick++
    }

    // The account whose numbers get the "Limit resets in ..." line. With one
    // account that is the account; with several it is the one closest to a limit,
    // because that is the countdown worth the space.
    readonly property var _limitingModel: {
        var worst = null
        var worstUtil = -1
        for (var i = 0; i < root.usageModels.length; i++) {
            var m = root.usageModels[i]
            var limitId = m.limitingWindow
            for (var j = 0; j < m.windows.length; j++) {
                if (m.windows[j].id === limitId && m.windows[j].utilization > worstUtil) {
                    worstUtil = m.windows[j].utilization
                    worst = m
                }
            }
        }
        return worst
    }

    readonly property var _limitingWindowData: {
        var model = root._limitingModel
        if (!model) return null
        var limitId = model.limitingWindow
        for (var i = 0; i < model.windows.length; i++) {
            if (model.windows[i].id === limitId) return model.windows[i]
        }
        return null
    }

    readonly property bool _anyWindows: {
        for (var i = 0; i < root.usageModels.length; i++) {
            if (root.usageModels[i].windows.length > 0) return true
        }
        return false
    }

    // KLocalizedContext injects i18n at runtime; the linter cannot see it.
    // qmllint disable unqualified
    readonly property string _emptyStateText: {
        switch (root._collectorState) {
            case "notinstalled":
                // %1/%2 keep the commands and paths out of translators' hands.
                return i18n("The collector is not installed.\n\nInstall it with:\n%1\n\nIt reads the OAuth token in %2 -- see the README.",
                            "./scripts/install.sh --with-daemon", "~/.claude/.credentials.json")
            case "starting":
                return i18n("Starting the collector...")
            case "active":
                return i18n("The collector is running.\nWaiting for the first update...")
            case "failed":
                return i18n("The collector failed to start.\n\nCheck:\n%1",
                            "journalctl --user -u kclaude.service")
            case "inactive":
                return i18n("The collector is not running.")
            default:
                return i18n("No usage data yet.")
        }
    }

    // "Max" / "Pro" next to the account name, or nothing at all when the file did
    // not say. Capitalised here rather than in the collector, so a hand-written
    // usage file that says "max" reads the same as one the collector wrote.
    function _planLabel(plan) {
        if (!plan || plan.length === 0) return ""
        return plan.charAt(0).toUpperCase() + plan.substring(1)
    }
    // qmllint enable unqualified

    readonly property real _warningThreshold: {
        for (var i = 0; i < root.usageModels.length; i++) {
            if (root.usageModels[i]) return root.usageModels[i].warningThreshold
        }
        return 0.75
    }
    readonly property real _criticalThreshold: {
        for (var i = 0; i < root.usageModels.length; i++) {
            if (root.usageModels[i]) return root.usageModels[i].criticalThreshold
        }
        return 0.9
    }

    Layout.minimumWidth: Kirigami.Units.gridUnit * 15
    Layout.preferredWidth: Kirigami.Units.gridUnit * 19
    // All three pinned to the content height on purpose. Leaving maximumHeight
    // unset makes the popup height depend on contentLayout.implicitHeight, which
    // depends on availableWidth, which depends on whether a scrollbar shows: that
    // circular dependency settles as a too-short popup with clipped buttons.
    // Plasma still clamps the popup to the screen, so the ScrollView is not
    // redundant -- it only stops being used for content that already fits.
    Layout.minimumHeight: contentLayout.implicitHeight
    Layout.preferredHeight: contentLayout.implicitHeight
    Layout.maximumHeight: contentLayout.implicitHeight

    PlasmaComponents3.ScrollView {
        id: scrollView
        anchors.fill: parent
        contentWidth: availableWidth
        // Nothing here is ever meant to scroll sideways; a stray wide child must
        // elide or wrap, not push a horizontal bar over the buttons.
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

        ColumnLayout {
            id: contentLayout
            width: scrollView.availableWidth
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                Layout.bottomMargin: 0
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: Qt.resolvedUrl("../icons/kclaude.svg")
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                }

                PlasmaComponents3.Label {
                    text: "kclaude"
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                StatusIndicator {
                    status: root.aggregateStatus
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            // Replaces the bars when there is nothing at all to show, so a stopped
            // or missing collector is visible instead of a silent empty popup. One
            // account with no data is not enough to hide the others, so this is
            // only for the case where no account has anything.
            ColumnLayout {
                visible: !root._anyWindows
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    opacity: 0.7
                    text: root._emptyStateText
                }

                PlasmaComponents3.Button {
                    // Only offered when there is an installed unit to start.
                    // Installing the collector is deliberately not done from here.
                    visible: root._collectorState === "inactive" || root._collectorState === "failed"
                    text: i18n("Start collector") // qmllint disable unqualified
                    icon.name: "media-playback-start"
                    Layout.alignment: Qt.AlignHCenter
                    onClicked: {
                        if (root.collector) root.collector.start()
                    }
                }
            }

            // One section per account: its name, its plan, its own bars and its own
            // countdowns. The two accounts' five-hour windows reset hours apart, so
            // a single merged list of bars would put two unrelated countdowns under
            // one heading and read as a single account with six limits.
            Repeater {
                model: root.usageModels

                delegate: ColumnLayout {
                    id: accountDelegate
                    required property var modelData
                    required property int index

                    readonly property bool _isFirst: index === 0
                    readonly property bool _hasWindows: modelData.windows.length > 0
                    readonly property bool _showPlan: modelData.plan.length > 0

                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    Layout.rightMargin: Kirigami.Units.largeSpacing
                    Layout.topMargin: _isFirst
                                     ? Kirigami.Units.smallSpacing
                                     : Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            text: accountDelegate.modelData.accountLabel.length > 0 ? accountDelegate.modelData.accountLabel : "kclaude"
                            textFormat: Text.PlainText
                            font.bold: true
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        // The plan, in a low-contrast pill. Worth showing because a
                        // pro account has no Fable window at all, and its absence
                        // otherwise looks like a bug rather than the plan.
                        PlasmaComponents3.Label {
                            visible: accountDelegate._showPlan
                            text: root._planLabel(accountDelegate.modelData.plan)
                            textFormat: Text.PlainText
                            font: Kirigami.Theme.smallFont
                            opacity: 0.6
                            Layout.alignment: Qt.AlignVCenter
                        }

                        StatusIndicator {
                            status: accountDelegate.modelData.status
                        }
                    }

                    // The collector's "only you can fix this" message (expired
                    // Claude Code login), per account: a dead login on one of them
                    // says nothing about the other.
                    PlasmaComponents3.Label {
                        visible: accountDelegate.modelData.dataError.length > 0
                        text: accountDelegate.modelData.dataError
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        color: Kirigami.Theme.negativeTextColor
                        Layout.fillWidth: true
                    }

                    PlasmaComponents3.Label {
                        visible: !accountDelegate._hasWindows && accountDelegate.modelData.dataError.length === 0
                        text: i18n("Waiting for usage data...") // qmllint disable unqualified
                        textFormat: Text.PlainText
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                    }

                    Repeater {
                        model: accountDelegate.modelData.windows

                        delegate: ColumnLayout {
                            id: windowDelegate
                            required property var modelData

                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                PlasmaComponents3.Label {
                                    text: windowDelegate.modelData.name
                                    textFormat: Text.PlainText
                                    font.bold: true
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }

                                PlasmaComponents3.Label {
                                    text: Math.round(windowDelegate.modelData.utilization * 100) + "%"
                                    font.bold: true
                                    color: {
                                        var u = windowDelegate.modelData.utilization
                                        if (u >= root._criticalThreshold) return Kirigami.Theme.negativeTextColor
                                        if (u >= root._warningThreshold) return Kirigami.Theme.neutralTextColor
                                        return Kirigami.Theme.highlightColor
                                    }
                                }
                            }

                            UsageBar {
                                utilization: windowDelegate.modelData.utilization
                                warningThreshold: root._warningThreshold
                                criticalThreshold: root._criticalThreshold
                                Layout.fillWidth: true
                            }

                            PlasmaComponents3.Label {
                                text: {
                                    // Same clock dependency as the per-window countdown above.
                                    var tick = root._now
                                    return i18n("Resets in %1", TimeUtils.formatResetTime(windowDelegate.modelData.resetAt)) // qmllint disable unqualified
                                }
                                textFormat: Text.PlainText
                                font: Kirigami.Theme.smallFont
                                opacity: 0.6
                                visible: !!windowDelegate.modelData.resetAt
                            }

                            // A window the collector refreshes on a rarer cadence than
                            // the file itself says how old it is, rather than being drawn
                            // with the same confidence as the one next to it. Most windows
                            // have no lag at all and never show this.
                            PlasmaComponents3.Label {
                                text: {
                                    var tick = root._now
                                    var behind = windowDelegate.modelData.behind || 0
                                    if (behind <= 0) return ""
                                    return i18n("as of %1", TimeUtils.formatRelativeTime(new Date(Date.now() - behind))) // qmllint disable unqualified
                                }
                                textFormat: Text.PlainText
                                font: Kirigami.Theme.smallFont
                                opacity: 0.45
                                visible: (windowDelegate.modelData.behind || 0) > 0
                            }
                        }
                    }

                    PlasmaComponents3.Label {
                        text: accountDelegate.modelData.lastUpdatedRelative
                        textFormat: Text.PlainText
                        font: Kirigami.Theme.smallFont
                        opacity: 0.45
                        Layout.fillWidth: true
                    }
                }
            }

            PlasmaComponents3.Label {
                visible: !!Plasmoid.configuration.showResetCountdown && !!root._limitingWindowData
                text: {
                    // Same clock dependency as the per-window countdown above.
                    var tick = root._now
                    return root._limitingWindowData
                        ? i18n("Limit resets in %1", TimeUtils.formatResetTime(root._limitingWindowData.resetAt)) // qmllint disable unqualified
                        : ""
                }
                font: Kirigami.Theme.smallFont
                opacity: 0.6
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                StatusIndicator {
                    status: root.aggregateStatus
                }

                Item { Layout.fillWidth: true }

                PlasmaComponents3.Label {
                    text: i18n("%1 accounts", root.usageModels.length) // qmllint disable unqualified
                    font: Kirigami.Theme.smallFont
                    opacity: 0.5
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Button {
                    // Says what it is doing: the file re-read is instant, but the
                    // collector's poll takes a moment, so a plain click would look
                    // like nothing happened. One click, every account -- the
                    // collector holds one process and one set of rate limits.
                    text: refreshFeedback.running ? i18n("Refreshing...") : i18n("Refresh") // qmllint disable unqualified
                    icon.name: "view-refresh"
                    Layout.fillWidth: true
                    onClicked: {
                        // Re-read what is on disk now, and ask the collector for
                        // fresh numbers; the file re-read follows a moment later.
                        for (var i = 0; i < root.usageModels.length; i++) {
                            root.usageModels[i].refresh()
                        }
                        if (root.collector) root.collector.requestPoll()
                        refreshFeedback.restart()
                    }

                    Timer {
                        id: refreshFeedback
                        interval: 4000
                        repeat: false
                    }
                }

                PlasmaComponents3.Button {
                    text: i18n("Open Claude") // qmllint disable unqualified
                    icon.source: Qt.resolvedUrl("../icons/kclaude.svg")
                    icon.color: "transparent"  // keep the brand colour, no theme recolouring
                    Layout.fillWidth: true
                    onClicked: Qt.openUrlExternally("https://claude.ai")
                }
            }
        }
    }
}
