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
}
