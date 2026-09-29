// Regression test for the accounts config page coming up blank, and for the
// editing rules that decide which file the collector will read.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_configaccounts.qml
//
// The blank-page part is the same failure tst_config.qml exists for: Plasma
// pushes each config page onto a Kirigami PageRow, whose onItemInserted assigns
// to item.ColumnView.globalHeader.transform and whose translation binding reads
// page.background. A page that is neither is blank, with no error the user can
// see and nothing qmllint can catch.
import QtQuick
import QtTest
import org.kde.kirigami as Kirigami
import "../contents/code/Accounts.js" as Accounts

TestCase {
    id: testCase
    name: "ConfigAccounts"
    when: windowShown
    visible: true
    width: 800
    height: 700

    Kirigami.ApplicationItem {
        id: app
        anchors.fill: parent
    }

    function pushPage() {
        while (app.pageStack.depth > 0) {
            app.pageStack.pop();
        }
        var page = app.pageStack.push(Qt.resolvedUrl("../contents/ui/configAccounts.qml"), {})
        verify(page !== null, "push returned null")
        wait(100)
        return page
    }

    // Push with initial properties, so they are in place before
    // Component.onCompleted runs. That is the only way to test a read that
    // happens during construction -- which is the read that was missing.
    function pushPageWith(props) {
        while (app.pageStack.depth > 0) {
            app.pageStack.pop();
        }
        var page = app.pageStack.push(Qt.resolvedUrl("../contents/ui/configAccounts.qml"), props)
        verify(page !== null, "push returned null")
        wait(100)
        return page
    }

    function countVisible(item, depth) {
        if (!item || depth > 14 || !item.children) {
            return 0
        }
        var n = 0
        for (var i = 0; i < item.children.length; i++) {
            var c = item.children[i]
            if (c && c.visible && c.width > 0 && c.height > 0) {
                n++
            }
            n += countVisible(c, depth + 1)
        }
        return n
    }

    function test_01_is_a_page() {
        var page = pushPage()
        verify(page.background !== undefined, "root is not a Kirigami Page: no background")
        verify(page.globalToolBarStyle !== undefined, "root is not a Kirigami Page")
    }

    function test_02_renders_controls() {
        var page = pushPage()
        verify(page.width > 0 && page.height > 0, "page has no geometry")
        verify(page.implicitHeight > 0, "page has zero implicitHeight -> blank panel")
        var n = countVisible(page, 0)
        verify(n > 10, "expected the form to be populated, only " + n + " visible items")
    }

    // --- the editing rules -------------------------------------------------
    //
    // These decide what the collector reads, so they are worth pinning even
    // though nothing on screen changes when they are wrong.

    function test_03_adding_an_account_appends_it() {
        var page = pushPage()
        page.draft = []
        compare(page.addAccount("/home/u/.claude"), true)
        compare(page.draft.length, 1)
        compare(page.draft[0].id, "claude")
        // The default label is the folder's own name, without the leading dot.
        compare(page.draft[0].label, "claude")
        compare(page.draft[0].path, "/home/u/.claude")
    }

    function test_04_the_same_folder_is_not_added_twice() {
        var page = pushPage()
        page.draft = []
        page.addAccount("/home/u/.claude")
        compare(page.addAccount("/home/u/.claude"), false,
                "a duplicate row would look like it added")
        compare(page.draft.length, 1)
    }

    // Two accounts whose folder names slug to the same id would share every state
    // file the collector derives from it, so the second gets a suffix.
    function test_05_colliding_ids_are_made_unique() {
        var page = pushPage()
        page.draft = []
        page.addAccount("/a/.claude")
        page.addAccount("/b/.claude")
        compare(page.draft.length, 2)
        compare(page.draft[0].id, "claude")
        compare(page.draft[1].id, "claude_2")
        verify(page.draft[0].id !== page.draft[1].id)
    }

    function test_06_a_folder_with_no_usable_name_is_refused() {
        var page = pushPage()
        page.draft = []
        compare(page.addAccount("/"), false)
        compare(page.addAccount(""), false)
        compare(page.draft.length, 0)
    }

    // The cap matches the collector's, so the page cannot offer an account that
    // would be silently truncated on the other side.
    function test_07_the_list_is_capped() {
        var page = pushPage()
        page.draft = []
        for (var i = 0; i < page.maxAccounts + 3; i++) {
            page.addAccount("/home/u/.claude" + i)
        }
        compare(page.draft.length, page.maxAccounts)
        compare(page.addAccount("/home/u/.one-more"), false)
    }

    // Order is meaningful: the first entry is the primary account, whose state
    // files are the unsuffixed ones the widget has always read.
    function test_08_moving_reorders_the_list() {
        var page = pushPage()
        page.draft = []
        page.addAccount("/a/.claude")
        page.addAccount("/b/.claude-dad")
        page.move(1, -1)
        compare(page.draft[0].id, "claude_dad")
        compare(page.draft[1].id, "claude")
        // Past either end is a no-op rather than a crash.
        page.move(0, -1)
        page.move(1, 1)
        compare(page.draft[0].id, "claude_dad")
        compare(page.draft[1].id, "claude")
    }

    function test_09_removing_takes_the_row_out() {
        var page = pushPage()
        page.draft = []
        page.addAccount("/a/.claude")
        page.addAccount("/b/.claude-dad")
        page.removeAt(0)
        compare(page.draft.length, 1)
        compare(page.draft[0].id, "claude_dad")
        // Out of range is ignored.
        page.removeAt(7)
        page.removeAt(-1)
        compare(page.draft.length, 1)
    }

    // The first entry is the primary account and keeps the configured usage file,
    // so the paths the widget reads are derived from one base.
    function test_10_the_derived_paths_line_up_with_the_collector() {
        var page = pushPage()
        page.draft = []
        page.addAccount("/a/.claude")
        page.addAccount("/b/.claude-dad")
        compare(page.usageBasePath, "~/.local/state/kclaude/usage.json")
        var first = Accounts.usageFile(page.usageBasePath, page.draft[0].id, 0)
        var second = Accounts.usageFile(page.usageBasePath, page.draft[1].id, 1)
        compare(first, page.usageBasePath)
        compare(second, "~/.local/state/kclaude/usage-claude_dad.json")
        verify(first !== second)
    }

    // The General page's usage-file setting has to reach this page, or a user who
    // pointed the widget at a collector of their own sees every plan badge read as
    // unknown here while the accounts themselves poll and draw fine -- which looks
    // like a bug in the accounts.
    function test_11_the_configured_usage_path_is_carried_over() {
        var page = pushPage()
        compare(page.cfg_filePath, "", "starts empty, so the default applies")
        compare(page.usageBasePath, "~/.local/state/kclaude/usage.json")
        page.cfg_filePath = "/tmp/mine/usage.json"
        compare(page.usageBasePath, "/tmp/mine/usage.json")
        page.draft = []
        page.addAccount("/a/.claude")
        page.addAccount("/b/.claude-dad")
        compare(Accounts.usageFile(page.usageBasePath, page.draft[0].id, 0), "/tmp/mine/usage.json")
        // ".claude-dad" slugs to "claude_dad", the same id the collector derives.
        compare(Accounts.usageFile(page.usageBasePath, page.draft[1].id, 1),
                "/tmp/mine/usage-claude_dad.json")
    }

    // Plasma assigns the General page's cfg_* values around construction, and
    // the badge sweep reads usageBasePath once, when the account list lands. A
    // path assigned after that is never used: every badge is answered from the
    // default directory and reads unknown until the dialog is reopened, which
    // for a user with a collector of their own looks exactly like the accounts
    // themselves are broken.
    function test_12_a_usage_path_assigned_after_the_list_lands_is_re_probed() {
        var page = pushPage()
        // The list has landed, so a path arriving now has to trigger a sweep.
        page._loadCompleted = true
        page.draft = [{ id: "solo", label: "Solo", path: "/home/u/.claude" }]
        compare(page.usageBasePath, "~/.local/state/kclaude/usage.json")

        // probeSweeps counts the sweeps that have started, which is the
        // observable effect of _reprobe(). The probe itself is a Timer, so it
        // is not reachable through `children` and the page exposes the count.
        var before = page.probeSweeps
        page.cfg_filePath = "/tmp/mine/usage.json"
        compare(page.usageBasePath, "/tmp/mine/usage.json")
        wait(200)
        compare(page.probeSweeps, before + 1,
                "a path arriving after the list must start a new sweep")

        // And before the list has landed there is nothing to sweep for, so
        // assignment must not start one.
        var other = pushPage()
        other._loadCompleted = false
        var before2 = other.probeSweeps
        other.cfg_filePath = "/tmp/other/usage.json"
        wait(200)
        compare(other.probeSweeps, before2, "no sweep before the list has been read")
    }

    // --- the real read and write path ---------------------------------------
    //
    // Every case above hand-assigns `draft`, which is why none of them noticed
    // that the read was never started: the AccountList on this page had no
    // Component.onCompleted: refresh(), so `accounts` kept its initial [], the
    // draft stayed empty, and pressing OK wrote {"accounts": []} over the
    // user's real list. Both readers treat that as "no accounts" and fall back
    // to ~/.claude. The whole suite was green the entire time.

    function test_13_the_page_reads_the_list_it_is_about_to_write() {
        var path = "/tmp/kclaude-tst-accounts-" + Math.floor(Date.now() / 1000) + ".json"

        // Write a real two-account list, through the page's own save().
        var writer = pushPage()
        writer.accountsFilePath = path
        writer.draft = [
            { id: "solo", label: "Solo", path: "/home/u/.claude" },
            { id: "work", label: "Work", path: "/home/u/.claude-work" }
        ]
        writer._loadCompleted = true
        writer.save()
        wait(2000)

        // A fresh page pointed at the same file, with accountsFilePath supplied
        // as an initial property so that the read happens during construction --
        // which is the path that was broken. Calling an explicit reload() here
        // instead would pass even with Component.onCompleted missing, and that is
        // exactly what the first version of this test did.
        var page = pushPageWith({ accountsFilePath: path })
        wait(2000)
        compare(page.draft.length, 2, "the page did not read the list it was pointed at")
        compare(page.draft[0].id, "solo")
        compare(page.draft[0].label, "Solo")
        compare(page.draft[1].id, "work")
        compare(page.draft[1].label, "Work")
    }

    function test_14_a_list_that_was_never_read_is_not_written_back_as_empty() {
        var page = pushPage()
        page.accountsFilePath = "/tmp/kclaude-tst-never-read.json"
        page.draft = []
        page._loadCompleted = false
        page.save()
        wait(500)
        verify(page.saveError.length > 0,
               "a refused save must say so, not write an empty list quietly")
    }

    // A plan badge belongs to the account it was read for. The probe runs one
    // read at a time and records which row the read in flight belongs to, and
    // that is only sound if a superseded sweep cannot still deliver. The draft
    // is edited -- a row moved, one added -- while a read is in flight, the
    // probe restarts, and index and entryId are reset underneath the read that
    // is still running. Its onUsageUpdated then files its result under the new
    // sweep's row and resumes the count from the wrong position, so one account
    // shows another's plan.
    function test_15_a_superseded_probe_result_is_dropped() {
        var page = pushPage()
        // A stand-in for the probe, with the same two counters: the sweep that
        // is in flight, and the sweep that is current. A read started by
        // generation 1 landing after the draft was edited is the case.
        var probe = { generation: 1, running: 1 }
        compare(page._sweepIsCurrent(probe), true, "the sweep in flight is current")

        // The edit restarts the probe, so the in-flight read is now stale.
        probe.generation = 2
        compare(page._sweepIsCurrent(probe), false,
                "a result from a superseded sweep must be dropped")

        // And the current sweep's own results are still accepted, or no badge
        // would ever appear.
        probe.running = 2
        compare(page._sweepIsCurrent(probe), true)
    }
}
