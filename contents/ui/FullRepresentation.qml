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

    property var usageModel: null
    property var collector: null

    readonly property string _collectorState: collector ? collector.serviceState : "unknown"

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
    // qmllint enable unqualified

    readonly property real _warningThreshold: usageModel ? usageModel.warningThreshold : 0.75
    readonly property real _criticalThreshold: usageModel ? usageModel.criticalThreshold : 0.9

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

    readonly property var _limitingWindowData: {
        var wins = root.usageModel ? root.usageModel.windows : []
        var limitId = root.usageModel ? root.usageModel.limitingWindow : ""
        if (!wins || !limitId) return null
        for (var i = 0; i < wins.length; i++) {
            if (wins[i].id === limitId) return wins[i]
        }
        return null
    }

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
                    status: root.usageModel ? root.usageModel.status : "unknown"
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            // The collector's "only you can fix this" message (expired Claude
            // Code login). Shown above the bars so it is visible whether or not
            // there are still numbers to display.
            PlasmaComponents3.Label {
                visible: !!(root.usageModel && root.usageModel.dataError)
                text: root.usageModel ? root.usageModel.dataError : ""
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Kirigami.Theme.negativeTextColor
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            // Replaces the bars when there is nothing to show, so a stopped or
            // missing collector is visible instead of a silent empty popup.
            ColumnLayout {
                visible: !root.usageModel || root.usageModel.windows.length === 0
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

            Repeater {
                model: root.usageModel ? root.usageModel.windows : []

                delegate: ColumnLayout {
                    id: windowDelegate
                    required property var modelData

                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    Layout.rightMargin: Kirigami.Units.largeSpacing
                    Layout.topMargin: Kirigami.Units.smallSpacing
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
                        text: i18n("Resets in %1", TimeUtils.formatResetTime(windowDelegate.modelData.resetAt)) // qmllint disable unqualified
                        textFormat: Text.PlainText
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                        visible: !!windowDelegate.modelData.resetAt
                    }
                }
            }

            PlasmaComponents3.Label {
                visible: !!Plasmoid.configuration.showResetCountdown && !!root._limitingWindowData
                text: root._limitingWindowData
                    ? i18n("Limit resets in %1", TimeUtils.formatResetTime(root._limitingWindowData.resetAt)) // qmllint disable unqualified
                    : ""
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
                    status: root.usageModel ? root.usageModel.status : "unknown"
                }

                Item { Layout.fillWidth: true }

                PlasmaComponents3.Label {
                    text: root.usageModel ? root.usageModel.lastUpdatedRelative : ""
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
                    // like nothing happened.
                    text: refreshFeedback.running ? i18n("Refreshing...") : i18n("Refresh") // qmllint disable unqualified
                    icon.name: "view-refresh"
                    Layout.fillWidth: true
                    onClicked: {
                        // Re-read what is on disk now, and ask the collector for
                        // fresh numbers; the file re-read follows a moment later.
                        if (root.usageModel) root.usageModel.refresh()
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
