import QtQuick
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import Quickshell
import Quickshell.Io

QuickToggleModel {
    id: root
    name: Translation.tr("VPN")

    toggled: false
    icon: "vpn_lock"
    statusText: toggled ? Translation.tr("Connected") : Translation.tr("Disconnected")
    tooltipText: Translation.tr("Home VPN")

    mainAction: () => {
        if (toggled) {
            root.toggled = false
            Quickshell.execDetached(["nmcli", "connection", "down", "Home"])
        } else {
            root.toggled = true
            Quickshell.execDetached(["nmcli", "connection", "up", "Home"])
        }
    }

    Process {
        id: fetchActiveState
        running: true
        command: ["bash", "-c", "nmcli -t -f NAME connection show --active"]
        stdout: StdioCollector {
            id: statusCollector
            onStreamFinished: {
                root.toggled = statusCollector.text.includes("Home")
            }
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: {
            fetchActiveState.running = true
        }
    }
}
