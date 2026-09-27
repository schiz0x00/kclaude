import QtQuick 2.15
import org.kde.plasma.configuration 2.0

ConfigModel {
    ConfigCategory {
        name: "General"
        icon: "configure"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        // Its own page because its own file: see docs/architecture.md for why the
        // account list is not in main.xml.
        name: "Accounts"
        icon: "view-list-symbolic"
        source: "configAccounts.qml"
    }
}
