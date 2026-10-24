# Local dashboard (IoT Open edge app)

An IoT Open edge app that serves the [IoT Open Dashboard](https://github.com/automateit-se/iotopen-dashboard) locally from the installation's edge client, for example a Raspberry Pi 5 on the local network. Screens and tablets on the LAN show the dashboard without signing in to IoT Open, and values and control keep working **without internet**.

> **Status: in development.** This README describes the design; the app is not usable yet.

## How it works

- The dashboard is **designed in the cloud** as today, in the IoT Open Dashboard. When it is saved there, the dashboard writes the layout, settings and a small logo into the configuration of this app's instances on the installation. The edge client receives `evt/edge_app/updated` and restarts the app with the new layout: no polling.
- The app is installed and configured centrally with [App Management](https://github.com/automateit-se/appmanagement), like any other edge app.
- On the edge client the app:
  - serves the dashboard (one HTML file, downloaded from the IoT Open Dashboard release it is pinned to) and a small local API on its own port,
  - reads functions, devices and their latest values from the edge client, with the gateway's own credentials,
  - relays MQTT between the browser and the edge client's local broker (WebSocket), only for the topics the layout uses, and `set/…` only when control is allowed,
  - keeps history locally: raw values for a few days and hourly and daily sums for a year, for the functions shown.
- Locally there is no IoT Open sign-in. Access is open for viewing, with a PIN for control, or with a password, as set on the app.

What the gateway's own credentials may read was tested in a real edge client: functions, devices and latest values yes; installation files, installation metadata and the history log (v3beta) no. That is why the layout comes through the app's configuration and the history is kept locally. An app configuration holds at most about 48 kB of JSON, which is enough for a layout with hundreds of widgets.

## Settings (planned)

| Setting | Default | |
|---|---|---|
| Port | 8090 | The app listens on all interfaces of the edge client |
| Allowed networks | *(all)* | e.g. `192.168.1.0/24` |
| Access | Open for viewing | Open (view) / PIN for control / password for everything |
| PIN / password | | A local PIN, stored in the app's configuration in IoT Open |
| Allow control | Yes | No = a display only |
| Pages | *(all)* | Page names, comma separated |
| Exclude widget types | Map (Tracker) | The map needs internet for its background and its position history is large |
| Start page | First page | |
| Local history | 48 h raw, 400 days of sums | As disk space, e.g. at most 50 MB |
| Map tiles | OpenStreetMap | Or a local tile server |
| Kiosk mode | Off | No header, fixed theme, automatic reload |
| IoT Open API key | *(none)* | Optional, a read-only user: full history from IoT Open when online |

Each instance on an installation has its own selection, so two wall screens can show different pages.

## Differences from the cloud dashboard

The same dashboard and widgets. Locally there is no sign-in and no list of installations, the edit mode is hidden (edit in the cloud), and a status line shows the connection to IoT Open. Without internet, history is limited to what the app has kept, ranges without data are greyed out, and the map has no background.

## Requirements

- An IoT Open edge client: an IoT Open gateway, or the IoT Open Docker Edge Client, e.g. set up by App Management. In Docker the app's port has to be published and a volume kept for its data.
- Internet when the app is installed or updated (to download the dashboard), not afterwards.

## Security

Serve it on the local network only. The app speaks plain HTTP; a PIN or password travels unencrypted on the LAN, so do not reuse one used elsewhere, and never expose the port to the internet.

## License

MIT, see [LICENSE](LICENSE).
