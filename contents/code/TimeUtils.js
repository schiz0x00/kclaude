// Inside plasmashell, KLocalizedContext puts i18n/i18np on the scope chain and
// this file (no .pragma library) sees them. Under qmltestrunner and node there
// is no such context, so fall back to identity with %N substitution. xgettext
// extraction uses -k_tr:1 -k_trp:1,2 (see docs/i18n.md).
function _tr(text) {
    var args = Array.prototype.slice.call(arguments, 1)
    if (typeof i18n === "function") return i18n.apply(null, [text].concat(args))
    for (var j = 0; j < args.length; j++) text = text.replace("%" + (j + 1), args[j])
    return text
}

function _trp(singular, plural, n) {
    if (typeof i18np === "function") return i18np(singular, plural, n)
    return (n === 1 ? singular : plural).replace("%1", n)
}

function formatResetTime(resetAt) {
    if (!resetAt) return _tr("Now")
    var reset = new Date(resetAt)
    // An unparseable timestamp otherwise falls through every branch below and
    // renders as "NaNd NaNh" in the panel. The usage file is user-configurable.
    if (isNaN(reset.getTime())) return _tr("unknown")
    var diff = reset.getTime() - new Date().getTime()
    if (diff <= 0) return _tr("Now")
    var seconds = Math.floor(diff / 1000)
    if (seconds < 60) return _tr("%1s", seconds)
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return _tr("%1m %2s", minutes, seconds % 60)
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return _tr("%1h %2m", hours, minutes % 60)
    var days = Math.floor(hours / 24)
    return _tr("%1d %2h", days, hours % 24)
}

function formatRelativeTime(date) {
    if (!date) return ""
    var d = (date instanceof Date) ? date : new Date(date)
    if (isNaN(d.getTime())) return ""
    var diff = Math.floor((new Date().getTime() - d.getTime()) / 1000)
    if (diff < 0) return _tr("just now")
    if (diff < 60) return _trp("%1 second ago", "%1 seconds ago", diff)
    var minutes = Math.floor(diff / 60)
    if (minutes < 60) return _trp("%1 minute ago", "%1 minutes ago", minutes)
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return _trp("%1 hour ago", "%1 hours ago", hours)
    var days = Math.floor(hours / 24)
    return _trp("%1 day ago", "%1 days ago", days)
}

function getStatus(utilization, warnThreshold, critThreshold) {
    if (utilization >= 1.0) return "limit_reached"
    if (utilization >= critThreshold) return "critical"
    if (utilization >= warnThreshold) return "warning"
    return "active"
}

function getStatusLabel(status) {
    switch (status) {
        case "active": return _tr("Active")
        case "warning": return _tr("High Usage")
        case "critical": return _tr("Near Limit")
        case "limit_reached": return _tr("Limit Reached")
        case "unknown": return _tr("Unknown")
        case "offline": return _tr("Collector Offline")
        default: return _tr("Unknown")
    }
}

function formatTime(date) {
    if (!date) return "--:--:--"
    var d = (date instanceof Date) ? date : new Date(date)
    if (isNaN(d.getTime())) return "--:--:--"
    var h = d.getHours()
    var m = d.getMinutes()
    var s = d.getSeconds()
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
}
