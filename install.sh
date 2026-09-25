#!/usr/bin/env bash
#
# Однокомандный установщик Remnawave Node на чистом сервере.
#
# Запуск (пин на релизный тег обязателен для прод-нод, см. README):
#   curl -fsSL https://raw.githubusercontent.com/VPLEXA/setup_remnanode_v2/<tag>/install.sh | \
#     sudo bash -s -- --domain node1.example.com --email you@example.com \
#       --secret-key-file /root/secret_key.txt --panel-ip 1.2.3.4 --protocols all
#
# Без --protocols выбор протоколов остаётся интерактивным (как в
# scripts/setup-protocols.sh) — для этого нужен управляющий терминал.
#
# Скрипт выполняется в две фазы:
#   1) от root: ставит зависимости, Docker, создаёт пользователя admin,
#      клонирует/обновляет репозиторий, передаёт управление admin'у.
#   2) от admin (--continue, внутренний флаг): ждёт DNS, прогоняет
#      setup-remnanode.sh, при необходимости ограничивает порт API до IP панели.
#
set -euo pipefail

# ============================================================================
# Константы и цвета
# ============================================================================

DEFAULT_REPO="https://github.com/VPLEXA/setup_remnanode_v2.git"
DEFAULT_REF="main"
DEFAULT_INSTALL_DIR="/opt/remnanode"
DEFAULT_NODE_PORT="8080"
DEFAULT_DNS_TIMEOUT=1200
DNS_POLL_INTERVAL=15

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}i${NC}  $*"; }
log_success() { echo -e "${GREEN}+${NC}  $*"; }
log_error()   { echo -e "${RED}x${NC}  $*" >&2; }
log_warning() { echo -e "${YELLOW}!${NC}  $*"; }
log_phase()   { echo ""; echo -e "${BLUE}=== $* ===${NC}"; }

# ============================================================================
# Параметры (флаги + значения по умолчанию)
# ============================================================================

CONTINUE=0
DRY_RUN=0
ASSUME_YES=0
TTY_AVAILABLE=0

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
NODE_PORT="${NODE_PORT:-}"
SECRET_KEY="${SECRET_KEY:-}"
SECRET_KEY_FILE=""
SECRET_KEY_FROM_FLAG=0
PANEL_IP="${PANEL_IP:-}"
PROTOCOLS_ARG="${PROTOCOLS_SELECT:-}"
REPO_URL="$DEFAULT_REPO"
REF="$DEFAULT_REF"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DNS_TIMEOUT="$DEFAULT_DNS_TIMEOUT"

usage() {
  cat <<EOF
Использование: install.sh [флаги]

Обязательные (можно ввести интерактивно, если есть терминал):
  --domain <домен>            Домен ноды (A/AAAA должна указывать на этот сервер)
  --email <email>             Email для Let's Encrypt
  --secret-key <ключ>         SECRET_KEY из панели Remnawave (виден в ps/истории шелла!)
  --secret-key-file <путь>    То же, но из файла — безопаснее bare-флага
  (или переменная окружения SECRET_KEY)

Опциональные:
  --panel-ip <ip>             Ограничить порт API только этим IP (иначе открыт всем)
  --node-port <port>          Порт API ноды (по умолчанию 8080)
  --protocols all|none|<список>
                               Список кодов через запятую: xhttp,hy2,tcpr,grpcr,trojan,bridge
                               Не передан => интерактивный выбор (нужен терминал)
  --repo <url>                Git-репозиторий форка (по умолчанию $DEFAULT_REPO)
  --ref <tag|branch>          Тег/ветка для клонирования (по умолчанию $DEFAULT_REF;
                               для прод рекомендуется пинить релизный тег)
  --install-dir <path>        Куда клонировать (по умолчанию $DEFAULT_INSTALL_DIR)
  --dns-timeout <секунды>     Таймаут ожидания DNS (по умолчанию $DEFAULT_DNS_TIMEOUT)
  --dry-run                   Только показать план действий, ничего не менять в системе
  --yes, -y                   Не пытаться спрашивать недостающие параметры интерактивно
  -h, --help                  Эта справка
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain|--email|--secret-key|--secret-key-file|--panel-ip|--node-port|--protocols|--repo|--ref|--install-dir|--dns-timeout)
        if [[ $# -lt 2 ]]; then
          log_error "Флаг $1 требует значение"
          exit 1
        fi
        ;;
    esac
    case "$1" in
      --domain) DOMAIN="$2"; shift 2 ;;
      --email) EMAIL="$2"; shift 2 ;;
      --secret-key) SECRET_KEY="$2"; SECRET_KEY_FROM_FLAG=1; shift 2 ;;
      --secret-key-file) SECRET_KEY_FILE="$2"; shift 2 ;;
      --panel-ip) PANEL_IP="$2"; shift 2 ;;
      --node-port) NODE_PORT="$2"; shift 2 ;;
      --protocols) PROTOCOLS_ARG="$2"; shift 2 ;;
      --repo) REPO_URL="$2"; shift 2 ;;
      --ref) REF="$2"; shift 2 ;;
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --dns-timeout) DNS_TIMEOUT="$2"; shift 2 ;;
      --continue) CONTINUE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "Неизвестный флаг: $1"; usage; exit 1 ;;
    esac
  done
}

