#!/usr/bin/env bash
# =============================================================================
# Proxy Infrastructure Orchestrator v2
# Supports: VLESS (3x-ui), Hysteria2 (h-ui), MTProto (Docker)
# Target: Ubuntu 22.04 / 24.04
# =============================================================================
set -uo pipefail

# ── Цвета ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

# ── Проверка root ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "Запустите скрипт от root"; exit 1; }

# ── Глобальные переменные (заполняются позже) ──────────────────────────────────
DOMAIN=""
CERT_PATH=""
KEY_PATH=""
XUI_PANEL_PORT=""
XUI_USER="admin"
XUI_PASS="admin"
XUI_BASE_PATH=""
HUI_PORT=8081
HUI_PASS=""
HY2_PORT=443
MTPROTO_PORT=28443
MTPROTO_SECRET=""
VLESS_UUID="1dcc4ae3-0000-0000-0000-000000000000"
VLESS_PUBLIC_KEY=""
INSTALL_XUI=false
INSTALL_HUI=false
INSTALL_MTPROTO=false
META_FILE="/server_meta.txt"

# =============================================================================
# МЕНЮ
# =============================================================================
show_menu() {
    echo -e "\n${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Proxy Infrastructure Orchestrator  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}\n"
    echo "  1) VLESS (3x-ui panel)"
    echo "  2) Hysteria2 (h-ui panel)"
    echo "  3) MTProto (Docker)"
    echo "  4) Установить всё"
    echo ""
    read -rp "Выберите вариант [1-4]: " CHOICE
    case "$CHOICE" in
        1) INSTALL_XUI=true ;;
        2) INSTALL_HUI=true ;;
        3) INSTALL_MTPROTO=true ;;
        4) INSTALL_XUI=true; INSTALL_HUI=true; INSTALL_MTPROTO=true ;;
        *) err "Неверный выбор"; exit 1 ;;
    esac
}

# =============================================================================
# ВВОД ДОМЕНА
# =============================================================================
get_domain() {
    echo ""
    read -rp "Введите домен (например: proxy.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && { err "Домен не может быть пустым"; exit 1; }
    CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    info "Домен: $DOMAIN"
}

# =============================================================================
# ЗАВИСИМОСТИ
# =============================================================================
install_deps() {
    info "Установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        curl jq ufw certbot docker.io docker-compose \
        netcat-openbsd openssl ca-certificates python3 sqlite3 expect
    systemctl enable --now docker
    log "Зависимости установлены"
}

# =============================================================================
# FIREWALL
# =============================================================================
setup_firewall() {
    info "Настройка ufw..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp    comment "SSH"
    ufw allow 80/tcp    comment "HTTP/certbot"
    ufw allow 443/tcp   comment "VLESS/HTTPS"
    $INSTALL_HUI     && ufw allow ${HUI_PORT}/tcp     comment "h-ui panel"
    $INSTALL_MTPROTO && ufw allow ${MTPROTO_PORT}/tcp  comment "MTProto"
    ufw --force enable
    log "Firewall настроен (порт 3x-ui будет открыт после установки)"
}

# =============================================================================
# SSL — выпускаем пока 80 свободен
# =============================================================================
issue_ssl() {
    # Если сертификат уже есть — пропускаем выпуск
    if [[ -f "$CERT_PATH" ]]; then
        log "SSL сертификат уже существует: $CERT_PATH"
        return 0
    fi

    # Ищем сертификат в нестандартных путях (certbot мог сохранить с суффиксом)
    local FOUND
    FOUND=$(find /etc/letsencrypt/live/ -name "fullchain.pem" 2>/dev/null | grep "$DOMAIN" | head -1)
    if [[ -n "$FOUND" ]]; then
        CERT_PATH="$FOUND"
        KEY_PATH="${FOUND/fullchain.pem/privkey.pem}"
        log "Найден существующий сертификат: $CERT_PATH"
        return 0
    fi

    info "Выпуск SSL сертификата для $DOMAIN..."
    systemctl stop nginx apache2 2>/dev/null || true

    if ! certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$DOMAIN" \
        --http-01-port 80; then
        err "certbot завершился с ошибкой"
        err "Если превышен лимит Let's Encrypt (5 сертификатов/7 дней) — подождите до следующего окна"
        err "Или используйте --staging флаг для тестирования"
        exit 1
    fi

    [[ -f "$CERT_PATH" ]] || { err "Сертификат не найден после выпуска"; exit 1; }
    log "SSL сертификат выпущен: $CERT_PATH"
}

