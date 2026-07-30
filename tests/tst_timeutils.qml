// Formatting checks, run against Qt's own JS engine rather than node, since
// that is what actually parses these timestamps at runtime.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_timeutils.qml
import QtQuick
import QtTest
import "../contents/code/TimeUtils.js" as TimeUtils

TestCase {
    name: "TimeUtils"

    // The live endpoint returns 6-digit fractional seconds and a +00:00 offset,
    // which is more precision than ECMAScript specifies. Qt's engine accepts it;
    // pin that, because a regression here shows up as "NaN" in the panel.
    function test_live_api_timestamp_shape() {
        var stamps = ["2026-07-30T00:10:00.333513+00:00", "2026-08-03T11:00:00.333538+00:00"]
        for (var i = 0; i < stamps.length; i++) {
            verify(!isNaN(new Date(stamps[i]).getTime()), stamps[i] + " did not parse")
            verify(TimeUtils.formatResetTime(stamps[i]).indexOf("NaN") === -1)
        }
    }

    function test_reset_time_never_renders_nan() {
        var bad = ["garbage", "not-a-date", "2026-13-45T99:99:99Z", "{}", "[]"]
        for (var i = 0; i < bad.length; i++) {
            var out = TimeUtils.formatResetTime(bad[i])
            compare(out, "unknown", "for input " + JSON.stringify(bad[i]))
        }
    }

    function test_reset_time_units() {
        var now = Date.now()
        compare(TimeUtils.formatResetTime(new Date(now - 1000).toISOString()), "Now")
        compare(TimeUtils.formatResetTime(""), "Now")
        verify(/^\d+s$/.test(TimeUtils.formatResetTime(new Date(now + 30 * 1000).toISOString())))
        verify(/^\d+m \d+s$/.test(TimeUtils.formatResetTime(new Date(now + 5 * 60000).toISOString())))
        verify(/^\d+h \d+m$/.test(TimeUtils.formatResetTime(new Date(now + 3 * 3600000).toISOString())))
        verify(/^\d+d \d+h$/.test(TimeUtils.formatResetTime(new Date(now + 3 * 86400000).toISOString())))
    }

    function test_relative_time() {
        var now = Date.now()
        compare(TimeUtils.formatRelativeTime(new Date(now + 5000)), "just now")
        compare(TimeUtils.formatRelativeTime(new Date(now - 1000)), "1 second ago")
        compare(TimeUtils.formatRelativeTime(new Date(now - 2000)), "2 seconds ago")
        compare(TimeUtils.formatRelativeTime(new Date(now - 60000)), "1 minute ago")
        compare(TimeUtils.formatRelativeTime(new Date(now - 7200000)), "2 hours ago")
        compare(TimeUtils.formatRelativeTime("garbage"), "")
        compare(TimeUtils.formatRelativeTime(null), "")
    }

    function test_status_thresholds() {
        compare(TimeUtils.getStatus(0.10, 0.75, 0.9), "active")
        compare(TimeUtils.getStatus(0.75, 0.75, 0.9), "warning")
        compare(TimeUtils.getStatus(0.90, 0.75, 0.9), "critical")
        compare(TimeUtils.getStatus(1.00, 0.75, 0.9), "limit_reached")
        // The value the live endpoint actually returned.
        compare(TimeUtils.getStatus(0.91, 0.75, 0.9), "critical")
    }

    function test_status_labels_cover_every_state() {
        var states = ["active", "warning", "critical", "limit_reached", "unknown", "offline"]
        for (var i = 0; i < states.length; i++) {
            var label = TimeUtils.getStatusLabel(states[i])
            verify(label.length > 0 && label !== "Unknown" || states[i] === "unknown",
                   states[i] + " has no distinct label")
        }
        compare(TimeUtils.getStatusLabel("something-new"), "Unknown")
    }
}
