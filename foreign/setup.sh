#!/bin/bash

set -euo pipefail

# НАСТРОЙКИ
DOMAIN="your-domain.com"
EMAIL="your@email.com"
CADDY_HTTPS_PORT="8443"
CADDY_HTTP_PORT="8080"
CERT_RENEW_DAYS="14"

# ПУТИ
ACME_HOME="/root/.acme.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
COMMON_DIR="$SCRIPT_DIR/../common"
STUB_DIR="/var/www/stub"
CERT_DIR="/etc/ssl/xray"
XRAY_DIR="/usr/local/etc/xray"
CADDYFILE="/etc/caddy/Caddyfile"
LOG_DIR_XRAY="/var/log/xray"
LOG_DIR_CADDY="/var/log/caddy"
CERT_RENEW_SCRIPT="$XRAY_DIR/cert-renew.sh"
CERT_CHECK_SCRIPT="$XRAY_DIR/cert-check.sh"

# функции вывода информации
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
die()     { error "$*"; exit 1; }

# ─── Система тегов ───
# Все доступные теги и их описания
declare -A TAG_DESC=(
    [deps]="Установка системных пакетов, Xray, Caddy, acme.sh"
    [ufw]="Настройка firewall (ufw)"
    [dns]="Проверка DNS-записи домена"
    [ports]="Проверка что порты 80/443 свободны"
    [dirs]="Создание рабочих директорий"
    [cert]="Выпуск/обновление TLS-сертификата"
    [xray]="Генерация конфига Xray (REALITY-ключи, UUID)"
    [caddy]="Запись Caddyfile"
    [cron]="Настройка cron для обновления сертификата"
    [stub]="Копирование сайта-заглушки"
    [fail2ban]="Настройка fail2ban"
    [logrotate]="Настройка logrotate для логов"
    [systemd]="Systemd override для автоперезапуска Xray"
    [restart]="Перезапуск сервисов (caddy, xray)"
    [summary]="Вывод итоговой информации и строки подключения"
)

# Теги, запрошенные через --tags (пусто = запускать всё)
RUN_TAGS=()

# Проверяет, нужно ли выполнять шаг с данным тегом
should_run() {
    local tag="$1"
    # Если теги не указаны — запускаем всё
    [[ ${#RUN_TAGS[@]} -eq 0 ]] && return 0
    local t
    for t in "${RUN_TAGS[@]}"; do
        [[ "$t" == "$tag" ]] && return 0
    done
    return 1
}

# Обёртка: выполняет функцию, если её тег активен, иначе пропускает
step() {
    local tag="$1" fn="$2"
    if should_run "$tag"; then
        "$fn"
    else
        info "Пропуск [$tag] — ${TAG_DESC[$tag]:-$fn}"
    fi
}

usage() {
    echo "Использование: $0 [--tags tag1,tag2,...] [--list-tags]"
    echo ""
    echo "Без --tags выполняются все шаги."
    echo ""
    echo "Опции:"
    echo "  --tags tag1,tag2   Выполнить только указанные шаги"
    echo "  --list-tags        Показать доступные теги и выйти"
    echo "  --help             Показать эту справку"
    exit 0
}

list_tags() {
    echo "Доступные теги:"
    echo ""
    # Порядок шагов в main
    local ordered_tags=(deps ufw dns ports dirs cert xray caddy cron stub fail2ban logrotate systemd restart summary)
    for tag in "${ordered_tags[@]}"; do
        printf "  %-12s %s\n" "$tag" "${TAG_DESC[$tag]}"
    done
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tags)
                [[ -z "${2:-}" ]] && die "--tags требует аргумент (например: --tags cert,xray,restart)"
                IFS=',' read -ra RUN_TAGS <<< "$2"
                # Валидация тегов
                for t in "${RUN_TAGS[@]}"; do
                    [[ -z "${TAG_DESC[$t]+x}" ]] && die "Неизвестный тег: $t (используйте --list-tags)"
                done
                shift 2
                ;;
            --list-tags) list_tags ;;
            --help|-h)   usage ;;
            *)           die "Неизвестный аргумент: $1 (используйте --help)" ;;
        esac
    done
}

