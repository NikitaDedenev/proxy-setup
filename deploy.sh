#!/usr/bin/env bash
# =============================================================================
#  proxy-setup :: deploy.sh
#  Единая точка входа 443/TCP (Nginx + 3x-ui selfSNI) + 443/UDP (h-ui/Hysteria2)
#  + MTProto (Docker). Ubuntu 22.04 / 24.04 / 26.04 LTS.
#
#  Идемпотентный: повторный запуск переиспользует сгенерированные секреты,
#  порты и пути из /root/proxy-setup/state.env, не ломая рабочую установку.
#
#  Документация и флаги: ./deploy.sh --help
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Пути и константы ─────────────────────────────────────────────────────────
STATE_DIR="/root/proxy-setup"
STATE_FILE="${STATE_DIR}/state.env"
MANIFEST="${STATE_DIR}/manifest.txt"
BACKUP_ROOT="${STATE_DIR}/backups"
SUMMARY_FILE="${STATE_DIR}/summary.txt"
LOG_FILE="/var/log/proxy-setup.log"

# One-command режим: скрипт запускается из process substitution (bash <(curl ...)),
# локальных assets/ рядом нет — шаблон сайта скачивается из этого репозитория.
REPO_SLUG="NikitaDedenev/proxy-setup"
REPO_BRANCH="main"
REPO_RAW="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}"
SITE_CACHE="${STATE_DIR}/site-template"

NGINX_SITES_AVAIL="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_STREAM_DIR="/etc/nginx/stream-enabled"
NGINX_CONF_D="/etc/nginx/conf.d"
NGINX_MODULES_DIR="/etc/nginx/modules-enabled"
NGINX_CONF="/etc/nginx/nginx.conf"
LE_DIR="/etc/letsencrypt/live"
WEBROOT="/var/www/html"

XUI_DIR="/usr/local/x-ui"
XUI_DB_DIR="/etc/x-ui"
XUI_DB="${XUI_DB_DIR}/x-ui.db"
XUI_DEFAULT_VERSION="3.11.0"
XUI_XHTTP_SOCK="/dev/shm/proxy-setup-xhttp.sock"

HUI_DIR="/usr/local/h-ui"
HUI_DB="${HUI_DIR}/data/h_ui.db"
HUI_HY_CONFIG="${HUI_DIR}/bin/hysteria2.yaml"

MTPROTO_DIR="/opt/mtproto"

# ── Значения по умолчанию (перекрываются .env / CLI / state.env) ─────────────
DOMAIN=""
REALITY_DOMAIN=""
LE_EMAIL=""
SSH_PORT=""
MT_PORT=""
MT_SECRET=""
MTPROTO_TAG=""

ENABLE_XUI=1
ENABLE_HUI=1
ENABLE_MTPROTO=1
ENABLE_XHTTP=1
SITE_DIR=""

ASSUME_YES=0
FORCE=0
DRY_RUN=0
SKIP_DNS_CHECK=0
UNINSTALL=0
NO_COLOR=0

# Сгенерированные артефакты (заполняются из state.env или генерируются)
XUI_USER=""
XUI_PASS=""
XUI_PORT=""
XUI_PATH=""
XUI_TOKEN=""
SUB_PORT=""
SUB_PATH=""
SUB_JSON_PATH=""
WS_PORT=""
WS_PATH=""
TROJAN_PORT=""
TROJAN_PATH=""
TROJAN_PASS=""
XHTTP_PATH=""
VLESS_UUID=""
VLESS_UUID_WS=""
VLESS_UUID_XHTTP=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
HUI_PORT=""
HUI_PATH=""
HUI_PASS=""
HY2_OBFS_PASS=""
HY2_STATS_SECRET=""
HY2_STATS_PORT=""
SERVER_IP=""
BACKUP_DIR=""
INVENTORY=""

# ── Цвета и логирование ──────────────────────────────────────────────────────
setup_colors() {
    if [[ $NO_COLOR -eq 1 ]] || [[ ! -t 1 ]]; then
        C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_OFF=''
    else
        C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m' C_YELLOW=$'\033[1;33m'
        C_CYAN=$'\033[0;36m' C_BOLD=$'\033[1m' C_OFF=$'\033[0m'
    fi
}

setup_colors
msg_ok()   { printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_OFF}" "$*"; }
msg_info() { printf '%s[ .. ]%s %s\n' "${C_CYAN}" "${C_OFF}" "$*"; }
msg_warn() { printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_OFF}" "$*" >&2; }
msg_err()  { printf '%s[FAIL]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }

die() { msg_err "$*"; exit 1; }

on_error() {
    local status=$1 line=$2
    msg_err "Сбой (код ${status}) на строке ${line}: ${BASH_COMMAND}"
    msg_err "Лог: ${LOG_FILE}. Бэкапы: ${BACKUP_ROOT}"
    exit "$status"
}
trap 'on_error $? $LINENO' ERR

init_logging() {
    mkdir -p "$STATE_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    printf '\n===== deploy.sh start: %s =====\n' "$(date -Is)"
}

# Защита от параллельного запуска: два экземпляра ломают state и конфиги.
init_lock() {
    mkdir -p "$STATE_DIR"
    exec 9>"${STATE_DIR}/.deploy.lock"
    if ! flock -n 9; then
        die "Другой экземпляр deploy.sh уже выполняется (${STATE_DIR}/.deploy.lock)"
    fi
}

# ── Вспомогательные функции ──────────────────────────────────────────────────
need_root() {
    [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root (sudo -i)."
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

rand_hex() { openssl rand -hex "$1"; }

rand_port() {
    local port
    for _ in $(seq 1 200); do
        port=$(shuf -i 20000-60000 -n 1)
        if ! ss -Hltn "sport = :${port}" 2>/dev/null | grep -q . \
           && ! ss -Hlun "sport = :${port}" 2>/dev/null | grep -q .; then
            printf '%s' "$port"
            return 0
        fi
    done
    die "Не удалось подобрать свободный порт"
}

wait_for_port() {
    local port=$1 timeout=${2:-60} i=0
    while (( i < timeout )); do
        if ss -Hltn "sport = :${port}" 2>/dev/null | grep -q . \
           || ss -Hlun "sport = :${port}" 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    msg_warn "Порт ${port} не поднялся за ${timeout}s"
    return 1
}

wait_for_http() {
    local url=$1 timeout=${2:-60} i=0
    while (( i < timeout )); do
        if curl -fsS --max-time 3 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    msg_warn "URL ${url} не ответил за ${timeout}s"
    return 1
}

manifest_add() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" >>"$MANIFEST"
}

manifest_has() { [[ -f $MANIFEST ]] && grep -Fxq "$1" "$MANIFEST"; }

# ── Проверки окружения ───────────────────────────────────────────────────────
require_ubuntu() {
    if [[ ! -r /etc/os-release ]]; then
        msg_warn "/etc/os-release недоступен, пропускаю проверку ОС"
        return 0
    fi
    local id version_id
    id=$(. /etc/os-release; printf '%s' "${ID:-}")
    version_id=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
    if [[ $id != "ubuntu" ]]; then
        die "Поддерживается только Ubuntu (найдено: ${id:-unknown})"
    fi
    case "$version_id" in
        22.04|24.04|26.04) msg_ok "Ubuntu ${version_id} — поддерживается" ;;
        *) msg_warn "Ubuntu ${version_id} официально не тестировалась; продолжаю" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
    esac
}

public_ip() {
    local ip
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    if [[ -z $ip ]]; then
        ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    fi
    [[ -n $ip ]] || die "Не удалось определить публичный IPv4"
    printf '%s' "$ip"
}

host_resolves_to() {
    local host=$1 ip=$2 resolved
    resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ $resolved == "$ip" ]]
}

