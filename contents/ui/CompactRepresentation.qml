import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.kirigami as Kirigami

// A custom compact representation must supply its own click handling; only the
// stock DefaultCompactRepresentation gets one for free.
MouseArea {
    id: root

    property var usageModel: null
    property PlasmoidItem plasmoidItem: null

    readonly property int _padding: Kirigami.Units.smallSpacing * 2

    Layout.minimumWidth: layout.implicitWidth + _padding
    Layout.maximumWidth: layout.implicitWidth + _padding
    Layout.minimumHeight: Kirigami.Units.iconSizes.small
    implicitWidth: layout.implicitWidth + _padding
    implicitHeight: Kirigami.Units.iconSizes.small

    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    onClicked: {
        if (plasmoidItem) plasmoidItem.expanded = !plasmoidItem.expanded
    }

    Accessible.role: Accessible.Button
    Accessible.name: Plasmoid.title

    // The panel always shows the session window, not whichever one happens to be
    // highest: a number whose meaning silently switches between five-hour and
    // weekly is unreadable at a glance. The dot still tracks the worst window,
    // so a weekly limit closing in is not hidden.
    readonly property var _panelWindowData: {
        var wins = usageModel ? usageModel.windows : []
        if (!wins || wins.length === 0) return null
        for (var i = 0; i < wins.length; i++) {
            if (wins[i].id === "five_hour") return wins[i]
        }
        // No session window in the file -- a custom collector need not write one
        // -- so fall back to whatever is closest to its limit.
        var limitId = usageModel ? usageModel.limitingWindow : ""
        for (var j = 0; j < wins.length; j++) {
            if (wins[j].id === limitId) return wins[j]
        }
        return null
    }

    readonly property string _utilText: _panelWindowData
        ? Math.round(_panelWindowData.utilization * 100) + "%" : ""

    readonly property string _windowName: _panelWindowData ? _panelWindowData.name : ""

    // Duplicated in StatusIndicator.qml on purpose: sharing it would need a
    // JS resource with an `.import` of Kirigami, more machinery than the
    // eight lines are worth.
    readonly property color _dotColor: {
        switch (usageModel ? usageModel.status : "unknown") {
            case "active": return Kirigami.Theme.positiveTextColor
            case "warning": return Kirigami.Theme.neutralTextColor
            case "critical": return Kirigami.Theme.negativeTextColor
            case "limit_reached": return Kirigami.Theme.negativeTextColor
            default: return Kirigami.Theme.disabledTextColor
        }
    }

    RowLayout {
        id: layout
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        Item {
            id: iconContainer
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            Layout.alignment: Qt.AlignVCenter

            Kirigami.Icon {
                anchors.fill: parent
                // Bundled, so it works however the package was installed.
                source: Qt.resolvedUrl("../icons/kclaude.svg")
                active: root.containsMouse
            }

            Rectangle {
                width: Math.round(parent.width / 3)
                height: width
                radius: width / 2
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                color: root._dotColor
                border.width: 1
                border.color: Kirigami.Theme.backgroundColor
                Behavior on color { ColorAnimation { duration: Kirigami.Units.longDuration } }
            }
        }

        PlasmaComponents3.Label {
            id: modeLabel
            text: {
                switch (Plasmoid.configuration.compactMode) {
                    case 1: return "Claude"
                    case 2: return root._utilText
                    case 3: return root._utilText + " " + root._windowName
                    default: return ""
                }
            }
            visible: text.length > 0
            textFormat: Text.PlainText
            elide: Text.ElideRight
            maximumLineCount: 1
            color: Kirigami.Theme.textColor
            font: Kirigami.Theme.smallFont
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
