# xray-setup

Автоматическая настройка Xray (VLESS + XTLS-Vision + REALITY) для двух сценариев:
- **Foreign VPS** — заграничный сервер с Caddy и сайтом-заглушкой
- **Bridge VPS** — промежуточный мост с раздельной маршрутизацией (RU напрямую, остальное через foreign)

## Структура репозитория

```
x-ray/
├── common/                         # Общие шаблоны
│   ├── jail.local                  # Конфиг fail2ban
│   └── xray.logrotate              # Ротация логов Xray
├── foreign/                        # Заграничный VPS
│   ├── setup.sh                    # Скрипт установки
│   └── templates/
│       ├── xray-config.json        # Конфиг Xray (VLESS + REALITY)
│       ├── Caddyfile               # Конфиг Caddy (HTTPS + HTTP + редирект)
│       ├── cert-renew.sh           # Принудительное обновление сертификата
│       ├── cert-check.sh           # Проверка срока + вызов cert-renew.sh
│       ├── xray-cert.cron          # Cron задача (ежедневная проверка в 03:00)
│       └── index.html              # Сайт-заглушка по умолчанию
├── bridge/                         # Промежуточный мост (RU VPS)
│   ├── setup.sh                    # Скрипт установки
│   └── templates/
│       └── xray-config.json        # Конфиг Xray (split-routing)
└── README.md
```

Шаблоны содержат плейсхолдеры вида `{{ПЕРЕМЕННАЯ}}`. Скрипты подставляют
значения через `sed` при установке.

---

## Foreign VPS (заграничный сервер)

### Архитектура

```
:443  (Xray REALITY)
  ├── Цензор/сканер → dest → :8443 (Caddy HTTPS + LE cert) → сайт-заглушка
  ├── VLESS клиент  → интернет
  └── fallback      → :8080 (Caddy HTTP) → сайт-заглушка

:80   (Caddy) → redirect → https://domain
```

Xray принимает все входящие соединения на порту 443 с протоколом REALITY.
Авторизованные VLESS-клиенты проксируются в интернет. Неавторизованные
соединения перенаправляются на Caddy с валидным Let's Encrypt сертификатом.

### Подготовка

1. **DNS** — A-запись домена должна указывать на IP foreign VPS
2. **Порты** — 80 и 443 должны быть свободны
3. **Сайт-заглушка** (опционально) — разместите файлы в `/var/www/stub/` до запуска

> Минимальный размер страницы желательно более 32 КБ.

### Настройка

Откройте `foreign/setup.sh` и заполните блок настроек:

```bash
DOMAIN="your-domain.com"       # ваш домен
EMAIL="your@email.com"         # email для Let's Encrypt
CADDY_HTTPS_PORT="8443"        # порт Caddy с TLS (для REALITY dest)
CADDY_HTTP_PORT="8080"         # порт Caddy без TLS (для VLESS fallbacks)
CERT_RENEW_DAYS="14"           # обновлять сертификат за N дней до истечения
```

### Установка

```bash
chmod +x foreign/setup.sh
sudo foreign/setup.sh
```

### После установки

Данные для подключения выводятся в конце установки и хранятся в `/etc/xray/config.json`.

```bash
grep '"id"' /etc/xray/config.json
```

Строка подключения:

```
vless://UUID@your-domain.com:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=your-domain.com&fp=firefox&pbk=PUBLIC_KEY&sid=SHORT_ID#your-domain.com
```

### Порты

| Порт | Сервис | Назначение |
|------|--------|------------|
| 443 | Xray | VLESS + REALITY — основной вход |
| 8443 | Caddy (HTTPS) | REALITY dest — сайт с LE-сертификатом для маскировки |
| 8080 | Caddy (HTTP) | VLESS fallbacks — расшифрованный трафик |
| 80 | Caddy | Редирект HTTP -> HTTPS |

### Логи

```bash
tail -f /var/log/xray/error.log
tail -f /var/log/xray/access.log
tail -f /var/log/caddy/stub.log
tail -f /var/log/xray/cert-renew.log
```

### Ручное обновление сертификата

```bash
sudo /etc/xray/cert-renew.sh
sudo /etc/xray/cert-check.sh
```

---

## Bridge VPS (промежуточный мост)

Промежуточный сервер с раздельной маршрутизацией:
российский трафик идёт напрямую, заграничный — через foreign VPS.

### Архитектура

```
Клиент → Bridge VPS (RU) :443 (VLESS + REALITY, SNI = внешний сайт)
           ├── geosite:category-ru / geoip:ru → напрямую в интернет
           ├── всё остальное → Foreign VPS :443 (VLESS + XTLS-Vision + REALITY)
           └── сканер/цензор → видит TLS-хендшейк с реальным внешним сайтом
```

REALITY на bridge использует внешний сайт (например, `www.ya.ru`)
в качестве dest/SNI. Caddy и сертификаты на bridge не нужны.

### Порядок развёртывания

1. **Сначала** — разверните foreign VPS по инструкции выше
2. Запишите из вывода foreign setup: UUID, Public Key, Short ID
3. На bridge VPS — откройте `bridge/setup.sh` и заполните:

```bash
# IP или домен bridge-сервера (для строки подключения клиента)
BRIDGE_ADDRESS="123.45.67.89"

# Внешний сайт для маскировки REALITY (TLS 1.3, H2)
REALITY_SNI="www.ya.ru"

# Данные foreign VPS (из вывода foreign/setup.sh)
FOREIGN_ADDRESS="your-foreign-domain.com"
FOREIGN_UUID="uuid-from-foreign-vps"
FOREIGN_PUBLIC_KEY="public-key-from-foreign-vps"
FOREIGN_SHORT_ID="short-id-from-foreign-vps"
FOREIGN_SNI="your-foreign-domain.com"
```

4. Запустите:

```bash
chmod +x bridge/setup.sh
sudo bridge/setup.sh
```

### Маршрутизация

| Трафик | Направление |
|--------|-------------|
| Российские домены и IP (geosite:category-ru, geoip:ru) | Напрямую с bridge |
| Реклама (geosite:category-ads-all) | Блокируется |
| BitTorrent | Блокируется |
| Приватные IP-адреса | Блокируется |
| Всё остальное | Через foreign VPS |

### Клиентское подключение

Клиент подключается к **bridge VPS**. SNI в строке подключения —
внешний сайт (REALITY_SNI), не адрес bridge:

```
vless://UUID@BRIDGE_IP:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=www.ya.ru&fp=firefox&pbk=BRIDGE_PUBLIC_KEY&sid=BRIDGE_SHORT_ID#bridge
```

---

## Общее

### fail2ban

```bash
fail2ban-client status
fail2ban-client status sshd
fail2ban-client set sshd unbanip 1.2.3.4
tail -f /var/log/fail2ban.log
```

### Обновление конфигурации

После изменения переменных в `setup.sh` или шаблонов в `templates/`
достаточно запустить скрипт повторно — он перезапишет все конфиги и
перезапустит сервисы. UUID, REALITY-ключи и Short ID сохраняются между запусками.
