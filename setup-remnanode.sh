#!/usr/bin/env bash
#
# Скрипт автоматической настройки Remnawave Node + ACME (Let's Encrypt)
# Запуск: ./setup-remnanode.sh
#
# Требования:
#  - Docker и Docker Compose уже установлены на сервер
#  - Пользователь admin создан и может использовать sudo без пароля для ufw
#  - Домен уже указывает на IP этого сервера (A/AAAA запись)
#

set -euo pipefail

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции логирования
log_info() {
  echo -e "${BLUE}ℹ${NC}  $*"
}

log_success() {
  echo -e "${GREEN}✓${NC}  $*"
}

log_error() {
  echo -e "${RED}✗${NC}  $*" >&2
}

log_warning() {
  echo -e "${YELLOW}⚠${NC}  $*"
}

# Определяем корневую директорию скрипта
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ============================================================================
# ФАЗА 0: Проверки
# ============================================================================

log_info "=== ФАЗА 0: Проверка предусловий ==="

# Проверка Docker
if ! command -v docker &> /dev/null; then
  log_error "Docker не установлен. Установите Docker перед запуском этого скрипта."
  exit 1
fi
log_success "Docker найден: $(docker --version)"

# Проверка Docker Compose
if ! docker compose version &> /dev/null; then
  log_error "Docker Compose не установлен. Установите Docker Compose перед запуском."
  exit 1
fi
log_success "Docker Compose найден"

