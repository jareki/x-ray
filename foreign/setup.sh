#!/bin/bash

set -euo pipefail

# Настройки задаются в foreign/settings.env (пример — settings.env.example).
# Значения по умолчанию, которые можно переопределить в settings.env:
CADDY_HTTPS_PORT="8443"
CADDY_HTTP_PORT="8080"

# ПУТИ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
COMMON_DIR="$SCRIPT_DIR/../common"
STUB_DIR="/var/www/stub"
XRAY_DIR="/usr/local/etc/xray"
CADDYFILE="/etc/caddy/Caddyfile"
LOG_DIR_XRAY="/var/log/xray"
LOG_DIR_CADDY="/var/log/caddy"

[[ -f "$COMMON_DIR/lib.sh" ]] || { echo "Не найден $COMMON_DIR/lib.sh — запускайте скрипт из репозитория"; exit 1; }
# shellcheck source=../common/lib.sh
source "$COMMON_DIR/lib.sh"

# Шаги в порядке выполнения: "тег|функция|описание"
STEPS=(
    "deps|install_dependencies|Установка системных пакетов, Xray, Caddy"
    "ufw|setup_firewall|Настройка firewall (ufw)"
    "dns|check_dns|Проверка DNS-записи домена"
    "ports|check_ports|Проверка что порты 80/443 свободны"
    "dirs|create_dirs|Создание рабочих директорий"
    "legacy|cleanup_legacy_acme|Удаление старой схемы сертификатов (acme.sh, cron)"
    "xray|write_xray_config|Генерация и проверка конфига Xray (REALITY-ключи, UUID)"
    "caddy|write_caddyfile|Запись и проверка Caddyfile"
    "stub|write_stub_site|Копирование сайта-заглушки"
    "fail2ban|write_fail2ban|Настройка fail2ban"
    "logrotate|write_logrotate|Настройка logrotate для логов"
    "systemd|write_systemd_override|Systemd override для автоперезапуска Xray"
    "restart|restart_services|Перезапуск сервисов (caddy, xray)"
    "cert|check_certificate|Проверка что Caddy получил TLS-сертификат"
    "summary|print_summary|Вывод итоговой информации и строки подключения"
)

# Переменные для подстановки в шаблоны (в дополнение к общим из lib.sh)
TEMPLATE_VARS=(DOMAIN EMAIL CADDY_HTTPS_PORT CADDY_HTTP_PORT STUB_DIR LOG_DIR_CADDY)

# проверка что настройки заполнены
validate_settings() {
    info "Проверка настроек..."
    require_setting DOMAIN "your-domain.com"
    require_setting EMAIL  "your@email.com"
    [[ "$DOMAIN" =~ \. ]] || die "DOMAIN выглядит некорректно: $DOMAIN"
    success "Настройки корректны"
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
        | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list

    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list

    apt-get update -qq
    apt-get install -y caddy
    command -v caddy &>/dev/null || die "Не удалось установить Caddy"
    success "Caddy установлен: $(caddy version)"
}

# Установка всех зависимостей
install_dependencies() {
    info "Проверка и установка зависимостей..."
    [[ -d "$TEMPLATES_DIR" ]] || die "Папка foreign/templates не найдена ($TEMPLATES_DIR)"
    install_packages curl openssl gnupg ufw fail2ban logrotate
    install_xray
    install_caddy
    success "Все зависимости готовы"
}

# Настройка firewall:
# 80  — Caddy выпускает и продлевает сертификат по HTTP-01, порт должен быть открыт постоянно
# 443 — Xray
setup_firewall() {
    setup_ufw 80 443
}

# Проверка DNS — домен должен резолвиться до выпуска сертификата
check_dns() {
    info "Проверка DNS для $DOMAIN..."
    local domain_ip
    domain_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1) || true
    [[ -n "$domain_ip" ]] || die "DNS: домен $DOMAIN не разрешается. Проверьте A-запись и повторите."
    success "DNS OK: $DOMAIN → $domain_ip"
}

# Проверка что порты 80 и 443 свободны (или заняты нашими сервисами)
check_ports() {
    check_ports_free "xray|caddy" 80 443
}

# Создание рабочих директорий
create_dirs() {
    mkdir -p "$XRAY_DIR" "$LOG_DIR_XRAY" "$LOG_DIR_CADDY" "$STUB_DIR"
    chmod 755 "$XRAY_DIR"
    # в лог-директорию пишет сервис caddy
    if id caddy &>/dev/null; then
        chown caddy:caddy "$LOG_DIR_CADDY"
    fi
    success "Директории созданы"
}