# =============================================================================
# УСТАНОВКА 3x-ui
# =============================================================================
install_xui() {
    info "Установка 3x-ui..."

    # Устанавливаем expect если нет
    if ! command -v expect &>/dev/null; then
        apt-get install -y -qq expect
    fi

    # Скачиваем установщик
    local INSTALLER="/tmp/xui_install.sh"
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$INSTALLER"
    chmod +x "$INSTALLER"

    # Запускаем через expect — отвечаем на все вопросы автоматически
    expect -f - <<EXPECT
set timeout 120
spawn bash $INSTALLER
# Вопрос о кастомизации порта — отвечаем n, пусть сам назначит
expect "Would you like to customize the Panel Port settings?"
send "n\r"
# Выбор SSL — используем свой сертификат (вариант 3)
expect "Choose an option"
send "3\r"
expect "Please enter domain name"
send "${DOMAIN}\r"
expect "Input certificate path"
send "${CERT_PATH}\r"
expect "Input private key path"
send "${KEY_PATH}\r"
expect eof
EXPECT

    # Ждём запуска сервиса
    info "Ожидание запуска x-ui..."
    local i=0
    until systemctl is-active --quiet x-ui; do
        sleep 2; ((i++))
        [[ $i -ge 30 ]] && { err "x-ui сервис не запустился за 60 сек"; exit 1; }
    done
    sleep 5

    # Читаем реальный порт и basePath из настроек
    XUI_PANEL_PORT=$(x-ui settings 2>/dev/null | grep -oP 'port: \K[0-9]+' | head -1)
    [[ -z "$XUI_PANEL_PORT" ]] && XUI_PANEL_PORT=2053

    XUI_BASE_PATH=$(x-ui settings 2>/dev/null | grep -oP 'webBasePath: \K\S+' | head -1)
    [[ -z "$XUI_BASE_PATH" ]] && XUI_BASE_PATH="/"
    XUI_BASE_PATH="${XUI_BASE_PATH%/}"
    info "3x-ui панель: порт=$XUI_PANEL_PORT basePath=$XUI_BASE_PATH"
    # Открываем порт
    ufw allow ${XUI_PANEL_PORT}/tcp comment "3x-ui panel"

    # Устанавливаем известные credentials через бинарник напрямую
    XUI_USER="admin"
    XUI_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)
    /usr/local/x-ui/x-ui setting -username "$XUI_USER" -password "$XUI_PASS" 2>/dev/null || true
    systemctl restart x-ui
    sleep 5
    info "Credentials установлены: $XUI_USER / $XUI_PASS"

    configure_xui_inbound "$XUI_BASE_PATH"
}

