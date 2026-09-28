#!/usr/bin/env bash
#
# Интерактивная настройка протоколов Xray для Remnawave Node.
# Запуск: ./scripts/setup-protocols.sh  (нода должна быть уже запущена)
#
# Скрипт:
#  1. Спрашивает, какие протоколы нужны (и на каких портах).
#  2. Генерирует Reality-ключи и shortIds.
#  3. Открывает нужные порты в UFW.
#  4. Собирает готовый мультиконфиг Xray → xray-multiconfig.json.
#  5. Валидирует его реальным бинарником xray внутри контейнера remnanode.
#
# Полученный JSON нужно вставить в панели Remnawave (Config ноды).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
log_success() { echo -e "${GREEN}✓${NC}  $*"; }
log_error()   { echo -e "${RED}✗${NC}  $*" >&2; }
log_warning() { echo -e "${YELLOW}⚠${NC}  $*"; }

if [[ ! -f .env ]]; then
  log_error "Нет .env — сначала выполните ./setup-remnanode.sh"
  exit 1
fi

DOMAIN=$(grep -m1 -E '^DOMAIN=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
if [[ -z "$DOMAIN" ]]; then
  log_error "В .env не задан DOMAIN."
  exit 1
fi

SSL_CERT="/var/lib/remnawave/configs/xray/ssl/fullchain.pem"
SSL_KEY="/var/lib/remnawave/configs/xray/ssl/privkey.key"
CONFIG_OUT="$ROOT/xray-multiconfig.json"

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

ask_yn() { # ask_yn "вопрос" "default(y|n)" -> 0=yes 1=no
  local prompt="$1" def="${2:-y}" reply hint
  if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "$prompt ($hint) " reply || true
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[YyДд] ]]
}

ask_port() { # ask_port "название" default -> echo port
  local name="$1" def="$2" p
  read -r -p "  Порт для $name (по умолчанию $def): " p || true
  p="${p:-$def}"
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
    echo "$p"
  else
    log_warning "Некорректный порт, используется $def" >&2
    echo "$def"
  fi
}

gen_short_ids() { # 3 shortId по 8 байт hex
  printf '"%s","%s","%s"' \
    "$(openssl rand -hex 8)" "$(openssl rand -hex 8)" "$(openssl rand -hex 8)"
}