resolve_secret_key_file() {
  [[ -z "$SECRET_KEY_FILE" ]] && return
  if [[ ! -r "$SECRET_KEY_FILE" ]]; then
    log_error "Не могу прочитать --secret-key-file: $SECRET_KEY_FILE"
    exit 1
  fi
  SECRET_KEY="$(tr -d '\r\n' < "$SECRET_KEY_FILE")"
}

detect_tty() {
  if [[ -r /dev/tty && -w /dev/tty ]] 2>/dev/null; then
    TTY_AVAILABLE=1
  else
    TTY_AVAILABLE=0
  fi
}

prompt_missing_required() {
  if [[ -z "$DOMAIN" ]]; then
    while true; do
      read -r -p "Домен ноды (например, node1.example.com): " DOMAIN
      if [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        break
      fi
      log_error "Некорректный формат домена, попробуйте снова"
    done
  fi
  if [[ -z "$EMAIL" ]]; then
    while true; do
      read -r -p "Email для Let's Encrypt: " EMAIL
      [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
      log_error "Некорректный email, попробуйте снова"
    done
  fi
  if [[ -z "$SECRET_KEY" ]]; then
    log_warning "SECRET_KEY берётся в панели Remnawave: Ноды -> Добавить ноду"
    while true; do
      read -r -p "SECRET_KEY: " SECRET_KEY
      [[ -n "$SECRET_KEY" ]] && break
      log_error "SECRET_KEY не может быть пустым"
    done
  fi
}

validate_required_or_prompt() {
  local missing=()
  [[ -n "$DOMAIN" ]] || missing+=(--domain)
  [[ -n "$EMAIL" ]] || missing+=(--email)
  [[ -n "$SECRET_KEY" ]] || missing+=(--secret-key)

  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  if [[ $TTY_AVAILABLE -eq 1 && $ASSUME_YES -eq 0 ]]; then
    log_warning "Не хватает параметров (${missing[*]}) — перехожу в интерактивный ввод"
    prompt_missing_required
  else
    log_error "Не хватает обязательных параметров: ${missing[*]}"
    usage
    exit 1
  fi
}

check_protocols_tty_requirement() {
  if [[ -z "$PROTOCOLS_ARG" && $TTY_AVAILABLE -eq 0 ]]; then
    log_error "Протоколы не переданы флагом --protocols, а управляющий терминал недоступен."
    log_error "Передайте --protocols all|none|xhttp,hy2,tcpr,grpcr,trojan,bridge,"
    log_error "либо запустите install.sh в интерактивной сессии (скачав файл, не через curl|bash)."
    exit 1
  fi
}

warn_if_secret_key_in_argv() {
  if [[ $SECRET_KEY_FROM_FLAG -eq 1 ]]; then
    log_warning "SECRET_KEY передан голым флагом --secret-key — виден в 'ps' и истории шелла."
    log_warning "Безопаснее: --secret-key-file <путь> или переменная окружения SECRET_KEY."
  fi
}

warn_if_unpinned_ref() {
  if [[ "$REF" == "main" ]]; then
    log_warning "REF=main — для прод-нод рекомендуется пинить конкретный релизный тег (--ref vX.Y.Z),"
    log_warning "чтобы форс-пуш или компрометация репозитория не подменили скрипт незаметно."
  fi
}

# ============================================================================
# Фаза Root
# ============================================================================

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "install.sh (без --continue) нужно запускать от root (sudo)."
    exit 1
  fi
}

install_packages() {
  log_phase "ФАЗА R1: Системные зависимости"
  local packages=(ca-certificates curl gnupg lsb-release git dnsutils)
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] apt-get update && apt-get install -y ${packages[*]}"
    return
  fi
  apt-get update -qq
  apt-get install -y "${packages[@]}"
  log_success "Зависимости установлены"
}

