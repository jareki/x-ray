#!/bin/bash

set -euo pipefail

# ==========================================
#  НАСТРОЙКИ BRIDGE VPS
# ==========================================

# IP-адрес или домен этого (bridge) сервера
BRIDGE_ADDRESS="your-bridge-ip-or-domain"

# SNI-сайт для маскировки REALITY (реальный внешний сайт с TLS 1.3 и H2)
REALITY_SNI="www.ya.ru"

# ------------------------------------------
#  Данные заграничного VPS (из вывода setup.sh на foreign VPS)
# ------------------------------------------
FOREIGN_ADDRESS="your-foreign-domain.com"   # домен или IP заграничного VPS
FOREIGN_UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
FOREIGN_PUBLIC_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx="
FOREIGN_SHORT_ID="xxxxxxxxxxxxxxxx"
FOREIGN_SNI="your-foreign-domain.com"       # SNI для подключения к foreign VPS

# ==========================================

# ПУТИ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
COMMON_DIR="$SCRIPT_DIR/../common"
XRAY_DIR="/etc/xray"
LOG_DIR_XRAY="/var/log/xray"

# функции вывода информации
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
die()     { error "$*"; exit 1; }

# Подставляет {{ПЕРЕМЕННАЯ}} в шаблоне и записывает результат в файл
render_template() {
    local src="$1" dst="$2"
    sed \
        -e "s|{{BRIDGE_ADDRESS}}|$BRIDGE_ADDRESS|g" \
        -e "s|{{REALITY_SNI}}|$REALITY_SNI|g" \
        -e "s|{{XRAY_DIR}}|$XRAY_DIR|g" \
        -e "s|{{LOG_DIR_XRAY}}|$LOG_DIR_XRAY|g" \
        -e "s|{{UUID}}|$UUID|g" \
        -e "s|{{PRIVATE_KEY}}|$PRIVATE_KEY|g" \
        -e "s|{{PUBLIC_KEY}}|$PUBLIC_KEY|g" \
        -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
        -e "s|{{FOREIGN_ADDRESS}}|$FOREIGN_ADDRESS|g" \
        -e "s|{{FOREIGN_UUID}}|$FOREIGN_UUID|g" \
        -e "s|{{FOREIGN_PUBLIC_KEY}}|$FOREIGN_PUBLIC_KEY|g" \
        -e "s|{{FOREIGN_SHORT_ID}}|$FOREIGN_SHORT_ID|g" \
        -e "s|{{FOREIGN_SNI}}|$FOREIGN_SNI|g" \
        "$src" > "$dst"
}

# проверка прав запуска
require_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите скрипт от root: sudo $0"
}