ufw_allow() { # ufw_allow 443 tcp "комментарий"
  local port="$1" proto="$2" comment="$3"
  if ! command -v ufw &>/dev/null; then return 0; fi
  local SUDO=""
  if sudo -n true &>/dev/null; then SUDO="sudo"; fi
  if $SUDO ufw status 2>/dev/null | grep -qE "^${port}/${proto}\s+ALLOW"; then
    log_success "UFW: ${port}/${proto} уже открыт"
  else
    if $SUDO ufw allow "${port}/${proto}" comment "$comment" &>/dev/null; then
      log_success "UFW: открыт ${port}/${proto} ($comment)"
    else
      log_warning "UFW: не удалось открыть ${port}/${proto} — откройте вручную"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Шаг 0. Обновление старой установки (безопасно запускать повторно)
# ---------------------------------------------------------------------------
# На нодах, поставленных старой версией setup-remnanode.sh:
#  - docker-compose.yml монтирует только letsencrypt/live/ без archive/ —
#    симлинки certbot внутри контейнера битые, Xray не видит сертификаты;
#  - иногда отсутствует симлинк privkey.key → privkey.pem.
# Здесь всё это чинится автоматически.

echo ""
log_info "=== Проверка установки ноды ==="

COMPOSE_CHANGED=0
if [[ -f docker-compose.yml ]]; then
  if ! grep -q 'letsencrypt/archive' docker-compose.yml; then
    log_info "Старый docker-compose.yml: добавляю mount letsencrypt/archive..."
    sed -i 's|^\( *\)- \./letsencrypt/live/.*:/var/lib/remnawave/configs/xray/ssl:ro *$|&\n\1# certbot кладёт в live/ симлинки на ../../archive/<домен>/ — без этого mount'"'"'а они битые\n\1- ./letsencrypt/archive/${DOMAIN}:/var/lib/remnawave/configs/archive/${DOMAIN}:ro|' docker-compose.yml
    if grep -q 'letsencrypt/archive' docker-compose.yml; then
      COMPOSE_CHANGED=1
      log_success "docker-compose.yml обновлён (mount letsencrypt/archive)"
    else
      log_warning "Не удалось пропатчить docker-compose.yml автоматически."
      log_warning "Добавьте вручную в volumes сервиса remnanode:"
      log_warning '  - ./letsencrypt/archive/${DOMAIN}:/var/lib/remnawave/configs/archive/${DOMAIN}:ro'
    fi
  else
    log_success "docker-compose.yml уже содержит mount letsencrypt/archive"
  fi
else
  log_warning "docker-compose.yml не найден в $ROOT — пропускаю проверку compose."
fi

# letsencrypt/archive/ иногда стоит 700 root:root (certbot) — без traverse-бита
# для admin'а -f/-e через live/ -> archive/ молча даёт false (EACCES), и симлинк
# ниже не создаётся даже при повторных прогонах на старых установках.
SUDO=""
sudo -n true &>/dev/null && SUDO="sudo"
$SUDO chmod o+x letsencrypt/archive 2>/dev/null || true

# Симлинк privkey.key → privkey.pem (как требует документация Xray SSL)
LIVE_DIR="letsencrypt/live/${DOMAIN}"
if [[ -f "$LIVE_DIR/privkey.pem" && ! -e "$LIVE_DIR/privkey.key" ]]; then
  ( cd "$LIVE_DIR" && ln -sf privkey.pem privkey.key )
  log_success "Создан симлинк privkey.key → privkey.pem"
fi

# Пересоздаём/запускаем контейнер, если compose менялся или нода не запущена
if (( COMPOSE_CHANGED )) || ! docker ps --format '{{.Names}}' | grep -qx remnanode; then
  log_info "Перезапускаю контейнер remnanode с новой конфигурацией..."
  docker compose up -d remnanode
  sleep 3
fi

# Проверяем, что сертификат действительно читается внутри контейнера
if docker ps --format '{{.Names}}' | grep -qx remnanode; then
  if docker exec remnanode sh -c "cat $SSL_CERT >/dev/null 2>&1 && cat $SSL_KEY >/dev/null 2>&1"; then
    log_success "Сертификаты читаются внутри контейнера"
  else
    log_warning "Сертификаты НЕ читаются внутри контейнера ($SSL_CERT)."
    log_warning "Проверьте: docker exec remnanode ls -la /var/lib/remnawave/configs/xray/ssl/"
    log_warning "Возможно, сертификат ещё не выпущен: ./scripts/issue-cert.sh"
  fi
else
  log_warning "Контейнер remnanode не запущен — проверить сертификаты не могу."
fi

# ---------------------------------------------------------------------------
# Шаг 1. Выбор протоколов
# ---------------------------------------------------------------------------

echo ""
log_info "=== Настройка протоколов Xray для ноды $DOMAIN ==="
echo ""
echo "Доступные протоколы:"
echo "  1) VLESS XHTTP + Reality   (443/tcp)"
echo "  2) Hysteria2               (реальный сертификат, 443/udp)"
echo "  3) VLESS TCP  + Reality    (4443/tcp)"
echo "  4) VLESS gRPC + Reality    (8443/tcp)"
echo "  5) Trojan WS  + TLS        (реальный сертификат, 2096/tcp)"
echo "  6) Bridge-inbound для каскада (VLESS TCP без TLS, 9999/tcp)"
echo ""

WANT_XHTTP=0; WANT_HY2=0; WANT_TCPR=0; WANT_GRPCR=0; WANT_TROJAN=0; WANT_BRIDGE=0

if [[ -n "${PROTOCOLS_SELECT:-}" ]]; then
  log_info "PROTOCOLS_SELECT=$PROTOCOLS_SELECT — выбор протоколов без вопросов"
  case "$PROTOCOLS_SELECT" in
    all)
      WANT_XHTTP=1; WANT_HY2=1; WANT_TCPR=1; WANT_GRPCR=1; WANT_TROJAN=1; WANT_BRIDGE=1
      ;;
    none)
      ;;
    *)
      IFS=',' read -ra _proto_codes <<< "$PROTOCOLS_SELECT"
      for _code in "${_proto_codes[@]}"; do
        case "$_code" in
          xhttp)  WANT_XHTTP=1 ;;
          hy2)    WANT_HY2=1 ;;
          tcpr)   WANT_TCPR=1 ;;
          grpcr)  WANT_GRPCR=1 ;;
          trojan) WANT_TROJAN=1 ;;
          bridge) WANT_BRIDGE=1 ;;
          "") ;;
          *) log_warning "Неизвестный код протокола в PROTOCOLS_SELECT: '$_code' — пропускаю" ;;
        esac
      done
      ;;
  esac