# Подставляет {{ПЕРЕМЕННАЯ}} в шаблоне и записывает результат в файл
render_template() {
    local src="$1" dst="$2"
    sed \
        -e "s|{{DOMAIN}}|$DOMAIN|g" \
        -e "s|{{EMAIL}}|$EMAIL|g" \
        -e "s|{{CADDY_HTTPS_PORT}}|$CADDY_HTTPS_PORT|g" \
        -e "s|{{CADDY_HTTP_PORT}}|$CADDY_HTTP_PORT|g" \
        -e "s|{{CERT_RENEW_DAYS}}|$CERT_RENEW_DAYS|g" \
        -e "s|{{STUB_DIR}}|$STUB_DIR|g" \
        -e "s|{{CERT_DIR}}|$CERT_DIR|g" \
        -e "s|{{XRAY_DIR}}|$XRAY_DIR|g" \
        -e "s|{{LOG_DIR_XRAY}}|$LOG_DIR_XRAY|g" \
        -e "s|{{LOG_DIR_CADDY}}|$LOG_DIR_CADDY|g" \
        -e "s|{{CERT_RENEW_SCRIPT}}|$CERT_RENEW_SCRIPT|g" \
        -e "s|{{CERT_CHECK_SCRIPT}}|$CERT_CHECK_SCRIPT|g" \
        -e "s|{{ACME_HOME}}|$ACME_HOME|g" \
        -e "s|{{UUID}}|$UUID|g" \
        -e "s|{{PRIVATE_KEY}}|$PRIVATE_KEY|g" \
        -e "s|{{PUBLIC_KEY}}|$PUBLIC_KEY|g" \
        -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
        "$src" > "$dst"
}

# проверка прав запуска
require_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите скрипт от root: sudo $0"
}

# проверка что настройки заполнены
validate_settings() {
    info "Проверка настроек..."
    [[ "$DOMAIN" == "your-domain.com" ]] && die "Задайте DOMAIN в начале setup.sh"
    [[ "$EMAIL"  == "your@email.com"  ]] && die "Задайте EMAIL в начале setup.sh"
    [[ "$DOMAIN" =~ \. ]]               || die "DOMAIN выглядит некорректно: $DOMAIN"
    success "Настройки корректны"
}

# Установка системных пакетов
install_packages() {
    info "Обновление списка пакетов..."
    apt-get update -qq

    local pkgs=(curl wget openssl cron ufw fail2ban logrotate)
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Установка пакетов: ${to_install[*]}..."
        apt-get install -y "${to_install[@]}"
        success "Пакеты установлены"
    else
        success "Все системные пакеты уже установлены"
    fi
}

# Установка Xray
install_xray() {
    if command -v xray &>/dev/null; then
        success "Xray уже установлен: $(xray version | head -1)"
        return
    fi
    info "Установка Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    command -v xray &>/dev/null || die "Не удалось установить Xray"
    success "Xray установлен: $(xray version | head -1)"
}

# Установка Caddy
install_caddy() {
    if command -v caddy &>/dev/null; then
        success "Caddy уже установлен: $(caddy version)"
        return
    fi
    info "Установка Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list

    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list

    apt-get update -qq
    apt-get install -y caddy
    command -v caddy &>/dev/null || die "Не удалось установить Caddy"
    success "Caddy установлен: $(caddy version)"
}

# Установка acme.sh
install_acme() {
    if [[ -f "$ACME_HOME/acme.sh" ]]; then
        success "acme.sh уже установлен"
        return
    fi
    info "Установка acme.sh..."
    curl https://get.acme.sh | sh -s email="$EMAIL"
    [[ -f "$ACME_HOME/acme.sh" ]] || die "Не удалось установить acme.sh (ожидался $ACME_HOME/acme.sh)"
    success "acme.sh установлен"
}

# Установка всех зависимостей
install_dependencies() {
    info "Проверка и установка зависимостей..."
    [[ -d "$TEMPLATES_DIR" ]] || die "Папка foreign/templates не найдена ($TEMPLATES_DIR)"
    [[ -d "$COMMON_DIR" ]]    || die "Папка common не найдена ($COMMON_DIR)"
    install_packages
    install_xray
    install_caddy
    install_acme
    success "Все зависимости готовы"
}

# Настройка firewall (ufw)
setup_ufw() {
    info "Настройка ufw..."
    ufw default deny incoming  2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    # SSH — чтобы не потерять доступ
    ufw allow 22/tcp   2>/dev/null || true
    # HTTP — для выпуска/обновления сертификата
    ufw allow 80/tcp   2>/dev/null || true
    # HTTPS — основной порт Xray
    ufw allow 443/tcp  2>/dev/null || true
    # Включаем ufw без интерактивного подтверждения
    echo "y" | ufw enable 2>/dev/null || true
    success "ufw настроен (22, 80, 443)"
}

# Проверка DNS — домен должен резолвиться до выпуска сертификата
check_dns() {
    info "Проверка DNS для $DOMAIN..."
    local domain_ip
    domain_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1) || true
    [[ -z "$domain_ip" ]] && die "DNS: домен $DOMAIN не разрешается. Проверьте A-запись и повторите."
    success "DNS OK: $DOMAIN → $domain_ip"
}

