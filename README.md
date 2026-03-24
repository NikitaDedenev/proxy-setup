# proxy-setup

One-click proxy infrastructure installer for Ubuntu 22.04 / 24.04.

Installs and configures three proxy services:

- **VLESS** via [3x-ui](https://github.com/mhsanaei/3x-ui) panel — port 443, Reality/TCP transport
- **Hysteria2** via [h-ui](https://github.com/jonssonyan/h-ui) panel — port 8443
- **MTProto** via Docker — port 28443

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NikitaDedenev/proxy-setup/main/proxy_setup.sh)
```

Or clone and run:

```bash
git clone https://github.com/NikitaDedenev/proxy-setup.git
cd proxy-setup
bash proxy_setup.sh
```

## What it does

1. Asks which services to install (1-4)
2. Asks for a domain name (used for SSL)
3. Installs dependencies, configures ufw firewall
4. Issues SSL certificate via certbot
5. Installs and fully configures selected services
6. Prints a summary with all credentials and connection links to console and `/server_meta.txt`

## Requirements

- Ubuntu 22.04 or 24.04
- Root access
- A domain pointed to the server (for SSL)
- Ports 80, 443, 8081, 28443 available

## Output example

```
[VLESS / 3x-ui]
  Panel URL  : https://1.2.3.4:XXXXX/basepath
  Login      : admin
  Password   : randompass
  VLESS link : vless://uuid@1.2.3.4:443?...

[Hysteria2 / h-ui]
  Panel URL  : https://your.domain:8081
  Login      : sysadmin
  Password   : randompass

[MTProto Proxy]
  Server     : 1.2.3.4:28443
  Secret     : hex
  Link       : tg://proxy?...
```
