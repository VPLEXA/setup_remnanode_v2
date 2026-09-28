#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Нет .env — выполните: ./scripts/bootstrap.sh"
  exit 1
fi

DOMAIN=$(grep -m1 -E '^DOMAIN=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
EMAIL=$(grep -m1 -E '^EMAIL=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')

if [[ -z "${DOMAIN}" || -z "${EMAIL}" ]]; then
  echo "В .env задайте DOMAIN и EMAIL."
  exit 1
fi

mkdir -p certbot/www "letsencrypt/live/${DOMAIN}"

echo "Запуск nginx для HTTP-01 на порту 80..."
docker compose --profile acme up -d nginx-acme

echo "Запрос сертификата Let's Encrypt..."
docker compose --profile cert run --rm certbot certonly \
  --webroot -w /var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  -d "$DOMAIN"

# certbot создаёт letsencrypt/archive/ с правами 700 root:root — без traverse-бита
# для admin'а (от которого выполняется этот скрипт) любой -f/-e через симлинк
# live/ -> archive/ молча падает в false (EACCES), и симлинк ниже не создаётся.
SUDO=""
sudo -n true &>/dev/null && SUDO="sudo"
$SUDO chmod o+x letsencrypt/archive 2>/dev/null || true

LIVE="letsencrypt/live/${DOMAIN}"
if [[ -f "$LIVE/privkey.pem" && ! -e "$LIVE/privkey.key" ]]; then
  ( cd "$LIVE" && ln -sf privkey.pem privkey.key )
  echo "Создана ссылка privkey.key → privkey.pem (как в документации Xray SSL)."
fi

echo "Освободить :80: docker compose --profile acme stop"
echo "Запуск ноды: ./scripts/up.sh"