# Проверка валидности существующего сертификата
cert_is_valid() {
    local cert="$CERT_DIR/fullchain.pem"
    [[ -f "$cert" ]] || return 1
    [[ -f "$CERT_DIR/key.pem" ]] || return 1

    local expiry days_left
    expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/notAfter=//') || return 1
    days_left=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))

    if [[ "$days_left" -gt "$CERT_RENEW_DAYS" ]]; then
        info "Сертификат валиден ещё $days_left дней (порог: $CERT_RENEW_DAYS) — пропускаем выпуск"
        return 0
    fi
    info "Сертификат истекает через $days_left дней (порог: $CERT_RENEW_DAYS) — требуется обновление"
    return 1
}

# Выпуск сертификата
issue_certificate() {
    info "Проверка сертификата для $DOMAIN..."

    mkdir -p "$CERT_DIR"

    if cert_is_valid; then
        success "Сертификат актуален — выпуск не требуется"
        return
    fi

    # Останавливаем сервисы, которые могут занимать порт 80/443
    systemctl stop caddy 2>/dev/null || true
    systemctl stop xray  2>/dev/null || true

    if "$ACME_HOME/acme.sh" --list | grep -q "$DOMAIN"; then
        info "Сертификат в acme.sh найден — обновляем"
        "$ACME_HOME/acme.sh" --renew --standalone -d "$DOMAIN" --httpport 80 --force
    else
        info "Первый выпуск сертификата..."
        "$ACME_HOME/acme.sh" --issue --standalone -d "$DOMAIN" --httpport 80
    fi

    "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
        --cert-file      "$CERT_DIR/cert.pem" \
        --key-file       "$CERT_DIR/key.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd      "systemctl restart xray && systemctl restart caddy"

    chown root:caddy "$CERT_DIR"
    chmod 750 "$CERT_DIR"
    chown root:caddy "$CERT_DIR"/*.pem
    chmod 640 "$CERT_DIR"/*.pem
    success "Сертификат установлен в $CERT_DIR"
}

# Подготовка скриптов обновления сертификата
write_cert_scripts() {
    info "Запись скриптов обновления сертификата..."
    render_template "$TEMPLATES_DIR/cert-renew.sh" "$CERT_RENEW_SCRIPT"
    render_template "$TEMPLATES_DIR/cert-check.sh" "$CERT_CHECK_SCRIPT"
    chmod +x "$CERT_RENEW_SCRIPT" "$CERT_CHECK_SCRIPT"
    success "Скрипты обновления записаны"
}

# Создание cron-задачи обновления сертификата
write_cron() {
    info "Настройка cron..."
    render_template "$TEMPLATES_DIR/xray-cert.cron" "/etc/cron.d/xray-cert"
    # cron игнорирует файлы без прав 644, принадлежащие не root
    chmod 644 /etc/cron.d/xray-cert
    success "Cron задача записана"
}

# Настройка Caddy
write_caddyfile() {
    info "Запись $CADDYFILE..."
    render_template "$TEMPLATES_DIR/Caddyfile" "$CADDYFILE"
    success "Записан $CADDYFILE"
}

# Настройка Xray — UUID сохраняется при повторном запуске
write_xray_config() {
    info "Генерация конфига Xray..."
    if [[ -f "$XRAY_DIR/config.json" ]]; then
        UUID=$(sed -n 's/.*"id"\s*:\s*"\([0-9a-f-]\+\)".*/\1/p' "$XRAY_DIR/config.json" | head -1)
        [[ -z "$UUID" ]] && die "Не удалось извлечь UUID из существующего конфига $XRAY_DIR/config.json"
        info "Используем существующий UUID: $UUID"

        PRIVATE_KEY=$(sed -n 's/.*"privateKey"\s*:\s*"\([^"]\+\)".*/\1/p' "$XRAY_DIR/config.json" | head -1)
        SHORT_ID=$(sed -n 's/.*"shortIds"\s*:\s*\["",\s*"\([^"]\+\)".*/\1/p' "$XRAY_DIR/config.json" | head -1)
    else
        UUID=$(xray uuid)
        info "Сгенерирован новый UUID: $UUID"

        PRIVATE_KEY=""
        SHORT_ID=""
    fi

    # Генерация REALITY-ключей (если ещё нет)
    if [[ -z "${PRIVATE_KEY:-}" ]]; then
        local key_pair
        key_pair=$(xray x25519 2>&1)
        PRIVATE_KEY=$(echo "$key_pair" | awk '/PrivateKey:/{print $NF}')
        PUBLIC_KEY=$(echo "$key_pair" | awk '/Password:/{print $NF}')
        [[ -z "$PRIVATE_KEY" ]] && die "Не удалось извлечь Private key из вывода xray x25519: $key_pair"
        [[ -z "$PUBLIC_KEY" ]]  && die "Не удалось извлечь Public key из вывода xray x25519: $key_pair"
        info "Сгенерированы REALITY-ключи"
    else
        # Восстанавливаем публичный ключ из приватного
        PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>&1 | awk '/Password:/{print $NF}')
        [[ -z "$PUBLIC_KEY" ]] && die "Не удалось восстановить Public key из Private key"
        info "Используем существующие REALITY-ключи: PUBLIC $PUBLIC_KEY PRIVATE $PRIVATE_KEY"
    fi

    if [[ -z "${SHORT_ID:-}" ]]; then
        SHORT_ID=$(openssl rand -hex 8)
        info "Сгенерирован Short ID: $SHORT_ID"
    else
        info "Используем существующий Short ID: $SHORT_ID"
    fi
    render_template "$TEMPLATES_DIR/xray-config.json" "$XRAY_DIR/config.json"
    chmod 600 "$XRAY_DIR/config.json"
    success "Конфиг Xray записан (UUID: $UUID)"
}

