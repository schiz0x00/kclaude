import QtQuick 2.15
import org.kde.kirigami as Kirigami

Rectangle {
    id: root

    property real utilization: 0.0
    // Defaults match config/main.xml; FullRepresentation feeds in the
    // configured values so the bar cannot disagree with the status dot.
    property real warningThreshold: 0.75
    property real criticalThreshold: 0.9

    implicitWidth: Kirigami.Units.gridUnit * 10
    implicitHeight: Math.round(Kirigami.Units.gridUnit / 2)

    radius: height / 2
    // Tint via alpha, not `opacity`: `opacity` also fades every child, which
    // would wash out the fill bar drawn on top of the track.
    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                   Kirigami.Theme.textColor.b, 0.15)

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * Math.max(0, Math.min(root.utilization, 1.0))
        radius: parent.radius
        color: {
            if (root.utilization >= root.criticalThreshold) return Kirigami.Theme.negativeTextColor
            if (root.utilization >= root.warningThreshold) return Kirigami.Theme.neutralTextColor
            return Kirigami.Theme.highlightColor
        }

        Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutQuart } }
        Behavior on color { ColorAnimation { duration: Kirigami.Units.longDuration } }
    }
}