else
  ask_yn "1) Настроить VLESS XHTTP + Reality?"     y && WANT_XHTTP=1
  ask_yn "2) Настроить Hysteria2?"                y && WANT_HY2=1
  ask_yn "3) Настроить VLESS TCP + Reality?"      y && WANT_TCPR=1
  ask_yn "4) Настроить VLESS gRPC + Reality?"     y && WANT_GRPCR=1
  ask_yn "5) Настроить Trojan WS + TLS?"          y && WANT_TROJAN=1
  ask_yn "6) Настроить bridge-inbound (каскад)?"  y && WANT_BRIDGE=1
fi

if (( WANT_XHTTP + WANT_HY2 + WANT_TCPR + WANT_GRPCR + WANT_TROJAN + WANT_BRIDGE == 0 )); then
  log_warning "Ничего не выбрано — выходим."
  exit 0
fi

echo ""
PORT_XHTTP=443; PORT_HY2=443; PORT_TCPR=4443; PORT_GRPCR=8443; PORT_TROJAN=2096; PORT_BRIDGE=9999
if [[ -z "${PROTOCOLS_SELECT:-}" ]]; then
  log_info "Порты (Enter — оставить по умолчанию):"
  (( WANT_XHTTP ))  && PORT_XHTTP=$(ask_port "VLESS XHTTP+Reality" 443)
  (( WANT_HY2 ))    && PORT_HY2=$(ask_port "Hysteria2 (udp)" 443)
  (( WANT_TCPR ))   && PORT_TCPR=$(ask_port "VLESS TCP+Reality" 4443)
  (( WANT_GRPCR ))  && PORT_GRPCR=$(ask_port "VLESS gRPC+Reality" 8443)
  (( WANT_TROJAN )) && PORT_TROJAN=$(ask_port "Trojan WS+TLS" 2096)
  (( WANT_BRIDGE )) && PORT_BRIDGE=$(ask_port "Bridge-inbound" 9999)
else
  log_info "PROTOCOLS_SELECT задан — использую порты по умолчанию (443/443/4443/8443/2096/9999)"
fi

# Один TCP-порт не могут делить два inbound'а
declare -A USED_TCP=()
for entry in "XHTTP:$PORT_XHTTP:$WANT_XHTTP" "TCPR:$PORT_TCPR:$WANT_TCPR" \
             "GRPCR:$PORT_GRPCR:$WANT_GRPCR" "TROJAN:$PORT_TROJAN:$WANT_TROJAN" \
             "BRIDGE:$PORT_BRIDGE:$WANT_BRIDGE"; do
  IFS=: read -r name port want <<< "$entry"
  (( want )) || continue
  if [[ -n "${USED_TCP[$port]:-}" ]]; then
    log_error "Конфликт: ${USED_TCP[$port]} и $name оба на ${port}/tcp. Запустите заново с разными портами."
    exit 1
  fi
  USED_TCP[$port]="$name"
