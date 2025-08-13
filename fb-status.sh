#!/usr/bin/env bash
set -euo pipefail
cd /opt/formbricks
echo "== Docker ps =="
docker compose -f docker-compose.yml -f docker-compose.override.yml ps || true
echo "== Health local =="
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:3000/ || true
echo "== Nginx test =="
sudo nginx -t && echo "nginx ok"
echo "== Port 443 listen =="
sudo ss -ltnp | grep ':443 ' || echo "no 443"
echo "== Public check =="
. ./.env.install 2>/dev/null || true
curl -s -o /dev/null -w 'HTTP %{http_code} %{redirect_url}\n' "https://${FB_DOMAIN:-$(hostname -f)}/" || true
