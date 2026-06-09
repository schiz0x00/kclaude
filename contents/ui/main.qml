pragma ComponentBehavior: Bound
import QtQuick
import org.kde.plasma.plasmoid
import "../code" as CodeModule
import "../code/TimeUtils.js" as TimeUtils

PlasmoidItem {
    id: root

    CodeModule.UsageModel {
        id: usageSource
        filePath: Plasmoid.configuration.filePath
        warningThreshold: Plasmoid.configuration.warningThreshold / 100
        criticalThreshold: Plasmoid.configuration.criticalThreshold / 100

        Component.onCompleted: refresh()
    }

    CodeModule.ServiceControl {
        id: collectorService
        // Know whether the collector exists before the popup is ever opened, so
        // the empty state can say something true.
        Component.onCompleted: check()
        onBecameActive: postActionRefresh.restart()
        onPollRequested: postActionRefresh.restart()
    }

    // The collector needs a moment for its HTTPS call after being started or
    // poked. Re-read a few times so a slow request is still picked up promptly
    // rather than waiting out the whole refresh interval.
    Timer {
        id: postActionRefresh
        interval: 1500
        repeat: true
        triggeredOnStart: false
        property int ticks: 0
        onRunningChanged: if (running) ticks = 0
        onTriggered: {
            ticks++
            usageSource.refresh()
            if (ticks >= 5) stop()
        }
    }

    compactRepresentation: CompactRepresentation {
        id: compactRep
        usageModel: usageSource
        plasmoidItem: root
    }

    fullRepresentation: FullRepresentation {
        id: fullRep
        usageModel: usageSource
        collector: collectorService
    }

    toolTipMainText: Plasmoid.configuration.showTooltip ? "kclaude" : ""
    // KLocalizedContext injects i18n at runtime; the linter cannot see it.
    // qmllint disable unqualified
    toolTipSubText: {
        if (!Plasmoid.configuration.showTooltip) return ""
        var wins = usageSource.windows
        if (!wins || wins.length === 0) {
            if (usageSource.dataError) return usageSource.dataError
            return collectorService.serviceState === "notinstalled"
                ? i18n("Collector not installed")
                : i18n("Waiting for usage data")
        }

        var lines = []
        for (var i = 0; i < wins.length; i++) {
            var w = wins[i]
            var line = i18n("%1: %2%", w.name, Math.round(w.utilization * 100))
            if (w.resetAt) {
                line += " " + i18n("(resets in %1)", TimeUtils.formatResetTime(w.resetAt))
            }
            lines.push(line)
        }
        lines.push(i18n("Status: %1", TimeUtils.getStatusLabel(usageSource.status)))
        if (usageSource.dataError) {
            lines.push(usageSource.dataError)
        }
        return lines.join("\n")
    }
    // qmllint enable unqualified

    Timer {
        id: refreshTimer
        // Floor at 30s: the collector only writes every 5 minutes, so polling
        // faster spawns processes to re-read an unchanged file.
        interval: Math.max(30000, Plasmoid.configuration.refreshInterval * 1000)
        running: true
        repeat: true
        onTriggered: usageSource.refresh()
    }

    // Property change signals carry no arguments; read the property instead.
    onExpandedChanged: {
        if (!root.expanded) {
            return
        }
        if (Plasmoid.configuration.refreshOnPopup) {
            usageSource.refresh()
        }
        // Starting an installed-but-stopped collector is fine: installing it was
        // the user's consent. Installing it from here would not be.
        if (Plasmoid.configuration.autoStartCollector) {
            collectorService.startIfNeeded()
        } else {
            collectorService.check()
        }
    }
}
