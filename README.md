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
  ├── цензор/сканер → :8443 Caddy HTTPS (Let's Encrypt) → сайт-заглушка
  └── fallback      → :8080 Caddy HTTP → сайт-заглушка
:80   Caddy → redirect → https://domain
```

### Подготовка

1. A-запись домена → IP сервера
2. Порты 80/443 свободны
3. (опц.) Сайт-заглушка в `/var/www/stub/` (желательно > 32 КБ)

### Установка

Создайте файл настроек из примера и заполните его:

```bash
cp foreign/settings.env.example foreign/settings.env
nano foreign/settings.env
```

```bash
DOMAIN="your-domain.com"
EMAIL="your@email.com"
#CADDY_HTTPS_PORT="8443"   # внутренние порты Caddy, по умолчанию 8443/8080
#CADDY_HTTP_PORT="8080"
```

`settings.env` не хранится в git (`.gitignore`), поэтому `git pull` его не трогает.

```bash
sudo foreign/setup.sh
```

Выборочный запуск шагов:

```bash
sudo foreign/setup.sh --list-tags           # список тегов
sudo foreign/setup.sh --tags caddy,restart  # только указанные шаги
```

### Строка подключения

Выводится в конце установки для каждого клиента (см. [Клиенты](#клиенты)). Формат:

```
vless://UUID@DOMAIN:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=DOMAIN&fp=firefox&pbk=PUBLIC_KEY&sid=SHORT_ID#DOMAIN-ИМЯ
```

> Foreign блокирует `geosite:category-ru` / `geoip:ru`. При прямом подключении к foreign
> российские сайты нужно пускать мимо прокси правилами маршрутизации на клиенте.

### Сертификаты

Выпускает и продлевает сам Caddy (Let's Encrypt, HTTP-01 через порт 80) — без остановки сервисов и без cron.
Порт 80 поэтому должен быть открыт постоянно. Шаг `cert` в конце установки проверяет, что сертификат получен.

```bash
journalctl -u caddy -n 50                    # ошибки выпуска/продления
sudo foreign/setup.sh --tags cert            # проверить сертификат
```

При обновлении со старой версии (acme.sh) шаг `legacy` удаляет старый cron и скрипты обновления.

### Порты

| Порт | Сервис | Назначение |
|------|--------|------------|
| 443 | Xray | VLESS + REALITY |
| 8443 | Caddy HTTPS | REALITY dest (Let's Encrypt) |
| 8080 | Caddy HTTP | VLESS fallbacks |
| 80 | Caddy | Редирект → HTTPS, ACME HTTP-01 |

### Логи

```bash
tail -f /var/log/xray/error.log   # access-лог отключён (приватность)
tail -f /var/log/caddy/stub.log
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

> Сначала разверните foreign VPS и заведите на нём отдельного клиента для bridge —
> так его можно отозвать, не трогая остальных:
>
> ```bash
> sudo foreign/setup.sh --add-client bridge
> ```

Создайте файл настроек из примера и заполните его:

```bash
cp bridge/settings.env.example bridge/settings.env
nano bridge/settings.env
```

```bash
BRIDGE_ADDRESS="123.45.67.89"
REALITY_SNI="www.ya.ru"

# Из вывода foreign/setup.sh
FOREIGN_ADDRESS="your-foreign-domain.com"
FOREIGN_UUID="..."                 # UUID клиента bridge на foreign
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
vless://UUID@BRIDGE_IP:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=REALITY_SNI&fp=firefox&pbk=PUBLIC_KEY&sid=SHORT_ID#bridge-ИМЯ
```

---

## Клиенты

На каждом сервере свой список клиентов в `/usr/local/etc/xray/clients.txt` (строки `имя UUID`, права 600).
При первой установке создаётся клиент `default`; если сервер уже был настроен старой версией,
его UUID переносится под этим именем — существующие ссылки продолжают работать.

```bash
sudo foreign/setup.sh --add-client alice      # новый UUID, перезапуск Xray, вывод ссылки
sudo foreign/setup.sh --remove-client alice   # отзыв доступа
sudo foreign/setup.sh --list-clients          # все клиенты и их ссылки
```

То же для `bridge/setup.sh`. Имя клиента — латиница, цифры, `. _ @ -`; оно же попадает в поле `email`
конфига Xray. Повторный запуск установки клиентов не теряет: конфиг собирается из `clients.txt`.

---

## Обновление

### Скрипты (этот репозиторий)

Настройки лежат в `settings.env`, который git не отслеживает, поэтому достаточно:

```bash
cd ~/xray-setup                  # каталог с репозиторием на сервере
git pull
```

Если после обновления скрипт пишет «Задайте … в settings.env» — в новой версии появилась
обязательная настройка: сверьте свой `settings.env` с `settings.env.example`.

Затем повторно запустить установку — она идемпотентна: клиенты, REALITY-ключи и Short ID
сохраняются, конфиги проверяются до замены рабочих.

```bash
sudo foreign/setup.sh            # или sudo bridge/setup.sh
```

Перезапуск Xray в конце обрывает текущие соединения на несколько секунд.

**Переход со старой версии** (настройки внутри `setup.sh`, acme.sh, один UUID в конфиге):

```bash
git diff foreign/setup.sh                    # посмотреть и записать свои значения настроек
git checkout -- foreign/setup.sh             # отбросить локальные правки, иначе git pull даст конфликт
git pull
cp foreign/settings.env.example foreign/settings.env
nano foreign/settings.env                    # перенести значения
sudo foreign/setup.sh
```

(для bridge — то же с `bridge/`). Полный запуск сам доделывает остальное:
- шаг `legacy` удаляет cron и скрипты acme.sh — сертификат дальше выпускает Caddy;
- UUID из старого конфига переносится в `clients.txt` под именем `default`, старые ссылки продолжают работать;
- ufw и fail2ban перенастраиваются под реальные SSH-порты. Старое правило ufw для 22,
  если SSH на другом порту, нужно удалить вручную: `ufw delete allow 22/tcp`;
- после проверки можно удалить остатки. acme.sh удаляйте его же командой `--uninstall`, а не `rm -rf`:
  установщик acme.sh прописал свой `acme.sh.env` в `/root/.bashrc`, и после ручного удаления
  каталога при каждом входе будет ошибка `-bash: /root/.acme.sh/acme.sh.env: No such file or directory`.

  ```bash
  sudo /root/.acme.sh/acme.sh --uninstall      # убирает cron и строку из .bashrc
  sudo rm -rf /root/.acme.sh /etc/ssl/xray
  sudo rm -f /var/log/xray/access.log /var/log/xray/cert-renew.log
  ```

  Если каталог уже удалён вручную, уберите строку из `.bashrc`:
  `sudo sed -i.bak '/acme\.sh\.env/d' /root/.bashrc`.

### Xray и geo-базы

`setup.sh` ставит Xray только если его нет и сам не обновляет. Обновление — официальным скриптом
(конфиг не трогается, сервис перезапускается):

```bash
# Xray до последней версии
sudo bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# geoip.dat / geosite.dat (списки RU-доменов и IP для маршрутизации)
sudo bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata
sudo systemctl restart xray
```

### Caddy и системные пакеты

Caddy ставится из apt-репозитория, обновляется вместе с системой:

```bash
sudo apt update && sudo apt upgrade
```

### Проверка после обновления

```bash
systemctl status xray caddy --no-pager    # caddy — только на foreign
xray version
sudo foreign/setup.sh --tags cert         # сертификат на месте (foreign)
sudo foreign/setup.sh --list-clients      # клиенты и ссылки не изменились
tail -n 50 /var/log/xray/error.log
```

---

## Общее

- **Повторный запуск** `setup.sh` безопасен — клиенты, ключи и Short ID сохраняются
- **Проверка конфигов** — новый конфиг Xray (`xray run -test`) и Caddyfile (`caddy validate`) проверяются до замены рабочих; при ошибке рабочий конфиг не трогается. После рестарта скрипт убеждается, что сервис поднялся
- **Общий код** обоих скриптов — в `common/lib.sh` (теги, шаблоны, ufw, ключи Xray, fail2ban, logrotate, systemd)
- **SSH-порты** определяются автоматически (`sshd -T`) и открываются в ufw / подставляются в fail2ban
- **fail2ban** настраивается автоматически из `common/jail.local`
- **logrotate** для логов Xray из `common/xray.logrotate`
- **systemd** override — автоперезапуск Xray при падении

```bash
fail2ban-client status sshd
fail2ban-client set sshd unbanip 1.2.3.4
```
