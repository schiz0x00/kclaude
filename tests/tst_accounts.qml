// The account list: what the widget does with whatever is in accounts.json.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_accounts.qml
//
// This is the file the settings page writes and the collector reads, so every
// field in it is treated as untrusted on both sides. The cases below are the
// shapes a hand-edited or truncated file turns into, plus the one that matters
// most: a missing file has to resolve to the single account this widget has
// always shown, or every existing install breaks the moment it is upgraded.
import QtQuick
import QtTest
import "../contents/code" as CodeModule

TestCase {
    id: testCase
    name: "AccountList"
    when: windowShown

    CodeModule.AccountList {
        id: list
    }

    // The list is a plain function of the file's contents, so most of this is
    // parse() with no file and no process.
    function test_00_defaults_without_a_file() {
        var accounts = list.defaultAccounts()
        compare(accounts.length, 1)
        compare(accounts[0].path, "~/.claude")
        compare(accounts[0].isDefault, true)
    }

    function test_01_a_well_formed_list() {
        var parsed = list.parse({ version: 1, accounts: [
            { id: "personal", label: "Max", path: "/home/u/.claude" },
            { id: "dad", label: "Dad", path: "/home/u/.claude-dad" }
        ]})
        compare(parsed.length, 2)
        compare(parsed[0].id, "personal")
        compare(parsed[0].label, "Max")
        compare(parsed[0].path, "/home/u/.claude")
        compare(parsed[1].id, "dad")
        compare(parsed[1].label, "Dad")
        // The first entry is the primary account, and the collector's unsuffixed
        // state files hang off that, so it has to be marked.
        compare(parsed[0].isDefault, true)
        compare(parsed[1].isDefault, false)
    }

    // An account nobody has named falls back to its id rather than rendering a
    // blank row next to a named one.
    function test_02_an_unnamed_account_falls_back_to_its_id() {
        var parsed = list.parse({ accounts: [
            { id: "personal", label: "Max", path: "/a" },
            { id: "dad", label: "", path: "/b" },
            { id: "third", path: "/c" }
        ]})
        compare(parsed[1].label, "dad")
        compare(parsed[2].label, "third")
    }

    // Everything unusable resolves to the default account, because a widget with
    // zero accounts shows nothing at all and there is nothing the user can do
    // about it from the panel.
    function test_03_unusable_shapes_fall_back() {
        var junk = [null, 42, "a string", [], {}, { accounts: null },
                    { accounts: "no" }, { accounts: [] }, { accounts: [1, 2, 3] },
                    { accounts: ["str", true] }]
        for (var i = 0; i < junk.length; i++) {
            var parsed = list.parse(junk[i])
            compare(parsed.length, 1, "input " + JSON.stringify(junk[i]))
            compare(parsed[0].path, "~/.claude", "input " + JSON.stringify(junk[i]))
        }
    }

    // A missing path would send the collector at the default config directory,
    // which is worse than dropping the entry: the user would be shown someone
    // else's account numbers.
    function test_04_entries_without_a_usable_path_are_dropped() {
        var parsed = list.parse({ accounts: [
            { id: "ok", path: "/home/u/.claude" },
            { id: "blank", path: "   " },
            { id: "missing" },
            { id: "null", path: null },
            { id: "nonnumber", path: 42 }
        ]})
        compare(parsed.length, 1)
        compare(parsed[0].id, "ok")
    }

    // Ids are filenames on the collector's side, so anything that would not
    // survive being one is rejected here rather than there.
    function test_05_unusable_ids_are_dropped_and_slugged() {
        var parsed = list.parse({ accounts: [
            { id: "Claude Dad", path: "/a" },
            { id: "///", path: "/b" },
            { id: "", path: "/c" },
            { id: null, path: "/d" }
        ]})
        compare(parsed.length, 1)
        compare(parsed[0].id, "claude_dad")
    }

    // Two accounts sharing an id would share every state file the collector
    // derives from it.
    function test_06_duplicate_ids_are_dropped() {
        var parsed = list.parse({ accounts: [
            { id: "same", path: "/a" },
            { id: "same", path: "/b" },
            { id: "SAME", path: "/c" },
            { id: "other", path: "/d" }
        ]})
        compare(parsed.length, 2)
        compare(parsed[0].path, "/a")
        compare(parsed[1].path, "/d")
    }

    // The collector truncates at the same number, so showing more rows than that
    // would advertise accounts that are never polled.
    function test_07_the_list_is_capped_like_the_collector() {
        var entries = []
        for (var i = 0; i < 20; i++) entries.push({ id: "a" + i, path: "/p" + i })
        var parsed = list.parse({ accounts: entries })
        compare(parsed.length, list.maxAccounts)
        compare(list.maxAccounts, 8)
        compare(parsed[0].id, "a0")
    }

    // Labels are rendered as Text and in the Plasma tooltip, and Text.AutoText
    // turns anything HTML-ish into rich text -- including an <img> that would
    // fetch a remote URL from inside plasmashell.
    function test_08_labels_cannot_carry_markup() {
        var parsed = list.parse({ accounts: [
            { id: "a", label: "<img src=http://evil/x>", path: "/a" }
        ]})
        compare(parsed[0].label.indexOf("<"), -1, parsed[0].label)
        compare(parsed[0].label.indexOf(">"), -1, parsed[0].label)
    }

    function test_09_labels_are_length_capped() {
        var filler = new Array(200).join("x")
        var parsed = list.parse({ accounts: [{ id: "a", label: filler, path: "/a" }]})
        verify(parsed[0].label.length <= 40, "label was " + parsed[0].label.length)
    }

    function test_10_paths_are_length_capped() {
        var filler = "/" + new Array(9000).join("y")
        var parsed = list.parse({ accounts: [{ id: "a", path: filler }]})
        verify(parsed[0].path.length <= 4096, "path was " + parsed[0].path.length)
    }

    // Where each account's numbers are. The primary keeps the configured path so
    // a hand-written collector keeps working; the rest are siblings named after
    // the id, which is the name the collector writes.
    function test_11_usage_paths_derive_from_the_configured_one() {
        var base = "~/.local/state/kclaude/usage.json"
        compare(list.usageFileFor(base, "personal", 0), base)
        compare(list.usageFileFor(base, "dad", 1), "~/.local/state/kclaude/usage-dad.json")
    // Two accounts can never land on one file.
    var seen = ({})
    for (var i = 0; i < 6; i++) {
        var p = list.usageFileFor(base, "acct" + i, i)
        verify(!seen[p], "duplicate usage path " + p)
        seen[p] = true
    }

    }
}