done

# ---------------------------------------------------------------------------
# Шаг 2. Параметры Reality (у каждого Reality-инбаунда — свой keypair)
# ---------------------------------------------------------------------------
# Отдельный ключ на инбаунд, а не общий на всех — компрометация одного
# протокола не даёт возможности зафингерпринтить остальные.

gen_reality_keypair() { # выводит "priv pub" одной строкой
  local out priv pub
  out=""
  if docker ps --format '{{.Names}}' | grep -qx remnanode; then
    out=$(docker exec remnanode xray x25519 2>/dev/null || true)
  fi
  if [[ -z "$out" ]]; then
    out=$(docker run --rm --entrypoint xray remnawave/node:latest x25519 2>/dev/null || true)
  fi
  # Форматы вывода: "Private key: .../Public key: ..." (старый)
  # или "PrivateKey: .../Password: ..." (новый)
  priv=$(echo "$out" | grep -iE '^\s*Private ?[Kk]ey' | head -1 | sed 's/.*:\s*//' | tr -d ' \r')
  pub=$(echo "$out" | grep -iE '^\s*(Public ?[Kk]ey|Password)' | head -1 | sed 's/.*:\s*//' | tr -d ' \r')
  if [[ -z "$priv" || -z "$pub" ]]; then
    log_error "Не удалось сгенерировать Reality-ключи (xray x25519). Вывод:"
    echo "$out" >&2
    exit 1
  fi
  echo "$priv $pub"
}

REALITY_SNI="www.github.com"
REALITY_PRIV_XHTTP=""; REALITY_PUB_XHTTP=""
REALITY_PRIV_TCP="";   REALITY_PUB_TCP=""
REALITY_PRIV_GRPC="";  REALITY_PUB_GRPC=""

if (( WANT_XHTTP || WANT_TCPR || WANT_GRPCR )); then
  echo ""
  if [[ -z "${PROTOCOLS_SELECT:-}" ]]; then
    read -r -p "SNI/dest для Reality (по умолчанию www.github.com): " REALITY_SNI_IN || true
    REALITY_SNI="${REALITY_SNI_IN:-www.github.com}"
  fi

  log_info "Генерация Reality-ключей..."
  if (( WANT_XHTTP )); then
    read -r REALITY_PRIV_XHTTP REALITY_PUB_XHTTP <<< "$(gen_reality_keypair)"
  fi
  if (( WANT_TCPR )); then
    read -r REALITY_PRIV_TCP REALITY_PUB_TCP <<< "$(gen_reality_keypair)"
  fi
  if (( WANT_GRPCR )); then
    read -r REALITY_PRIV_GRPC REALITY_PUB_GRPC <<< "$(gen_reality_keypair)"
  fi
  log_success "Reality-ключи сгенерированы (public key каждого протокола — в итоговом отчёте)"
fi

TROJAN_WS_PATH="/ws"
if (( WANT_TROJAN )) && [[ -z "${PROTOCOLS_SELECT:-}" ]]; then
  read -r -p "Путь WebSocket для Trojan (по умолчанию /ws): " TROJAN_WS_PATH_IN || true
  TROJAN_WS_PATH="${TROJAN_WS_PATH_IN:-/ws}"
fi

# ---------------------------------------------------------------------------
# Шаг 3. UFW
# ---------------------------------------------------------------------------

echo ""
log_info "=== Открытие портов в UFW ==="
(( WANT_XHTTP ))  && ufw_allow "$PORT_XHTTP"  tcp "vless-xhttp-reality"
(( WANT_HY2 ))    && ufw_allow "$PORT_HY2"    udp "hysteria2"
(( WANT_TCPR ))   && ufw_allow "$PORT_TCPR"   tcp "vless-tcp-reality"
(( WANT_GRPCR ))  && ufw_allow "$PORT_GRPCR"  tcp "vless-grpc-reality"
(( WANT_TROJAN )) && ufw_allow "$PORT_TROJAN" tcp "trojan-ws"
(( WANT_BRIDGE )) && ufw_allow "$PORT_BRIDGE" tcp "bridge-cascade"

