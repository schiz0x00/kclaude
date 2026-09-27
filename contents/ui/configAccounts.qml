pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as QQC2Dialogs
import QtQuick.Layouts 1.15
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import "../code" as CodeModule
import "../code/Shell.js" as Shell
import "../code/Accounts.js" as Accounts

// The account list: which Claude config directories to watch, what to call them,
// and in what order.
//
// A separate page from the rest, because this is the only setting that lives in
// its own file rather than in main.xml. kcfg has no string-list type, and a list
// of arbitrary paths each with its own label has no kcfg representation at all,
// so the list is written to accounts.json -- the same file the collector reads.
// See docs/architecture.md.
//
// KCM.SimpleKCM, not a bare Kirigami.FormLayout, for the reason spelled out in
// configGeneral.qml: Plasma pushes each page onto a Kirigami PageRow and a plain
// FormLayout comes up blank.
KCM.SimpleKCM {
    id: page

    function _tr(text) {
        var args = Array.prototype.slice.call(arguments, 1)
        if (typeof i18n === "function") return i18n.apply(null, [text].concat(args)) // qmllint disable unqualified
        for (var j = 0; j < args.length; j++) text = text.replace("%" + (j + 1), args[j])
        return text
    }

    // Must agree with ACCOUNTS_FILE in the collector.
    property string accountsFilePath: "~/.config/kclaude/accounts.json"

    // The General page's usage-file setting, injected by Plasma, needed here to
    // work out where each account's numbers are. Declared rather than hardcoded
    // because a user who pointed the widget at a collector of their own would
    // otherwise see every plan badge on this page read as unknown — the accounts
    // themselves would be polled and drawn perfectly well, so the inconsistency
    // would look like a bug in the accounts themselves.
    property alias cfg_filePath: usageBaseField.text

    // The base the collector derives each account's usage file from, so this page
    // can show what the collector has made of each one. The plan is published in
    // the usage file because the widget is not allowed to read the credentials.
    readonly property string usageBasePath:
        String(usageBaseField.text || "").trim() || "~/.local/state/kclaude/usage.json"

    // Carries cfg_filePath and nothing else. Outside the FormLayout on purpose:
    // a hidden control in the form would still take a row's height.
    QQC2.TextField {
        id: usageBaseField
        visible: false
        width: 0
        height: 0
    }

    // The working copy. Edits land here and are only written on save(), so
    // Cancel really cancels.
    property var draft: []
    property string saveError: ""
    property bool saved: false

    readonly property int maxAccounts: 8

    // --- reading the current list ------------------------------------------
    //
    // Started from onAccountsChanged rather than Component.onCompleted: the read
    // is asynchronous, and completed() fires at construction, before there is
    // anything in `accounts` to copy.
    CodeModule.AccountList {
        id: loader
        filePath: page.accountsFilePath
        onAccountsChanged: {
            page.draft = JSON.parse(JSON.stringify(accounts))
            planProbe.start()
        }
    }

    // --- what the collector thinks of each one -----------------------------
    //
    // Read-only, and from the usage files rather than the credentials: the plan
    // and any login problem are already published there, so this page learns the
    // same thing the popup does without a token ever entering this process.
    CodeModule.FileUsageProvider {
        id: usageReader
    }

    // One read per account, in sequence, so N accounts do not start N `cat`
    // processes at the same instant on a dialog that is opening. Driven by a timer
    // rather than by usageUpdated, because usageUpdated is the thing this is
    // waiting for -- wiring the two together would spin.
    Timer {
        id: planProbe
        interval: 60
        repeat: false
        property int index: 0
        // Which account the read in flight belongs to. A slow read for one account
        // must not be filed under another's id.
        property string entryId: ""
        property var plan: ({})

        onTriggered: {
            planProbe.index = 0
            planProbe.plan = ({})
            planProbe.runNext()
        }

        function runNext() {
            if (planProbe.index >= page.draft.length) {
                page.planState = planProbe.plan
                return
            }
            var entry = page.draft[planProbe.index]
            planProbe.entryId = entry.id
            usageReader.filePath = Accounts.usageFile(page.usageBasePath, entry.id, planProbe.index)
            usageReader.refresh()
        }
    }

    // Plans arrive asynchronously and are keyed by id, so one account's read
    // cannot be mistaken for another's.
    property var planState: ({})

    Connections {
        target: usageReader
        function onUsageUpdated() {
            if (usageReader.isOffline) return
            planProbe.plan[planProbe.entryId] = usageReader.plan
            // The next one only after this read has landed, so the reads cannot
            // overlap and overwrite each other's entry.
            planProbe.index++
            planProbe.runNext()
        }
    }

    // --- writing ------------------------------------------------------------
    CodeModule.OneShotReader {
        id: saver
        // printf writes a file and prints nothing; a zero exit is the whole
        // success signal.
        expectOutput: false
        onCompleted: {
            page.saved = true
            page.saveError = ""
        }
        onFailed: function(reason) {
            page.saveError = page._tr("Could not write %1 (%2)", page.accountsFilePath, reason)
        }
    }

    // Plasma calls this when the dialog is accepted. The cfg_* properties are
    // handled by SimpleKCM itself; the account list is ours to persist.
    function save() {
        var payload = {
            version: 1,
            accounts: page.draft.map(function(entry) {
                return { id: entry.id, label: entry.label, path: entry.path }
            })
        }
        saver.command = Shell.writeFile(page.accountsFilePath, JSON.stringify(payload, null, 2) + "\n")
        saver.run()
    }

    function load() {
        // Nothing to do: SimpleKCM reloads the cfg_* properties, and the account
        // list is read by the loader above on every construction of this page.
    }

    // --- editing ------------------------------------------------------------

    function addAccount(dir) {
        if (page.draft.length >= page.maxAccounts) {
            page.saveError = page._tr("At most %1 accounts can be watched.", page.maxAccounts)
            return false
        }
        var id = Accounts.slug(Accounts.defaultLabel(dir))
        if (id.length === 0) return false
        // A second account for a folder already listed is a mistake worth naming
        // rather than silently ignoring, because the row would look like it added.
        for (var i = 0; i < page.draft.length; i++) {
            if (page.draft[i].path === dir) {
                page.saveError = page._tr("That folder is already in the list.")
                return false
            }
        }
        // Two accounts with the same id would share every state file the collector
        // derives from it, so the second one gets a suffix instead.
        var taken = {}
        for (var j = 0; j < page.draft.length; j++) taken[page.draft[j].id] = true
        var unique = id
        var n = 2
        while (taken[unique]) unique = id + "_" + n++
        page.draft = page.draft.concat([{ id: unique, label: Accounts.defaultLabel(dir), path: dir }])
        return true
    }

    function removeAt(index) {
        if (index < 0 || index >= page.draft.length) return
        var next = page.draft.slice()
        next.splice(index, 1)
        page.draft = next
    }

    function move(index, delta) {
        var to = index + delta
        if (index < 0 || index >= page.draft.length || to < 0 || to >= page.draft.length) return
        var next = page.draft.slice()
        var moved = next.splice(index, 1)[0]
        next.splice(to, 0, moved)
        page.draft = next
    }

    function labelOf(index) {
        return page.draft[index] && page.draft[index].label.length > 0
            ? page.draft[index].label : Accounts.defaultLabel(page.draft[index].path)
    }

    // --- discovery ----------------------------------------------------------

    CodeModule.OneShotReader {
        id: scanner
        onCompleted: function(stdout) {
            var found = stdout.split("\n").map(function(line) { return line.trim() })
                                .filter(function(line) { return line.length > 0 })
            var added = 0
            for (var i = 0; i < found.length; i++) {
                if (page.addAccount(found[i])) added++
            }
            page.saveError = added === 0
                ? page._tr("No new Claude config folders found in your home directory.")
                : ""
        }
        onFailed: page.saveError = page._tr("Could not search your home directory.")
    }

    // Checks one candidate folder for a credentials file before offering it.
    CodeModule.OneShotReader {
        id: checker
        onCompleted: {
            page.addAccount(page.checkerCandidate.dir)
        }
        onFailed: {
            page.saveError = page._tr("%1 has no .credentials.json, so it is not a Claude config folder.",
                                      page.checkerCandidate.dir)
        }
    }

    property var checkerCandidate: ({ dir: "" })

    function chooseFolder(dir) {
        page.checkerCandidate = { dir: dir }
        checker.command = Shell.hasCredentials(dir)
        checker.run()
    }

    function scanHome() {
        scanner.command = Shell.findConfigDirs("~", 1)
        scanner.run()
    }

    QQC2Dialogs.FileDialog {
        id: folderPicker
        title: page._tr("Choose a Claude config folder")
        fileMode: QQC2Dialogs.FileDialog.Directory
        onAccepted: page.chooseFolder(selectedFile.toString().replace("file://", ""))
    }

    // --- the form -----------------------------------------------------------

    Kirigami.FormLayout {
        id: form

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Accounts")
        }

        QQC2.Label {
            Kirigami.FormData.label: " "
            text: page._tr("Each folder is a Claude config directory: the one holding\n.claude.json, as ~/.claude does. The collector reads the\nOAuth token in each one, and the widget shows them all at once.\n\nThe first entry is the primary account. Adding an account here does\nnot need a restart -- the collector picks the change up within a minute.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        Repeater {
            model: page.draft

            delegate: ColumnLayout {
                id: row
                required property var modelData
                required property int index

                readonly property string plan: page.planState[modelData.id] || ""

                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.Label {
                        // The order is meaningful -- the first entry is primary --
                        // so it is stated rather than implied by position alone.
                        text: "#" + (row.index + 1)
                        opacity: 0.6
                        font: Kirigami.Theme.smallFont
                        Layout.preferredWidth: Kirigami.Units.gridUnit
                    }

                    QQC2.TextField {
                        id: labelField
                        Layout.fillWidth: true
                        // Start empty and fall back to the folder's name, so an
                        // account nobody has named does not carry a label that
                        // then disagrees with the folder.
                        placeholderText: Accounts.defaultLabel(row.modelData.path)
                        text: row.modelData.label
                        onTextChanged: {
                            if (text === row.modelData.label) return
                            var next = page.draft.slice()
                            next[row.index] = { id: row.modelData.id, label: text, path: row.modelData.path }
                            page.draft = next
                        }
                    }

                    QQC2.Label {
                        visible: row.plan.length > 0
                        text: row.plan.charAt(0).toUpperCase() + row.plan.substring(1)
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                    }

                    QQC2.ToolButton {
                        text: "↑"
                        enabled: row.index > 0
                        onClicked: page.move(row.index, -1)
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: page._tr("Move up")
                    }

                    QQC2.ToolButton {
                        text: "↓"
                        enabled: row.index < page.draft.length - 1
                        onClicked: page.move(row.index, 1)
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: page._tr("Move down")
                    }

                    QQC2.ToolButton {
                        text: "✕"
                        onClicked: page.removeAt(row.index)
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: page._tr("Remove")
                    }
                }

                QQC2.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit
                    text: row.modelData.path
                    textFormat: Text.PlainText
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                    elide: Text.ElideMiddle
                }
            }
        }

        QQC2.Label {
            visible: page.draft.length === 0
            Kirigami.FormData.label: " "
            text: page._tr("No accounts. The widget will show nothing until one is added.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: page._tr("Scan home folder")
                icon.name: "folder-refresh"
                enabled: page.draft.length < page.maxAccounts
                onClicked: page.scanHome()
            }

            QQC2.Button {
                text: page._tr("Add folder...")
                icon.name: "folder-add"
                enabled: page.draft.length < page.maxAccounts
                onClicked: folderPicker.open()
            }

            Item { Layout.fillWidth: true }
        }

        QQC2.Label {
            visible: page.saveError.length > 0
            Layout.fillWidth: true
            text: page.saveError
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Kirigami.Theme.negativeTextColor
        }

        QQC2.Label {
            visible: page.saved
            Layout.fillWidth: true
            text: page._tr("Saved. The collector will pick this up within a minute.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Where the numbers are read from")
        }

        QQC2.Label {
            Kirigami.FormData.label: " "
            text: page._tr("The collector writes one file per account next to the one below,\nnamed after the account: usage-<id>.json. The first account keeps\nthis exact path, so a collector of your own can replace it entirely.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }
}
