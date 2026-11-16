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

## Быстрый старт

```bash
scp -r deploy.sh assets .env root@SERVER:/root/proxy-setup-src/
ssh root@SERVER
cd /root/proxy-setup-src
./deploy.sh --domain example.com --reality-domain reality.example.com --yes
```

Без интерактива параметры берутся из `.env` (см. `.env.example`) и CLI-флагов
(CLI имеет приоритет). Полный список: `./deploy.sh --help`.

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

```
-d/--domain, -r/--reality-domain, -e/--email, --ssh-port, --mt-port, --mt-tag,
--site-dir, --no-xui, --no-hui, --no-mtproto, --no-xhttp,
--force, -y/--yes, --skip-dns-check, --dry-run, --uninstall, --no-color, -h/--help
```

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