# ---------------------------------------------------------------------------
# Шаг 4. Сборка конфига
# ---------------------------------------------------------------------------

echo ""
log_info "=== Сборка мультиконфига ==="

INBOUNDS=()
DIRECT_TAGS=()

if (( WANT_XHTTP )); then
  DIRECT_TAGS+=('"VLESS_XHTTP_REALITY"')
  INBOUNDS+=("$(cat <<EOF
    {
      "tag": "VLESS_XHTTP_REALITY",
      "port": $PORT_XHTTP,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "host": "www.github.com",
          "mode": "auto",
          "path": "/api/v2/stream/",
          "extra": {
            "noSSEHeader": true,
            "xPaddingBytes": "100-1000",
            "scMaxBufferedPosts": 50,
            "scMaxEachPostBytes": 2000000,
            "scStreamUpServerSecs": "120-240"
          }
        },
        "realitySettings": {
          "dest": "$REALITY_SNI:443",
          "show": false,
          "xver": 0,
          "shortIds": [$(gen_short_ids)],
          "privateKey": "$REALITY_PRIV_XHTTP",
          "serverNames": ["$REALITY_SNI"]
        }
      }
    }
EOF
)")
fi

if (( WANT_GRPCR )); then
  INBOUNDS+=("$(cat <<EOF
    {
      "tag": "VLESS_GRPC_REALITY",
      "port": $PORT_GRPCR,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "grpcSettings": { "serviceName": "grpc-stream", "multiMode": false },
        "realitySettings": {
          "dest": "$REALITY_SNI:443",
          "show": false,
          "xver": 0,
          "shortIds": [$(gen_short_ids)],
          "privateKey": "$REALITY_PRIV_GRPC",
          "serverNames": ["$REALITY_SNI"]
        }
      }
    }
EOF
)")
fi

if (( WANT_TCPR )); then
  INBOUNDS+=("$(cat <<EOF
    {
      "tag": "VLESS_TCP_REALITY",
      "port": $PORT_TCPR,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$REALITY_SNI:443",
          "show": false,
          "xver": 0,
          "shortIds": [$(gen_short_ids)],
          "privateKey": "$REALITY_PRIV_TCP",
          "serverNames": ["$REALITY_SNI"]
        }
      }
    }
EOF
)")
fi

if (( WANT_HY2 )); then
  INBOUNDS+=("$(cat <<EOF
    {
      "tag": "HYSTERIA2_IN",
      "port": $PORT_HY2,
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "settings": { "version": 2, "users": [] },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [
            { "certificateFile": "$SSL_CERT", "keyFile": "$SSL_KEY" }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          "masquerade": {
            "type": "", "dir": "", "url": "", "rewriteHost": false,
            "insecure": false, "content": "", "headers": {}, "statusCode": 0
          }
        }
      }
    }
EOF
)")
fi

if (( WANT_TROJAN )); then
  INBOUNDS+=("$(cat <<EOF
    {
      "tag": "TROJAN_WS_TLS",
      "port": $PORT_TROJAN,
      "listen": "0.0.0.0",
      "protocol": "trojan",
      "settings": { "clients": [] },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": { "path": "$TROJAN_WS_PATH", "headers": {} },
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "minVersion": "1.2",
          "certificates": [
            { "certificateFile": "$SSL_CERT", "keyFile": "$SSL_KEY" }
          ]
        }
      }
    }
EOF
)")
fi

if (( WANT_BRIDGE )); then
  DIRECT_TAGS+=('"BRIDGE_DE_IN_MULT"')
  INBOUNDS+=("$(cat <<EOF
    {
      "tag": "BRIDGE_DE_IN_MULT",
      "port": $PORT_BRIDGE,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": { "network": "tcp" }
    }
EOF
)")
fi

# Склейка inbound'ов через запятую
INBOUNDS_JSON=$(printf '%s,\n' "${INBOUNDS[@]}")
INBOUNDS_JSON="${INBOUNDS_JSON%,}"

