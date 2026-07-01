# فزعة · Fz3a — On-Demand Towing Marketplace (Kuwait)

Uber-style tow-truck / flatbed / roadside-assistance marketplace for Kuwait.
Arabic-first (RTL) bilingual UI, live map, real auth + backend.

**Live:** https://tryfz3a.com · **Android APK:** https://tryfz3a.com/app.apk
**Driver portal:** https://tryfz3a.com/driver · **Admin panel:** https://tryfz3a.com/admin

---

## Stack
| Part | Tech |
|------|------|
| Rider app (web + Android) | Flutter (`lib/main.dart`) |
| Maps / routing | `flutter_map` + OpenStreetMap, Photon (search), OSRM (routing) — no API key |
| Backend API | **Zero-dependency Node.js** (`server/server.js`) — built-in `http` + `crypto` |
| Auth | scrypt password hashing + HMAC-signed tokens |
| Database | JSON datastore (`server/data/db.json`) — swappable for SQLite/Postgres |
| Driver portal | Static HTML/JS (`web_pages/driver/`) |
| Admin panel | Static HTML/JS (`web_pages/admin/`) |

## Roles & auth
- **Riders** sign up / log in inside the app, then book a service.
- **Drivers** sign up at `/driver`, go online, accept jobs, update status.
- **Admin** logs in at `/admin` with **`Admin` / `Admin`** and is **forced to set a new password** on first login. Sees stats, users, drivers, and rides.

## API (all under `/api`)
```
POST /auth/signup            {name, username, password, phone, role}
POST /auth/login             {username, password}
GET  /auth/me
POST /auth/change-password   {oldPassword?, newPassword}
POST /rides                  {service, distanceKm, pickup, dropoff}   (rider)
GET  /rides/mine             (rider)
GET  /rides/available        (driver)  GET /rides/active  (driver)
POST /rides/:id/accept       (driver)  POST /rides/:id/status {status}
POST /driver/online          {online}  (driver)
GET  /admin/stats | /admin/users | /admin/rides   (admin)
```

Pricing mirrors the app: base 5.000 KWD (≤5 km), +1.000 KWD/km, capped 15.000 KWD, 15% platform commission.

## Run the backend locally
```bash
cd server
node server.js          # listens on :3001, seeds Admin/Admin
curl localhost:3001/api/health
```

## Deploy
One command from a machine with SSH access to the server:
```bash
./deploy/deploy.sh
```
It builds the web app, uploads the Flutter build + driver/admin pages + APK,
installs the backend as a **systemd service** (`deploy/fz3a-api.service`), and
restarts it. Then wire `/api` → `127.0.0.1:3001` in LiteSpeed — see
[`deploy/litespeed-proxy.md`](deploy/litespeed-proxy.md).

## Repo layout
```
lib/main.dart          Flutter rider app (auth + booking + map + tracking)
server/                Node backend (API, auth, JSON DB)
web_pages/driver/      Driver portal (static)
web_pages/admin/       Admin panel (static)
deploy/                deploy.sh, systemd unit, LiteSpeed proxy guide
web_pages, assets/     logo + mascot art
```
