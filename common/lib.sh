#!/bin/bash
# Общие функции для foreign/setup.sh и bridge/setup.sh (подключается через source).
#
# Вызывающий скрипт должен задать:
#   STEPS          — шаги в порядке выполнения, элемент: "тег|функция|описание"
#   TEMPLATE_VARS  — имена своих переменных, подставляемых в шаблоны как {{ИМЯ}}
#   COMMON_DIR, XRAY_DIR, LOG_DIR_XRAY
#   client_link NAME UUID — функция, печатающая vless://-ссылку клиента

export DEBIAN_FRONTEND=noninteractive

# Список клиентов Xray на сервере: строки «имя UUID»
CLIENTS_FILE="$XRAY_DIR/clients.txt"

# Переменные, которые подставляются в шаблоны обоих скриптов
COMMON_TEMPLATE_VARS=(XRAY_DIR LOG_DIR_XRAY SSH_PORTS CLIENTS_JSON PRIVATE_KEY PUBLIC_KEY SHORT_ID)

# ─── Вывод ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
die()     { error "$*"; exit 1; }

# ─── Шаги и теги ───

# Теги, запрошенные через --tags (пусто = запускать всё)
RUN_TAGS=()

# Проверяет, нужно ли выполнять шаг с данным тегом
should_run() {
    local tag="$1" t
    # Если теги не указаны — запускаем всё
    if [[ ${#RUN_TAGS[@]} -eq 0 ]]; then
        return 0
    fi
    for t in "${RUN_TAGS[@]}"; do
        if [[ "$t" == "$tag" ]]; then
            return 0
        fi
    done
    return 1
}

# Проверяет, что тег объявлен в STEPS
tag_exists() {
    local wanted="$1" entry tag fn desc
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r tag fn desc <<< "$entry"
        if [[ "$tag" == "$wanted" ]]; then
            return 0
        fi
    done
    return 1
}

# Выполняет шаги из STEPS по порядку, пропуская не выбранные через --tags
run_steps() {
    local entry tag fn desc
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r tag fn desc <<< "$entry"
        if should_run "$tag"; then
            "$fn"
        else
            info "Пропуск [$tag] — $desc"
        fi
    done
}

usage() {
    echo "Использование: $0 [--tags tag1,tag2,...] [--list-tags]"
    echo "               $0 --add-client ИМЯ | --remove-client ИМЯ | --list-clients"
    echo ""
    echo "Без --tags выполняются все шаги."
    echo ""
    echo "Опции:"
    echo "  --tags tag1,tag2      Выполнить только указанные шаги"
    echo "  --list-tags           Показать доступные теги и выйти"
    echo "  --add-client ИМЯ      Добавить клиента (новый UUID) и перезапустить Xray"
    echo "  --remove-client ИМЯ   Удалить клиента и перезапустить Xray"
    echo "  --list-clients        Показать клиентов и их строки подключения"
    echo "  --help                Показать эту справку"
    exit 0
}

list_tags() {
    echo "Доступные теги (в порядке выполнения):"
    echo ""
    local entry tag fn desc
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r tag fn desc <<< "$entry"
        printf "  %-12s %s\n" "$tag" "$desc"
    done
    exit 0
}

# Действие с клиентами (add/remove/list) — выполняется вместо шагов установки
CLIENT_ACTION=""
CLIENT_NAME=""

parse_args() {
    local t
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --add-client|--remove-client)
                if [[ -z "${2:-}" ]]; then
                    die "$1 требует имя клиента"
                fi
                CLIENT_ACTION="${1#--}"
                CLIENT_ACTION="${CLIENT_ACTION%-client}"
                CLIENT_NAME="$2"
                shift 2
                ;;
            --list-clients)
                CLIENT_ACTION="list"
                shift
                ;;
            --tags)
                if [[ -z "${2:-}" ]]; then
                    die "--tags требует аргумент (например: --tags xray,restart)"
                fi
                IFS=',' read -ra RUN_TAGS <<< "$2"
                for t in "${RUN_TAGS[@]}"; do
                    tag_exists "$t" || die "Неизвестный тег: $t (используйте --list-tags)"
                done
                shift 2
                ;;
            --list-tags) list_tags ;;
            --help|-h)   usage ;;
            *)           die "Неизвестный аргумент: $1 (используйте --help)" ;;
        esac
    done
    if [[ -n "$CLIENT_ACTION" && ${#RUN_TAGS[@]} -gt 0 ]]; then
        die "Управление клиентами нельзя совмещать с --tags"
    fi
}

# ─── Шаблоны ───

# Подставляет {{ПЕРЕМЕННАЯ}} в шаблоне и записывает результат в файл.
# Замена средствами bash, а не sed: значения с «|», «&», «/» не ломают подстановку.
render_template() {
    local src="$1" dst="$2" content var val
    content=$(<"$src")
    # в bash 5.2+ «&» в строке замены означает найденный текст — отключаем
    shopt -u patsub_replacement 2>/dev/null || true
    for var in "${COMMON_TEMPLATE_VARS[@]}" "${TEMPLATE_VARS[@]}"; do
        val="${!var:-}"
        content="${content//"{{$var}}"/"$val"}"
    done
    if [[ "$content" =~ \{\{[A-Z_]+\}\} ]]; then
        die "В шаблоне $src осталась неподставленная переменная ${BASH_REMATCH[0]}"
    fi
    printf '%s\n' "$content" > "$dst"
}

# ─── Настройки ───

# Подключает settings.env рядом со скриптом (не хранится в git, создаётся из settings.env.example)
load_settings() {
    local file="$SCRIPT_DIR/settings.env"
    if [[ ! -f "$file" ]]; then
        die "Не найден $file. Создайте его из примера и заполните: cp $SCRIPT_DIR/settings.env.example $file"
    fi
    # shellcheck source=/dev/null
    source "$file"
}

# Проверяет, что настройка задана и не равна значению-заглушке из примера.
# $1 — имя переменной, $2 — заглушка (необязательно)
require_setting() {
    local name="$1" placeholder="${2:-}" value
    value="${!name:-}"
    if [[ -z "$value" || ( -n "$placeholder" && "$value" == "$placeholder" ) ]]; then
        die "Задайте $name в $SCRIPT_DIR/settings.env"
    fi
}

# ─── Система ───

# проверка прав запуска
require_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите скрипт от root: sudo $0"
}

# Устанавливает недостающие пакеты из списка аргументов
install_packages() {
    info "Обновление списка пакетов..."
    apt-get update -qq

    local pkg to_install=()
    for pkg in "$@"; do
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

# Определение портов SSH, чтобы ufw и fail2ban не отрезали доступ к серверу
detect_ssh_ports() {
    local ports
    # эффективная конфигурация sshd (с учётом Include и sshd_config.d)
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | paste -sd, -) || true
    if [[ -z "$ports" ]]; then
        # запасной вариант — порты, которые реально слушает sshd
        ports=$(ss -tlnpH 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}' | sort -un | paste -sd, -) || true
    fi
    if [[ -z "$ports" ]]; then
        warn "Не удалось определить порт SSH — используем 22"
        ports="22"
    fi
    SSH_PORTS="$ports"
    info "Порты SSH: $SSH_PORTS"
}

# Настройка ufw: SSH-порты + TCP-порты из аргументов
setup_ufw() {
    info "Настройка ufw..."
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    local port ssh_ports
    IFS=',' read -ra ssh_ports <<< "$SSH_PORTS"
    for port in "${ssh_ports[@]}" "$@"; do
        ufw allow "$port/tcp" >/dev/null
    done
    ufw --force enable >/dev/null
    success "ufw настроен (SSH: $SSH_PORTS; $*)"
}

# Проверяет, что порты свободны или заняты разрешёнными процессами.
# $1 — регулярное выражение имён процессов (например "xray|caddy"), остальные — порты
check_ports_free() {
    local allowed="$1" port pid pname
    shift
    for port in "$@"; do
        pid=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1) || true
        if [[ -n "$pid" ]]; then
            pname=$(ps -p "$pid" -o comm= 2>/dev/null) || pname="unknown"
            if [[ ! "$pname" =~ ^($allowed)$ ]]; then
                die "Порт $port занят процессом $pname (PID $pid). Остановите его перед установкой."
            fi
        fi
    done
    success "Порты $* свободны"
}

