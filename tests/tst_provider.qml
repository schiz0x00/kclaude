// usage.json parsing, including the collector's "error" key (the
// re-authenticate surface). Drives _parseResponse directly: no file or
// process involved, just the contract between the daemon and the widget.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_provider.qml
import QtQuick
import QtTest
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "FileUsageProvider"

    CodeModule.FileUsageProvider {
        id: provider
    }

    function init() {
        provider.lastUsage = null
        provider.isOffline = true
        provider.isStale = false
        provider.errorMessage = ""
        provider.fileError = ""
    }

    function test_01_valid_payload() {
        provider._parseResponse(JSON.stringify({
            windows: {
                five_hour: { utilization: 0.68, resetAt: "2026-07-30T18:00:00Z" },
                seven_day: { utilization: 0.41 }
            },
            updatedAt: new Date().toISOString()
        }))
        compare(provider.isOffline, false)
        compare(provider.isStale, false)
        compare(provider.fileError, "")
        compare(provider.lastUsage.windows.length, 2)
        compare(provider.lastUsage.windows[0].name, "5-hour")
    }

    function test_02_error_alongside_windows() {
        provider._parseResponse(JSON.stringify({
            windows: { five_hour: { utilization: 0.5 } },
            updatedAt: new Date().toISOString(),
            error: "Claude Code login expired: run 'claude' and sign in again"
        }))
        compare(provider.isOffline, false)
        compare(provider.lastUsage.windows.length, 1, "numbers must survive an auth error")
        verify(provider.fileError.indexOf("login expired") !== -1)
    }

    function test_03_error_only_payload_is_not_a_parse_error() {
        // What the daemon writes when auth died before the first ever poll.
        provider._parseResponse(JSON.stringify({
            windows: {},
            updatedAt: new Date().toISOString(),
            error: "No Claude Code credentials found: run 'claude' and sign in"
        }))
        compare(provider.isOffline, false, "an error-only payload is data, not an unreadable file")
        compare(provider.lastUsage.windows.length, 0)
        verify(provider.fileError.length > 0)
    }

    function test_04_error_is_sanitized_and_capped() {
        var filler = new Array(500).join("x")
        provider._parseResponse(JSON.stringify({
            windows: {},
            error: "<img src=http://evil>" + filler
        }))
        verify(provider.fileError.indexOf("<") === -1, "angle brackets must be stripped")
        verify(provider.fileError.indexOf(">") === -1)
        verify(provider.fileError.length <= 160, "got " + provider.fileError.length)
    }

    function test_05_no_windows_and_no_error_still_fails() {
        provider._parseResponse(JSON.stringify({ windows: {} }))
        compare(provider.isOffline, true)
        compare(provider.errorMessage, "No valid window entries")
    }

    function test_06_unreadable_file_clears_stale_error_banner() {
        provider._parseResponse(JSON.stringify({
            windows: {},
            error: "re-auth"
        }))
        verify(provider.fileError.length > 0)
        provider._parseResponse("not json at all")
        compare(provider.isOffline, true)
        compare(provider.fileError, "", "a parse failure says nothing about auth")
    }

    function test_07_malformed_windows_are_skipped() {
        provider._parseResponse(JSON.stringify({
            windows: {
                good: { utilization: 0.2 },
                no_util: { resetAt: "x" },
                bad_util: { utilization: "high" },
                nulled: null
            }
        }))
        compare(provider.lastUsage.windows.length, 1)
        compare(provider.lastUsage.windows[0].id, "good")
        compare(provider.lastUsage.windows[0].name, "Good", "unknown ids are title-cased")
    }

    function test_08_window_cap() {
        var windows = {}
        for (var i = 0; i < 20; i++) windows["w" + i] = { utilization: 0.1 }
        provider._parseResponse(JSON.stringify({ windows: windows }))
        compare(provider.lastUsage.windows.length, provider.maxWindows)
    }

    // Fable Weekly is only sent by plans that have it, so the widget's job is to
    // name it when it turns up and say nothing at all when it does not.
    function test_09_fable_window_is_named() {
        provider._parseResponse(JSON.stringify({
            windows: {
                five_hour: { utilization: 0.82, resetAt: "2026-09-27T16:29:59Z" },
                fable: { utilization: 0.22, resetAt: "2026-09-29T19:59:59Z" }
            },
            updatedAt: new Date().toISOString()
        }))
        compare(provider.lastUsage.windows.length, 2)
        var names = provider.lastUsage.windows.map(function(w) { return w.name })
        verify(names.indexOf("Fable Weekly") !== -1, "got " + names.join(", "))
        verify(names.indexOf("5-hour") !== -1)
    }

    function test_10_absent_fable_is_simply_absent() {
        // The ordinary account: no fable key, and nothing invented for it.
        provider._parseResponse(JSON.stringify({
            windows: { five_hour: { utilization: 0.82 }, seven_day: { utilization: 0.11 } },
            updatedAt: new Date().toISOString()
        }))
        compare(provider.lastUsage.windows.length, 2)
        for (var i = 0; i < provider.lastUsage.windows.length; i++) {
            verify(provider.lastUsage.windows[i].name.indexOf("Fable") === -1)
        }
    }

    // A window read off the scarce endpoint is older than the file around it, and
    // says so. Without this the popup would draw a half-hour-old number with the
    // same confidence as a one-minute-old one.
    function test_11_slow_window_reports_its_lag() {
        var fileAt = new Date(Date.now() - 60000).toISOString()
        var stale = new Date(Date.now() - 40 * 60 * 1000).toISOString()
        provider._parseResponse(JSON.stringify({
            windows: {
                five_hour: { utilization: 0.82 },
                fable: { utilization: 0.22, updatedAt: stale }
            },
            updatedAt: fileAt
        }))
        var byId = {}
        for (var i = 0; i < provider.lastUsage.windows.length; i++) {
            byId[provider.lastUsage.windows[i].id] = provider.lastUsage.windows[i]
        }
        compare(byId.five_hour.behind, 0, "a polled window is as fresh as the file")
        compare(byId.fable.behind, 39 * 60 * 1000)
    }

    function test_12_small_lag_is_not_worth_a_label() {
        // Two minutes apart is noise, not a stale reading.
        provider._parseResponse(JSON.stringify({
            windows: { fable: { utilization: 0.22, updatedAt: new Date(Date.now() - 120000).toISOString() } },
            updatedAt: new Date().toISOString()
        }))
        compare(provider.lastUsage.windows[0].behind, 0)
    }

    function test_13_unparseable_window_timestamp_is_not_a_lag() {
        provider._parseResponse(JSON.stringify({
            windows: { fable: { utilization: 0.22, updatedAt: "not a date" } },
            updatedAt: new Date().toISOString()
        }))
        compare(provider.lastUsage.windows[0].behind, 0)
    }

    // The plan arrives from the collector, because the widget is not allowed to
    // read the credentials to work it out. It is drawn next to the account name,
    // so the accept list is short and anything else becomes no badge at all.
    function test_14_the_plan_is_read_and_allowlisted() {
        provider._parseResponse(JSON.stringify({
            windows: { five_hour: { utilization: 0.5 } },
            plan: "max",
            updatedAt: new Date().toISOString()
        }))
        compare(provider.plan, "max")
    }

    function test_15_plan_case_does_not_matter() {
        provider._parseResponse(JSON.stringify({
            windows: { five_hour: { utilization: 0.5 } },
            plan: "Max",
            updatedAt: new Date().toISOString()
        }))
        compare(provider.plan, "max")
    }

    // A hand-written file need not carry a plan, and a value nobody recognises
    // must not be shown as if it were one.
    function test_16_unknown_or_absent_plans_show_nothing() {
        for (const bad of ["enterprise-plus", "<b>max</b>", "42", "true", ""]) {
            provider._parseResponse(JSON.stringify({
                windows: { five_hour: { utilization: 0.5 } },
                plan: bad,
                updatedAt: new Date().toISOString()
            }))
            compare(provider.plan, "", "plan " + JSON.stringify(bad) + " should not be shown")
        }
        // Omitted entirely.
        provider._parseResponse(JSON.stringify({
            windows: { five_hour: { utilization: 0.5 } },
            updatedAt: new Date().toISOString()
        }))
        compare(provider.plan, "")
    }

    // A payload rejected for having no usable windows must not leave a plan from
    // a file this provider just decided not to trust.
    function test_17_a_rejected_payload_leaves_no_plan_behind() {
        provider._parseResponse(JSON.stringify({
            windows: {},
            plan: "max",
            updatedAt: new Date().toISOString()
        }))
        compare(provider.isOffline, true)
        compare(provider.plan, "")
    }
}