ensure_docker() {
  log_phase "ФАЗА R2: Docker"
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log_success "Docker и Compose уже установлены: $(docker --version)"
    return
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] установил бы Docker CE + docker-compose-plugin из официального репозитория"
    return
  fi
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  log_success "Docker установлен: $(docker --version)"
}

ensure_admin_user() {
  log_phase "ФАЗА R3: Пользователь admin"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] создал бы пользователя admin (если нет), добавил в группу docker,"
    log_info "[dry-run] настроил NOPASSWD sudo через /etc/sudoers.d/admin"
    return
  fi

  if ! id admin &>/dev/null; then
    useradd -m -s /bin/bash admin
    log_success "Пользователь admin создан"
  else
    log_success "Пользователь admin уже существует"
  fi
  usermod -aG docker admin

  local sudoers_file="/etc/sudoers.d/admin"
  local sudoers_line="admin ALL=(ALL) NOPASSWD:ALL"
  if [[ -f "$sudoers_file" && "$(cat "$sudoers_file")" == "$sudoers_line" ]]; then
    log_success "sudoers для admin уже настроен"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  echo "$sudoers_line" > "$tmp"
  if visudo -c -f "$tmp" &>/dev/null; then
    install -m 0440 "$tmp" "$sudoers_file"
    log_success "sudoers для admin настроен"
  else
    log_error "Не удалось провалидировать sudoers-файл — не применяю, чтобы не сломать sudo"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
}

