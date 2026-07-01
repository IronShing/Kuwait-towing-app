#!/usr/bin/env bash
# One-shot deploy for Fz3a to the tryfz3a.com server.
# Run from the repo root on a machine with SSH access to root@njabi.net.
set -euo pipefail

SERVER="${SERVER:-root@njabi.net}"
DOCROOT="/home/tryfz3a.com/public_html"
APPDIR="/home/tryfz3a.com/app"
OWNER="tryfz9546"

echo "==> Building Flutter web"
flutter build web --release --pwa-strategy=none

echo "==> Uploading web app (Flutter build) -> $DOCROOT"
rsync -az --delete \
  --exclude 'app.apk' --exclude '.htaccess' \
  --exclude 'driver/' --exclude 'admin/' \
  -e ssh build/web/ "$SERVER:$DOCROOT/"

echo "==> Uploading driver & admin pages"
rsync -az -e ssh web_pages/driver/  "$SERVER:$DOCROOT/driver/"
rsync -az -e ssh web_pages/admin/   "$SERVER:$DOCROOT/admin/"

echo "==> Uploading APK"
if [ -f build/app/outputs/flutter-apk/app-release.apk ]; then
  scp build/app/outputs/flutter-apk/app-release.apk "$SERVER:$DOCROOT/app.apk"
fi

echo "==> Uploading backend -> $APPDIR"
ssh "$SERVER" "mkdir -p $APPDIR/data"
rsync -az -e ssh --exclude 'data/' server/ "$SERVER:$APPDIR/"
scp deploy/fz3a-api.service "$SERVER:/etc/systemd/system/fz3a-api.service"

echo "==> Installing systemd service + ensuring Node"
ssh "$SERVER" bash -s <<'REMOTE'
set -e
if ! command -v node >/dev/null 2>&1; then
  echo "Node not found — installing Node 20 via NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
systemctl daemon-reload
systemctl enable fz3a-api
systemctl restart fz3a-api
sleep 1
curl -s localhost:3001/api/health && echo " <- API healthy"
REMOTE

echo "==> Fixing ownership/permissions"
ssh "$SERVER" "
  chown -R $OWNER:$OWNER $DOCROOT
  find $DOCROOT -type d -exec chmod 755 {} \;
  find $DOCROOT -type f -exec chmod 644 {} \;
"

echo "==> Purging Cloudflare cache"
if [ -f deploy/.cf_token ]; then
  CF=$(cat deploy/.cf_token)
  ZONE=$(curl -s -H "Authorization: Bearer $CF" \
    "https://api.cloudflare.com/client/v4/zones?name=tryfz3a.com" \
    | grep -o '"id":"[a-f0-9]*"' | head -1 | cut -d'"' -f4)
  curl -s -X POST -H "Authorization: Bearer $CF" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/purge_cache" \
    --data '{"purge_everything":true}' >/dev/null && echo "cache purged"
else
  echo "deploy/.cf_token not found — purge Cloudflare manually."
fi

echo "==> Done. LiteSpeed /api proxy is already configured (see deploy/litespeed-proxy.md)."
