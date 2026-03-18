# xray-setup

Автоматическая настройка Xray (VLESS + XTLS-Vision) и Caddy.

## Архитектура

Xray принимает все входящие соединения на порту 443. Валидные VLESS-клиенты
проксируются далее во внешний контур. Невалидные получают fallback на Caddy,
который отдаёт им обычный статический сайт, под который и осуществляется маскировка.

## Структура репозитория

```
x-ray/
├── setup.sh              # Главный скрипт установки
├── README.md
└── templates/
    ├── xray-config.json    # Конфиг Xray
    ├── Caddyfile           # Конфиг Caddy
    ├── cert-renew.sh       # Принудительное обновление сертификата
    ├── cert-check.sh       # Проверка срока + вызов cert-renew.sh
    ├── xray-cert.cron      # Cron задача (ежедневная проверка в 03:00)
    ├── xray.logrotate      # Ротация логов Xray (устанавливается в /etc/logrotate.d/)
    └── index.html          # Сайт-заглушка по умолчанию
```

Шаблоны содержат плейсхолдеры вида `{{ПЕРЕМЕННАЯ}}`. Скрипт подставляет
значения через `sed` при установке.

## Подготовка

### 1. DNS

Перед запуском убедитесь, что A-запись домена указывает на IP сервера:

```bash
dig +short your-domain.com
# должен вернуть IP вашего VPS
```

### 2. Порты

Порты 80 и 443 должны быть свободны до запуска скрипта (не заняты nginx, apache и т.д.).

### 3. Сайт-заглушка (опционально)

Если хотите использовать свою страницу — разместите файлы в `/var/www/stub/`
до запуска скрипта. Если каталог пуст, скрипт скопирует заглушку из `templates/index.html`.

> Минимальный размер страницы желательно более 32 КБ, чтобы пройти фильтры
> по объёму передаваемого содержимого.

---

## Настройка

Откройте `setup.sh` и заполните блок настроек в начале файла:

```bash
DOMAIN="your-domain.com"       # ваш домен
EMAIL="your@email.com"         # email для Let's Encrypt
CADDY_PORT="9443"              # порт сайта-заглушки (любой свободный >1024)
CERT_RENEW_DAYS="14"           # обновлять сертификат за N дней до истечения
```

---

## Установка

```bash
chmod +x setup.sh
sudo ./setup.sh
```

Скрипт выполняет следующие шаги:

1. Проверяет настройки (DOMAIN/EMAIL не должны быть плейсхолдерами)
2. Устанавливает зависимости (curl, openssl, cron, ufw, fail2ban, Xray, Caddy, acme.sh)
3. Настраивает firewall (ufw: 22, 80, 443)
4. Проверяет что DNS-запись домена разрешается
5. Выпускает TLS-сертификат через acme.sh (Let's Encrypt)
6. Устанавливает скрипты обновления сертификата и cron задачу
7. Копирует сайт-заглушку (если отсутствует)
8. Разворачивает Caddyfile из шаблона
9. Генерирует конфиг Xray (при повторном запуске — сохраняет существующий UUID)
10. Устанавливает logrotate конфиг для логов Xray
11. Настраивает fail2ban (jail.local)
12. Создаёт systemd override для автоперезапуска Xray при падении
13. Перезапускает Caddy и Xray
14. Выводит строку подключения для клиента

---

## После установки

UUID клиента выводится в конце установки и хранится в `/etc/xray/config.json`.

Получить UUID повторно:

```bash
grep '"id"' /etc/xray/config.json
```

Строка подключения для клиента:

```
vless://UUID@your-domain.com:443?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp#your-domain
```

### Логи

```bash
# Xray
tail -f /var/log/xray/error.log
tail -f /var/log/xray/access.log

# Caddy (сайт-заглушка)
tail -f /var/log/caddy/stub.log

# Обновление сертификата
tail -f /var/log/xray/cert-renew.log
```

### fail2ban

```bash
# Общий статус
fail2ban-client status

# Статус jail SSH
fail2ban-client status sshd

# Разблокировать IP вручную
fail2ban-client set sshd unbanip 1.2.3.4

# Логи
tail -f /var/log/fail2ban.log
```

### Ручное обновление сертификата

```bash
sudo /etc/xray/cert-renew.sh
```

### Проверка срока сертификата

```bash
sudo /etc/xray/cert-check.sh
```

---

## Обновление конфигурации

После изменения переменных в `setup.sh` или шаблонов в `templates/`
достаточно запустить скрипт повторно — он перезапишет все конфиги и
перезапустит сервисы.