# проверка что настройки заполнены
validate_settings() {
    info "Проверка настроек..."
    [[ "$BRIDGE_ADDRESS" == "your-bridge-ip-or-domain" ]] && die "Задайте BRIDGE_ADDRESS в начале setup.sh"
    [[ "$REALITY_SNI" == *"example"* ]]                   && die "Задайте REALITY_SNI — реальный внешний сайт"

    # Проверка данных foreign VPS
    [[ "$FOREIGN_ADDRESS" == "your-foreign-domain.com" ]] && die "Задайте FOREIGN_ADDRESS"
    [[ "$FOREIGN_UUID" == *"xxxx"* ]]                     && die "Задайте FOREIGN_UUID"
    [[ "$FOREIGN_PUBLIC_KEY" == *"xxx"* ]]                && die "Задайте FOREIGN_PUBLIC_KEY"
    [[ "$FOREIGN_SHORT_ID" == *"xxx"* ]]                  && die "Задайте FOREIGN_SHORT_ID"

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

# Установка всех зависимостей
install_dependencies() {
    info "Проверка и установка зависимостей..."
    [[ -d "$TEMPLATES_DIR" ]]        || die "Папка bridge/templates не найдена ($TEMPLATES_DIR)"
    [[ -d "$COMMON_DIR" ]] || die "Папка common не найдена ($COMMON_DIR)"
    install_packages
    install_xray
    success "Все зависимости готовы"
}

# Настройка firewall (ufw)
setup_ufw() {
    info "Настройка ufw..."
    ufw default deny incoming  2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow 22/tcp   2>/dev/null || true
    ufw allow 443/tcp  2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    success "ufw настроен (22, 443)"
}

# Проверка доступности SNI-сайта (REALITY dest)
check_reality_sni() {
    info "Проверка доступности REALITY SNI ($REALITY_SNI)..."
    if timeout 5 bash -c "echo > /dev/tcp/$REALITY_SNI/443" 2>/dev/null; then
        success "REALITY SNI ($REALITY_SNI) доступен"
    else
        warn "REALITY SNI ($REALITY_SNI:443) недоступен с этого сервера — маскировка может не работать"
    fi
}

# Проверка связи с foreign VPS
check_foreign_connectivity() {
    info "Проверка связи с foreign VPS ($FOREIGN_ADDRESS)..."
    if timeout 5 bash -c "echo > /dev/tcp/$FOREIGN_ADDRESS/443" 2>/dev/null; then
        success "Foreign VPS доступен на порту 443"
    else
        warn "Foreign VPS ($FOREIGN_ADDRESS:443) недоступен — проверьте что foreign VPS запущен"
    fi
}

# Настройка Xray — bridge конфиг с маршрутизацией
write_xray_config() {
    info "Генерация конфига Xray (bridge)..."
    if [[ -f "$XRAY_DIR/config.json" ]]; then
        UUID=$(grep -oP '"id"\s*:\s*"\K[0-9a-f-]+' "$XRAY_DIR/config.json" | head -1)
        [[ -z "$UUID" ]] && die "Не удалось извлечь UUID из существующего конфига $XRAY_DIR/config.json"
        info "Используем существующий UUID: $UUID"

        PRIVATE_KEY=$(grep -oP '"privateKey"\s*:\s*"\K[^"]+' "$XRAY_DIR/config.json" | head -1)
        SHORT_ID=$(grep -oP '"shortIds"\s*:\s*\["",\s*"\K[^"]+' "$XRAY_DIR/config.json" | head -1)
    else
        UUID=$(xray uuid)
        info "Сгенерирован новый UUID: $UUID"

        PRIVATE_KEY=""
        SHORT_ID=""
    fi

    # Генерация REALITY-ключей (если ещё нет)
    if [[ -z "${PRIVATE_KEY:-}" ]]; then
        local key_pair
        key_pair=$(xray x25519)
        PRIVATE_KEY=$(echo "$key_pair" | grep -oP 'Private key:\s*\K\S+')
        PUBLIC_KEY=$(echo "$key_pair" | grep -oP 'Public key:\s*\K\S+')
        info "Сгенерированы REALITY-ключи"
    else
        PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" | grep -oP 'Public key:\s*\K\S+')
        info "Используем существующие REALITY-ключи"
    fi

    if [[ -z "${SHORT_ID:-}" ]]; then
        SHORT_ID=$(openssl rand -hex 8)
        info "Сгенерирован Short ID: $SHORT_ID"
    else
        info "Используем существующий Short ID: $SHORT_ID"
    fi

    render_template "$TEMPLATES_DIR/xray-config.json" "$XRAY_DIR/config.json"
    chmod 600 "$XRAY_DIR/config.json"
    success "Конфиг Xray (bridge) записан (UUID: $UUID)"
}

# Настройка fail2ban (из общих шаблонов)
write_fail2ban() {
    info "Настройка fail2ban..."
    cp "$COMMON_DIR/jail.local" /etc/fail2ban/jail.local
    chmod 644 /etc/fail2ban/jail.local
    systemctl enable --now fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    success "fail2ban настроен"
}

# Настройка logrotate (из общих шаблонов)
write_logrotate() {
    info "Настройка logrotate для Xray..."
    render_template "$COMMON_DIR/xray.logrotate" "/etc/logrotate.d/xray"
    chmod 644 /etc/logrotate.d/xray
    success "logrotate конфиг записан"
}

# systemd override
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

# Рестарт Xray
restart_services() {
    info "Перезапуск xray..."
    systemctl stop xray 2>/dev/null || true
    systemctl enable --now xray
    success "xray запущен"
}

# Вывод итоговой информации
print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Bridge VPS — установка завершена${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  ${YELLOW}Режим: BRIDGE (split-routing)${NC}"
    echo -e "  REALITY SNI:           ${CYAN}$REALITY_SNI${NC}"
    echo -e "  Российский трафик  →   напрямую"
    echo -e "  Заграничный трафик →   ${CYAN}$FOREIGN_ADDRESS${NC}"
    echo ""
    echo -e "  UUID клиента (bridge):  ${CYAN}$UUID${NC}"
    echo -e "  Public Key (bridge):    ${CYAN}$PUBLIC_KEY${NC}"
    echo -e "  Short ID (bridge):      ${CYAN}$SHORT_ID${NC}"
    echo ""
    echo -e "  Строка подключения (клиент → bridge):"
    echo -e "  ${CYAN}vless://$UUID@$BRIDGE_ADDRESS:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=$REALITY_SNI&fp=firefox&pbk=$PUBLIC_KEY&sid=$SHORT_ID#bridge${NC}"
    echo ""
}

# запуск
main() {
    require_root
    validate_settings
    install_dependencies
    setup_ufw
    check_reality_sni
    check_foreign_connectivity

    # Проверка что порт 443 свободен (или занят Xray)
    local pid
    pid=$(ss -tlnp "sport = :443" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1) || true
    if [[ -n "$pid" ]]; then
        local pname
        pname=$(ps -p "$pid" -o comm= 2>/dev/null) || pname="unknown"
        if [[ "$pname" != "xray" ]]; then
            die "Порт 443 занят процессом $pname (PID $pid). Остановите его перед установкой."
        fi
    fi

    mkdir -p "$XRAY_DIR" "$LOG_DIR_XRAY"

    write_xray_config
    write_logrotate
    write_fail2ban
    write_systemd_override
    restart_services
    print_summary
}

main "$@"
