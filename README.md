# Bus system v2: phone app + ESP32/RC522 unit

```
 student card -> [RC522]--SPI--[ESP32] --BLE--> [Driver phone app] --HTTPS--> [Server API]
                                                  GPS, queue, status,         (Next.js/Firebase,
                                                  student names, sync          portals, parents)
```

## What lives where
| Part | Does |
|---|---|
| ESP32 + RC522 | Reads card UID, sends it over BLE, re-sends until the phone acknowledges. Nothing else. |
| Phone app | GPS (every N s), offline queue (SQLite), BOARDING/ALIGHTING status, on-board list, student names, upload to server. |
| Server | Validates device key, de-duplicates by `clientId`, maps card -> student, notifies parents, updates live map. |

## Build the app
Upload this folder to GitHub (keep `.github/workflows/build-apk.yml`), run
**Actions -> Build Bus Driver APK**, download `bus-driver-apk`.

## Flash the unit
Open `firmware/bus_rfid/bus_rfid.ino` in Arduino IDE, install the "MFRC522"
library, board "ESP32 Dev Module", upload. Wiring is in the file header.

## First use
1. Install the app, open **Settings** (gear icon): *Search for RFID units*, select `BusRFID-XXXX`.
2. Enter server address, bus ID and API key, Save, *Download student list*.
3. Press **Start trip**. Choose BOARDING or ALIGHTING by tapping the half of the screen.
4. Press Home/Back to hide the app. Do not swipe it out of recent apps.
5. Huawei: Settings > Battery > App launch > Bus Driver > Manage manually (all 3 on).

## Server API the app expects
`POST {server}/api/device/events`  headers `x-device-id`, `x-device-key`
```json
{ "deviceId": "BUS-001", "sentAt": "...Z",
  "events": [
    {"clientId":"BUS-001-ABC:12","kind":"gps","time":"...Z","tripId":"BUS-001-ABC","lat":6.9,"lng":80.3,"accuracy":8,"speed":5.2,"heading":90},
    {"clientId":"BUS-001-ABC:13","kind":"scan","time":"...Z","tripId":"BUS-001-ABC","uid":"04A1B2C3","status":"BOARDING","outcome":"OK","name":"Nimal","lat":6.9,"lng":80.3},
    {"clientId":"...","kind":"status","tripId":"...","status":"ALIGHTING"},
    {"clientId":"...","kind":"trip","tripId":"...","action":"start|end"} ] }
```
Reply any 2xx = the phone deletes those events. De-duplicate by `clientId`.

`GET {server}/api/device/roster` -> `{"cards":[{"uid":"04A1B2C3","name":"Nimal"}]}`
