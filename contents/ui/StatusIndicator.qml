import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "../code/TimeUtils.js" as TimeUtils

RowLayout {
    id: root

    property string status: "unknown"

    spacing: Kirigami.Units.smallSpacing

    readonly property color _dotColor: {
        switch (root.status) {
            case "active": return Kirigami.Theme.positiveTextColor
            case "warning": return Kirigami.Theme.neutralTextColor
            case "critical": return Kirigami.Theme.negativeTextColor
            case "limit_reached": return Kirigami.Theme.negativeTextColor
            // Same grey as an outage, deliberately: neither is reporting right
            // now, and the two differ only in the label beside the dot. A
            // distinct hue here would read as a third severity level that means
            // nothing.
            case "sleeping": return Kirigami.Theme.disabledTextColor
            default: return Kirigami.Theme.disabledTextColor
        }
    }

    Rectangle {
        implicitWidth: Kirigami.Units.smallSpacing * 2
        implicitHeight: implicitWidth
        radius: width / 2
        color: root._dotColor
        Layout.alignment: Qt.AlignVCenter

        Behavior on color { ColorAnimation { duration: Kirigami.Units.longDuration } }
    }

    PlasmaComponents3.Label {
        text: TimeUtils.getStatusLabel(root.status)
        color: root._dotColor
        font: Kirigami.Theme.smallFont
        Layout.alignment: Qt.AlignVCenter

        Behavior on color { ColorAnimation { duration: Kirigami.Units.longDuration } }
    }
}
