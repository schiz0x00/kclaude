pragma ComponentBehavior: Bound
import QtQuick
import org.kde.plasma.plasmoid
import "../code" as CodeModule
import "../code/TimeUtils.js" as TimeUtils

PlasmoidItem {
    id: root

    // The accounts to watch. Read once at startup and again whenever the settings
    // page rewrites the list, so adding an account does not need a plasmashell
    // restart -- the collector picks the same file up on its own.
    CodeModule.AccountList {
        id: accountList
        Component.onCompleted: refresh()
        onAccountsChanged: {
            root.refreshAll()
            root._syncModels()
        }
    }

    // One model per account, owned by a Repeater so adding or removing an account
    // creates and destroys exactly the right ones. `accounts` is the array the
    // representations read, and it is rebuilt only when the list really changes,
    // so a re-read of the same file does not hand every binding a new array and
    // repaint the panel for nothing.
    property var accounts: []
    property var accountModels: []

    function _syncModels() {
        var next = []
        for (var i = 0; i < accountList.accounts.length; i++) {
            var model = modelRepeater.itemAt(i)
            if (model) next.push(model)
        }
        root.accountModels = next
    }

    Repeater {
        id: modelRepeater
        model: accountList.accounts

        delegate: CodeModule.UsageModel {
            required property var modelData
            required property int index

            accountId: modelData.id
            accountLabel: modelData.label
            // The primary account keeps the configured path, so a custom
            // collector's file is still the one that gets read; the rest are
            // siblings named after the id, which is the name the collector
            // writes. See Accounts.usageFile.
            filePath: accountList.usageFileFor(Plasmoid.configuration.filePath,
                                               modelData.id, index)
            warningThreshold: Plasmoid.configuration.warningThreshold / 100
            criticalThreshold: Plasmoid.configuration.criticalThreshold / 100

            Component.onCompleted: {
                refresh()
                root._syncModels()
            }
        }
    }

    // Refresh every account. One loop rather than N connections: a signal carries
    // no arguments, and a per-model handler would be N places to forget one.
    function refreshAll() {
        for (var i = 0; i < root.accountModels.length; i++) {
            root.accountModels[i].refresh()
        }
    }

    // The worst status across accounts, which is what the panel's dot and the
    // popup's summary line report. An account with no numbers contributes
    // "unknown" rather than nothing, so a second account that has not polled yet
    // cannot make a full one look healthy.
    readonly property string worstStatus: {
        var order = { "limit_reached": 4, "critical": 3, "warning": 2, "active": 1,
                      "offline": 0, "unknown": 0 }
        var worst = "unknown"
        for (var i = 0; i < root.accountModels.length; i++) {
            var s = root.accountModels[i].status
            if (!Object.prototype.hasOwnProperty.call(order, s)) continue
            if (order[s] > order[worst]) worst = s
        }
        return worst
    }

    CodeModule.ServiceControl {
        id: collectorService
        // Know whether the collector exists before the popup is ever opened, so
        // the empty state can say something true.
        Component.onCompleted: check()
        onBecameActive: postActionRefresh.restart()
        onPollRequested: postActionRefresh.restart()
    }

    CodeModule.SessionPrimer {
        id: sessionPrimer
        active: Plasmoid.configuration.primeOnReset
        // The earliest five-hour reset across all accounts, which is the one that
        // runs out first. The collector primes every account whose window has
        // expired, each under its own hourly ceiling, so one signal covering all of
        // them is enough -- the widget does not have to know which one it was.
        resetAt: {
            var earliest = ""
            var earliestMs = 0
            for (var i = 0; i < root.accountModels.length; i++) {
                var wins = root.accountModels[i].windows
                for (var j = 0; j < wins.length; j++) {
                    if (wins[j].id !== "five_hour" || !wins[j].resetAt) continue
                    var ms = new Date(wins[j].resetAt).getTime()
                    if (isNaN(ms)) continue
                    if (earliestMs === 0 || ms < earliestMs) {
                        earliestMs = ms
                        earliest = wins[j].resetAt
                    }
                }
            }
            return earliest
        }
        // The only caller of requestPrime, and it only fires when a five-hour
        // window that was running has expired. No refresh path reaches this.
        // The re-read is already covered: requestPrime goes out on the same
        // source that emits pollRequested.
        //
        // confirm() only when it really went out. requestPrime returns false
        // while the collector is not active -- which is what the first seconds
        // after a plasmashell start look like -- and settling the window on that
        // would throw the prime away for good.
        onPrimeRequested: if (collectorService.requestPrime()) sessionPrimer.confirm()
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
            root.refreshAll()
            if (ticks >= 5) stop()
        }
    }

    compactRepresentation: CompactRepresentation {
        id: compactRep
        usageModels: root.accountModels
        aggregateStatus: root.worstStatus
        plasmoidItem: root
    }

    fullRepresentation: FullRepresentation {
        id: fullRep
        usageModels: root.accountModels
        aggregateStatus: root.worstStatus
        collector: collectorService
    }

    toolTipMainText: Plasmoid.configuration.showTooltip ? "kclaude" : ""
    // KLocalizedContext injects i18n at runtime; the linter cannot see it.
    // qmllint disable unqualified
    toolTipSubText: {
        if (!Plasmoid.configuration.showTooltip) return ""
        var models = root.accountModels
        if (!models || models.length === 0) {
            return collectorService.serviceState === "notinstalled"
                ? i18n("Collector not installed")
                : i18n("Waiting for usage data")
        }

        // One line per account, then its windows indented under it. A flat list of
        // six "82%: 3h 12m" lines is unreadable with two accounts -- there is
        // nothing to say which number belongs to whom.
        var lines = []
        for (var a = 0; a < models.length; a++) {
            var model = models[a]
            var wins = model.windows
            if (a > 0) lines.push("")
            lines.push(model.accountLabel.length > 0 ? model.accountLabel : "kclaude")
            if (wins.length === 0) {
                lines.push("  " + (model.dataError.length > 0
                                   ? model.dataError
                                   : i18n("Waiting for usage data")))
                continue
            }
            for (var i = 0; i < wins.length; i++) {
                var w = wins[i]
                var line = "  " + i18n("%1: %2%", w.name, Math.round(w.utilization * 100))
                if (w.resetAt) {
                    line += " " + i18n("(resets in %1)", TimeUtils.formatResetTime(w.resetAt))
                }
                lines.push(line)
            }
            if (model.dataError.length > 0) {
                lines.push("  " + model.dataError)
            }
        }
        lines.push(i18n("Status: %1", TimeUtils.getStatusLabel(root.worstStatus)))
        return lines.join("\n")
    }
    // qmllint enable unqualified

    Timer {
        id: refreshTimer
        // Floor at 30s: the collector only writes every 60s, so polling
        // faster spawns processes to re-read unchanged files.
        interval: Math.max(30000, Plasmoid.configuration.refreshInterval * 1000)
        running: true
        repeat: true
        onTriggered: root.refreshAll()
    }

    // Property change signals carry no arguments; read the property instead.
    onExpandedChanged: {
        if (!root.expanded) {
            return
        }
        if (Plasmoid.configuration.refreshOnPopup) {
            root.refreshAll()
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
