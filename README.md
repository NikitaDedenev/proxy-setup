# proxy-setup

Идемпотентный скрипт развёртывания на Ubuntu Server (22.04 / 24.04 / 26.04 LTS):

* **443/TCP** — Nginx (stream + ssl_preread) как единая точка входа:
  * `DOMAIN` → nginx `:7443` → сайт-заглушка, панель **3x-ui**, панель **h-ui**, подписки,
    а также WS / XHTTP / Trojan-gRPC инбаунды Xray (все на loopback);
  * `REALITY_DOMAIN` → Xray **VLESS Reality** на `127.0.0.1:8443`, у которого `target` —
    локальный nginx `:9443` с валидным LE-сертификатом (схема **selfSNI**);
  * любой другой SNI / прямой IP → сайт-заглушка (не палим Reality).
* **443/UDP** — **Hysteria2** (h-ui): TLS от Let's Encrypt, `sniGuard: strict`,
  obfs `salamander`, `masquerade.proxy` → `https://DOMAIN` (маскировка под тот же сайт).
* **Docker + MTProto** — `telegrammessenger/proxy`, готовая `tg://proxy` ссылка.

## Требования

* Ubuntu 22.04/24.04/26.04, root-доступ, чистый сервер (или согласие на удаление
  предыдущей установки).
* Два домена/поддомена с A-записями на IP сервера, открытые 80/tcp и 443/tcp+udp.

## Установка в одну команду

Нужен чистый Ubuntu-сервер (22.04/24.04/26.04) с root-доступом и два домена,
которые уже указывают A-записью на этот сервер.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NikitaDedenev/proxy-setup/main/deploy.sh) \
  --domain example.com \
  --reality-domain reality.example.com
```

Без флагов скрипт спросит домены интерактивно. Если домены уже прописаны в
`.env` рядом с текущим каталогом — они подхватятся автоматически.

> Важно: используйте именно `bash <(curl ...)`, а не `curl ... | bash`.
> При пайпе stdin занят скриптом, и интерактивные подтверждения/запросы работать
> не будут.

### Деинсталляция

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NikitaDedenev/proxy-setup/main/deploy.sh) --uninstall
```

Удаляет всё созданное (по `manifest.txt`), бэкапы и `state.env` остаются в
`/root/proxy-setup/`.

### Другие частые варианты

```bash
# только отрендерить конфиги nginx в /tmp/proxy-setup-dryrun, ничего не меняя
bash <(curl -fsSL .../deploy.sh) -d example.com -r reality.example.com --dry-run

# повторный запуск поверх существующей установки — идемпотентно, без удаления
bash <(curl -fsSL .../deploy.sh) -d example.com -r reality.example.com

# полный сброс с бэкапом и удалением старой установки
bash <(curl -fsSL .../deploy.sh) -d example.com -r reality.example.com --force

# параметры из переменных окружения (без интерактива)
DOMAIN=example.com REALITY_DOMAIN=reality.example.com \
  bash <(curl -fsSL .../deploy.sh) --yes

# локальный запуск из клонированного репозитория
git clone https://github.com/NikitaDedenev/proxy-setup && cd proxy-setup
./deploy.sh -d example.com -r reality.example.com
```

Скрипт скачивает `deploy.sh` из ветки `master`; шаблон сайта-заглушки при
одно-командном запуске тоже подтягивается с GitHub (`assets/site`), поэтому
клонировать репозиторий не обязательно.

## Что создаётся

| Путь | Назначение |
|---|---|
| `/root/proxy-setup/state.env` | все сгенерированные секреты, порты и пути (chmod 600) |
| `/root/proxy-setup/summary.txt` | итоговые ссылки `vless://`, `hy2://`, `tg://proxy`, креды панелей |
| `/root/proxy-setup/manifest.txt` | список созданных файлов (для `--uninstall`) |
| `/root/proxy-setup/backups/<ts>/` | бэкапы `x-ui.db`, `/etc/nginx`, `h_ui.db`, compose, снимок `ss`/`ufw` |
| `/etc/nginx/sites-available/{DOMAIN,REALITY_DOMAIN,80.conf}` | vhost'ы |
| `/etc/nginx/stream-enabled/stream.conf` | SNI-маршрутизация 443/TCP |
| `/var/www/html/` | сайт-заглушка (`assets/site` или `--site-dir`) |
| `/etc/letsencrypt/live/{DOMAIN,REALITY_DOMAIN}` | сертификаты (certbot + deploy-hook) |
| `/opt/mtproto/docker-compose.yml` | MTProto контейнер |

Панели не публикуются напрямую: 3x-ui слушает `127.0.0.1`, h-ui — на случайном
порту, который не открыт в ufw (default-deny). Доступ к обеим — только через nginx
по секретным путям.

## Идемпотентность и повторный запуск