# Удаление старой схемы сертификатов: acme.sh + собственный cron.
# Теперь сертификат выпускает и продлевает сам Caddy.
cleanup_legacy_acme() {
    info "Удаление старой схемы сертификатов (acme.sh, cron)..."
    rm -f /etc/cron.d/xray-cert "$XRAY_DIR/cert-renew.sh" "$XRAY_DIR/cert-check.sh"
    if [[ -x /root/.acme.sh/acme.sh ]]; then
        # cron acme.sh в standalone-режиме конфликтует с Caddy за порт 80
        /root/.acme.sh/acme.sh --uninstall-cronjob >/dev/null 2>&1 || true
        warn "cron acme.sh отключён. /root/.acme.sh и /etc/ssl/xray больше не используются. Удаляйте acme.sh командой /root/.acme.sh/acme.sh --uninstall (она убирает строку из /root/.bashrc), затем rm -rf /root/.acme.sh /etc/ssl/xray"
    fi
    success "Старая схема сертификатов удалена"
}

# Настройка Xray — UUID и ключи сохраняются при повторном запуске
write_xray_config() {
    info "Генерация конфига Xray..."
    ensure_xray_keys
    install_xray_config "$TEMPLATES_DIR/xray-config.json"
    success "Конфиг Xray записан (клиентов: ${#CLIENT_NAMES[@]})"
}

# Настройка Caddy (сертификат Caddy получает сам по HTTP-01 через порт 80).
# Новый Caddyfile проверяется до замены рабочего.
write_caddyfile() {
    info "Запись $CADDYFILE..."
    local tmp out
    tmp=$(mktemp)
    render_template "$TEMPLATES_DIR/Caddyfile" "$tmp"
    chmod 644 "$tmp"
    # проверяем от пользователя caddy: от root caddy validate создал бы лог-файлы, недоступные сервису
    if ! out=$(runuser -u caddy -- env HOME=/var/lib/caddy \
            caddy validate --config "$tmp" --adapter caddyfile 2>&1); then
        rm -f "$tmp"
        error "$out"
        die "Новый Caddyfile не прошёл проверку — рабочий не изменён"
    fi
    install -m 644 "$tmp" "$CADDYFILE"
    rm -f "$tmp"
    success "Записан $CADDYFILE"
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

# Рестарт сервисов: сначала Caddy — он REALITY dest для Xray
restart_services() {
    restart_units caddy xray
}

# Проверка, что Caddy получил сертификат (REALITY dest без валидного TLS не работает)
check_certificate() {
    info "Ожидание TLS-сертификата для $DOMAIN от Caddy..."
    local i cert_info
    for i in $(seq 1 30); do
        # curl проверяет цепочку сертификата; HTTP-статус не важен
        if curl -s -o /dev/null --max-time 5 \
                --resolve "$DOMAIN:$CADDY_HTTPS_PORT:127.0.0.1" "https://$DOMAIN:$CADDY_HTTPS_PORT/"; then
            cert_info=$(echo | openssl s_client -connect "127.0.0.1:$CADDY_HTTPS_PORT" -servername "$DOMAIN" 2>/dev/null \
                | openssl x509 -noout -issuer -enddate 2>/dev/null | paste -sd' ' -) || true
            success "Сертификат получен: $cert_info"
            return
        fi
        sleep 3
    done
    warn "Caddy пока не получил сертификат для $DOMAIN. Проверьте: journalctl -u caddy -n 50 (порт 80 должен быть доступен снаружи)"
}

# Строка подключения клиента: client_link ИМЯ UUID
client_link() {
    echo "vless://$2@$DOMAIN:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=$DOMAIN&fp=firefox&pbk=$PUBLIC_KEY&sid=$SHORT_ID#$DOMAIN-$1"
}

# Вывод итоговой информации
print_summary() {
    require_xray_keys
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Foreign VPS — установка завершена${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  Public Key:    ${CYAN}$PUBLIC_KEY${NC}"
    echo -e "  Short ID:      ${CYAN}$SHORT_ID${NC}"
    echo ""
    echo -e "  Клиенты и строки подключения (REALITY):"
    echo ""
    print_client_links
    echo -e "  Для bridge добавьте отдельного клиента: ${CYAN}$0 --add-client bridge${NC}"
    echo ""
}

# запуск setup.sh
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