# ── API: добавление VLESS Reality inbound ─────────────────────────────────────
configure_xui_inbound() {
    local BASE_PATH="${1:-}"
    info "Добавление VLESS inbound через API..."

    # Генерируем реальный X25519 ключ для Reality
    local REALITY_KEY XRAY_OUT
    XRAY_OUT=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519 2>/dev/null)
    REALITY_KEY=$(echo "$XRAY_OUT" | grep -i "private" | awk '{print $NF}')
    VLESS_PUBLIC_KEY=$(echo "$XRAY_OUT" | grep -i "public" | awk '{print $NF}')
    [[ -z "$REALITY_KEY" ]] && { err "Не удалось сгенерировать Reality ключ"; return 1; }
    info "Reality privateKey сгенерирован"

    local BASE="https://127.0.0.1:${XUI_PANEL_PORT}${BASE_PATH}"
    local COOK="/tmp/xui_session.cook"
    local i=0

    # Retry логин — ждём пока веб-сервер поднимется
    local LOGIN_OK=""
    until [[ "$LOGIN_OK" == "true" ]]; do
        LOGIN_OK=$(curl -sk -X POST "${BASE}/login" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=${XUI_USER}&password=${XUI_PASS}" \
            -c "$COOK" -b "$COOK" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('success') else 'false')" 2>/dev/null || echo "false")
        sleep 3; ((i++))
        [[ $i -ge 15 ]] && { err "Не удалось авторизоваться в 3x-ui API (проверьте credentials)"; return 1; }
    done
    log "Авторизация в 3x-ui API успешна"

    # Собираем JSON через python3 — безопасная подстановка ключа без проблем с экранированием
    local PAYLOAD
    PAYLOAD=$(python3 - "$REALITY_KEY" <<'PYEOF'
import sys, json

private_key = sys.argv[1]

settings = json.dumps({
    "clients": [{
        "id": "1dcc4ae3-0000-0000-0000-000000000000",
        "email": "admin",
        "enable": True,
        "expiryTime": 0,
        "limitIp": 0,
        "totalGB": 0,
        "tgId": "",
        "subId": ""
    }],
    "decryption": "none",
    "fallbacks": []
})

stream_settings = json.dumps({
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
        "show": False,
        "dest": "google.com:443",
        "serverNames": ["google.com"],
        "privateKey": private_key,
        "shortIds": ["6f", "a1b2c3d4"]
    },
    "tcpSettings": {
        "header": {"type": "none"}
    }
})

sniffing = json.dumps({
    "enabled": True,
    "destOverride": ["http", "tls"]
})

payload = {
    "enable": True,
    "remark": "VLESS_443",
    "listen": "",
    "port": 443,
    "protocol": "vless",
    "expiryTime": 0,
    "settings": settings,
    "streamSettings": stream_settings,
    "sniffing": sniffing
}

print(json.dumps(payload))
PYEOF
)

    local RESP
    RESP=$(curl -sk -X POST "${BASE}/panel/api/inbounds/add" \
        -c "$COOK" -b "$COOK" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('success') else 1)" 2>/dev/null; then
        log "VLESS Reality inbound добавлен на порт 443"
        # Перезапускаем xray чтобы применить конфиг
        systemctl restart x-ui
        sleep 5
    else
        warn "Ответ API: $RESP"
        warn "Inbound не добавлен — настройте вручную через панель"
    fi
    rm -f "$COOK"
}