# Проверка TCP-доступности host:port
tcp_reachable() {
    timeout 5 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null
}

# Включает и перезапускает сервисы, проверяя что они поднялись
restart_units() {
    local svc
    for svc in "$@"; do
        info "Перезапуск $svc..."
        systemctl enable -q "$svc"
        systemctl restart "$svc"
        sleep 2
        systemctl is-active --quiet "$svc" || die "$svc не запустился: journalctl -u $svc -n 50"
        success "$svc запущен"
    done
}

# ─── Xray ───

# Разбор вывода xray x25519: старые версии печатают «Private key / Public key»,
# новые — «PrivateKey / Password»
x25519_private() { awk '/^Private ?[Kk]ey:/ {print $NF}'; }
x25519_public()  { awk '/^(Public ?[Kk]ey|Password):/ {print $NF}'; }

# Читает privateKey и shortId из существующего конфига Xray.
# LEGACY_UUID — первый UUID в конфиге: нужен для переноса единственного клиента
# из конфигов, созданных до появления clients.txt.
# Возвращает 1, если настроенного конфига ещё нет.
read_xray_keys() {
    local cfg="$XRAY_DIR/config.json"
    PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""; LEGACY_UUID=""
    # Xray-install создаёт config.json с содержимым "{}", поэтому проверяем содержимое, а не только файл
    if [[ ! -f "$cfg" ]] || ! grep -q '"privateKey"' "$cfg"; then
        return 1
    fi
    # первый "id" в файле — клиент inbound (в bridge ниже ещё есть UUID outbound)
    LEGACY_UUID=$(sed -n 's/.*"id"\s*:\s*"\([0-9a-fA-F-]\+\)".*/\1/p' "$cfg" | head -1)
    PRIVATE_KEY=$(sed -n 's/.*"privateKey"\s*:\s*"\([^"]\+\)".*/\1/p' "$cfg" | head -1)
    SHORT_ID=$(sed -n 's/.*"shortIds"\s*:\s*\["",\s*"\([^"]\+\)".*/\1/p' "$cfg" | head -1)
    if [[ -n "$PRIVATE_KEY" ]]; then
        # Восстанавливаем публичный ключ из приватного
        PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>&1 | x25519_public)
    fi
}

