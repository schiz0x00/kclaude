// Regression test for the config page coming up blank.
//
//   QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/tst_config.qml
//
// The Plasma config dialog pushes each page onto a Kirigami PageRow. PageRow's
// onItemInserted assigns to item.ColumnView.globalHeader.transform and its
// translation binding reads page.background -- a bare Kirigami.FormLayout root
// has neither, so the handler throws mid-insertion and the page renders empty.
// qmllint cannot see this; only pushing it onto a real PageRow can.
import QtQuick
import QtTest
import org.kde.kirigami as Kirigami

TestCase {
    id: testCase
    name: "ConfigGeneral"
    when: windowShown
    visible: true
    width: 800
    height: 600

    Kirigami.ApplicationItem {
        id: app
        anchors.fill: parent
    }

    function pushPage() {
        while (app.pageStack.depth > 0) {
            app.pageStack.pop()
        }
        var page = app.pageStack.push(Qt.resolvedUrl("../contents/ui/configGeneral.qml"), {})
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
        // The two members PageRow needs and a plain FormLayout lacks.
        verify(page.background !== undefined, "root is not a Kirigami Page: no background")
        verify(page.globalToolBarStyle !== undefined, "root is not a Kirigami Page")
    }

    function test_02_renders_controls() {
        var page = pushPage()
        verify(page.width > 0 && page.height > 0, "page has no geometry")
        verify(page.implicitHeight > 0, "page has zero implicitHeight -> blank panel")
        var n = countVisible(page, 0)
        verify(n > 20, "expected the form to be populated, only " + n + " visible items")
    }

    function test_03_refresh_interval_is_settable() {
        var page = pushPage()
        page.cfg_refreshInterval = 300
        compare(page.cfg_refreshInterval, 300)
        page.cfg_refreshInterval = 5
        verify(page.cfg_refreshInterval >= 30, "not clamped up, got " + page.cfg_refreshInterval)
        page.cfg_refreshInterval = 99999
        verify(page.cfg_refreshInterval <= 3600, "not capped, got " + page.cfg_refreshInterval)
    }

    function test_04_critical_stays_above_warning() {
        var page = pushPage()
        page.cfg_warningThreshold = 95
        verify(page.cfg_criticalThreshold > 95,
               "critical (" + page.cfg_criticalThreshold + ") must stay above warning 95")
    }

    function test_05_every_setting_is_exposed() {
        var page = pushPage()
        var keys = ["cfg_compactMode", "cfg_refreshInterval", "cfg_warningThreshold",
                    "cfg_criticalThreshold", "cfg_filePath", "cfg_refreshOnPopup",
                    "cfg_showTooltip", "cfg_showResetCountdown",
                    "cfg_autoStartCollector"]
        for (var i = 0; i < keys.length; i++) {
            // Plasma reads and writes these by name; a typo silently drops the setting.
            verify(page[keys[i]] !== undefined, keys[i] + " is not exposed on the page")
        }
    }
}
