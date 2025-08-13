#!/usr/bin/env bash
# Uso: sudo bash fb-uninstall.sh [--full]
set -euo pipefail
if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
cd /opt/formbricks || exit 0
# Apaga
docker compose -f docker-compose.yml -f docker-compose.override.yml down ${FULL:+-v} || true
# Quita vhost
. ./.env.install 2>/dev/null || true
SITE="/etc/nginx/sites-available/formbricks-${FB_DOMAIN:-fb.local}.conf"
LINK="/etc/nginx/sites-enabled/formbricks-${FB_DOMAIN:-fb.local}.conf"
rm -f "$LINK" "$SITE" || true
sudo nginx -t && sudo systemctl reload nginx || true
echo "Desinstalado."