# Загружает ключи из существующего конфига, недостающие генерирует; загружает клиентов.
# Ключи, Short ID и клиенты сохраняются при повторном запуске.
ensure_xray_keys() {
    read_xray_keys || true

    if [[ -z "$PRIVATE_KEY" ]]; then
        local key_pair
        key_pair=$(xray x25519 2>&1)
        PRIVATE_KEY=$(x25519_private <<< "$key_pair")
        PUBLIC_KEY=$(x25519_public <<< "$key_pair")
        if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
            die "Не удалось разобрать вывод xray x25519 ($(xray version | head -1))"
        fi
        info "Сгенерированы REALITY-ключи"
    else
        [[ -n "$PUBLIC_KEY" ]] || die "Не удалось восстановить Public key из Private key"
        info "Используем существующие REALITY-ключи (Public Key: $PUBLIC_KEY)"
    fi

    if [[ -z "$SHORT_ID" ]]; then
        SHORT_ID=$(openssl rand -hex 8)
        info "Сгенерирован Short ID: $SHORT_ID"
    else
        info "Используем существующий Short ID: $SHORT_ID"
    fi

    ensure_clients
}

# Для шагов, которым нужны ключи и клиенты без генерации (summary, --list-clients)
require_xray_keys() {
    if [[ -z "${PUBLIC_KEY:-}" ]]; then
        if ! read_xray_keys || [[ -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
            die "Конфиг Xray не найден или неполный — сначала выполните установку (шаг xray)"
        fi
    fi
    [[ -f "$CLIENTS_FILE" ]] || die "Не найден $CLIENTS_FILE — сначала выполните установку (шаг xray)"
    load_clients
}

# ─── Клиенты ───

# Записывает строки клиентов (аргументы) в CLIENTS_FILE с правами 600
write_clients_file() {
    local tmp
    tmp=$(mktemp)
    {
        echo "# Клиенты Xray: «имя UUID» в строке."
        echo "# Управление: setup.sh --add-client ИМЯ / --remove-client ИМЯ / --list-clients"
        printf '%s\n' "$@"
    } > "$tmp"
    install -m 600 -o root -g root "$tmp" "$CLIENTS_FILE"
    rm -f "$tmp"
}

# Читает CLIENTS_FILE в массивы CLIENT_NAMES / CLIENT_UUIDS
load_clients() {
    CLIENT_NAMES=(); CLIENT_UUIDS=()
    local name uuid rest
    while read -r name uuid rest || [[ -n "$name" ]]; do
        if [[ -z "$name" || "$name" == \#* ]]; then
            continue
        fi
        if [[ ! "$uuid" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
            die "Некорректная строка в $CLIENTS_FILE: $name $uuid"
        fi
        CLIENT_NAMES+=("$name")
        CLIENT_UUIDS+=("$uuid")
    done < "$CLIENTS_FILE"
    [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || die "В $CLIENTS_FILE нет ни одного клиента"
}

# Собирает JSON-массив clients для inbound Xray (подставляется как {{CLIENTS_JSON}})
build_clients_json() {
    local i json="["
    for i in "${!CLIENT_NAMES[@]}"; do
        if [[ $i -gt 0 ]]; then
            json+=","
        fi
        json+=$'\n          {"id": "'"${CLIENT_UUIDS[$i]}"'", "flow": "xtls-rprx-vision", "email": "'"${CLIENT_NAMES[$i]}"'"}'
    done
    json+=$'\n        ]'
    CLIENTS_JSON="$json"
}

# Создаёт CLIENTS_FILE при первом запуске (с переносом UUID из старого конфига),
# загружает клиентов и собирает CLIENTS_JSON
ensure_clients() {
    if [[ ! -f "$CLIENTS_FILE" ]]; then
        local uuid="${LEGACY_UUID:-}"
        if [[ -n "$uuid" ]]; then
            info "Существующий клиент перенесён в $CLIENTS_FILE под именем default"
        else
            uuid=$(xray uuid)
            info "Создан клиент default"
        fi
        write_clients_file "default $uuid"
    fi
    load_clients
    build_clients_json
    info "Клиентов: ${#CLIENT_NAMES[@]} (${CLIENT_NAMES[*]})"
}

# Имя клиента идёт в поле email конфига и во фрагмент ссылки — ограничиваем набор символов
validate_client_name() {
    [[ "$1" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || die "Некорректное имя клиента: $1 (допустимы латиница, цифры, . _ @ -)"
}

# Возвращает 0, если клиент с таким именем есть в загруженном списке
client_exists() {
    local name
    for name in "${CLIENT_NAMES[@]}"; do
        if [[ "$name" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

# Печатает строки подключения всех клиентов
print_client_links() {
    local i
    for i in "${!CLIENT_NAMES[@]}"; do
        echo -e "  ${YELLOW}${CLIENT_NAMES[$i]}${NC} (UUID: ${CLIENT_UUIDS[$i]})"
        echo -e "  ${CYAN}$(client_link "${CLIENT_NAMES[$i]}" "${CLIENT_UUIDS[$i]}")${NC}"
        echo ""
    done
}

# Применяет изменённый список клиентов: перегенерирует конфиг и перезапускает Xray
apply_clients() {
    write_xray_config
    restart_units xray
}

add_client() {
    local name="$1" uuid
    validate_client_name "$name"
    read_xray_keys || die "Xray ещё не настроен — сначала выполните установку"
    ensure_clients
    if client_exists "$name"; then
        die "Клиент $name уже существует"
    fi
    uuid=$(xray uuid)
    write_clients_file "$(grep -v '^#' "$CLIENTS_FILE")" "$name $uuid"
    apply_clients
    success "Клиент $name добавлен"
    echo ""
    echo -e "  ${CYAN}$(client_link "$name" "$uuid")${NC}"
    echo ""
}

remove_client() {
    local name="$1"
    read_xray_keys || die "Xray ещё не настроен — сначала выполните установку"
    ensure_clients
    client_exists "$name" || die "Клиент $name не найден"
    [[ ${#CLIENT_NAMES[@]} -gt 1 ]] || die "Нельзя удалить последнего клиента"
    write_clients_file "$(awk -v n="$name" '!/^#/ && $1 != n' "$CLIENTS_FILE")"
    apply_clients
    success "Клиент $name удалён"
}

# Выполняет действие из --add-client / --remove-client / --list-clients
run_client_action() {
    case "$CLIENT_ACTION" in
        add)    add_client "$CLIENT_NAME" ;;
        remove) remove_client "$CLIENT_NAME" ;;
        list)
            require_xray_keys
            echo ""
            print_client_links
            ;;
    esac
}

# Рендерит конфиг Xray во временный файл, проверяет через xray -test
# и только после этого заменяет рабочий конфиг
install_xray_config() {
    local template="$1" cfg="$XRAY_DIR/config.json" tmp out
    # xray определяет формат конфига по расширению
    tmp=$(mktemp --suffix=.json)
    render_template "$template" "$tmp"
    if ! out=$(xray run -test -c "$tmp" 2>&1); then
        rm -f "$tmp"
        error "$out"
        die "Новый конфиг Xray не прошёл проверку — рабочий конфиг не изменён"
    fi
    # конфиг содержит privateKey и UUID: читать может только root и группа пользователя nobody, от которого работает xray
    install -m 640 -o root -g "$(id -gn nobody)" "$tmp" "$cfg"
    rm -f "$tmp"
}

# ─── Общие шаги ───

# Настройка fail2ban (из common/jail.local)
write_fail2ban() {
    info "Настройка fail2ban..."
    render_template "$COMMON_DIR/jail.local" /etc/fail2ban/jail.local
    chmod 644 /etc/fail2ban/jail.local
    fail2ban-client -t >/dev/null || die "Конфиг fail2ban не прошёл проверку: fail2ban-client -t"
    systemctl enable -q fail2ban
    systemctl restart fail2ban
    success "fail2ban настроен"
}

# Настройка logrotate для логов Xray (из common/xray.logrotate)
write_logrotate() {
    info "Настройка logrotate для Xray..."
    render_template "$COMMON_DIR/xray.logrotate" /etc/logrotate.d/xray
    chmod 644 /etc/logrotate.d/xray
    logrotate -d /etc/logrotate.d/xray &>/dev/null || die "Конфиг logrotate не прошёл проверку: logrotate -d /etc/logrotate.d/xray"
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
