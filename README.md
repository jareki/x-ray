# xray-setup

Настройка Xray (VLESS + XTLS-Vision + REALITY) для двух сценариев:
- **Foreign VPS** — заграничный сервер с Caddy и сайтом-заглушкой
- **Bridge VPS** — промежуточный мост (RU напрямую, остальное через foreign)

Шаблоны содержат плейсхолдеры `{{ПЕРЕМЕННАЯ}}`, которые подставляются при установке.

---

## Foreign VPS

```
:443  Xray REALITY
  ├── VLESS клиент  → интернет
  ├── цензор/сканер → :8443 Caddy HTTPS (LE cert) → сайт-заглушка
  └── fallback      → :8080 Caddy HTTP → сайт-заглушка
:80   Caddy → redirect → https://domain
```

### Подготовка

1. A-запись домена → IP сервера
2. Порты 80/443 свободны
3. (опц.) Сайт-заглушка в `/var/www/stub/` (желательно > 32 КБ)

### Установка

Заполните настройки в `foreign/setup.sh`:

```bash
DOMAIN="your-domain.com"
EMAIL="your@email.com"
CADDY_HTTPS_PORT="8443"
CADDY_HTTP_PORT="8080"
CERT_RENEW_DAYS="14"
```

```bash
sudo foreign/setup.sh
```

Выборочный запуск шагов:

```bash
sudo foreign/setup.sh --list-tags           # список тегов
sudo foreign/setup.sh --tags cert,restart   # только указанные шаги
```

### Строка подключения

Выводится в конце установки. Формат:

```
vless://UUID@DOMAIN:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=DOMAIN&fp=firefox&pbk=PUBLIC_KEY&sid=SHORT_ID#DOMAIN
```

### Сертификаты

acme.sh в standalone-режиме. Cron проверяет срок ежедневно в 03:00 (`cert-check.sh`),
при необходимости обновляет (`cert-renew.sh` — останавливает Caddy, открывает порт 80 в ufw, обновляет, восстанавливает).

```bash
sudo /etc/xray/cert-check.sh   # проверка + обновление
sudo /etc/xray/cert-renew.sh   # принудительное обновление
```

### Порты

| Порт | Сервис | Назначение |
|------|--------|------------|
| 443 | Xray | VLESS + REALITY |
| 8443 | Caddy HTTPS | REALITY dest (LE cert) |
| 8080 | Caddy HTTP | VLESS fallbacks |
| 80 | Caddy | Редирект → HTTPS |

### Логи

```bash
tail -f /var/log/xray/{error,access}.log
tail -f /var/log/caddy/stub.log
tail -f /var/log/xray/cert-renew.log
```

---

## Bridge VPS

```
Клиент → Bridge :443 (VLESS + REALITY, SNI = внешний сайт)
  ├── geosite:category-ru / geoip:ru → напрямую
  ├── остальное → Foreign VPS :443
  └── цензор → видит TLS с реальным внешним сайтом
```

Caddy и сертификаты на bridge не нужны.

### Установка

> Сначала разверните foreign VPS.

Заполните настройки в `bridge/setup.sh`:

```bash
BRIDGE_ADDRESS="123.45.67.89"
REALITY_SNI="www.ya.ru"

# Из вывода foreign/setup.sh
FOREIGN_ADDRESS="your-foreign-domain.com"
FOREIGN_UUID="..."
FOREIGN_PUBLIC_KEY="..."
FOREIGN_SHORT_ID="..."
FOREIGN_SNI="your-foreign-domain.com"
```

```bash
sudo bridge/setup.sh
```

### Маршрутизация

| Трафик | Направление |
|--------|-------------|
| geosite:category-ru, geoip:ru | Напрямую |
| geosite:category-ads-all | Блокируется |
| BitTorrent, приватные IP | Блокируется |
| Остальное | Через foreign VPS |

### Строка подключения

```
vless://UUID@BRIDGE_IP:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=REALITY_SNI&fp=firefox&pbk=PUBLIC_KEY&sid=SHORT_ID#bridge
```

---

## Общее

- **Повторный запуск** `setup.sh` безопасен — UUID, ключи и Short ID сохраняются
- **fail2ban** настраивается автоматически из `common/jail.local`
- **logrotate** для логов Xray из `common/xray.logrotate`
- **systemd** override — автоперезапуск Xray при падении

```bash
fail2ban-client status sshd
fail2ban-client set sshd unbanip 1.2.3.4
```
