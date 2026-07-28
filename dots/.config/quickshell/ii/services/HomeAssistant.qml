pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import qs.modules.common

/**
 * Home Assistant client for the office overlay widget.
 *
 * Connection details (baseUrl + long-lived token) are read from an UNTRACKED
 * file so the secret never lands in the git-tracked fork:
 *
 *   ~/.config/illogical-impulse/homeassistant.json
 *   {
 *     "baseUrl": "https://ha.tegreeny.net",
 *     "token":   "<long-lived access token>",
 *     "entities": { ... optional overrides of the office entity map ... }
 *   }
 *
 * The token is passed to curl through the process environment (HA_TOKEN) so it
 * doesn't show up in the process argument list. States are polled with a single
 * /api/states call filtered by jq; actions POST to /api/services/<domain>/<svc>.
 */
Singleton {
    id: root

    readonly property string configPath: `${Quickshell.env("HOME")}/.config/illogical-impulse/homeassistant.json`

    // ---- Connection (from the untracked config file) ----
    property string baseUrl: ""
    property string token: ""
    readonly property bool configured: root.baseUrl.length > 0 && root.token.length > 0

    // ---- Office entity map (defaults mirror the HA "Office" dashboard view) ----
    readonly property var defaultEntities: ({
        "climate": "climate.third_floor_a_c",
        "fan": "fan.office",
        "media": "media_player.office",
        "sceneIn": "scene.in_the_office",
        "sceneOut": "scene.out_of_the_office",
        "co2": "sensor.aranet4_2a0db_carbon_dioxide",
        "humidity": "sensor.aranet4_2a0db_humidity",
        "pressure": "sensor.aranet4_2a0db_pressure",
        "lights": [
            { "id": "light.office_ceiling", "name": "Ceiling" },
            { "id": "light.office_floor_lamp", "name": "Floor lamp" },
            { "id": "light.ikea_of_sweden_tradfri_bulb_e26_cws_opal_600lm", "name": "IKEA" },
            { "id": "light.philips_915005987401", "name": "Hue 1" },
            { "id": "light.philips_440400982841", "name": "Hue 2" },
            { "id": "light.philips_440400982841_2", "name": "Hue 3" }
        ]
    })
    property var entities: root.defaultEntities

    // ---- Live state: entity_id -> { state, attributes } ----
    property var states: ({})
    property bool reachable: false
    property double lastUpdate: 0
    property string lastError: ""

    // Polling is gated by `active` (the widget sets it true while on-screen)
    property bool active: false
    property int pollInterval: 4000
    property bool fetching: false

    // ---- Accessors (function reads register a dependency on `states`, so
    //      bindings that call them re-evaluate whenever a poll updates it) ----
    function stateOf(id: string): var {
        return root.states[id]?.state ?? null;
    }
    function attr(id: string, key: string): var {
        return root.states[id]?.attributes?.[key] ?? null;
    }
    function lightIds(): var {
        return (root.entities.lights ?? []).map(l => l.id);
    }
    function watchedIds(): var {
        const e = root.entities;
        const ids = [e.climate, e.fan, e.media, e.sceneIn, e.sceneOut, e.co2, e.humidity, e.pressure].filter(x => !!x);
        return ids.concat(root.lightIds());
    }

    // =====================================================================
    // Config file
    // =====================================================================
    function applyConfig(txt: string): void {
        try {
            const cfg = JSON.parse(txt);
            root.baseUrl = String(cfg.baseUrl ?? "").replace(/\/+$/, "");
            root.token = String(cfg.token ?? "");
            root.entities = cfg.entities ? Object.assign({}, root.defaultEntities, cfg.entities) : root.defaultEntities;
            root.lastError = root.configured ? "" : "no token set";
            if (root.configured)
                root.refresh();
        } catch (e) {
            root.lastError = "config parse error: " + e.message;
            console.error(`[HomeAssistant] ${root.lastError}`);
        }
    }

    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.applyConfig(configFile.text())
        onLoadFailed: (error) => {
            root.baseUrl = "";
            root.token = "";
            root.reachable = false;
            root.lastError = (error === FileViewError.FileNotFound) ? "config file not found" : ("config load error: " + error);
        }
    }

    // =====================================================================
    // State polling
    // =====================================================================
    readonly property string fetchScript: root.configured
        ? `curl -sf -m 8 -H "Authorization: Bearer $HA_TOKEN" "${root.baseUrl}/api/states" ` +
          `| jq -c --argjson ids '${JSON.stringify(root.watchedIds())}' ` +
          `'[.[] | select(.entity_id | IN($ids[]))] | map({(.entity_id): {state: .state, attributes: .attributes}}) | add // {}'`
        : "true"

    function refresh(): void {
        if (!root.configured || root.fetching)
            return;
        root.fetching = true;
        fetchProc.running = true;
    }

    Timer {
        interval: root.pollInterval
        running: root.active && root.configured
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Process {
        id: fetchProc
        environment: ({ "HA_TOKEN": root.token })
        command: ["bash", "-c", root.fetchScript]
        onExited: root.fetching = false
        stdout: StdioCollector {
            onStreamFinished: {
                root.fetching = false;
                const t = text.trim();
                if (t.length === 0) {
                    root.reachable = false;
                    return;
                }
                try {
                    root.states = JSON.parse(t) ?? {};
                    root.reachable = true;
                    root.lastUpdate = Date.now();
                    root.lastError = "";
                } catch (e) {
                    root.reachable = false;
                    root.lastError = "state parse error";
                }
            }
        }
    }

    // =====================================================================
    // Service calls (queued so rapid taps don't clobber each other)
    // =====================================================================
    property var cmdQueue: []
    property bool cmdRunning: false

    function callService(domain: string, service: string, data: var): void {
        if (!root.configured)
            return;
        const payload = JSON.stringify(data ?? {});
        const script = `curl -s -m 8 -X POST -H "Authorization: Bearer $HA_TOKEN" ` +
            `-H "Content-Type: application/json" -d '${payload}' ` +
            `"${root.baseUrl}/api/services/${domain}/${service}" >/dev/null`;
        root.cmdQueue = root.cmdQueue.concat([script]);
        root.drainQueue();
    }

    function drainQueue(): void {
        if (root.cmdRunning || root.cmdQueue.length === 0)
            return;
        const script = root.cmdQueue[0];
        root.cmdQueue = root.cmdQueue.slice(1);
        root.cmdRunning = true;
        cmdProc.command = ["bash", "-c", script];
        cmdProc.running = true;
    }

    Process {
        id: cmdProc
        environment: ({ "HA_TOKEN": root.token })
        onExited: {
            root.cmdRunning = false;
            root.drainQueue();
            refreshSoon.restart(); // reflect the new state promptly
        }
    }

    Timer {
        id: refreshSoon
        interval: 400
        onTriggered: root.refresh()
    }

    // ---- Optimistic local update so the UI reacts instantly ----
    function setLocalState(id: string, newState: string, patchAttrs: var): void {
        var s = Object.assign({}, root.states);
        const cur = s[id] ?? { "state": newState, "attributes": {} };
        s[id] = {
            "state": newState,
            "attributes": Object.assign({}, cur.attributes, patchAttrs ?? {})
        };
        root.states = s;
    }

    // =====================================================================
    // High-level office helpers
    // =====================================================================
    function setLight(id: string, on: bool): void {
        root.setLocalState(id, on ? "on" : "off", {});
        root.callService("light", on ? "turn_on" : "turn_off", { "entity_id": id });
    }
    function toggleLight(id: string): void {
        root.setLight(id, root.stateOf(id) !== "on");
    }

    function activateScene(id: string): void {
        root.callService("scene", "turn_on", { "entity_id": id });
    }

    function setClimateTemp(temp: real): void {
        root.setLocalState(root.entities.climate, root.stateOf(root.entities.climate) ?? "cool", { "temperature": temp });
        root.callService("climate", "set_temperature", { "entity_id": root.entities.climate, "temperature": temp });
    }
    function setClimateMode(mode: string): void {
        root.setLocalState(root.entities.climate, mode, {});
        root.callService("climate", "set_hvac_mode", { "entity_id": root.entities.climate, "hvac_mode": mode });
    }

    function setFan(on: bool): void {
        root.setLocalState(root.entities.fan, on ? "on" : "off", {});
        root.callService("fan", on ? "turn_on" : "turn_off", { "entity_id": root.entities.fan });
    }
    function setFanPercentage(pct: int): void {
        root.setLocalState(root.entities.fan, pct > 0 ? "on" : "off", { "percentage": pct });
        root.callService("fan", "set_percentage", { "entity_id": root.entities.fan, "percentage": pct });
    }

    function mediaCommand(service: string): void {
        root.callService("media_player", service, { "entity_id": root.entities.media });
    }

    Component.onCompleted: {
        // Defensive: a Quickshell restart may find us mid-toggle
        root.active = false;
    }
}