# ── State ────────────────────────────────────────────────────────────────────
load_state() {
    if [[ -f $STATE_FILE ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        msg_info "Загружено состояние предыдущего запуска: ${STATE_FILE}"
    fi
}

save_state() {
    mkdir -p "$STATE_DIR"
    local old_umask
    old_umask=$(umask)
    umask 077
    cat >"$STATE_FILE" <<EOF
# Сгенерировано deploy.sh $(date -Is). Не редактируйте вручную.
DOMAIN='${DOMAIN}'
REALITY_DOMAIN='${REALITY_DOMAIN}'
SERVER_IP='${SERVER_IP}'
XUI_USER='${XUI_USER}'
XUI_PASS='${XUI_PASS}'
XUI_PORT='${XUI_PORT}'
XUI_PATH='${XUI_PATH}'
SUB_PORT='${SUB_PORT}'
SUB_PATH='${SUB_PATH}'
SUB_JSON_PATH='${SUB_JSON_PATH}'
WS_PORT='${WS_PORT}'
WS_PATH='${WS_PATH}'
TROJAN_PORT='${TROJAN_PORT}'
TROJAN_PATH='${TROJAN_PATH}'
TROJAN_PASS='${TROJAN_PASS}'
XHTTP_PATH='${XHTTP_PATH}'
VLESS_UUID='${VLESS_UUID}'
VLESS_UUID_WS='${VLESS_UUID_WS}'
VLESS_UUID_XHTTP='${VLESS_UUID_XHTTP}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
HUI_PORT='${HUI_PORT}'
HUI_PATH='${HUI_PATH}'
HUI_PASS='${HUI_PASS}'
HY2_OBFS_PASS='${HY2_OBFS_PASS}'
HY2_STATS_SECRET='${HY2_STATS_SECRET}'
HY2_STATS_PORT='${HY2_STATS_PORT}'
MT_PORT='${MT_PORT}'
MT_SECRET='${MT_SECRET}'
MTPROTO_TAG='${MTPROTO_TAG}'
EOF
    umask "$old_umask"
    chmod 600 "$STATE_FILE"
}

ensure_secrets() {
    SERVER_IP=${SERVER_IP:-$(public_ip)}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    VLESS_UUID_WS=${VLESS_UUID_WS:-$(cat /proc/sys/kernel/random/uuid)}
    VLESS_UUID_XHTTP=${VLESS_UUID_XHTTP:-$(cat /proc/sys/kernel/random/uuid)}
    XUI_USER=${XUI_USER:-admin}
    XUI_PASS=${XUI_PASS:-$(rand_hex 12)}
    XUI_PORT=${XUI_PORT:-$(rand_port)}
    XUI_PATH=${XUI_PATH:-$(rand_hex 6)}
    SUB_PORT=${SUB_PORT:-$(rand_port)}
    SUB_PATH=${SUB_PATH:-$(rand_hex 6)}
    SUB_JSON_PATH=${SUB_JSON_PATH:-$(rand_hex 6)}
    WS_PORT=${WS_PORT:-$(rand_port)}
    WS_PATH=${WS_PATH:-$(rand_hex 8)}
    TROJAN_PORT=${TROJAN_PORT:-$(rand_port)}
    TROJAN_PATH=${TROJAN_PATH:-$(rand_hex 8)}
    TROJAN_PASS=${TROJAN_PASS:-$(rand_hex 10)}
    XHTTP_PATH=${XHTTP_PATH:-$(rand_hex 8)}
    REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(rand_hex 8)}
    HUI_PORT=${HUI_PORT:-$(rand_port)}
    HUI_PATH=${HUI_PATH:-$(rand_hex 6)}
    HUI_PASS=${HUI_PASS:-$(rand_hex 10)}
    HY2_OBFS_PASS=${HY2_OBFS_PASS:-$(rand_hex 10)}
    HY2_STATS_PORT=${HY2_STATS_PORT:-$(rand_port)}
    HY2_STATS_SECRET=${HY2_STATS_SECRET:-$(rand_hex 10)}
    MT_SECRET=${MT_SECRET:-$(rand_hex 16)}
    MT_PORT=${MT_PORT:-$(rand_port)}
}
# ── CLI / .env / интерактив ──────────────────────────────────────────────────
usage() {
    cat <<'EOF'
proxy-setup deploy.sh — развёртывание 3x-ui (selfSNI за Nginx), h-ui (Hysteria2) и MTProto.

Использование:
  ./deploy.sh [флаги]

Флаги:
  -d, --domain <домен>            основной домен (сайт-заглушка, панели, WS/XHTTP/Trojan)
  -r, --reality-domain <домен>    домен для VLESS Reality (SNI и dest)
  -e, --email <email>             e-mail для Let's Encrypt
      --ssh-port <порт>           SSH-порт для ufw (по умолчанию определяется автоматически)
      --mt-port <порт>            порт MTProto (TCP, по умолчанию случайный)
      --mt-tag <tag>              тег прокси из @MTProxybot (необязательно)
      --site-dir <путь>           свой каталог сайта-заглушки (index.html обязателен)
      --no-xui                    не устанавливать 3x-ui
      --no-hui                    не устанавливать h-ui / Hysteria2
      --no-mtproto                не устанавливать MTProto
      --no-xhttp                  не создавать inbound VLESS XHTTP
      --force                     согласие на удаление существующей установки
  -y, --yes                       не задавать вопросов (эквивалент --force для wipe)
      --skip-dns-check            не проверять A-записи доменов
      --dry-run                   только отрендерить конфиги в /tmp/proxy-setup-dryrun
      --uninstall                 удалить созданное этим скриптом (по manifest)
      --no-color                  без ANSI-цветов
  -h, --help                      эта справка

Переменные окружения и .env: DOMAIN, REALITY_DOMAIN, LE_EMAIL, SSH_PORT, MT_PORT,
MT_SECRET, MTPROTO_TAG, ENABLE_XUI, ENABLE_HUI, ENABLE_MTPROTO, ENABLE_XHTTP, SITE_DIR.

Установка в одну команду:
  bash <(curl -fsSL https://raw.githubusercontent.com/NikitaDedenev/proxy-setup/main/deploy.sh) \\
       --domain example.com --reality-domain reality.example.com
EOF
}

load_env_file() {
    local env_file
    for env_file in "${SCRIPT_DIR}/.env" "${PWD}/.env"; do
        [[ -f $env_file ]] || continue
        msg_info "Читаю ${env_file}"
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
        break
    done
}

normalize_domain() {
    local d=$1
    d=${d#http://}
    d=${d#https://}
    d=${d%%/*}
    d=${d%.}
    printf '%s' "${d,,}"
}

validate_domain() {
    local d=$1 what=$2
    [[ -n $d ]] || die "${what} не задан"
    if [[ ! $d =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        die "Некорректный ${what}: '${d}'"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) DOMAIN="${2:-}"; shift 2 ;;
            -r|--reality-domain) REALITY_DOMAIN="${2:-}"; shift 2 ;;
            -e|--email) LE_EMAIL="${2:-}"; shift 2 ;;
            --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
            --mt-port) MT_PORT="${2:-}"; shift 2 ;;
            --mt-tag) MTPROTO_TAG="${2:-}"; shift 2 ;;
            --site-dir) SITE_DIR="${2:-}"; shift 2 ;;
            --no-xui) ENABLE_XUI=0; shift ;;
            --no-hui) ENABLE_HUI=0; shift ;;
            --no-mtproto) ENABLE_MTPROTO=0; shift ;;
            --no-xhttp) ENABLE_XHTTP=0; shift ;;
            --force) FORCE=1; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            --no-color) NO_COLOR=1; setup_colors; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Неизвестный аргумент: $1 (см. --help)" ;;
        esac
    done
}

prompt_missing() {
    if [[ -z $DOMAIN ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Основной домен (например example.com): " DOMAIN
        else
            die "Не задан DOMAIN (используйте --domain или .env)"
        fi
    fi
    if [[ -z $REALITY_DOMAIN ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Домен для Reality (например reality.example.com): " REALITY_DOMAIN
        else
            die "Не задан REALITY_DOMAIN (используйте --reality-domain или .env)"
        fi
    fi
    DOMAIN=$(normalize_domain "$DOMAIN")
    REALITY_DOMAIN=$(normalize_domain "$REALITY_DOMAIN")
    validate_domain "$DOMAIN" "DOMAIN"
    validate_domain "$REALITY_DOMAIN" "REALITY_DOMAIN"
    [[ $DOMAIN != "$REALITY_DOMAIN" ]] || die "DOMAIN и REALITY_DOMAIN должны различаться"
}

detect_ssh_port() {
    if [[ -n $SSH_PORT ]]; then
        printf '%s' "$SSH_PORT"
        return 0
    fi
    local port=""
    if cmd_exists sshd; then
        port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    fi
    printf '%s' "${port:-22}"
}
# ── Инвентаризация существующей установки ────────────────────────────────────
collect_inventory() {
    local found=0
    INVENTORY=""

    if [[ -x ${XUI_DIR}/x-ui ]] || [[ -f $XUI_DB ]] || systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        local state="inactive"
        systemctl is-active --quiet x-ui 2>/dev/null && state="active"
        local inbound_count=0
        if [[ -f $XUI_DB ]] && cmd_exists sqlite3; then
            inbound_count=$(sqlite3 "$XUI_DB" 'SELECT COUNT(*) FROM inbounds;' 2>/dev/null || printf '?')
        fi
        INVENTORY+="  - 3x-ui (${state}): ${XUI_DIR}, БД ${XUI_DB}, inbound'ов: ${inbound_count}"$'\n'
        found=1
    fi

    # Nginx считаем «чужой установкой» только если есть реальные vhost'ы
    # (наши или от x-ui-pro), а не дефолтный сайт из пакета nginx.
    if [[ -f "${NGINX_SITES_AVAIL}/${DOMAIN}" ]] \
       || [[ -f "${NGINX_SITES_AVAIL}/${REALITY_DOMAIN}" ]] \
       || [[ -f "${NGINX_STREAM_DIR}/stream.conf" ]] \
       || [[ -f "${NGINX_CONF_D}/00-proxy-setup-maps.conf" ]]; then
        local sites
        # shellcheck disable=SC2012 # имена сайтов формируем сами, пробелов в них нет
        sites=$(ls -m "${NGINX_SITES_ENABLED}" 2>/dev/null | tr -d '\n')
        INVENTORY+="  - nginx: sites-enabled: ${sites:-—}"$'\n'
        found=1
    fi

    if [[ -x ${HUI_DIR}/h-ui ]] || [[ -f $HUI_DB ]] || systemctl list-unit-files 2>/dev/null | grep -q '^h-ui\.service'; then
        INVENTORY+="  - h-ui: ${HUI_DIR}, БД ${HUI_DB}"$'\n'
        found=1
    fi

    if cmd_exists docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'mtproto_proxy'; then
        INVENTORY+="  - docker: контейнер mtproto_proxy"$'\n'
        found=1
    fi

    if [[ -f $STATE_FILE ]]; then
        INVENTORY+="  - state предыдущего запуска: ${STATE_FILE}"$'\n'
        found=1
    fi

    if [[ -d ${LE_DIR} ]]; then
        local le_domains
        le_domains=$(find "${LE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null | sed 's/ $//')
        if [[ -n $le_domains ]]; then
            INVENTORY+="  - сертификаты Let's Encrypt: ${le_domains}"$'\n'
        fi
    fi

    return "$found"
}

confirm_destructive() {
    local found=$1
    if [[ $found -eq 0 ]]; then
        return 0
    fi

    printf '\n%s[!] ВНИМАНИЕ: обнаружена существующая установка%s\n%s\n' \
        "$C_YELLOW" "$C_OFF" "$INVENTORY" >&2
    cat >&2 <<'EOF'
[!] Продолжение УДАЛИТ следующее:
    - сервис и каталоги 3x-ui (/usr/local/x-ui, /etc/x-ui, systemd unit x-ui.service)
    - конфиги nginx, созданные предыдущей установкой (sites/stream/snippets)
    - сервис и данные h-ui (/usr/local/h-ui)
    - контейнер и каталог MTProto (/opt/mtproto)
  Перед удалением будет создан бэкап в /root/proxy-setup/backups/<timestamp>/.
  Сертификаты Let's Encrypt (/etc/letsencrypt) СОХРАНЯЮТСЯ и переиспользуются.
EOF

    if [[ $FORCE -eq 1 ]] || [[ $ASSUME_YES -eq 1 ]]; then
        msg_warn "Продолжаю, так как передан --force/--yes"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Обнаружена существующая установка. Для удаления запустите с --force"
    fi
    local answer=""
    read -r -p "Продолжить и удалить перечисленное? Введите 'yes': " answer
    [[ $answer == "yes" ]] || die "Отменено пользователем"
}
# ── Бэкапы и удаление ────────────────────────────────────────────────────────
backup_all() {
    local ts dir
    ts=$(date +%Y%m%d-%H%M%S)
    dir="${BACKUP_ROOT}/${ts}"
    mkdir -p "$dir"
    chmod 700 "$dir"
    BACKUP_DIR="$dir"

    msg_info "Бэкап существующих данных → ${dir}"

    if [[ -f $XUI_DB ]] && cmd_exists sqlite3; then
        sqlite3 "$XUI_DB" ".backup '${dir}/x-ui.db'" || msg_warn "Не удалось снять копию x-ui.db"
    fi
    if [[ -d /etc/x-ui ]]; then tar czf "${dir}/etc-x-ui.tar.gz" -C /etc x-ui || true; fi
    if [[ -d /etc/nginx ]]; then tar czf "${dir}/etc-nginx.tar.gz" -C /etc nginx || true; fi
    if [[ -d $HUI_DIR ]]; then tar czf "${dir}/usr-local-h-ui.tar.gz" -C /usr/local h-ui || true; fi
    if [[ -d $MTPROTO_DIR ]]; then tar czf "${dir}/opt-mtproto.tar.gz" -C /opt mtproto || true; fi
    if [[ -f $STATE_FILE ]]; then cp -a "$STATE_FILE" "${dir}/state.env" || true; fi
    {
        ss -tulpn 2>/dev/null || true
        ufw status verbose 2>/dev/null || true
        systemctl list-units --type=service --all 2>/dev/null | grep -E 'x-ui|h-ui|nginx|docker' || true
    } >"${dir}/runtime.txt" 2>&1 || true

    # Проверка целостности бэкапа: без неё удалять ничего нельзя.
    local f
    for f in "${dir}"/*.tar.gz; do
        [[ -e $f ]] || continue
        tar -tzf "$f" >/dev/null 2>&1 || die "Повреждён бэкап: $f"
    done
    if [[ -f ${dir}/x-ui.db ]] && cmd_exists sqlite3; then
        local integrity
        integrity=$(sqlite3 "${dir}/x-ui.db" 'PRAGMA integrity_check;' 2>/dev/null || printf 'failed')
        [[ $integrity == "ok" ]] || msg_warn "sqlite integrity_check копии x-ui.db: ${integrity}"
    fi
    msg_ok "Бэкап создан: ${dir}"
}

reset_generated_vars() {
    XUI_USER="" XUI_PASS="" XUI_PORT="" XUI_PATH="" XUI_TOKEN=""
    SUB_PORT="" SUB_PATH="" SUB_JSON_PATH=""
    WS_PORT="" WS_PATH="" TROJAN_PORT="" TROJAN_PATH="" TROJAN_PASS=""
    XHTTP_PATH="" VLESS_UUID="" VLESS_UUID_WS="" VLESS_UUID_XHTTP=""
    REALITY_PRIVATE_KEY="" REALITY_PUBLIC_KEY="" REALITY_SHORT_ID=""
    HUI_PORT="" HUI_PATH="" HUI_PASS="" HY2_OBFS_PASS="" HY2_STATS_SECRET="" HY2_STATS_PORT=""
    MT_SECRET=""
}

wipe_existing() {
    msg_warn "Удаляю существующую установку (бэкап: ${BACKUP_DIR})"

    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        systemctl stop x-ui 2>/dev/null || true
        systemctl disable x-ui 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/x-ui.service
    rm -rf "${XUI_DIR}" "${XUI_DB_DIR}" /usr/bin/x-ui
    rm -f /usr/local/x-ui-linux-*.tar.gz

    if systemctl list-unit-files 2>/dev/null | grep -q '^h-ui\.service'; then
        systemctl stop h-ui 2>/dev/null || true
        systemctl disable h-ui 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/h-ui.service
    rm -rf "${HUI_DIR}"

    if [[ -d $MTPROTO_DIR ]]; then
        if cmd_exists docker; then
            (cd "$MTPROTO_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
            docker rm -f mtproto_proxy >/dev/null 2>&1 || true
        fi
        rm -rf "$MTPROTO_DIR"
    fi

    systemctl stop nginx 2>/dev/null || true
    rm -f "${NGINX_SITES_ENABLED}/default" "${NGINX_SITES_AVAIL}/default"
    rm -f "${NGINX_SITES_ENABLED}/${DOMAIN}" "${NGINX_SITES_AVAIL}/${DOMAIN}"
    rm -f "${NGINX_SITES_ENABLED}/${REALITY_DOMAIN}" "${NGINX_SITES_AVAIL}/${REALITY_DOMAIN}"
    rm -f "${NGINX_SITES_ENABLED}/80.conf" "${NGINX_SITES_AVAIL}/80.conf"
    rm -f "${NGINX_STREAM_DIR}/stream.conf"
    rm -f "${NGINX_CONF_D}/00-proxy-setup-maps.conf"
    rm -f "${NGINX_MODULES_DIR}/50-proxy-setup-stream.conf"
    rm -rf /var/www/subpage

    systemctl daemon-reload

    if [[ -f $STATE_FILE ]]; then
        mv "$STATE_FILE" "${STATE_FILE}.old-$(date +%Y%m%d-%H%M%S)"
    fi
    : >"$MANIFEST"
    reset_generated_vars
    msg_ok "Существующая установка удалена"
}

uninstall_all() {
    need_root
    init_logging
    msg_warn "Удаление proxy-setup по manifest"
    [[ -f $MANIFEST ]] || msg_warn "manifest не найден: ${MANIFEST}"

    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        systemctl disable --now x-ui 2>/dev/null || true
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^h-ui\.service'; then
        systemctl disable --now h-ui 2>/dev/null || true
    fi
    if [[ -d $MTPROTO_DIR ]] && cmd_exists docker; then
        (cd "$MTPROTO_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
        docker rm -f mtproto_proxy >/dev/null 2>&1 || true
    fi

    if [[ -f $MANIFEST ]]; then
        local entry
        while IFS= read -r entry; do
            [[ -n $entry ]] || continue
            rm -rf "$entry" 2>/dev/null || true
        done <"$MANIFEST"
    fi

    rm -f /etc/systemd/system/x-ui.service /etc/systemd/system/h-ui.service
    systemctl daemon-reload
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi

    rm -rf "${XUI_DIR}" "${XUI_DB_DIR}" "${HUI_DIR}" "${MTPROTO_DIR}"
    : >"$MANIFEST"
    msg_ok "Компоненты удалены. Бэкапы и state остались в ${STATE_DIR}"
    msg_info "При необходимости: systemctl disable --now nginx && apt remove nginx-full"
    exit 0
}
# ── Системная обвязка ────────────────────────────────────────────────────────
install_packages() {
    msg_info "Установка пакетов"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local pkgs=(
        curl wget jq bash sudo tar openssl ca-certificates tzdata
        nginx-full libnginx-mod-stream certbot python3-certbot-nginx
        sqlite3 ufw fail2ban socat cron netcat-openbsd
    )
    if [[ $ENABLE_MTPROTO -eq 1 ]]; then
        pkgs+=(docker.io docker-compose-v2)
    fi
    apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
    msg_ok "Пакеты установлены"

    if [[ $ENABLE_MTPROTO -eq 1 ]]; then
        systemctl enable --now docker >/dev/null 2>&1 || die "Не удалось запустить docker"
    fi
}

setup_sysctl() {
    msg_info "Настройка sysctl (BBR + буферы)"
    cat >/etc/sysctl.d/99-proxy-setup.conf <<'EOF'
# Managed by proxy-setup (deploy.sh)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
fs.file-max = 2097152
EOF
    manifest_add /etc/sysctl.d/99-proxy-setup.conf
    sysctl --system >/dev/null 2>&1 || msg_warn "sysctl --system вернул ошибку"
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ $cc == "bbr" ]]; then
        msg_ok "BBR активен"
    else
        msg_warn "BBR не активировался (текущий: ${cc:-?}); модуль tcp_bbr: $(modprobe tcp_bbr 2>&1 || true)"
    fi
}

setup_firewall() {
    msg_info "Настройка ufw (SSH ${SSH_PORT}/tcp, 80/tcp, 443/tcp, 443/udp$([[ $ENABLE_MTPROTO -eq 1 ]] && printf ', %s/tcp' "$MT_PORT"))"
    ufw --force default deny incoming >/dev/null
    ufw --force default allow outgoing >/dev/null
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
    ufw allow 80/tcp comment 'HTTP / ACME' >/dev/null
    ufw allow 443/tcp comment 'HTTPS: nginx + xray reality' >/dev/null
    ufw allow 443/udp comment 'Hysteria2 (h-ui)' >/dev/null
    if [[ $ENABLE_MTPROTO -eq 1 ]]; then
        ufw allow "${MT_PORT}/tcp" comment 'MTProto' >/dev/null
    fi
    ufw --force enable >/dev/null
    msg_ok "ufw настроен"
}

setup_fail2ban() {
    msg_info "Настройка fail2ban (sshd)"
    cat >/etc/fail2ban/jail.local <<EOF
# Managed by proxy-setup (deploy.sh)
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
EOF
    manifest_add /etc/fail2ban/jail.local
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || msg_warn "fail2ban не перезапустился"
    msg_ok "fail2ban настроен"
}

# ── TLS-сертификаты ──────────────────────────────────────────────────────────
cert_valid() {
    local domain=$1
    [[ -f ${LE_DIR}/${domain}/fullchain.pem && -f ${LE_DIR}/${domain}/privkey.pem ]] || return 1
    openssl x509 -checkend 2592000 -noout -in "${LE_DIR}/${domain}/fullchain.pem" >/dev/null 2>&1
}

issue_cert() {
    local domain=$1
    if cert_valid "$domain"; then
        msg_ok "Сертификат ${domain} уже есть и действует > 30 дней"
        return 0
    fi

    msg_info "Выпуск сертификата для ${domain}"
    systemctl stop nginx >/dev/null 2>&1 || true

    local args=(certonly --standalone --non-interactive --agree-tos
                --preferred-challenges http-01 -d "$domain")
    if [[ -n $LE_EMAIL ]]; then
        args+=(-m "$LE_EMAIL")
    else
        args+=(--register-unsafely-without-email)
    fi

    if ! certbot "${args[@]}"; then
        die "certbot не смог выпустить сертификат для ${domain}. Проверьте A-запись и доступность 80/tcp"
    fi
    cert_valid "$domain" || die "Сертификат для ${domain} не найден после выпуска"
    msg_ok "Сертификат ${domain} выпущен"
}

setup_certificates() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/50-proxy-setup.sh"
    mkdir -p "$(dirname "$hook")"
    cat >"$hook" <<'EOF'
#!/bin/sh
# Managed by proxy-setup (deploy.sh)
nginx -t >/dev/null 2>&1 && systemctl reload nginx
systemctl is-active --quiet h-ui && systemctl restart h-ui
exit 0
EOF
    chmod +x "$hook"
    manifest_add "$hook"

    issue_cert "$DOMAIN"
    issue_cert "$REALITY_DOMAIN"

    # Сертификаты выпущены через standalone (порт 80 был свободен до nginx).
    # Для автопродления переключаем renewal на webroot: nginx занимает 80/tcp.
    cert_renewal_use_webroot "$DOMAIN"
    cert_renewal_use_webroot "$REALITY_DOMAIN"

    systemctl enable certbot.timer >/dev/null 2>&1 || true
}

cert_renewal_use_webroot() {
    local domain=$1
    local conf="/etc/letsencrypt/renewal/${domain}.conf"
    [[ -f $conf ]] || return 0
    sed -i 's/^authenticator = .*/authenticator = webroot/' "$conf"
    if ! grep -q '^webroot_path' "$conf"; then
        sed -i "/^\[renewalparams\]/a webroot_path = ${WEBROOT}," "$conf"
    fi
    if ! grep -q '^\[\[webroot_map\]\]' "$conf"; then
        printf '\n[[webroot_map]]\n%s = %s\n' "$domain" "$WEBROOT" >>"$conf"
    fi
}
# ── Сайт-заглушка ────────────────────────────────────────────────────────────
fetch_site_assets() {
    local dest=$1
    local files=(index.html about.html contacts.html privacy.html 404.html
                 style.css favicon.svg robots.txt sitemap.xml)
    local f
    mkdir -p "$dest" || return 1
    for f in "${files[@]}"; do
        if ! curl -fsSL --retry 2 --max-time 30 -o "${dest}/${f}" "${REPO_RAW}/assets/site/${f}"; then
            msg_warn "Не удалось скачать assets/site/${f} с GitHub"
            return 1
        fi
    done
    [[ -s "${dest}/index.html" ]] || return 1
    msg_ok "Шаблон сайта загружен с ${REPO_SLUG}@${REPO_BRANCH}"
    return 0
}

deploy_site() {
    msg_info "Разворачиваю сайт-заглушку в ${WEBROOT}"
    mkdir -p "$WEBROOT"
    find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

    local src=""
    if [[ -n $SITE_DIR ]]; then
        [[ -f ${SITE_DIR}/index.html ]] || die "В ${SITE_DIR} нет index.html"
        src=$SITE_DIR
    elif [[ -d ${SCRIPT_DIR}/assets/site ]]; then
        src="${SCRIPT_DIR}/assets/site"
    else
        msg_info "Локальный assets/site не найден (режим одной команды) — тяну с GitHub"
        if fetch_site_assets "$SITE_CACHE"; then
            src=$SITE_CACHE
        fi
    fi

    if [[ -n $src ]]; then
        cp -a "${src}/." "$WEBROOT/"
        local f
        while IFS= read -r -d '' f; do
            sed -i "s|{{DOMAIN}}|${DOMAIN}|g; s|{{SITE_NAME}}|${DOMAIN}|g; s|{{YEAR}}|$(date +%Y)|g" "$f"
        done < <(find "$WEBROOT" -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' -o -name '*.txt' -o -name '*.xml' \) -print0)
    else
        msg_warn "Шаблон сайта не найден — создаю минимальную страницу"
        cat >"${WEBROOT}/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${DOMAIN}</title></head>
<body><h1>${DOMAIN}</h1><p>Site is under construction.</p></body></html>
EOF
    fi
    chown -R www-data:www-data "$WEBROOT" 2>/dev/null || true
    find "$WEBROOT" -type d -exec chmod 755 {} +
    find "$WEBROOT" -type f -exec chmod 644 {} +
    msg_ok "Сайт-заглушка готова"
}

# ── Nginx: конфигурация ──────────────────────────────────────────────────────
ensure_stream_module() {
    if nginx -V 2>&1 | grep -q -- '--with-stream'; then
        return 0
    fi
    if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]] \
       && ! grep -rqs 'ngx_stream_module' "$NGINX_MODULES_DIR" 2>/dev/null; then
        echo 'load_module modules/ngx_stream_module.so;' >"${NGINX_MODULES_DIR}/50-proxy-setup-stream.conf"
        manifest_add "${NGINX_MODULES_DIR}/50-proxy-setup-stream.conf"
        msg_ok "Подключён модуль ngx_stream_module"
    fi
    nginx -V 2>&1 | grep -q -- '--with-stream' \
        || die "Nginx собран без stream-модуля — установите libnginx-mod-stream"
}

render_nginx() {
    local root=${1:-}
    local cfg="${root}/etc/nginx"

    mkdir -p "${cfg}/conf.d" "${cfg}/sites-available" "${cfg}/stream-enabled"

    cat >"${cfg}/conf.d/00-proxy-setup-maps.conf" <<'EOF'
# Managed by proxy-setup (deploy.sh)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

    cat >"${cfg}/stream-enabled/stream.conf" <<EOF
# Managed by proxy-setup (deploy.sh)
map \$ssl_preread_server_name \$ps_upstream {
    hostnames;
    ${REALITY_DOMAIN}  xray;
    default            www;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream www {
    server 127.0.0.1:7443;
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_protocol on;
    proxy_pass \$ps_upstream;
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
}
EOF

    cat >"${cfg}/sites-available/80.conf" <<EOF
# Managed by proxy-setup (deploy.sh)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${REALITY_DOMAIN};
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    cat >"${cfg}/sites-available/${REALITY_DOMAIN}" <<EOF
# Managed by proxy-setup (deploy.sh) — REALITY destination (selfSNI)
server {
    server_tokens off;
    server_name ${REALITY_DOMAIN};
    server_name_in_redirect off;
    port_in_redirect off;

    listen 9443 ssl http2;
    listen [::]:9443 ssl http2;

    root ${WEBROOT};
    index index.html;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:proxy_setup_reality:10m;
    ssl_session_timeout 1d;
    ssl_certificate     ${LE_DIR}/${REALITY_DOMAIN}/fullchain.pem;
    ssl_certificate_key ${LE_DIR}/${REALITY_DOMAIN}/privkey.pem;

    add_header X-Content-Type-Options nosniff always;

    if (\$host !~* ^(.+\.)?${REALITY_DOMAIN}\$) { return 444; }

    location ~ /\.(?!well-known) { deny all; }
    location / { try_files \$uri \$uri/ =404; }

    error_page 404 /404.html;
}
EOF
    msg_ok "Отрендерены stream/80/reality-конфиги"
    render_nginx_main "${cfg}"
}

render_nginx_main() {
    local cfg=$1
    cat >"${cfg}/sites-available/${DOMAIN}" <<EOF
# Managed by proxy-setup (deploy.sh) — main entry: site + panels + xray transports
server {
    server_tokens off;
    server_name ${DOMAIN};
    server_name_in_redirect off;
    port_in_redirect off;

    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl http2 proxy_protocol;

    root ${WEBROOT};
    index index.html;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:proxy_setup_main:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_certificate     ${LE_DIR}/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${LE_DIR}/${DOMAIN}/privkey.pem;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer-when-downgrade always;

    # Совпадение Host и SNI — иначе рвём соединение (анти-скан).
    if (\$host !~* ^(.+\.)?${DOMAIN}\$) { return 444; }
    if (\$scheme ~* https) { set \$ps_safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${DOMAIN}\$) { set \$ps_safe "\${ps_safe}0"; }
    if (\$ps_safe = 10) { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|;|&&|\\?\\?|0x00|0X00|\\||\\{|\\}|\\[|\\]|<|>|\\.\\.\\.|\\.\\./|///)") { set \$ps_hack 1; }

    # ── 3x-ui panel (только loopback) ──────────────────────────────────────
    location = /${XUI_PATH} { return 301 https://\$host/${XUI_PATH}/; }

    location ^~ /${XUI_PATH}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:${XUI_PORT};
    }

    # ── h-ui panel (только loopback) ───────────────────────────────────────
    # Без отдельного redirect: h-ui сам редиректит /<path>/ → /<path>,
    # поэтому проксируем оба варианта, сохраняя URI.
    location ^~ /${HUI_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:${HUI_PORT};
    }

    # ── Подписки 3x-ui ─────────────────────────────────────────────────────
    location ^~ /${SUB_PATH}/ {
        if (\$ps_hack = 1) { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${SUB_PORT};
    }

    location ^~ /${SUB_JSON_PATH}/ {
        if (\$ps_hack = 1) { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${SUB_PORT};
    }

$(if [[ $ENABLE_XHTTP -eq 1 && $ENABLE_XUI -eq 1 ]]; then cat <<XHTTP
    # ── VLESS XHTTP через unix-сокет Xray ──────────────────────────────────
    location ^~ /${XHTTP_PATH} {
        grpc_pass grpc://unix:${XUI_XHTTP_SOCK};
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Connection "";
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Host \$host;
    }
XHTTP
fi)

    # ── Универсальный форвардер в loopback-порты Xray: /<port>/<path> ──────
    location ~ ^/(?<ps_fwdport>\d+)/(?<ps_fwdpath>.*)\$ {
        if (\$ps_hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        grpc_socket_keepalive on;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        grpc_set_header Connection "";
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$ps_fwdport;
            break;
        }
        proxy_pass http://127.0.0.1:\$ps_fwdport;
    }

    location ~ /\\.(?!well-known) { deny all; }

    location / {
        if (\$ps_hack = 1) { return 404; }
        try_files \$uri \$uri/ =404;
    }

    error_page 404 /404.html;
    error_page 400 401 403 500 502 503 504 =404 /404.html;
}
EOF
}
# ── Применение конфигурации nginx ────────────────────────────────────────────
apply_nginx() {
    msg_info "Применяю конфигурацию nginx"
    ensure_stream_module
    render_nginx ""

    local nginx_backup="${BACKUP_DIR:-$STATE_DIR}/nginx.before-apply.tar.gz"
    tar czf "$nginx_backup" -C /etc nginx 2>/dev/null || true

    if ! grep -q 'BEGIN proxy-setup stream' "$NGINX_CONF"; then
        cat >>"$NGINX_CONF" <<'EOF'

# BEGIN proxy-setup stream
stream {
    include /etc/nginx/stream-enabled/*.conf;
}
# END proxy-setup stream
EOF
    fi

    mkdir -p "$NGINX_STREAM_DIR" "$NGINX_SITES_ENABLED"
    rm -f "${NGINX_SITES_ENABLED}/default" "${NGINX_SITES_AVAIL}/default"
    ln -sfn "${NGINX_SITES_AVAIL}/${DOMAIN}" "${NGINX_SITES_ENABLED}/${DOMAIN}"
    ln -sfn "${NGINX_SITES_AVAIL}/${REALITY_DOMAIN}" "${NGINX_SITES_ENABLED}/${REALITY_DOMAIN}"
    ln -sfn "${NGINX_SITES_AVAIL}/80.conf" "${NGINX_SITES_ENABLED}/80.conf"

    manifest_add "${NGINX_SITES_AVAIL}/${DOMAIN}"
    manifest_add "${NGINX_SITES_ENABLED}/${DOMAIN}"
    manifest_add "${NGINX_SITES_AVAIL}/${REALITY_DOMAIN}"
    manifest_add "${NGINX_SITES_ENABLED}/${REALITY_DOMAIN}"
    manifest_add "${NGINX_SITES_AVAIL}/80.conf"
    manifest_add "${NGINX_SITES_ENABLED}/80.conf"
    manifest_add "${NGINX_STREAM_DIR}/stream.conf"
    manifest_add "${NGINX_CONF_D}/00-proxy-setup-maps.conf"

    if ! nginx -t; then
        msg_err "nginx -t не прошёл — откатываю конфигурацию"
        rm -f "${NGINX_CONF_D}/00-proxy-setup-maps.conf"
        rm -f "${NGINX_STREAM_DIR}/stream.conf"
        systemctl stop nginx 2>/dev/null || true
        if [[ -f $nginx_backup ]]; then
            tar xzf "$nginx_backup" -C /etc
            msg_warn "Конфигурация nginx восстановлена из ${nginx_backup}"
        fi
        die "Проверьте конфигурацию nginx"
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    wait_for_port 443 30 || die "nginx не слушает 443/tcp"
    msg_ok "nginx запущен, 443/tcp за nginx"
}

# ── 3x-ui ────────────────────────────────────────────────────────────────────
xui_latest_version() {
    local tag=""
    tag=$(curl -fsS --max-time 20 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null \
          | jq -r '.tag_name // empty' 2>/dev/null || true)
    tag=${tag#v}
    printf '%s' "${tag:-$XUI_DEFAULT_VERSION}"
}

xui_xray_bin() {
    find "$XUI_DIR/bin" -maxdepth 1 -type f -name 'xray-linux-*' 2>/dev/null | head -1
}

generate_reality_keys() {
    if key_ok "$REALITY_PRIVATE_KEY" && key_ok "$REALITY_PUBLIC_KEY"; then
        msg_info "Reality-ключи уже сохранены в state"
        return 0
    fi
    local bin out
    bin=$(xui_xray_bin)
    [[ -n $bin ]] || die "Не найден бинарник Xray в ${XUI_DIR}/bin"
    out=$("$bin" x25519)
    REALITY_PRIVATE_KEY=$(printf '%s\n' "$out" | awk '/^PrivateKey/{print $2; exit}')
    REALITY_PUBLIC_KEY=$(printf '%s\n' "$out" | awk '/^(Password|PublicKey)/{print $NF; exit}')
    if ! key_ok "$REALITY_PRIVATE_KEY" || ! key_ok "$REALITY_PUBLIC_KEY"; then
        die "Не удалось разобрать вывод x25519: ${out}"
    fi
    save_state
    msg_ok "Сгенерированы Reality-ключи (x25519)"
}

# Ключи x25519 в base64url (43 символа, опционально '='), иначе считаем мусором.
key_ok() {
    [[ $1 =~ ^[A-Za-z0-9_-]{43}=?$ ]]
}

install_xui() {
    local arch version url tmp expected actual
    arch=$(detect_arch)
    version=$(xui_latest_version)

    if [[ -x ${XUI_DIR}/x-ui && $FORCE -eq 0 ]]; then
        local cur=""
        cur=$("${XUI_DIR}/x-ui" -v 2>/dev/null | tr -d 'v' || true)
        if [[ -n $cur ]]; then
            msg_ok "3x-ui уже установлен (${cur}), переустановка не требуется"
            generate_reality_keys
            return 0
        fi
    fi

    msg_info "Установка 3x-ui v${version} (${arch})"
    url="https://github.com/MHSanaei/3x-ui/releases/download/v${version}/x-ui-linux-${arch}.tar.gz"
    tmp=$(mktemp -d)

    curl -fL --retry 3 --max-time 300 -o "${tmp}/x-ui.tar.gz" "$url" \
        || die "Не удалось скачать 3x-ui: ${url}"

    if curl -fsSL --max-time 30 -o "${tmp}/x-ui.tar.gz.sha256" "${url}.sha256" 2>/dev/null; then
        expected=$(awk '{print $1}' "${tmp}/x-ui.tar.gz.sha256")
        actual=$(sha256sum "${tmp}/x-ui.tar.gz" | awk '{print $1}')
        if [[ -n $expected && $expected != "$actual" ]]; then
            rm -rf "$tmp"
            die "sha256 не совпал для ${url}"
        fi
        msg_ok "sha256 архива 3x-ui проверен"
    else
        msg_warn "Файл .sha256 недоступен, пропускаю проверку подписи"
    fi

    tar -xzf "${tmp}/x-ui.tar.gz" -C "$tmp"
    [[ -x "${tmp}/x-ui/x-ui" ]] || { rm -rf "$tmp"; die "Неожиданная структура архива 3x-ui"; }

    systemctl stop x-ui 2>/dev/null || true
    rm -rf "$XUI_DIR"
    mv "${tmp}/x-ui" "$XUI_DIR"
    chmod +x "${XUI_DIR}/x-ui"
    [[ -f ${XUI_DIR}/x-ui.sh ]] && cp -f "${XUI_DIR}/x-ui.sh" /usr/bin/x-ui && chmod +x /usr/bin/x-ui
    if [[ -f ${XUI_DIR}/x-ui.service.debian ]]; then
        cp -f "${XUI_DIR}/x-ui.service.debian" /etc/systemd/system/x-ui.service
    fi
    rm -rf "$tmp"

    systemctl daemon-reload
    # Каталог БД должен существовать ДО первого старта: unit использует
    # ProtectSystem=full + ReadWritePaths=-/etc/x-ui, и отсутствующий путь
    # молча игнорируется systemd (иначе mkdir /etc/x-ui = read-only fs).
    mkdir -p "$XUI_DB_DIR"
    chmod 700 "$XUI_DB_DIR"
    systemctl enable x-ui >/dev/null 2>&1 || true
    manifest_add "$XUI_DIR"
    manifest_add "$XUI_DB_DIR"
    manifest_add "/usr/bin/x-ui"
    manifest_add "/etc/systemd/system/x-ui.service"

    msg_ok "3x-ui v${version} установлен"
    generate_reality_keys
}
configure_xui() {
    msg_info "Первичная инициализация 3x-ui (создание БД)"
    mkdir -p "$XUI_DB_DIR"
    chmod 700 "$XUI_DB_DIR"
    systemctl reset-failed x-ui >/dev/null 2>&1 || true
    systemctl start x-ui >/dev/null 2>&1 || true
    local i=0
    until [[ -f $XUI_DB ]]; do
        sleep 2
        i=$((i + 1))
        if [[ $i -ge 40 ]]; then
            journalctl -u x-ui -n 20 --no-pager || true
            die "3x-ui не создал ${XUI_DB} за 80s"
        fi
    done
    systemctl stop x-ui >/dev/null 2>&1 || true

    msg_info "Настройка панели: порт ${XUI_PORT} (127.0.0.1), путь /${XUI_PATH}"
    "${XUI_DIR}/x-ui" setting \
        -username "$XUI_USER" \
        -password "$XUI_PASS" \
        -port "$XUI_PORT" \
        -webBasePath "/${XUI_PATH}" \
        -listenIP 127.0.0.1

    xui_db_set subEnable true
    xui_db_set subListen 127.0.0.1
    xui_db_set subPort "$SUB_PORT"
    xui_db_set subPath "/${SUB_PATH}/"
    xui_db_set subJsonPath "/${SUB_JSON_PATH}"
    xui_db_set subURI "https://${DOMAIN}/${SUB_PATH}/"
    xui_db_set subJsonURI "https://${DOMAIN}/${SUB_JSON_PATH}/"
    xui_db_set subDomain ""
    xui_db_set subCertFile ""
    xui_db_set subKeyFile ""
    xui_db_set webListen 127.0.0.1
    xui_db_set webDomain ""
    xui_db_set webCertFile ""
    xui_db_set webKeyFile ""

    systemctl start x-ui
    wait_for_http "http://127.0.0.1:${XUI_PORT}/${XUI_PATH}/" 90 \
        || die "Панель 3x-ui не отвечает на 127.0.0.1:${XUI_PORT}/${XUI_PATH}/"
    msg_ok "3x-ui работает: http://127.0.0.1:${XUI_PORT}/${XUI_PATH}/"

    XUI_TOKEN=$("${XUI_DIR}/x-ui" setting -getApiToken -tokenName deploy -tokenScope admin 2>/dev/null \
        | awk -F': *' '/^apiToken:/{print $2; exit}')
    [[ -n $XUI_TOKEN ]] || die "Не удалось получить API-токен 3x-ui"
    msg_ok "API-токен 3x-ui получен"
}

xui_db_set() {
    local key=$1 value=$2
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${key}'; INSERT INTO settings (key,value) VALUES ('${key}','${value}');"
}

xui_api() {
    local method=$1 path=$2 body=${3:-}
    local url="http://127.0.0.1:${XUI_PORT}/${XUI_PATH}/panel/api${path}"
    if [[ -n $body ]]; then
        curl -sS --max-time 60 -X "$method" \
            -H "Authorization: Bearer ${XUI_TOKEN}" \
            -H 'Content-Type: application/json' \
            --data-binary "$body" "$url"
    else
        curl -sS --max-time 60 -X "$method" \
            -H "Authorization: Bearer ${XUI_TOKEN}" "$url"
    fi
}

ensure_inbound() {
    local tag=$1 payload=$2 existing resp
    existing=$(xui_api GET /inbounds/list \
        | jq -r --arg t "$tag" '(.obj // [])[] | select(.tag == $t) | .id' 2>/dev/null | head -1 || true)

    if [[ -n $existing ]]; then
        msg_info "Inbound ${tag} уже существует (id=${existing}), пропускаю"
        return 0
    fi

    resp=$(xui_api POST /inbounds/add "$payload")
    if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
        msg_warn "Не удалось добавить inbound ${tag}: ${resp}"
        return 1
    fi
    msg_ok "Inbound ${tag} создан"
}
xui_inbound_reality() {
    jq -n \
        --arg tag "inbound-reality" \
        --arg remark "reality" \
        --arg uuid "$VLESS_UUID" \
        --arg priv "$REALITY_PRIVATE_KEY" \
        --arg pub "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" \
        --arg sni "$REALITY_DOMAIN" \
        --arg ext "$DOMAIN" \
        '{
            up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0,
            listen: "127.0.0.1", port: 8443, protocol: "vless", tag: $tag,
            settings: ({clients: [{id: $uuid, flow: "xtls-rprx-vision", email: "reality",
                        limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: "",
                        subId: "default", reset: 0}], decryption: "none", fallbacks: []} | tojson),
            streamSettings: ({network: "tcp", security: "reality",
                    externalProxy: [{forceTls: "tls", dest: $ext, port: 443, remark: ""}],
                    realitySettings: {show: false, xver: 0, target: "127.0.0.1:9443",
                        serverNames: [$sni], privateKey: $priv, minClient: "", maxClient: "",
                        maxTimediff: 0, shortIds: [$sid],
                        settings: {publicKey: $pub, fingerprint: "chrome", serverName: "", spiderX: "/"}},
                    tcpSettings: {acceptProxyProtocol: true, header: {type: "none"}}} | tojson),
            sniffing: ({enabled: false, destOverride: ["http", "tls", "quic", "fakedns"],
                    metadataOnly: false, routeOnly: false} | tojson)
        }'
}

xui_inbound_ws() {
    jq -n \
        --arg tag "inbound-${WS_PORT}" \
        --arg remark "ws" \
        --arg uuid "$VLESS_UUID_WS" \
        --arg path "/${WS_PORT}/${WS_PATH}" \
        --arg host "$DOMAIN" \
        --argjson port "$WS_PORT" \
        '{
            up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0,
            listen: "127.0.0.1", port: $port, protocol: "vless", tag: $tag,
            settings: ({clients: [{id: $uuid, flow: "", email: "ws", limitIp: 0, totalGB: 0,
                        expiryTime: 0, enable: true, tgId: "", subId: "default", reset: 0}],
                        decryption: "none", fallbacks: []} | tojson),
            streamSettings: ({network: "ws", security: "none",
                    externalProxy: [{forceTls: "tls", dest: $host, port: 443, remark: ""}],
                    wsSettings: {acceptProxyProtocol: false, path: $path, host: $host, headers: {}}} | tojson),
            sniffing: ({enabled: false, destOverride: ["http", "tls"], metadataOnly: false, routeOnly: false} | tojson)
        }'
}

xui_inbound_trojan() {
    jq -n \
        --arg tag "inbound-${TROJAN_PORT}" \
        --arg remark "trojan-grpc" \
        --arg pass "$TROJAN_PASS" \
        --arg service "/${TROJAN_PORT}/${TROJAN_PATH}" \
        --arg host "$DOMAIN" \
        --argjson port "$TROJAN_PORT" \
        '{
            up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0,
            listen: "127.0.0.1", port: $port, protocol: "trojan", tag: $tag,
            settings: ({clients: [{password: $pass, email: "trojan", limitIp: 0, totalGB: 0,
                        expiryTime: 0, enable: true, tgId: "", subId: "default", reset: 0}],
                        fallbacks: []} | tojson),
            streamSettings: ({network: "grpc", security: "none",
                    externalProxy: [{forceTls: "tls", dest: $host, port: 443, remark: ""}],
                    grpcSettings: {serviceName: $service, authority: $host, multiMode: false}} | tojson),
            sniffing: ({enabled: false, destOverride: ["http", "tls"], metadataOnly: false, routeOnly: false} | tojson)
        }'
}
xui_inbound_xhttp() {
    jq -n \
        --arg tag "inbound-xhttp" \
        --arg remark "xhttp" \
        --arg uuid "$VLESS_UUID_XHTTP" \
        --arg path "/${XHTTP_PATH}" \
        --arg host "$DOMAIN" \
        --arg sock "${XUI_XHTTP_SOCK},0666" \
        '{
            up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0,
            listen: $sock, port: 0, protocol: "vless", tag: $tag,
            settings: ({clients: [{id: $uuid, flow: "", email: "xhttp", limitIp: 0, totalGB: 0,
                        expiryTime: 0, enable: true, tgId: "", subId: "default", reset: 0}],
                        decryption: "none", fallbacks: []} | tojson),
            streamSettings: ({network: "xhttp", security: "none",
                    externalProxy: [{forceTls: "tls", dest: $host, port: 443, remark: ""}],
                    xhttpSettings: {path: $path, host: $host, headers: {},
                        scMaxBufferedPosts: 30, scMaxEachPostBytes: "1000000",
                        noSSEHeader: false, xPaddingBytes: "100-1000", mode: "packet-up"}} | tojson),
            sniffing: ({enabled: true, destOverride: ["http", "tls", "quic", "fakedns"],
                    metadataOnly: false, routeOnly: false} | tojson)
        }'
}

reconcile_reality_inbound() {
    local list id cur_priv cur_pub cur_sni
    list=$(xui_api GET /inbounds/list 2>/dev/null || true)
    id=$(printf '%s' "$list" | jq -r '(.obj // [])[] | select(.tag == "inbound-reality") | .id' 2>/dev/null | head -1 || true)
    [[ -n $id ]] || return 0

    cur_priv=$(printf '%s' "$list" | jq -r '.obj[] | select(.tag == "inbound-reality") | .streamSettings.realitySettings.privateKey // empty' 2>/dev/null || true)
    cur_pub=$(printf '%s' "$list" | jq -r '.obj[] | select(.tag == "inbound-reality") | .streamSettings.realitySettings.settings.publicKey // empty' 2>/dev/null || true)
    cur_sni=$(printf '%s' "$list" | jq -r '.obj[] | select(.tag == "inbound-reality") | .streamSettings.realitySettings.serverNames[0] // empty' 2>/dev/null || true)

    if [[ $cur_priv != "$REALITY_PRIVATE_KEY" || $cur_pub != "$REALITY_PUBLIC_KEY" || $cur_sni != "$REALITY_DOMAIN" ]]; then
        msg_warn "Параметры Reality inbound'а расходятся со state — пересоздаю inbound (id=${id})"
        xui_api POST "/inbounds/del/${id}" >/dev/null 2>&1 || true
    fi
}

create_xui_inbounds() {
    msg_info "Создание inbound'ов 3x-ui через API"
    reconcile_reality_inbound
    ensure_inbound "inbound-reality" "$(xui_inbound_reality)"
    ensure_inbound "inbound-${WS_PORT}" "$(xui_inbound_ws)"
    ensure_inbound "inbound-${TROJAN_PORT}" "$(xui_inbound_trojan)"
    if [[ $ENABLE_XHTTP -eq 1 ]]; then
        ensure_inbound "inbound-xhttp" "$(xui_inbound_xhttp)" \
            || msg_warn "XHTTP inbound не создан — остальные транспорты продолжат работу"
    fi

    systemctl restart x-ui
    wait_for_port "$XUI_PORT" 60 || die "3x-ui не поднялся после создания inbound'ов"

    local xray_bin cfg
    xray_bin=$(xui_xray_bin)
    cfg="${XUI_DIR}/bin/config.json"
    if [[ -n $xray_bin && -f $cfg ]]; then
        if "$xray_bin" run -test -c "$cfg" >/dev/null 2>&1 \
           || "$xray_bin" -test -config "$cfg" >/dev/null 2>&1; then
            msg_ok "Конфигурация Xray прошла проверку (xray -test)"
        else
            die "Xray отверг сгенерированный конфиг ${cfg}"
        fi
    else
        msg_warn "Не удалось проверить конфиг Xray (${cfg})"
    fi
}
# ── h-ui / Hysteria2 ─────────────────────────────────────────────────────────
install_hui() {
    local arch url
    arch=$(detect_arch)

    if [[ -x ${HUI_DIR}/h-ui && $FORCE -eq 0 ]]; then
        msg_ok "h-ui уже установлен, переустановка не требуется"
        return 0
    fi

    msg_info "Установка h-ui (${arch})"
    url=$(curl -fsS --max-time 30 https://api.github.com/repos/jonssonyan/h-ui/releases/latest \
        | jq -r --arg n "h-ui-linux-${arch}" '(.assets // [])[] | select(.name == $n) | .browser_download_url' \
        | head -1 || true)
    [[ -n $url ]] || die "Не удалось найти релиз h-ui для ${arch}"

    mkdir -p "${HUI_DIR}/bin" "${HUI_DIR}/data" "${HUI_DIR}/export" "${HUI_DIR}/logs"
    curl -fL --retry 3 --max-time 300 -o "${HUI_DIR}/h-ui" "$url" || die "Не удалось скачать h-ui"
    chmod +x "${HUI_DIR}/h-ui"

    cat >/etc/systemd/system/h-ui.service <<'EOF'
[Unit]
Description=h-ui Service
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/h-ui/
ExecStart=/usr/local/h-ui/h-ui
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable h-ui >/dev/null 2>&1 || true
    manifest_add "$HUI_DIR"
    manifest_add "/etc/systemd/system/h-ui.service"
    msg_ok "h-ui установлен"
}

hui_db_set() {
    local key=$1 value=$2 esc
    esc=${value//\'/\'\'}
    sqlite3 "$HUI_DB" "INSERT INTO config (key, value) VALUES ('${key}', '${esc}') ON CONFLICT(key) DO UPDATE SET value = excluded.value, update_time = CURRENT_TIMESTAMP;"
}

hui_hysteria_yaml() {
    cat <<EOF
listen: :443
obfs:
    type: salamander
    salamander:
        password: ${HY2_OBFS_PASS}
tls:
    cert: ${LE_DIR}/${DOMAIN}/fullchain.pem
    key: ${LE_DIR}/${DOMAIN}/privkey.pem
    sniGuard: strict
auth:
    type: http
    http:
        url: http://127.0.0.1:${HUI_PORT}/${HUI_PATH}/hui/hysteria2/auth
        insecure: true
trafficStats:
    listen: 127.0.0.1:${HY2_STATS_PORT}
    secret: ${HY2_STATS_SECRET}
masquerade:
    type: proxy
    proxy:
        url: https://${DOMAIN}
        rewriteHost: true
        insecure: false
        xForwarded: false
EOF
}

configure_hui() {
    msg_info "Первичная инициализация h-ui"
    mkdir -p "${HUI_DIR}/bin" "${HUI_DIR}/data" "${HUI_DIR}/logs" "${HUI_DIR}/export"

    # Если предыдущая попытка была прервана на скачивании, файл остаётся
    # неполным/без +x, а h-ui видит, что файл есть, и chmod не повторяет.
    local bin
    bin=$(find "${HUI_DIR}/bin" -maxdepth 1 -name 'hysteria-*' -type f 2>/dev/null | head -1)
    if [[ -n $bin ]] && { [[ ! -x $bin ]] || [[ $(stat -c%s "$bin") -lt 1000000 ]]; }; then
        msg_warn "Найден неполный бинарник Hysteria2 (${bin}) — удаляю, h-ui скачает заново"
        rm -f "$bin"
    fi

    systemctl reset-failed h-ui >/dev/null 2>&1 || true
    systemctl start h-ui >/dev/null 2>&1 || true

    local i=0
    until [[ -f $HUI_DB ]]; do
        sleep 2
        i=$((i + 1))
        [[ $i -ge 40 ]] && die "h-ui не создал ${HUI_DB} за 80s"
    done

    msg_info "Ожидаю загрузку бинарника Hysteria2 (h-ui качает его при старте)"
    i=0
    while :; do
        bin=$(find "${HUI_DIR}/bin" -maxdepth 1 -name 'hysteria-*' -type f 2>/dev/null | head -1)
        if [[ -n $bin && -x $bin ]] && [[ $(stat -c%s "$bin") -gt 1000000 ]]; then
            msg_ok "Бинарник Hysteria2 готов: ${bin}"
            break
        fi
        sleep 3
        i=$((i + 1))
        if [[ $i -ge 100 ]]; then
            msg_warn "Бинарник Hysteria2 не скачался за 300s; продолжаю, h-ui докачает позже"
            break
        fi
    done

    systemctl stop h-ui >/dev/null 2>&1 || true

    local pass_hash jwt
    pass_hash=$(printf '%s' "$HUI_PASS" | sha224sum | awk '{print $1}')

    # h-ui ходит в API Hysteria (online/kick) с секретом JWT_SECRET, поэтому
    # trafficStats.secret в hysteria2.yaml обязан совпадать с JWT_SECRET.
    jwt=$(sqlite3 "$HUI_DB" "SELECT value FROM config WHERE key='JWT_SECRET';")
    if [[ -z $jwt ]]; then
        jwt=$(rand_hex 16)
        hui_db_set JWT_SECRET "$jwt"
    fi
    HY2_STATS_SECRET=$jwt

    hui_db_set H_UI_WEB_PORT "$HUI_PORT"
    hui_db_set H_UI_WEB_CONTEXT "/${HUI_PATH}"
    hui_db_set H_UI_CRT_PATH ""
    hui_db_set H_UI_KEY_PATH ""
    hui_db_set HYSTERIA2_ENABLE "1"
    hui_db_set HYSTERIA2_CONFIG "$(hui_hysteria_yaml)"
    hui_db_set HYSTERIA2_CONFIG_REMARK "443/udp hysteria2"

    sqlite3 "$HUI_DB" "UPDATE account SET pass='${pass_hash}', con_pass='sysadmin.${HUI_PASS}' WHERE username='sysadmin';"

    systemctl reset-failed h-ui >/dev/null 2>&1 || true
    systemctl start h-ui
    if ! wait_for_port "$HUI_PORT" 90; then
        tail -n 20 "${HUI_DIR}/logs/h-ui.log" 2>/dev/null || true
        die "Панель h-ui не слушает 127.0.0.1:${HUI_PORT}"
    fi
    if [[ -f $HUI_HY_CONFIG ]]; then
        msg_ok "Конфиг Hysteria2 записан: ${HUI_HY_CONFIG}"
    else
        msg_warn "h-ui не записал ${HUI_HY_CONFIG}"
    fi
    if wait_for_udp 443 60; then
        msg_ok "Hysteria2 слушает 443/udp"
    else
        msg_warn "443/udp не поднялся — смотрите logs/hysteria2.log в ${HUI_DIR}"
    fi
    msg_ok "h-ui работает: http://127.0.0.1:${HUI_PORT}/${HUI_PATH}/"
}
wait_for_udp() {
    local port=$1 timeout=${2:-60} i=0
    while (( i < timeout )); do
        if ss -Hlun "sport = :${port}" 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ── MTProto (Docker) ────────────────────────────────────────────────────────
install_mtproto() {
    msg_info "Запуск MTProto в Docker (порт ${MT_PORT}/tcp)"
    mkdir -p "${MTPROTO_DIR}/data"

    local tag_line=""
    if [[ -n $MTPROTO_TAG ]]; then
        tag_line="      - TAG=${MTPROTO_TAG}"
    fi

    cat >"${MTPROTO_DIR}/docker-compose.yml" <<EOF
# Managed by proxy-setup (deploy.sh)
services:
  mtproto:
    image: telegrammessenger/proxy:latest
    container_name: mtproto_proxy
    restart: always
    ports:
      - "${MT_PORT}:443"
    environment:
      - SECRET=${MT_SECRET}
      - WORKERS=2
${tag_line}
    volumes:
      - ./data:/data
EOF
    manifest_add "${MTPROTO_DIR}/docker-compose.yml"

    if ! ( cd "$MTPROTO_DIR" && docker compose pull -q >/dev/null 2>&1 ); then
        msg_warn "docker compose pull не удался — использую локальный образ, если он есть"
    fi
    ( cd "$MTPROTO_DIR" && docker compose up -d ) || die "docker compose up не удался"

    local i=0 running=""
    while (( i < 40 )); do
        running=$(docker inspect -f '{{.State.Running}}' mtproto_proxy 2>/dev/null || true)
        [[ $running == "true" ]] && break
        sleep 2
        i=$((i + 1))
    done
    [[ $running == "true" ]] || die "Контейнер mtproto_proxy не запустился (docker logs mtproto_proxy)"
    wait_for_port "$MT_PORT" 30 || msg_warn "Порт ${MT_PORT} ещё не слушается"
    msg_ok "MTProto запущен: ${MT_PORT}/tcp"
}

mtproto_link() {
    # telegrammessenger/proxy печатает ссылку с внутренним портом 443 и без
    # префикса dd, поэтому собираем каноническую ссылку из наших же значений.
    printf 'tg://proxy?server=%s&port=%s&secret=dd%s' "$SERVER_IP" "$MT_PORT" "$MT_SECRET"
}
# ── Ссылки и итоговая сводка ────────────────────────────────────────────────
vless_reality_link() {
    printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#reality-%s' \
        "$VLESS_UUID" "$DOMAIN" "$REALITY_DOMAIN" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$DOMAIN"
}

vless_ws_link() {
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2F%s%%2F%s#ws-%s' \
        "$VLESS_UUID_WS" "$DOMAIN" "$DOMAIN" "$DOMAIN" "$WS_PORT" "$WS_PATH" "$DOMAIN"
}

vless_xhttp_link() {
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%%2F%s&mode=packet-up#xhttp-%s' \
        "$VLESS_UUID_XHTTP" "$DOMAIN" "$DOMAIN" "$DOMAIN" "$XHTTP_PATH" "$DOMAIN"
}

trojan_link() {
    printf 'trojan://%s@%s:443?security=tls&sni=%s&type=grpc&serviceName=%%2F%s%%2F%s#trojan-%s' \
        "$TROJAN_PASS" "$DOMAIN" "$DOMAIN" "$TROJAN_PORT" "$TROJAN_PATH" "$DOMAIN"
}

hy2_link() {
    printf 'hy2://sysadmin.%s@%s:443?sni=%s&obfs=salamander&obfs-password=%s&insecure=0#hysteria2-%s' \
        "$HUI_PASS" "$DOMAIN" "$DOMAIN" "$HY2_OBFS_PASS" "$DOMAIN"
}

print_summary() {
    local body mt_line=""
    local -a sections=()

    sections+=("  Сайт-заглушка : https://${DOMAIN}/  (и https://${REALITY_DOMAIN}/)")

    if [[ $ENABLE_XUI -eq 1 ]]; then
        sections+=("")
        sections+=("  [3x-ui]")
        sections+=("  Панель        : https://${DOMAIN}/${XUI_PATH}/")
        sections+=("  Логин/пароль  : ${XUI_USER} / ${XUI_PASS}")
        sections+=("  Подписка      : https://${DOMAIN}/${SUB_PATH}/default")
        sections+=("")
        sections+=("  VLESS Reality : $(vless_reality_link)")
        sections+=("  VLESS WS      : $(vless_ws_link)")
        if [[ $ENABLE_XHTTP -eq 1 ]]; then
            sections+=("  VLESS XHTTP   : $(vless_xhttp_link)")
        fi
        sections+=("  Trojan gRPC   : $(trojan_link)")
    fi

    if [[ $ENABLE_HUI -eq 1 ]]; then
        sections+=("")
        sections+=("  [h-ui / Hysteria2]")
        sections+=("  Панель        : https://${DOMAIN}/${HUI_PATH}/")
        sections+=("  Логин/пароль  : sysadmin / ${HUI_PASS}")
        sections+=("  Hysteria2     : $(hy2_link)")
    fi

    if [[ $ENABLE_MTPROTO -eq 1 ]]; then
        mt_line=$(mtproto_link)
        sections+=("")
        sections+=("  [MTProto]")
        sections+=("  Ссылка        : ${mt_line}")
        sections+=("  Docker        : ${MTPROTO_DIR} (container mtproto_proxy)")
    fi

    sections+=("")
    sections+=("  Порты         : ${SSH_PORT}/tcp (SSH), 80/tcp, 443/tcp (nginx), 443/udp (hysteria2)$([[ $ENABLE_MTPROTO -eq 1 ]] && printf ', %s/tcp (MTProto)' "$MT_PORT")")
    sections+=("  Панели        : 3x-ui 127.0.0.1:${XUI_PORT}; h-ui :${HUI_PORT} (ufw default-deny); доступ только через nginx")
    sections+=("  Сертификаты   : ${LE_DIR}/${DOMAIN}, ${LE_DIR}/${REALITY_DOMAIN} (certbot renew --dry-run)")
    sections+=("  State         : ${STATE_FILE}")
    sections+=("  Лог           : ${LOG_FILE}")
    sections+=("  Бэкапы        : ${BACKUP_ROOT}")

    body="${C_BOLD}$(printf '=%.0s' {1..78})
 proxy-setup: установка завершена $(date -Is)${C_OFF}
=$(printf '=%.0s' {1..78})
 Сервер        : ${SERVER_IP}
 Домен         : ${DOMAIN}
 Reality-домен : ${REALITY_DOMAIN}
$(printf '%s\n' "${sections[@]}")
$(printf '=%.0s' {1..78})"

    local old_umask
    old_umask=$(umask)
    umask 077
    printf '%s\n' "$body" >"$SUMMARY_FILE"
    umask "$old_umask"
    chmod 600 "$SUMMARY_FILE"
    printf '%s\n' "$body"
    msg_ok "Сводка сохранена: ${SUMMARY_FILE}"
}
# ── Финальные проверки ──────────────────────────────────────────────────────
final_checks() {
    msg_info "Финальные проверки"
    local code

    ss -tulpn | grep -E ':443\b|:80\b' || msg_warn "Порты 443/80 не найдены в ss"

    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/" || true)
    if [[ $code == "200" ]]; then
        msg_ok "https://${DOMAIN}/ → 200 (сайт-заглушка)"
    else
        msg_warn "https://${DOMAIN}/ → ${code:-нет ответа}"
    fi

    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${REALITY_DOMAIN}/" || true)
    if [[ $code == "200" ]]; then
        msg_ok "https://${REALITY_DOMAIN}/ → 200 (REALITY dest)"
    else
        msg_warn "https://${REALITY_DOMAIN}/ → ${code:-нет ответа} (ожидаемо, если Reality отвечает только своим клиентам)"
    fi

    if openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" -brief </dev/null 2>&1 | grep -q 'Verification: OK'; then
        msg_ok "TLS-сертификат ${DOMAIN} валиден"
    else
        msg_warn "Не удалось подтвердить валидность сертификата ${DOMAIN} через openssl s_client"
    fi

    if [[ $ENABLE_XUI -eq 1 ]]; then
        if systemctl is-active --quiet x-ui; then
            msg_ok "x-ui active; inbound'ов: $(xui_api GET /inbounds/list | jq -r '(.obj // []) | length' 2>/dev/null || echo '?')"
        else
            msg_warn "x-ui не активен"
        fi
    fi
    if [[ $ENABLE_HUI -eq 1 ]]; then
        if systemctl is-active --quiet h-ui; then
            msg_ok "h-ui active"
        else
            msg_warn "h-ui не активен"
        fi
        if wait_for_udp 443 5; then
            msg_ok "443/udp слушается (Hysteria2)"
        else
            msg_warn "443/udp не слушается"
        fi
    fi
    if [[ $ENABLE_MTPROTO -eq 1 ]]; then
        if [[ $(docker inspect -f '{{.State.Running}}' mtproto_proxy 2>/dev/null) == "true" ]]; then
            msg_ok "MTProto контейнер работает"
        else
            msg_warn "MTProto контейнер не работает"
        fi
    fi

    if fail2ban-client status sshd >/dev/null 2>&1; then
        msg_ok "fail2ban: jail sshd активен"
    else
        msg_warn "fail2ban: jail sshd не активен"
    fi

    if timeout 180 certbot renew --dry-run --no-random-sleep-on-renew >/dev/null 2>&1; then
        msg_ok "certbot renew --dry-run успешен"
    else
        msg_warn "certbot renew --dry-run не прошёл (проверьте /var/log/letsencrypt/letsencrypt.log)"
    fi
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
        esac
    done

    need_root
    init_logging
    init_lock
    require_ubuntu

    load_state
    load_env_file
    parse_args "$@"

    if [[ $UNINSTALL -eq 1 ]]; then
        uninstall_all
    fi

    prompt_missing
    SSH_PORT=$(detect_ssh_port)
    SERVER_IP=${SERVER_IP:-$(public_ip)}

    if [[ $SKIP_DNS_CHECK -eq 0 ]]; then
        host_resolves_to "$DOMAIN" "$SERVER_IP" \
            || die "A-запись ${DOMAIN} не указывает на ${SERVER_IP} (или используйте --skip-dns-check)"
        host_resolves_to "$REALITY_DOMAIN" "$SERVER_IP" \
            || die "A-запись ${REALITY_DOMAIN} не указывает на ${SERVER_IP} (или используйте --skip-dns-check)"
        msg_ok "DNS: оба домена указывают на ${SERVER_IP}"
    fi

    local found=0 resume=0
    collect_inventory || found=$?
    [[ -f $STATE_FILE ]] && resume=1

    if [[ $resume -eq 1 && $FORCE -eq 0 ]]; then
        msg_info "Найден state предыдущего запуска — продолжаю идемпотентно, без удаления"
        if [[ -n $INVENTORY ]]; then
            printf '%s' "$INVENTORY" | sed 's/^/         /' >&2 || true
        fi
        found=0
    else
        confirm_destructive "$found"
    fi

    if [[ $found -eq 1 ]]; then
        backup_all
        wipe_existing
    fi

    ensure_secrets
    save_state

    if [[ $DRY_RUN -eq 1 ]]; then
        local root="/tmp/proxy-setup-dryrun"
        rm -rf "$root"
        mkdir -p "$root"
        render_nginx "$root"
        msg_ok "Dry-run: конфиги отрендерены в ${root}/etc/nginx"
        exit 0
    fi

    if [[ $ENABLE_XUI -eq 0 && $ENABLE_HUI -eq 0 && $ENABLE_MTPROTO -eq 0 ]]; then
        die "Все компоненты отключены флагами --no-*: нечего устанавливать"
    fi

    install_packages
    setup_sysctl
    setup_firewall
    setup_fail2ban
    setup_certificates
    deploy_site

    if [[ $ENABLE_XUI -eq 1 ]]; then
        install_xui
        configure_xui
        create_xui_inbounds
    fi

    if [[ $ENABLE_HUI -eq 1 ]]; then
        install_hui
        configure_hui
    fi

    if [[ $ENABLE_MTPROTO -eq 1 ]]; then
        install_mtproto
    fi

    apply_nginx
    save_state

    final_checks
    print_summary
    msg_ok "Готово. Все секреты в ${STATE_FILE}, сводка в ${SUMMARY_FILE}"
}

main "$@"