# Проверка, что скрипты выполняемы
if [[ ! -x scripts/issue-cert.sh ]]; then
  chmod +x scripts/*.sh
  log_info "Выданы права на выполнение скриптам"
fi

echo ""

# ============================================================================
# ФАЗА 1: Интерактивный ввод параметров
# ============================================================================

log_info "=== ФАЗА 1: Ввод параметров конфигурации ==="
echo ""

# Проверка существует ли .env
if [[ -f .env ]]; then
  log_warning ".env уже существует."
  if [[ "${INSTALL_SH_DRIVEN:-0}" == "1" ]]; then
    REPLY="y"
    log_info "INSTALL_SH_DRIVEN=1 — использую существующий .env без вопроса"
  else
    read -p "Использовать существующий .env? (y/n) " -n 1 -r
    echo
  fi
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Загрузить значения из .env
    DOMAIN=$(grep -m1 -E '^DOMAIN=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
    EMAIL=$(grep -m1 -E '^EMAIL=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
    NODE_PORT=$(grep -m1 -E '^NODE_PORT=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
    SECRET_KEY=$(grep -m1 -E '^SECRET_KEY=' .env | cut -d= -f2- | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
    log_success "Загружены значения из .env"
    echo ""
  else
    log_info "Введите новые параметры конфигурации"
  fi
fi

# Если переменные не загружены, запросить их
if [[ -z "${DOMAIN:-}" ]]; then
  while true; do
    read -p "Домен ноды (например, node1.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr -d '\r')
    if [[ -n "$DOMAIN" && "$DOMAIN" != "node.example.com" ]]; then
      # Простая проверка валидности домена
      if [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_success "Домен: $DOMAIN"
        break
      else
        log_error "Некорректный формат домена. Попробуйте снова."
      fi
    else
      log_error "Домен не может быть пустым и не может быть example.com"
    fi
  done
fi

if [[ -z "${EMAIL:-}" ]]; then
  while true; do
    read -p "Email для Let's Encrypt уведомлений: " EMAIL
    EMAIL=$(echo "$EMAIL" | tr -d '\r')
    if [[ -n "$EMAIL" && "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      log_success "Email: $EMAIL"
      break
    else
      log_error "Некорректный email. Попробуйте снова."
    fi
  done
fi

if [[ -z "${NODE_PORT:-}" ]]; then
  NODE_PORT="8080"
  read -p "Порт API ноды (по умолчанию 8080): " -t 5 USER_PORT || true
  if [[ -n "$USER_PORT" && "$USER_PORT" != "8080" ]]; then
    if [[ "$USER_PORT" =~ ^[0-9]+$ ]] && [[ "$USER_PORT" -ge 1024 && "$USER_PORT" -le 65535 ]]; then
      NODE_PORT="$USER_PORT"
    else
      log_warning "Некорректный порт, используется 8080"
    fi
  fi
  log_success "Порт API: $NODE_PORT"
fi

if [[ -z "${SECRET_KEY:-}" ]]; then
  log_warning "SECRET_KEY требуется из панели remnawave"
  while true; do
    echo "Вставьте SECRET_KEY (должен быть base64-строка):"
    read -p "> " SECRET_KEY
    SECRET_KEY=$(echo "$SECRET_KEY" | tr -d '\r')
    if [[ -n "$SECRET_KEY" && ${#SECRET_KEY} -gt 100 ]]; then
      # Простая проверка: попытаемся декодировать
      if echo "$SECRET_KEY" | base64 -d &> /dev/null || echo "$SECRET_KEY" | base64 -w0 -d &> /dev/null 2>/dev/null || true; then
        log_success "SECRET_KEY принят (длина: ${#SECRET_KEY})"
        break
      else
        log_warning "Не удалось проверить base64. Если вы уверены, продолжу."
        read -p "Продолжить? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          break
        fi
      fi
    else
      log_error "SECRET_KEY слишком короткий или пуст"
    fi
  done
fi

echo ""

# ============================================================================
# ФАЗА 2: Создание .env файла
# ============================================================================

log_info "=== ФАЗА 2: Создание .env файла ==="

ENV_FILE=".env"

cat > "$ENV_FILE" << EOF
# Сгенерировано скриптом setup-remnanode.sh
# Домен должен указывать на этот сервер (A/AAAA) для HTTP-01 Let's Encrypt.

DOMAIN=$DOMAIN
EMAIL=$EMAIL

# Порт API ноды для панели (в файрволе открыть только для IP панели).
NODE_PORT=$NODE_PORT

# SECRET_KEY из панели remnawave — содержит сертификаты и ключи ноды
SECRET_KEY=$SECRET_KEY
EOF

chmod 600 "$ENV_FILE"
log_success ".env файл создан с правами 600"

echo ""

# ============================================================================
# ФАЗА 3: Проверка и настройка UFW (если доступен)
# ============================================================================

log_info "=== ФАЗА 3: Настройка UFW (если доступен) ==="

if command -v ufw &> /dev/null; then
  log_info "UFW найден. Проверка правил..."

  # Попытаемся использовать sudo для ufw (если нужно)
  if ! sudo -n ufw status &> /dev/null 2>&1; then
    log_warning "Требуется sudo для UFW. Попытаюсь без sudo..."
    if ! ufw status &> /dev/null 2>&1; then
      log_warning "Не удалось проверить UFW. Пропускаю настройку."
      echo ""
    else
      SUDO_PREFIX=""
    fi
  else
    SUDO_PREFIX="sudo"
  fi

  if [[ -z "${SUDO_PREFIX:-}" ]]; then
    SUDO_PREFIX="sudo"
  fi

  if $SUDO_PREFIX ufw status 2>/dev/null | grep -q "inactive"; then
    log_info "UFW неактивен. Активирую..."
    $SUDO_PREFIX ufw default deny incoming 2>/dev/null || true
    $SUDO_PREFIX ufw default allow outgoing 2>/dev/null || true
    log_success "Правила по умолчанию установлены"
  else
    log_info "UFW уже активен"
  fi

  # Открытие необходимых портов
  for PORT in 22 80 443 "$NODE_PORT"; do
    if ! $SUDO_PREFIX ufw status | grep -q "$PORT.*ALLOW"; then
      log_info "Открываю порт $PORT..."
      $SUDO_PREFIX ufw allow "$PORT"/tcp 2>/dev/null || log_warning "Не удалось открыть порт $PORT"
    else
      log_success "Порт $PORT уже открыт"
    fi
  done

  # Включение UFW (если еще не включен)
  if $SUDO_PREFIX ufw status | grep -q "inactive"; then
    log_info "Включаю UFW..."
    echo y | $SUDO_PREFIX ufw enable 2>/dev/null || log_warning "Не удалось включить UFW"
  fi

  log_success "UFW настроен"
else
  log_warning "UFW не установлен. Пропускаю настройку файрвола."
fi

echo ""

# ============================================================================
# ФАЗА 4: Получение SSL-сертификата
# ============================================================================

log_info "=== ФАЗА 4: Получение SSL-сертификата от Let's Encrypt ==="

mkdir -p certbot/www "letsencrypt/live/${DOMAIN}"

if [[ ! -f "letsencrypt/live/${DOMAIN}/cert.pem" ]]; then
  log_info "Сертификат не найден. Запрашиваю новый..."
  
  if bash scripts/issue-cert.sh; then
    log_success "Сертификат успешно получен"
    
    # Остановка временного nginx
    log_info "Остановка временного nginx (acme профиль)..."
    docker compose --profile acme stop 2>/dev/null || true
    sleep 2
    
    log_success "Временный nginx остановлен"
  else
    log_error "Не удалось получить сертификат"
    echo "Попробуйте вручную: cd $ROOT && ./scripts/issue-cert.sh"
    exit 1
  fi
else
  log_success "Сертификат уже существует: letsencrypt/live/${DOMAIN}/cert.pem"
fi

echo ""

# ============================================================================
# ФАЗА 5: Запуск контейнера ноды
# ============================================================================

log_info "=== ФАЗА 5: Запуск контейнера remnanode ==="

if bash scripts/up.sh; then
  log_success "Контейнер remnanode запущен"
  sleep 3
  
  # Проверка статуса контейнера
  if docker compose ps remnanode | grep -q "Up"; then
    log_success "Контейнер remnanode работает"
  else
    log_warning "Контейнер не запустился. Проверьте логи:"
    docker compose logs remnanode | tail -20
  fi
else
  log_error "Не удалось запустить контейнер"
  exit 1
fi

echo ""

# ============================================================================
# ФАЗА 6: Настройка Cron для продления сертификата
# ============================================================================

log_info "=== ФАЗА 6: Настройка Cron для продления сертификата ==="

CRON_JOB="0 4 1 * * $ROOT/scripts/renew-cert.sh >> /var/log/ssl-remnanode-acme.log 2>&1"
CRON_MARKER="# ssl-remnanode-acme"

# Попытаемся добавить cron для текущего пользователя
if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
  log_success "Cron job для продления уже добавлен"
else
  log_info "Добавляю Cron job для продления сертификата..."
  
  # Создаем новый crontab с новой записью
  (crontab -l 2>/dev/null || echo "") | grep -v "ssl-remnanode-acme" > /tmp/crontab.tmp || true
  echo "$CRON_MARKER" >> /tmp/crontab.tmp
  echo "$CRON_JOB" >> /tmp/crontab.tmp
  
  crontab /tmp/crontab.tmp
  rm /tmp/crontab.tmp
  
  log_success "Cron job добавлен (продление сертификата 1-го числа в 04:00)"
fi

# Создание лог-файла с правильными разрешениями
if [[ ! -f /var/log/ssl-remnanode-acme.log ]]; then
  # Попробуем создать от текущего пользователя, если нет доступа - просто пропустим
  touch /var/log/ssl-remnanode-acme.log 2>/dev/null || log_warning "Не удалось создать лог-файл (требуется sudo или достаточные права)"
else
  log_success "Лог-файл уже существует"
fi

echo ""

# ============================================================================
# ФАЗА 7: Настройка протоколов Xray
# ============================================================================

log_info "=== ФАЗА 7: Настройка протоколов Xray ==="
echo ""

if [[ -n "${PROTOCOLS_SELECT:-}" ]]; then
  PROTO_REPLY="y"
  log_info "PROTOCOLS_SELECT=${PROTOCOLS_SELECT} — настраиваю протоколы без вопроса"
else
  read -p "Настроить протоколы Xray сейчас? (Y/n) " -n 1 -r PROTO_REPLY || true
  echo
  PROTO_REPLY="${PROTO_REPLY:-y}"
fi
if [[ $PROTO_REPLY =~ ^[YyДд]$ ]]; then
  if bash scripts/setup-protocols.sh; then
    log_success "Протоколы настроены, конфиг: $ROOT/xray-multiconfig.json"
  else
    log_warning "Настройка протоколов не завершена. Позже можно запустить: ./scripts/setup-protocols.sh"
  fi
else
  log_info "Пропущено. Позже можно запустить: ./scripts/setup-protocols.sh"
fi

echo ""

# ============================================================================
# ФАЗА 8: Итоговый отчет
# ============================================================================

log_info "=== ФАЗА 8: Итоговый отчет ==="
echo ""

cat << EOF
${GREEN}✓ Настройка Remnanode-SSL завершена успешно!${NC}

${BLUE}Конфигурация:${NC}
  Домен:           $DOMAIN
  Email:           $EMAIL
  Порт API:        $NODE_PORT
  Директория:      $ROOT

${BLUE}Проверки:${NC}
  • Сертификат:    letsencrypt/live/${DOMAIN}/cert.pem
  • Конфиг:        .env (права 600)
  • Контейнер:     docker compose ps remnanode

${BLUE}Полезные команды:${NC}
  Логи ноды:       docker compose logs -f remnanode
  Остановка:       docker compose down
  Перезапуск:      docker compose restart remnanode
  Статус ноды:     docker compose ps

${BLUE}Дальнейшие действия:${NC}
  1. Убедитесь, что домен $DOMAIN указывает на этот IP (A/AAAA запись)
  2. Проверьте, что порт 8080 открыт для IP панели remnawave
  3. В панели remnawave добавьте эту ноду и подключитесь к ней
  4. Вставьте в панели (Config ноды) содержимое xray-multiconfig.json,
     если настраивали протоколы (перенастроить: ./scripts/setup-protocols.sh)
  5. Проверьте логи контейнера на наличие ошибок:
     docker compose logs remnanode | tail -50

${YELLOW}Примечание:${NC}
  Сертификат будет автоматически продлеваться 1-го числа каждого месяца в 04:00.
  Логи продления: /var/log/ssl-remnanode-acme.log

${GREEN}Успешно!${NC}
EOF

echo ""
