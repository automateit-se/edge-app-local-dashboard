# Local dashboard (IoT Open edge app)

An IoT Open edge app that serves the [IoT Open Dashboard](https://github.com/automateit-se/iotopen-dashboard) locally from the installation's edge client, for example a Raspberry Pi 5 on the local network. Screens and tablets on the LAN show the dashboard without signing in to IoT Open, and values and control keep working **without internet**.

## How it works

- The dashboard is **designed in the cloud** as today, in the IoT Open Dashboard. This app shows the same layout, pages, colours, logo and background images.
- The app is installed and configured centrally with [App Management](https://github.com/automateit-se/appmanagement), like any other edge app. Each instance has its own settings, so two wall screens can show different pages.
- On the edge client the app:
  - serves the dashboard on its own port. The dashboard is one HTML file, `iotopen-dashboard-local.html` from an IoT Open Dashboard release, downloaded when the app starts and kept on disk,
  - answers the dashboard like a read-only IoT Open for this one installation (REST and MQTT over WebSocket), so the dashboard is the same code as in the cloud,
  - reads functions and devices from the edge client's own copies and live values from the edge client's broker,
  - reads the layout file, logo and background images (installation files named `dashboard-*`), the installation's metadata and history from IoT Open over REST, and keeps a copy on disk,
  - learns from MQTT when something changed (`evt/file/updated`, `evt/installation/updated`) and only then reads it again: nothing is polled,
  - keeps its own history of the functions' values (default 48 hours), used for graphs when IoT Open cannot be reached.
- Locally there is no IoT Open sign-in. Access is open, with a PIN for control, or with a password for everything, as set on the app.

### Reading from IoT Open: the edge client's credentials or an API key

The app first uses the edge client's own credentials. Those may read functions, devices and latest values, but today not installation files, installation metadata or the history log. Until they may, add an **API key** in the app's settings:

1. Create a user in IoT Open that may only **read** this installation (files, metadata and log), not your own account. An API key has the same rights as its user.
2. Create an API key for that user and paste it in *API-nyckel* on the app.

The key is used only by the app for its own requests to IoT Open; it is never sent to the browser or written to the log. It is stored in the app's configuration in IoT Open and on the edge client, so anyone who can see the app's settings can see it. That is why the user should be one that can only read this installation. When the edge client's own credentials are given read access, the key can be removed and the app keeps working.

Without either, the dashboard still works with the cached layout (if one was read earlier), live values and control, and the history the app keeps itself.

## Settings

| Setting | Default | |
|---|---|---|
| Port | 8090 | The app listens on all interfaces of the edge client: `http://<edge client>:8090` |
| Name in the browser | Dashboard | Shown in the header |
| Pages | *(all)* | Page names or ids, comma separated |
| Start page | *(first page)* | Page name or id |
| Widget types not shown | `tracker` | The map needs internet for its background |
| Kiosk mode | Off | No header, for a wall screen |
| Allowed networks | *(all)* | e.g. `192.168.1.0/24`, comma separated |
| Access | Open | Open / PIN for control / password for everything |
| PIN or password | | For the PIN and password modes |
| Allow control | On | Off = a display only |
| API key | *(none)* | See above |
| Local history (hours) | 48 | 1-168 hours, at most one value per function every ~45 s |
| Dashboard address | latest release | The HTML file downloaded at start, e.g. a pinned version: `https://github.com/automateit-se/iotopen-dashboard/releases/download/v0.11.0/iotopen-dashboard-local.html` |

With *PIN for control*, everyone on the network can see the dashboard; *Lås upp* in the header asks for the PIN, and control is then unlocked in that browser for 12 hours. With *password*, the password is asked for once per browser (kept for 30 days). Five wrong attempts lock out that address for five minutes. A session ends when the app restarts.

## Differences from the cloud dashboard

The same dashboard and widgets. Locally there is no sign-in to IoT Open and no list of installations, editing is hidden (edit in the cloud), and the footer shows whether IoT Open can be reached. Without internet, history is what the app has kept, and the map has no background.

## Requirements

- An IoT Open edge client: an IoT Open gateway, or the IoT Open Docker Edge Client. In Docker the app's port has to be published to reach it from the network.
- Internet the first time the app starts (to download the dashboard), not afterwards.
- IoT Open Dashboard 0.11.0 or later (the first release with `iotopen-dashboard-local.html`).

The app keeps its data in `/var/lib/iot-open/edge/local-dashboard/<instance id>/`: the dashboard file, the cached installation files and metadata, the latest values and the history.

## Security

Serve it on the local network only. The app speaks plain HTTP; a PIN or password travels unencrypted on the LAN, so do not reuse one used elsewhere, and never expose the port to the internet. Use *Allowed networks* to limit who can reach it. The app only reads from IoT Open; changes to the dashboard are made in the cloud.

## Development

`app.lua` is the whole app (IoT Open's limit is 64 kB), `app.json` its settings and `edge-app.json` its description in App Management. It runs in the edge client's Lua runtime (`iotopen-rt`, Lua 5.3 with lua-http and cqueues). The app was tested by running it in an IoT Open edge client image against the IoT Open Dashboard's mock server.

## License

MIT, see [LICENSE](LICENSE).
