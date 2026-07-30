import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

// KCM.SimpleKCM, not a bare Kirigami.FormLayout. The Plasma config dialog
// pushes each page onto a Kirigami PageRow, whose onItemInserted assigns to
// item.ColumnView.globalHeader.transform and whose translation binding reads
// page.background. A FormLayout has neither, so the handler throws part-way
// through insertion and the page comes up blank. SimpleKCM is a Kirigami.Page,
// which is what every in-tree Plasma applet config page uses.
// Regression test: tests/tst_config.qml.
KCM.SimpleKCM {
    id: page

    // tst_config.qml loads this page under qmltestrunner, which has no
    // KLocalizedContext, so a bare i18n() there is a ReferenceError and every
    // label renders blank. Inside plasmashell/systemsettings the real i18n is
    // on the scope chain and wins. xgettext extracts via -k_tr:1 (docs/i18n.md).
    function _tr(text) {
        var args = Array.prototype.slice.call(arguments, 1)
        if (typeof i18n === "function") return i18n.apply(null, [text].concat(args)) // qmllint disable unqualified
        for (var j = 0; j < args.length; j++) text = text.replace("%" + (j + 1), args[j])
        return text
    }

    property alias cfg_compactMode: compactModeCombo.currentIndex
    property alias cfg_refreshInterval: refreshSpin.value
    property alias cfg_warningThreshold: warnSpin.value
    property alias cfg_criticalThreshold: critSpin.value
    property alias cfg_filePath: filePathField.text
    property alias cfg_refreshOnPopup: refreshPopupCheck.checked
    property alias cfg_autoStartCollector: autoStartCheck.checked
    property alias cfg_primeOnReset: primeCheck.checked
    property alias cfg_showTooltip: tooltipCheck.checked
    property alias cfg_showResetCountdown: resetCountdownCheck.checked

    Kirigami.FormLayout {

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Panel")
        }

        QQC2.ComboBox {
            id: compactModeCombo
            Kirigami.FormData.label: page._tr("Compact display:")
            model: [page._tr("Icon only"), page._tr("Icon and name"), page._tr("Icon and usage"), page._tr("Icon, usage and window")]
        }

        QQC2.CheckBox {
            id: tooltipCheck
            Kirigami.FormData.label: page._tr("Tooltip:")
            text: page._tr("Show usage on hover")
        }

        QQC2.CheckBox {
            id: resetCountdownCheck
            Kirigami.FormData.label: page._tr("Countdown:")
            text: page._tr("Show time until the limit resets")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Updates")
        }

        // A plain alias to an editable SpinBox: no index mapping, and no
        // dependence on when Plasma assigns the saved cfg_* value.
        QQC2.SpinBox {
            id: refreshSpin
            Kirigami.FormData.label: page._tr("Re-read the file every:")
            from: 30
            to: 3600
            stepSize: 30
            editable: true
            textFromValue: function(value) { return value + " s" }
            valueFromText: function(text) {
                var n = parseInt(String(text).replace(/[^0-9]/g, ""), 10)
                return isNaN(n) ? refreshSpin.value : n
            }
        }

        QQC2.Label {
            Kirigami.FormData.label: " "
            text: page._tr("The collector writes new numbers every 5 minutes, so a shorter\ninterval re-reads identical data.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        QQC2.CheckBox {
            id: refreshPopupCheck
            Kirigami.FormData.label: page._tr("On opening:")
            text: page._tr("Re-read when the popup opens")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Thresholds")
        }

        QQC2.SpinBox {
            id: warnSpin
            Kirigami.FormData.label: page._tr("Warning at:")
            from: 50
            to: 99
            editable: true
            textFromValue: function(value) { return value + " %" }
            valueFromText: function(text) {
                var n = parseInt(String(text).replace(/[^0-9]/g, ""), 10)
                return isNaN(n) ? warnSpin.value : n
            }
        }

        QQC2.SpinBox {
            id: critSpin
            Kirigami.FormData.label: page._tr("Critical at:")
            // Kept above the warning level, otherwise "warning" is a state the
            // widget can never reach. One-directional, so no binding loop.
            from: Math.min(100, warnSpin.value + 1)
            to: 100
            editable: true
            textFromValue: function(value) { return value + " %" }
            valueFromText: function(text) {
                var n = parseInt(String(text).replace(/[^0-9]/g, ""), 10)
                return isNaN(n) ? critSpin.value : n
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Data source")
        }

        QQC2.CheckBox {
            id: autoStartCheck
            Kirigami.FormData.label: page._tr("Collector:")
            text: page._tr("Start it when the popup opens, if it is installed but stopped")
        }

        QQC2.TextField {
            id: filePathField
            Kirigami.FormData.label: page._tr("Usage file:")
            placeholderText: "~/.local/state/kclaude/usage.json"
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: page._tr("Session window")
        }

        QQC2.CheckBox {
            id: primeCheck
            Kirigami.FormData.label: page._tr("On reset:")
            text: page._tr("Start the next 5-hour window immediately")
        }

        QQC2.Label {
            Kirigami.FormData.label: " "
            text: page._tr("Sends one \"hi\" through the collector when the window resets, so it\nbegins on the clock instead of when you next type something.\nCosts a sliver of the subscription usage it is watching. Never on a refresh.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        QQC2.Label {
            Kirigami.FormData.label: " "
            text: page._tr("Written by the collector: %1\nAnything that writes this format works; see the README.",
                       "systemctl --user status kclaude.service")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }
}
