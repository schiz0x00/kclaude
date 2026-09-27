import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.kirigami as Kirigami

// A custom compact representation must supply its own click handling; only the
// stock DefaultCompactRepresentation gets one for free.
MouseArea {
    id: root

    // One entry per configured account. Empty only before the account list has
    // been read, which is a single frame at startup.
    property var usageModels: []

    // The worst status across accounts, computed once in main.qml so the dot, the
    // tooltip and the popup footer cannot disagree about what "worst" means.
    property string aggregateStatus: "unknown"

    property PlasmoidItem plasmoidItem: null

    readonly property int _padding: Kirigami.Units.smallSpacing * 2

    readonly property bool _multiAccount: usageModels.length > 1

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

    // The panel always shows the session window, never whichever one happens to
    // be highest: a number whose meaning silently switches between five-hour and
    // weekly is unreadable at a glance. The dot still tracks the worst window
    // across every account, so a weekly limit closing in is not hidden.
    //
    // With one account this is exactly what it always was. With more, every
    // account's session window is listed in configuration order, because the
    // alternative -- one number for whichever account is worst -- leaves the
    // panel silent about the fact that there is a second account at all.
    function _sessionWindow(model) {
        if (!model || !model.windows) return null
        for (var i = 0; i < model.windows.length; i++) {
            if (model.windows[i].id === "five_hour") return model.windows[i]
        }
        // No session window in the file -- a custom collector need not write one
        // -- so fall back to whatever is closest to its limit.
        var limitId = model.limitingWindow
        for (var j = 0; j < model.windows.length; j++) {
            if (model.windows[j].id === limitId) return model.windows[j]
        }
        return null
    }

    readonly property string _utilText: {
        if (usageModels.length === 0) return ""
        var parts = []
        for (var i = 0; i < usageModels.length; i++) {
            var w = root._sessionWindow(usageModels[i])
            // An en dash, not a gap: an account with nothing to report has to be
            // visibly not reporting, or the shorter row reads as a smaller number.
            parts.push(w ? Math.round(w.utilization * 100) + "%" : "–")
        }
        return parts.join(" · ")
    }

    // The window name only earns its place when there is one account. With
    // several, every row is the same window and naming it three times says
    // nothing -- so the labels go in instead, and the names live in the popup.
    readonly property string _windowName: {
        if (usageModels.length !== 1) return ""
        var w = root._sessionWindow(usageModels[0])
        return w ? w.name : ""
    }

    readonly property string _accountNames: {
        var parts = []
        for (var i = 0; i < usageModels.length; i++) {
            var m = usageModels[i]
            var w = root._sessionWindow(m)
            parts.push(m.accountLabel + " " + (w ? Math.round(w.utilization * 100) + "%" : "–"))
        }
        return parts.join(" · ")
    }

    // Duplicated in StatusIndicator.qml on purpose: sharing it would need a
    // JS resource with an `.import` of Kirigami, more machinery than the
    // eight lines are worth.
    readonly property color _dotColor: {
        switch (aggregateStatus) {
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
                    // Mode 3 is the "more detail" mode, so with several accounts
                    // the detail it adds is which account is which.
                    case 3: return root._multiAccount ? root._accountNames
                                                      : root._utilText + " " + root._windowName
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