# Копирование сайта-заглушки (если в STUB_DIR нет index.html)
write_stub_site() {
    if [[ ! -f "$STUB_DIR/index.html" ]]; then
        info "Копируем сайт-заглушку из шаблонов в $STUB_DIR..."
        cp "$TEMPLATES_DIR/index.html" "$STUB_DIR/index.html"
        success "index.html скопирован в $STUB_DIR"
    else
        info "Сайт-заглушка уже существует в $STUB_DIR — пропускаем"
    fi
}

# Настройка fail2ban (из common)
write_fail2ban() {
    info "Настройка fail2ban..."
    cp "$COMMON_DIR/jail.local" /etc/fail2ban/jail.local
    chmod 644 /etc/fail2ban/jail.local
    systemctl enable --now fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    success "fail2ban настроен"
}

# Настройка logrotate для логов Xray (из common)
write_logrotate() {
    info "Настройка logrotate для Xray..."
    render_template "$COMMON_DIR/xray.logrotate" "/etc/logrotate.d/xray"
    chmod 644 /etc/logrotate.d/xray
    success "logrotate конфиг записан"
}

# systemd override — Xray автоматически перезапускается при падении
write_systemd_override() {
    info "Настройка systemd override для xray..."
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
    systemctl daemon-reload
    success "systemd override записан"
}

# Рестарт Сервисов
restart_services() {
    for svc in caddy xray; do
        info "Перезапуск $svc..."
        systemctl stop "$svc" 2>/dev/null || true
        systemctl enable --now "$svc"
        success "$svc запущен"
    done
}

# Вывод итоговой информации
print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Foreign VPS — установка завершена${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  UUID клиента:  ${CYAN}$UUID${NC}"
    echo -e "  Public Key:    ${CYAN}$PUBLIC_KEY${NC}"
    echo -e "  Short ID:      ${CYAN}$SHORT_ID${NC}"
    echo ""
    echo -e "  Строка подключения (REALITY):"
    local encoded_domain
    encoded_domain=$(printf '%s' "$DOMAIN" | sed 's/ /%20/g; s/#/%23/g; s/&/%26/g')
    echo -e "  ${CYAN}vless://$UUID@$DOMAIN:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=$encoded_domain&fp=firefox&pbk=$PUBLIC_KEY&sid=$SHORT_ID#$encoded_domain${NC}"
    echo ""
}

# Проверка что порты 80 и 443 свободны (или заняты нашими сервисами)
check_ports() {
    for port in 80 443; do
        local pid
        pid=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1) || true
        if [[ -n "$pid" ]]; then
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null) || pname="unknown"
            if [[ "$pname" != "xray" && "$pname" != "caddy" ]]; then
                die "Порт $port занят процессом $pname (PID $pid). Остановите его перед установкой."
            fi
        fi
    done
    success "Порты 80 и 443 свободны"
}

# Создание рабочих директорий
create_dirs() {
    mkdir -p "$XRAY_DIR" "$CERT_DIR" "$LOG_DIR_XRAY" "$LOG_DIR_CADDY" "$STUB_DIR"
    success "Директории созданы"
}

# запуск setup.sh
main() {
    parse_args "$@"
    require_root
    validate_settings

    step deps      install_dependencies
    step ufw       setup_ufw
    step dns       check_dns
    step ports     check_ports
    step dirs      create_dirs
    step cert      issue_certificate
    step xray      write_xray_config
    step caddy     write_caddyfile
    step cron      write_cron
    step stub      write_stub_site
    step fail2ban  write_fail2ban
    step logrotate write_logrotate
    step systemd   write_systemd_override
    step restart   restart_services
    step summary   print_summary
}

main "$@"