# Правило DIRECT только если есть кому его назначить
DIRECT_RULE=""
if (( ${#DIRECT_TAGS[@]} > 0 )); then
  TAGS_JOINED=$(IFS=,; echo "${DIRECT_TAGS[*]}")
  DIRECT_RULE=",
      {
        \"type\": \"field\",
        \"inboundTag\": [$TAGS_JOINED],
        \"outboundTag\": \"DIRECT\"
      }"
fi

cat > "$CONFIG_OUT" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
$INBOUNDS_JSON
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "type": "field", "outboundTag": "BLOCK" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "BLOCK" }$DIRECT_RULE
    ],
    "domainStrategy": "IPOnDemand"
  }
}
EOF

log_success "Конфиг записан: $CONFIG_OUT"

# ---------------------------------------------------------------------------
# Шаг 5. Валидация конфига реальным xray в контейнере
# ---------------------------------------------------------------------------

echo ""
log_info "=== Валидация конфига (xray -test в контейнере) ==="
if docker ps --format '{{.Names}}' | grep -qx remnanode; then
  docker cp "$CONFIG_OUT" remnanode:/tmp/xray-test-config.json
  if docker exec remnanode xray -test -c /tmp/xray-test-config.json; then
    log_success "Configuration OK"
  else
    log_error "xray -test нашёл ошибку в конфиге — не вставляйте его в панель, проверьте вывод выше."
    docker exec remnanode rm -f /tmp/xray-test-config.json || true
    exit 1
  fi
  docker exec remnanode rm -f /tmp/xray-test-config.json || true
else
  log_warning "Контейнер remnanode не запущен — пропускаю валидацию."
fi

# ---------------------------------------------------------------------------
# Шаг 6. Итог
# ---------------------------------------------------------------------------

echo ""
echo -e "${GREEN}=== Готово! ===${NC}"
echo ""
echo -e "${BLUE}Настроенные протоколы:${NC}"
(( WANT_XHTTP ))  && echo "  • VLESS XHTTP + Reality  → ${PORT_XHTTP}/tcp  (SNI: $REALITY_SNI)"
(( WANT_HY2 ))    && echo "  • Hysteria2              → ${PORT_HY2}/udp  (SNI: $DOMAIN)"
(( WANT_TCPR ))   && echo "  • VLESS TCP + Reality    → ${PORT_TCPR}/tcp  (SNI: $REALITY_SNI)"
(( WANT_GRPCR ))  && echo "  • VLESS gRPC + Reality   → ${PORT_GRPCR}/tcp  (SNI: $REALITY_SNI, serviceName: grpc-stream)"
(( WANT_TROJAN )) && echo "  • Trojan WS + TLS        → ${PORT_TROJAN}/tcp  (path: $TROJAN_WS_PATH)"
(( WANT_BRIDGE )) && echo "  • Bridge (каскад)        → ${PORT_BRIDGE}/tcp"
if [[ -n "$REALITY_PUB_XHTTP$REALITY_PUB_TCP$REALITY_PUB_GRPC" ]]; then
  echo ""
  echo -e "${BLUE}Reality public key (для клиентов / хостов в панели, свой на каждый протокол):${NC}"
  (( WANT_XHTTP )) && echo "  XHTTP: $REALITY_PUB_XHTTP"
  (( WANT_TCPR ))  && echo "  TCP:   $REALITY_PUB_TCP"
  (( WANT_GRPCR )) && echo "  gRPC:  $REALITY_PUB_GRPC"
fi
echo ""
echo -e "${YELLOW}Что дальше:${NC}"
echo "  1. Откройте панель Remnawave → Config ноды."
echo "  2. Вставьте туда содержимое файла:"
echo "       $CONFIG_OUT"
echo "  3. Сохраните — панель перезапустит Xray на ноде с новым конфигом."
echo "  4. Проверьте логи: docker compose logs -f remnanode"
echo ""
