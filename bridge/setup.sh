#!/bin/bash

set -euo pipefail

# Настройки задаются в bridge/settings.env (пример — settings.env.example).

# ПУТИ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
COMMON_DIR="$SCRIPT_DIR/../common"
XRAY_DIR="/usr/local/etc/xray"
LOG_DIR_XRAY="/var/log/xray"

[[ -f "$COMMON_DIR/lib.sh" ]] || { echo "Не найден $COMMON_DIR/lib.sh — запускайте скрипт из репозитория"; exit 1; }
# shellcheck source=../common/lib.sh
source "$COMMON_DIR/lib.sh"

# Шаги в порядке выполнения: "тег|функция|описание"
STEPS=(
    "deps|install_dependencies|Установка системных пакетов, Xray"
    "ufw|setup_firewall|Настройка firewall (ufw)"
    "sni|check_reality_sni|Проверка доступности REALITY SNI"
    "foreign|check_foreign_connectivity|Проверка связи с foreign VPS"
    "ports|check_ports|Проверка что порт 443 свободен"
    "dirs|create_dirs|Создание рабочих директорий"
    "xray|write_xray_config|Генерация и проверка конфига Xray (REALITY-ключи, UUID)"
    "fail2ban|write_fail2ban|Настройка fail2ban"
    "logrotate|write_logrotate|Настройка logrotate для логов"
    "systemd|write_systemd_override|Systemd override для автоперезапуска Xray"
    "restart|restart_services|Перезапуск сервисов (xray)"
    "summary|print_summary|Вывод итоговой информации и строки подключения"
)

# Переменные для подстановки в шаблоны (в дополнение к общим из lib.sh)
TEMPLATE_VARS=(BRIDGE_ADDRESS REALITY_SNI FOREIGN_ADDRESS FOREIGN_UUID FOREIGN_PUBLIC_KEY FOREIGN_SHORT_ID FOREIGN_SNI)

# проверка что настройки заполнены
validate_settings() {
    info "Проверка настроек..."
    require_setting BRIDGE_ADDRESS     "your-bridge-ip-or-domain"
    require_setting REALITY_SNI

    # Данные foreign VPS
    require_setting FOREIGN_ADDRESS    "your-foreign-domain.com"
    require_setting FOREIGN_UUID       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    require_setting FOREIGN_PUBLIC_KEY "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx="
    require_setting FOREIGN_SHORT_ID   "xxxxxxxxxxxxxxxx"
    require_setting FOREIGN_SNI        "your-foreign-domain.com"

    success "Настройки корректны"
}

# Установка всех зависимостей
install_dependencies() {
    info "Проверка и установка зависимостей..."
    [[ -d "$TEMPLATES_DIR" ]] || die "Папка bridge/templates не найдена ($TEMPLATES_DIR)"
    install_packages curl openssl ufw fail2ban logrotate
    install_xray
    success "Все зависимости готовы"
}

# Настройка firewall: 443 — Xray
setup_firewall() {
    setup_ufw 443
}

# Проверка доступности SNI-сайта (REALITY dest)
check_reality_sni() {
    info "Проверка доступности REALITY SNI ($REALITY_SNI)..."
    if tcp_reachable "$REALITY_SNI" 443; then
        success "REALITY SNI ($REALITY_SNI) доступен"
    else
        warn "REALITY SNI ($REALITY_SNI:443) недоступен с этого сервера — маскировка может не работать"
    fi
}

# Проверка связи с foreign VPS
check_foreign_connectivity() {
    info "Проверка связи с foreign VPS ($FOREIGN_ADDRESS)..."
    if tcp_reachable "$FOREIGN_ADDRESS" 443; then
        success "Foreign VPS доступен на порту 443"
    else
        warn "Foreign VPS ($FOREIGN_ADDRESS:443) недоступен — проверьте что foreign VPS запущен"
    fi
}

# Проверка что порт 443 свободен (или занят Xray)
check_ports() {
    check_ports_free "xray" 443
}

# Создание рабочих директорий
create_dirs() {
    mkdir -p "$XRAY_DIR" "$LOG_DIR_XRAY"
    chmod 755 "$XRAY_DIR"
    success "Директории созданы"
}

# Настройка Xray — bridge конфиг с маршрутизацией; UUID и ключи сохраняются при повторном запуске
write_xray_config() {
    info "Генерация конфига Xray (bridge)..."
    ensure_xray_keys
    install_xray_config "$TEMPLATES_DIR/xray-config.json"
    success "Конфиг Xray (bridge) записан (клиентов: ${#CLIENT_NAMES[@]})"
}

# Рестарт Xray
restart_services() {
    restart_units xray
}

# Вывод итоговой информации
print_summary() {
    require_xray_keys
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
    echo -e "  Public Key (bridge):    ${CYAN}$PUBLIC_KEY${NC}"
    echo -e "  Short ID (bridge):      ${CYAN}$SHORT_ID${NC}"
    echo ""
    echo -e "  Клиенты и строки подключения (клиент → bridge):"
    echo ""
    print_client_links
}

# Строка подключения клиента: client_link ИМЯ UUID
client_link() {
    echo "vless://$2@$BRIDGE_ADDRESS:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=$REALITY_SNI&fp=firefox&pbk=$PUBLIC_KEY&sid=$SHORT_ID#bridge-$1"
}

# запуск
main() {
    parse_args "$@"
    require_root
    load_settings
    validate_settings
    if [[ -n "$CLIENT_ACTION" ]]; then
        run_client_action
        return
    fi
    detect_ssh_ports
    run_steps
}

main "$@"