sync_repo() {
  log_phase "ФАЗА R4: Репозиторий ($REPO_URL @ $REF)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] клонировал бы/обновил $REPO_URL (ref: $REF) в $INSTALL_DIR"
    return
  fi

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log_info "Репозиторий уже есть в $INSTALL_DIR — обновляю"
    git -C "$INSTALL_DIR" fetch --tags origin
    git -C "$INSTALL_DIR" checkout "$REF"
    git -C "$INSTALL_DIR" merge --ff-only "origin/$REF" 2>/dev/null || true
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --branch "$REF" "$REPO_URL" "$INSTALL_DIR"
  fi

  chown -R admin:admin "$INSTALL_DIR"
  chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/setup-remnanode.sh"
  chmod +x "$INSTALL_DIR"/scripts/*.sh
  log_success "Репозиторий готов в $INSTALL_DIR"
}

reexec_as_admin() {
  log_phase "ФАЗА R5: Передача установки пользователю admin"

  local admin_args=(--continue
    --domain "$DOMAIN" --email "$EMAIL" --secret-key "$SECRET_KEY"
    --node-port "$NODE_PORT" --install-dir "$INSTALL_DIR" --dns-timeout "$DNS_TIMEOUT")
  [[ -n "$PANEL_IP" ]] && admin_args+=(--panel-ip "$PANEL_IP")
  [[ -n "$PROTOCOLS_ARG" ]] && admin_args+=(--protocols "$PROTOCOLS_ARG")
  [[ $DRY_RUN -eq 1 ]] && admin_args+=(--dry-run)
  [[ $ASSUME_YES -eq 1 ]] && admin_args+=(--yes)

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] sudo -u admin bash $INSTALL_DIR/install.sh ${admin_args[*]//$SECRET_KEY/<secret>}"
    return
  fi

  if [[ $TTY_AVAILABLE -eq 1 ]]; then
    exec sudo -u admin -H bash "$INSTALL_DIR/install.sh" "${admin_args[@]}" < /dev/tty
  else
    exec sudo -u admin -H bash "$INSTALL_DIR/install.sh" "${admin_args[@]}" < /dev/null
  fi
}

run_root_phase() {
  require_root
  validate_required_or_prompt
  check_protocols_tty_requirement
  warn_if_secret_key_in_argv
  warn_if_unpinned_ref

  install_packages
  ensure_docker
  ensure_admin_user
  sync_repo
  reexec_as_admin
}

# ============================================================================
# Фаза Admin
# ============================================================================

wait_for_dns() {
  log_phase "ФАЗА A1: Ожидание DNS"

  local public_ip=""
  local svc
  for svc in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
    public_ip="$(curl -4s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$public_ip" ]] && break
  done

  if [[ -z "$public_ip" ]]; then
    log_warning "Не удалось определить публичный IP сервера — пропускаю проверку DNS"
    return
  fi
  log_info "Публичный IP сервера: $public_ip"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] ожидал бы, пока $DOMAIN укажет на $public_ip (таймаут ${DNS_TIMEOUT}с)"
    return
  fi

  log_info "Ожидаю, пока $DOMAIN укажет на $public_ip (таймаут ${DNS_TIMEOUT}с)..."
  local waited=0 resolved
  while true; do
    resolved="$(dig +short "$DOMAIN" A 2>/dev/null | tail -n1 || true)"
    if [[ "$resolved" == "$public_ip" ]]; then
      log_success "DNS настроен верно: $DOMAIN -> $resolved"
      return
    fi
    if (( waited >= DNS_TIMEOUT )); then
      log_error "$DOMAIN не указывает на $public_ip после ${DNS_TIMEOUT}с (сейчас: ${resolved:-<нет ответа>})."
      log_error "Проверьте A/AAAA-запись у регистратора домена и запустите install.sh снова."
      exit 1
    fi
    sleep "$DNS_POLL_INTERVAL"
    waited=$((waited + DNS_POLL_INTERVAL))
  done
}

apply_panel_ip_restriction() {
  if [[ -z "$PANEL_IP" ]]; then
    log_warning "Порт ${NODE_PORT}/tcp остаётся открыт для всех IP (флаг --panel-ip не передан)."
    return
  fi

  log_phase "ФАЗА A3: Ограничение порта ${NODE_PORT} до IP панели"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] ufw delete allow ${NODE_PORT}/tcp"
    log_info "[dry-run] ufw allow from $PANEL_IP to any port ${NODE_PORT} proto tcp"
    log_info "[dry-run] ufw reload"
    return
  fi
  if ! command -v ufw &>/dev/null; then
    log_warning "UFW не найден — пропускаю ограничение порта"
    return
  fi

  local sudo_prefix=""
  sudo -n true &>/dev/null && sudo_prefix="sudo"
  $sudo_prefix ufw delete allow "${NODE_PORT}/tcp" &>/dev/null || true
  $sudo_prefix ufw allow from "$PANEL_IP" to any port "${NODE_PORT}" proto tcp
  $sudo_prefix ufw reload
  log_success "Порт ${NODE_PORT}/tcp теперь открыт только для $PANEL_IP"
}

print_summary() {
  log_phase "ФАЗА A4: Итог"
  local port_note
  if [[ -n "$PANEL_IP" ]]; then
    port_note="(открыт только для $PANEL_IP)"
  else
    port_note="(открыт всем — передайте --panel-ip)"
  fi
  echo ""
  echo -e "${GREEN}Установка завершена.${NC}"
  echo ""
  echo "  Домен:      $DOMAIN"
  echo "  Директория: $INSTALL_DIR"
  echo "  Порт API:   $NODE_PORT $port_note"
  echo ""
  echo "  Логи ноды:  docker compose -f $INSTALL_DIR/docker-compose.yml logs -f remnanode"
  echo "  Статус:     docker compose -f $INSTALL_DIR/docker-compose.yml ps"
}

run_admin_phase() {
  if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$SECRET_KEY" ]]; then
    log_error "Внутренняя ошибка: admin-фаза (--continue) вызвана без domain/email/secret-key."
    exit 1
  fi

  cd "$INSTALL_DIR"
  wait_for_dns

  export DOMAIN EMAIL NODE_PORT SECRET_KEY
  export INSTALL_SH_DRIVEN=1
  [[ -n "$PROTOCOLS_ARG" ]] && export PROTOCOLS_SELECT="$PROTOCOLS_ARG"

  log_phase "ФАЗА A2: setup-remnanode.sh"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] запустил бы ./setup-remnanode.sh (DOMAIN=$DOMAIN, NODE_PORT=$NODE_PORT,"
    log_info "[dry-run] PROTOCOLS_SELECT=${PROTOCOLS_SELECT:-<интерактивно>})"
  else
    bash ./setup-remnanode.sh
  fi

  apply_panel_ip_restriction
  print_summary
}

# ============================================================================
# main
# ============================================================================

main() {
  parse_args "$@"
  NODE_PORT="${NODE_PORT:-$DEFAULT_NODE_PORT}"
  DNS_TIMEOUT="${DNS_TIMEOUT:-$DEFAULT_DNS_TIMEOUT}"
  detect_tty
  resolve_secret_key_file

  if [[ $CONTINUE -eq 1 ]]; then
    run_admin_phase
  else
    run_root_phase
  fi
}

main "$@"
