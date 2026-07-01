# Wiring `/api` → Node backend on LiteSpeed / CyberPanel

The Flutter app, driver page, and admin page all call `/api/...` on the same
origin. LiteSpeed serves the static files from `public_html`; we need it to
**reverse-proxy `/api` to the Node service** on `127.0.0.1:3001`.

## Option A — CyberPanel UI (easiest)
1. CyberPanel → **Websites → List Websites → tryfz3a.com → Manage → Rewrite Rules**.
2. Add:
   ```
   RewriteEngine On
   RewriteRule ^api/(.*)$ http://127.0.0.1:3001/api/$1 [P,L]
   ```
3. Save. (Requires the LiteSpeed proxy module, enabled by default.)

## Option B — External App + Context (most reliable on LiteSpeed)
Edit `/usr/local/lsws/conf/vhosts/tryfz3a.com/vhost.conf` and add:

```
extprocessor fz3aapi {
  type                    proxy
  address                 127.0.0.1:3001
  maxConns                100
  initTimeout             20
  retryTimeout            0
  respBuffer              0
}

context /api {
  type                    proxy
  handler                 fz3aapi
  addDefaultCharset       off
}
```

Then:
```
/usr/local/lsws/bin/lswsctrl restart
```

## Verify
```
curl -s https://tryfz3a.com/api/health
# -> {"ok":true,...}
```

## Cloudflare
`/api` responses are `Cache-Control: no-store`, so Cloudflare won't cache them.
If the static app still shows an old build, purge the Cloudflare cache or set the
DNS records to **grey cloud** (DNS-only) during active development.