* повторный запуск переиспользует `state.env` (порты, пути, пароли, ключи Reality,
  UUID клиентов) и **не пересоздаёт** существующие inbound'ы (сверка по `tag`);
* сертификаты переиспользуются, если действуют более 30 дней;
* конфиги nginx/юниты/файлы перезаписываются детерминированно, `nginx -t` выполняется
  до reload с откатом из бэкапа при ошибке;
* если обнаружена предыдущая установка (3x-ui/nginx/h-ui/MTProto), скрипт печатает
  предупреждение, делает бэкап и требует `--force`/`--yes` (или ввода `yes`).

## Флаги

| Флаг | Описание |
|---|---|
| `-d, --domain <домен>` | основной домен: сайт-заглушка, панели, WS/XHTTP/Trojan, Hysteria2 TLS |
| `-r, --reality-domain <домен>` | домен для VLESS Reality (SNI и dest, selfSNI) |
| `-e, --email <email>` | e-mail для Let's Encrypt (иначе регистрация без email) |
| `--ssh-port <порт>` | SSH-порт для ufw (по умолчанию из `sshd -T`) |
| `--mt-port <порт>` | порт MTProto (по умолчанию случайный) |
| `--mt-tag <tag>` | тег прокси из @MTProxybot (необязательно) |
| `--site-dir <путь>` | свой сайт-заглушка (обязателен `index.html`) |
| `--no-xui` / `--no-hui` / `--no-mtproto` | не устанавливать компонент |
| `--no-xhttp` | не создавать inbound VLESS XHTTP |
| `--force`, `-y`, `--yes` | согласие на удаление существующей установки |
| `--skip-dns-check` | не проверять A-записи доменов |
| `--dry-run` | отрендерить nginx-конфиги в `/tmp/proxy-setup-dryrun` и выйти |
| `--uninstall` | удалить созданное этим скриптом (по manifest) |
| `--no-color` | без ANSI-цветов |
| `-h, --help` | справка |

`--dry-run` только рендерит nginx-конфиги в `/tmp/proxy-setup-dryrun` и выходит.
`--uninstall` удаляет созданное по manifest (бэкапы и state остаются).

## Подводные камни (учтено в скрипте)

* **3x-ui v3 и `/etc/x-ui`.** Unit-файл панели использует `ProtectSystem=full` и
  `ReadWritePaths=-/etc/x-ui`: если каталога нет, systemd молча игнорирует путь и
  панель падает с `mkdir /etc/x-ui: read-only file system`. Скрипт создаёт каталог
  до первого старта.
* **Reality-ключи.** `xray x25519` печатает `Password (PublicKey): …`; парсер скрипта
  берёт последнее поле строки и валидирует base64url-формат (43 символа). При
  расхождении ключей с inbound'ом скрипт пересоздаёт Reality inbound.
* **h-ui и `trafficStats.secret`.** h-ui опрашивает API Hysteria для online/kick,
  подписывая запросы `JWT_SECRET`. Поэтому `trafficStats.secret` в `hysteria2.yaml`
  **обязан** совпадать с `JWT_SECRET`, иначе auth Hysteria2 возвращает
  `ok:false` и клиенты не подключаются.
* **Первый старт h-ui** скачивает `hysteria-linux-amd64` в `bin/`. Если прервать
  загрузку, останется неполный файл без `+x`, и h-ui больше не попытается его
  скачать. Скрипт проверяет размер/права и удаляет битый бинарник.
* **Автопродление сертификатов.** Первичный выпуск идёт через `--standalone`
  (nginx ещё не слушает 80), после чего renewal-конфиг переключается на `webroot`
  с `/var/www/html`, иначе `certbot renew` упадёт на занятом порту 80.
* **h-ui редиректит** `/<context>/` → `/<context>`; nginx проксирует оба варианта
  без собственного redirect, чтобы не получить цикл.
* **Docker и ufw.** Опубликованный порт MTProto обходит ufw; публикуется только он,
  остальные сервисы слушают loopback/закрыты default-deny.

## Проверка после установки

```bash
ss -tulpn | grep -E ':443|:80'
curl -sI https://example.com/ | head -3
openssl s_client -connect example.com:443 -servername example.com -brief </dev/null
curl -sI https://reality.example.com/ | head -3
systemctl status x-ui h-ui nginx docker --no-pager
docker logs mtproto_proxy 2>&1 | tail -5
certbot renew --dry-run
fail2ban-client status sshd
```

## Разработка

`deploy.sh` проходит `shellcheck -x -S info` без замечаний. Локально:

```bash
shellcheck -x -S info deploy.sh
bash -n deploy.sh
```

## Безопасность репозитория

`.env`, `info.md`, `refs/`, `.refs/` исключены через `.gitignore`. Перед коммитом
проверьте: `git status --short` не должен показывать эти пути.