# =============================================================================
# УСТАНОВКА h-ui (Hysteria2)
# =============================================================================
install_hui() {
    info "Установка h-ui (Hysteria2)..."

    mkdir -p /usr/local/h-ui/{bin,data,export,logs}

    local ARCH; ARCH=$(uname -m)
    local HUI_BIN="h-ui-linux-amd64"
    [[ "$ARCH" == "aarch64" ]] && HUI_BIN="h-ui-linux-arm64"

    local HUI_URL
    HUI_URL=$(curl -s https://api.github.com/repos/jonssonyan/h-ui/releases/latest \
        | python3 -c "import sys,json; assets=json.load(sys.stdin)['assets']; \
          [print(a['browser_download_url']) for a in assets if a['name']=='${HUI_BIN}']" \
        | head -1)

    if [[ -z "$HUI_URL" ]]; then
        err "Не удалось получить URL h-ui из GitHub API"
        return 1
    fi

    curl -L "$HUI_URL" -o /usr/local/h-ui/h-ui
    chmod +x /usr/local/h-ui/h-ui

    cat > /etc/systemd/system/h-ui.service <<EOF
[Unit]
Description=h-ui Hysteria2 Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/h-ui
ExecStart=/usr/local/h-ui/h-ui -p ${HUI_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now h-ui

    # Ждём старта и создания БД
    local i=0
    until nc -z 127.0.0.1 "$HUI_PORT" 2>/dev/null; do
        sleep 3; ((i++))
        [[ $i -ge 20 ]] && { warn "h-ui не ответил за 60 сек"; break; }
    done
    sleep 2

    configure_hui_db
    log "h-ui установлен на порту $HUI_PORT"
}

# ── Настройка h-ui через SQLite ───────────────────────────────────────────────
configure_hui_db() {
    local DB="/usr/local/h-ui/data/h_ui.db"
    local i=0

    # Ждём появления БД
    until [[ -f "$DB" ]]; do
        sleep 2; ((i++))
        [[ $i -ge 15 ]] && { warn "h-ui БД не появилась, пропускаем настройку"; return 1; }
    done

    # Генерируем пароль для панели (SHA-224 — формат h-ui)
    HUI_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local HUI_PASS_HASH
    HUI_PASS_HASH=$(echo -n "$HUI_PASS" | sha224sum | awk '{print $1}')

    # Hysteria2 порт — если VLESS уже занял 443, используем 8443
    HY2_PORT=443
    $INSTALL_XUI && HY2_PORT=8443

    local HY2_STATS_SECRET
    HY2_STATS_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

    # Конфиг записывается как строка в поле HYSTERIA2_CONFIG
    local HY2_CONFIG
    HY2_CONFIG="listen: :${HY2_PORT}
tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}
auth:
  type: http
  http:
    url: http://127.0.0.1:${HUI_PORT}/hui/hysteria2/auth
    insecure: false
bandwidth:
  up: 200 mbps
  down: 200 mbps
ignoreClientBandwidth: false
trafficStats:
  listen: :9999
  secret: ${HY2_STATS_SECRET}"

    systemctl stop h-ui

    # Экранируем одинарные кавычки для SQLite
    local HY2_CONFIG_ESC="${HY2_CONFIG//\'/\'\'}"

    sqlite3 "$DB" "UPDATE account SET pass='${HUI_PASS_HASH}' WHERE username='sysadmin';"
    sqlite3 "$DB" "UPDATE config SET value='${CERT_PATH}' WHERE key='H_UI_CRT_PATH';"
    sqlite3 "$DB" "UPDATE config SET value='${KEY_PATH}'  WHERE key='H_UI_KEY_PATH';"
    sqlite3 "$DB" "UPDATE config SET value='1'            WHERE key='HYSTERIA2_ENABLE';"
    sqlite3 "$DB" "UPDATE config SET value='${HY2_CONFIG_ESC}' WHERE key='HYSTERIA2_CONFIG';"

    systemctl start h-ui
    sleep 3
    info "h-ui настроен: sysadmin / $HUI_PASS, Hysteria2 порт: $HY2_PORT"
}

# =============================================================================
# УСТАНОВКА MTProto (Docker)
# =============================================================================
install_mtproto() {
    info "Установка MTProto proxy (Docker)..."

    MTPROTO_SECRET=$(openssl rand -hex 16)
    mkdir -p /opt/mtproto

    cat > /opt/mtproto/docker-compose.yml <<EOF
version: '3.8'
services:
  mtproto:
    image: telegrammessenger/proxy:latest
    container_name: mtproto_proxy
    restart: always
    ports:
      - "${MTPROTO_PORT}:443"
    environment:
      - SECRET=${MTPROTO_SECRET}
    volumes:
      - mtproto_data:/data

volumes:
  mtproto_data:
EOF

    cd /opt/mtproto
    docker-compose pull
    docker-compose up -d

    local i=0
    until docker ps --filter "name=mtproto_proxy" --filter "status=running" | grep -q mtproto_proxy; do
        sleep 3; ((i++))
        [[ $i -ge 20 ]] && { err "MTProto контейнер не запустился"; return 1; }
    done
    log "MTProto запущен на порту $MTPROTO_PORT, secret: $MTPROTO_SECRET"
}

# =============================================================================
# ПРОВЕРКА ПОРТОВ
# =============================================================================
check_ports() {
    info "Проверка портов..."
    echo ""
    _chk() {
        if nc -z -w3 127.0.0.1 "$1" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $1 ($2)"
        else
            echo -e "  ${RED}✗${NC} $1 ($2) — не отвечает"
        fi
    }
    _chk 22 "SSH"
    $INSTALL_XUI     && _chk 443 "VLESS"
    $INSTALL_XUI     && [[ -n "$XUI_PANEL_PORT" ]] && _chk "$XUI_PANEL_PORT" "3x-ui panel"
    $INSTALL_HUI     && _chk "$HUI_PORT" "h-ui panel"
    $INSTALL_MTPROTO && _chk "$MTPROTO_PORT" "MTProto"
    echo ""
}

