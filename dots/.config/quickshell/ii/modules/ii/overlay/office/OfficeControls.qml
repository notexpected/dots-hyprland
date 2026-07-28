pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.overlay

/*
 * Office controls for the Super+G overlay. Mirrors the HA "Office" dashboard
 * view: environment readout, third-floor A/C, office fan, office lights, the
 * in/out-of-office scenes, and a compact media strip for media_player.office.
 * All data flows through the HomeAssistant service singleton.
 */
StyledOverlayWidget {
    id: root
    title: Translation.tr("Office")
    showCenterButton: true
    minimumWidth: 340
    minimumHeight: 300

    readonly property var ent: HomeAssistant.entities

    // Only poll HA while the panel is actually on-screen.
    property bool onScreen: GlobalStates.overlayOpen || root.actuallyPinned
    onOnScreenChanged: HomeAssistant.active = root.onScreen
    Component.onCompleted: HomeAssistant.active = root.onScreen

    function num(v, digits = 0): string {
        const n = Number(v);
        return isNaN(n) ? "--" : n.toFixed(digits);
    }

    function stepTemp(delta: int): void {
        const cur = Number(HomeAssistant.attr(root.ent.climate, "temperature") ?? 72);
        const step = Number(HomeAssistant.attr(root.ent.climate, "target_temp_step") ?? 1);
        const lo = Number(HomeAssistant.attr(root.ent.climate, "min_temp") ?? 45);
        const hi = Number(HomeAssistant.attr(root.ent.climate, "max_temp") ?? 95);
        const v = Math.min(hi, Math.max(lo, cur + delta * step));
        HomeAssistant.setClimateTemp(v);
    }
    function cycleMode(): void {
        const modes = HomeAssistant.attr(root.ent.climate, "hvac_modes") ?? ["off", "cool"];
        const cur = HomeAssistant.stateOf(root.ent.climate) ?? "off";
        const i = modes.indexOf(cur);
        HomeAssistant.setClimateMode(modes[(i + 1) % modes.length]);
    }

    contentItem: OverlayBackground {
        id: bg
        radius: root.contentRadius
        property real pad: 12
        implicitWidth: 360
        implicitHeight: mainCol.implicitHeight + bg.pad * 2

        ColumnLayout {
            id: mainCol
            anchors {
                fill: parent
                margins: bg.pad
            }
            spacing: 12

            // ---------------- Not-configured notice ----------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8
                spacing: 6
                visible: !HomeAssistant.configured

                MaterialSymbol {
                    Layout.alignment: Qt.AlignHCenter
                    text: "home"
                    iconSize: 42
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Translation.tr("Connect Home Assistant")
                    font.pixelSize: Appearance.font.pixelSize.large
                }
                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: Translation.tr("Add your HA URL and a long-lived token to:")
                }
                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAnywhere
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnSecondaryContainer
                    text: HomeAssistant.configPath
                }
                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: HomeAssistant.lastError.length > 0
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    text: HomeAssistant.lastError
                }
            }

            // ---------------- Environment strip ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: HomeAssistant.configured

                StatChip {
                    icon: "ac_unit"
                    value: root.num(HomeAssistant.attr(root.ent.climate, "current_temperature")) + "°"
                    label: Translation.tr("A/C now")
                }
                StatChip {
                    icon: "co2"
                    value: root.num(HomeAssistant.stateOf(root.ent.co2))
                    unit: "ppm"
                    label: Translation.tr("CO₂")
                }
                StatChip {
                    icon: "humidity_percentage"
                    value: root.num(HomeAssistant.stateOf(root.ent.humidity)) + "%"
                    label: Translation.tr("Humidity")
                }
            }

            // ---------------- Climate ----------------
            SectionLabel {
                text: Translation.tr("Climate")
                visible: HomeAssistant.configured
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: HomeAssistant.configured

                RippleButtonWithIcon {
                    materialIcon: {
                        const s = HomeAssistant.stateOf(root.ent.climate);
                        return s === "cool" ? "ac_unit" : s === "heat" ? "local_fire_department" : s === "off" ? "power_settings_new" : "mode_fan";
                    }
                    mainText: {
                        const s = HomeAssistant.stateOf(root.ent.climate) ?? "off";
                        return s.charAt(0).toUpperCase() + s.slice(1).replace(/_/g, " ");
                    }
                    onClicked: root.cycleMode()
                    StyledToolTip {
                        text: Translation.tr("Cycle A/C mode")
                    }
                }

                Item { Layout.fillWidth: true }

                RoundIconButton {
                    symbol: "remove"
                    onClicked: root.stepTemp(-1)
                }
                StyledText {
                    Layout.minimumWidth: 52
                    horizontalAlignment: Text.AlignHCenter
                    text: root.num(HomeAssistant.attr(root.ent.climate, "temperature")) + "°"
                    font.pixelSize: Appearance.font.pixelSize.huge
                    font.family: Appearance.font.family.numbers
                }
                RoundIconButton {
                    symbol: "add"
                    onClicked: root.stepTemp(1)
                }
            }

            // ---------------- Fan ----------------
            SectionLabel {
                text: Translation.tr("Fan")
                visible: HomeAssistant.configured
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: HomeAssistant.configured

                readonly property bool fanOn: HomeAssistant.stateOf(root.ent.fan) === "on"

                RoundIconButton {
                    symbol: "mode_fan"
                    toggled: parent.fanOn
                    onClicked: HomeAssistant.setFan(!parent.fanOn)
                }
                StyledSlider {
                    id: fanSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    stepSize: 1
                    enabled: HomeAssistant.stateOf(root.ent.fan) === "on"
                    Component.onCompleted: value = Number(HomeAssistant.attr(root.ent.fan, "percentage") ?? 0)
                    onMoved: fanDebounce.restart()
                    Connections {
                        target: HomeAssistant
                        function onStatesChanged() {
                            if (!fanSlider.pressed)
                                fanSlider.value = Number(HomeAssistant.attr(root.ent.fan, "percentage") ?? 0);
                        }
                    }
                    Timer {
                        id: fanDebounce
                        interval: 250
                        onTriggered: HomeAssistant.setFanPercentage(Math.round(fanSlider.value))
                    }
                }
                StyledText {
                    Layout.minimumWidth: 34
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(fanSlider.value) + "%"
                    color: Appearance.colors.colSubtext
                    font.family: Appearance.font.family.numbers
                }
            }

            // ---------------- Lights ----------------
            SectionLabel {
                text: Translation.tr("Lights")
                visible: HomeAssistant.configured
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: HomeAssistant.configured

                Repeater {
                    model: root.ent.lights ?? []
                    delegate: LightChip {}
                }
            }

            // ---------------- Scenes ----------------
            SectionLabel {
                text: Translation.tr("Scenes")
                visible: HomeAssistant.configured
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: HomeAssistant.configured

                RippleButtonWithIcon {
                    Layout.fillWidth: true
                    materialIcon: "meeting_room"
                    mainText: Translation.tr("In the Office")
                    onClicked: HomeAssistant.activateScene(root.ent.sceneIn)
                }
                RippleButtonWithIcon {
                    Layout.fillWidth: true
                    materialIcon: "door_front"
                    mainText: Translation.tr("Out of Office")
                    onClicked: HomeAssistant.activateScene(root.ent.sceneOut)
                }
            }

            // ---------------- Media ----------------
            SectionLabel {
                text: Translation.tr("Media")
                visible: HomeAssistant.configured
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: HomeAssistant.configured

                readonly property string mediaState: HomeAssistant.stateOf(root.ent.media) ?? "off"

                MaterialSymbol {
                    text: "music_note"
                    iconSize: 20
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        const title = HomeAssistant.attr(root.ent.media, "media_title");
                        if (title)
                            return title;
                        return parent.mediaState === "off" || parent.mediaState === "unavailable"
                            ? Translation.tr("Off") : Translation.tr("Nothing playing");
                    }
                }
                RoundIconButton {
                    symbol: "skip_previous"
                    onClicked: HomeAssistant.mediaCommand("media_previous_track")
                }
                RoundIconButton {
                    symbol: parent.mediaState === "playing" ? "pause" : "play_arrow"
                    onClicked: HomeAssistant.mediaCommand("media_play_pause")
                }
                RoundIconButton {
                    symbol: "skip_next"
                    onClicked: HomeAssistant.mediaCommand("media_next_track")
                }
            }

            // ---------------- Status footer ----------------
            StyledText {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: HomeAssistant.configured && !HomeAssistant.reachable
                horizontalAlignment: Text.AlignHCenter
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                text: HomeAssistant.lastError.length > 0
                    ? Translation.tr("Home Assistant unreachable — %1").arg(HomeAssistant.lastError)
                    : Translation.tr("Connecting to Home Assistant…")
            }

            Item { Layout.fillHeight: true }
        }
    }

    // =====================================================================
    // Inline components
    // =====================================================================
    component SectionLabel: StyledText {
        Layout.fillWidth: true
        color: Appearance.colors.colSubtext
        font.pixelSize: Appearance.font.pixelSize.smaller
    }

    component StatChip: Rectangle {
        id: chip
        property string icon: ""
        property string value: "--"
        property string unit: ""
        property string label: ""
        Layout.fillWidth: true
        implicitHeight: chipCol.implicitHeight + 14
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer2

        ColumnLayout {
            id: chipCol
            anchors.centerIn: parent
            spacing: 1

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 3
                MaterialSymbol {
                    text: chip.icon
                    iconSize: 15
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: chip.value
                    font.pixelSize: Appearance.font.pixelSize.normal
                    font.family: Appearance.font.family.numbers
                }
                StyledText {
                    visible: chip.unit.length > 0
                    text: chip.unit
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                }
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: chip.label
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    component RoundIconButton: RippleButton {
        id: rib
        property string symbol: ""
        implicitWidth: 34
        implicitHeight: 34
        padding: 0
        buttonRadius: height / 2
        colBackground: Appearance.colors.colLayer2
        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            text: rib.symbol
            iconSize: 20
            fill: rib.toggled ? 1 : 0
            color: rib.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSurface
        }
    }

    component LightChip: RippleButton {
        id: lc
        required property var modelData
        readonly property bool isOn: HomeAssistant.stateOf(modelData.id) === "on"
        toggled: lc.isOn
        implicitHeight: 36
        padding: 0
        horizontalPadding: 12
        buttonRadius: Appearance.rounding.small
        colBackground: Appearance.colors.colLayer2
        onClicked: HomeAssistant.setLight(lc.modelData.id, !lc.isOn)
        contentItem: RowLayout {
            spacing: 6
            MaterialSymbol {
                text: "lightbulb"
                iconSize: 18
                fill: lc.isOn ? 1 : 0
                color: lc.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSurface
            }
            StyledText {
                text: lc.modelData.name
                color: lc.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSurface
            }
        }
    }
}