# =============================================================================
# SUMMARY
# =============================================================================
generate_summary() {
    local SERVER_IP
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    cat > "$META_FILE" <<EOF
═══════════════════════════════════════════════════════
         SERVER PROXY CONFIGURATION SUMMARY
═══════════════════════════════════════════════════════
Дата установки : $(date '+%Y-%m-%d %H:%M:%S')
Домен          : ${DOMAIN}
IP сервера     : ${SERVER_IP}
SSL сертификат : /etc/letsencrypt/live/${DOMAIN}/

───────────────────────────────────────────────────────
EOF

    if $INSTALL_XUI; then
        local SERVER_IP_XUI="$SERVER_IP"
        local VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP_XUI}:443?encryption=none&security=reality&sni=google.com&fp=chrome&pbk=${VLESS_PUBLIC_KEY}&sid=6f&type=tcp&flow=#VLESS-Reality-${SERVER_IP_XUI}"
        cat >> "$META_FILE" <<EOF
[VLESS / 3x-ui]
  Панель URL   : https://${SERVER_IP}:${XUI_PANEL_PORT}${XUI_BASE_PATH}
  Логин        : ${XUI_USER}
  Пароль       : ${XUI_PASS}
  VLESS порт   : 443 (Reality / TCP)
  UUID клиента : ${VLESS_UUID}
  PublicKey    : ${VLESS_PUBLIC_KEY}
  SNI          : google.com
  Ссылка       : ${VLESS_LINK}

───────────────────────────────────────────────────────
EOF
        echo -e "\n${CYAN}VLESS ссылка:${NC}"
        echo "$VLESS_LINK"
    fi

    if $INSTALL_HUI; then
        cat >> "$META_FILE" <<EOF
[Hysteria2 / h-ui]
  Панель URL   : https://${DOMAIN}:${HUI_PORT}
  Логин        : sysadmin
  Пароль       : ${HUI_PASS}
  Hysteria2    : порт ${HY2_PORT:-8443}
  Cert         : ${CERT_PATH}
  Key          : ${KEY_PATH}

───────────────────────────────────────────────────────
EOF
    fi

    if $INSTALL_MTPROTO; then
        local MTPROTO_LINK="tg://proxy?server=${SERVER_IP}&port=${MTPROTO_PORT}&secret=${MTPROTO_SECRET}"
        cat >> "$META_FILE" <<EOF
[MTProto Proxy]
  Сервер       : ${SERVER_IP}:${MTPROTO_PORT}
  Secret       : ${MTPROTO_SECRET}
  Ссылка       : ${MTPROTO_LINK}
  Docker dir   : /opt/mtproto/

───────────────────────────────────────────────────────
EOF
    fi

    # Порты
    {
        echo "[Занятые порты]"
        echo "  22    — SSH"
        echo "  80    — HTTP (certbot renewal)"
        $INSTALL_XUI     && echo "  443   — VLESS Reality"
        $INSTALL_XUI     && [[ -n "$XUI_PANEL_PORT" ]] && echo "  ${XUI_PANEL_PORT}  — 3x-ui панель"
        $INSTALL_HUI     && echo "  ${HUI_PORT}   — h-ui панель (Hysteria2)"
        $INSTALL_MTPROTO && echo "  ${MTPROTO_PORT} — MTProto Telegram Proxy"
        echo ""
        echo "═══════════════════════════════════════════════════════"
    } >> "$META_FILE"

    echo ""
    cat "$META_FILE"
    echo -e "${GREEN}Summary сохранён: ${META_FILE}${NC}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    show_menu
    get_domain
    install_deps
    setup_firewall
    issue_ssl

    $INSTALL_XUI     && install_xui
    $INSTALL_HUI     && install_hui
    $INSTALL_MTPROTO && install_mtproto

    info "Ожидание применения конфигурации xray (10 сек)..."
    sleep 10
    check_ports
    generate_summary
}

main "$@"
