# TYPO3 Server Installation Script

[![TYPO3](https://img.shields.io/badge/TYPO3-12.4_LTS_|_13.4_LTS-orange.svg)](https://typo3.org/)
[![PHP](https://img.shields.io/badge/PHP-8.1_|_8.3_|_8.4-blue.svg)](https://php.net/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04_|_24.04-E95420.svg)](https://ubuntu.com/)
[![Nginx](https://img.shields.io/badge/Nginx-Brotli-009639.svg)](https://nginx.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![shellcheck](https://github.com/oliverthiele/server-install/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/oliverthiele/server-install/actions/workflows/shellcheck.yml)

Automated bash installer for TYPO3 on Ubuntu Server. Sets up a complete production stack — Nginx with Brotli, PHP-FPM,
MariaDB, Redis, SSL hardening — and installs TYPO3 v12 or v13 via Composer in one interactive run. Interrupted
installations can be resumed at any step.

> **Designed for fresh servers only.** This script is intended for newly provisioned Ubuntu servers with no existing
> web server, PHP installation, or TYPO3. Existing Nginx, Apache, or PHP configurations **will be overwritten without
> warning.** Do not run this on a server with active services or existing websites.

## Features

| Category            | Details                                                                             |
|---------------------|-------------------------------------------------------------------------------------|
| **TYPO3**           | v12.4 LTS and v13.4 LTS (interactive selection)                                     |
| **Ubuntu**          | 22.04, 24.04 (recommended) — 20.04 legacy¹                                          |
| **PHP**             | 8.1 / 8.3 / 8.4 — ondrej/php PPA for PHP 8.4 on 24.04                               |
| **Web server**      | Nginx with dynamically compiled Brotli module                                       |
| **Database**        | MariaDB with automated hardening                                                    |
| **Cache**           | Redis with `requirepass` authentication, page and section cache pre-configured      |
| **Security**        | SSH hardening, fileadmin CSP, SSL/TLS, HTTP method filtering, kernel hardening      |
| **Performance**     | TCP BBR, Brotli + Gzip, browser caching, OPcache tuning, PHP-FPM slow log           |
| **Scheduler**       | TYPO3 Scheduler cronjob pre-configured (every 5 min, `/etc/cron.d/typo3-scheduler`) |
| **CLI context**     | `TYPO3_CONTEXT` auto-set from nginx config on every shell login (root + www-data)   |
| **Resume support**  | Interrupted installations resume at the last completed step                         |
| **Resource tuning** | `bin/tune-server.sh` — PHP-FPM + MariaDB tuned to server RAM/CPU                    |
| **SSH hardening**   | `bin/harden-ssh.sh` — interactive port change, key-only auth, Hetzner-aware         |
| **Slow log**        | `bin/toggle-php-slowlog.sh` — enable/disable PHP-FPM slow log (threshold 2s)        |

## Requirements

| Requirement          | Details                                                                  |
|----------------------|--------------------------------------------------------------------------|
| OS                   | Ubuntu 22.04 LTS or 24.04 LTS (fresh installation, nothing else running) |
| RAM                  | 2 GB minimum recommended                                                 |
| Disk                 | 4 GB free on `/`                                                         |
| Internet             | Required (apt, Composer, GitHub for Brotli source)                       |
| SSH key              | Public key in `/root/.ssh/authorized_keys` before running                |
| Conflicting services | No Apache2, no existing Nginx site configs, ports 80/443 free            |

The installer runs a pre-flight check at startup and will stop or warn if any of these conditions are not met.

Update and reboot before running the installer:

```bash
apt update && apt --assume-yes dist-upgrade && apt --assume-yes autoremove
reboot
```

> The script detects pending reboots via `/var/run/reboot-required` and will stop if a reboot is required.

Add your SSH public key before running (required for key-only login after SSH hardening):

```bash
# From your local machine:
ssh-copy-id root@<server-ip>
# Or paste directly on the server:
mkdir -p /root/.ssh && echo "ssh-rsa AAAA..." >> /root/.ssh/authorized_keys
```

VirtualBox only — disable IPv6 if needed:

```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

### Network / Firewall

This script is designed for servers protected by a network-level firewall (e.g. Hetzner Cloud Firewall). The following
services are **not** secured at the application level against external access:

| Service | Port | Notes                                                                |
|---------|------|----------------------------------------------------------------------|
| MariaDB | 3306 | Binds to localhost only by default                                   |
| Redis   | 6379 | `requirepass` configured — password stored in `.env` as `REDIS_PASS` |

**Recommended firewall rules** (allow inbound only):

| Port     | Protocol | Purpose                                               |
|----------|----------|-------------------------------------------------------|
| 80       | TCP      | HTTP                                                  |
| 443      | TCP      | HTTPS                                                 |
| 22 / 222 | TCP      | SSH (close port 22 after running `bin/harden-ssh.sh`) |

On Hetzner Cloud, configure this via the Cloud Firewall in your project settings.

## Installation

```bash
git clone git@github.com:oliverthiele/server-install.git
cd server-install
chmod +x install.sh
sudo ./install.sh
```

The installer runs interactively and asks for: TYPO3 version, PHP version, domain, and admin email. At the end it
optionally runs `bin/tune-server.sh` and `bin/harden-ssh.sh`.

## Project Structure

```
server-install/
├── install.sh                          # Main entry point, orchestrates all steps
├── bin/
│   ├── tune-server.sh                  # Resource tuning (PHP-FPM + MariaDB)
│   ├── harden-ssh.sh                   # Interactive SSH hardening (port change, key-only auth)
│   └── toggle-php-slowlog.sh           # Enable/disable PHP-FPM slow log
├── lib/
│   ├── state.sh                        # Resume support: saveConfig(), loadConfig(), isStepComplete()
│   ├── config.sh                       # Interactive prompts: TYPO3 version, domain, email
│   ├── utils.sh                        # generatePassword(), getUbuntuVersionAndSetPhpVersion()
│   ├── system.sh                       # System packages, Composer, PHP PPA, Node.js, Zsh
│   ├── php.sh                          # PHP-FPM settings, OPcache, php-redis
│   ├── database.sh                     # MariaDB: create database and user
│   ├── nginx.sh                        # Nginx + Brotli, site config, fileadmin CSP
│   ├── typo3.sh                        # TYPO3 Composer install, activation, .env setup
│   ├── users.sh                        # www-data user, SSH keys, file permissions
│   └── security.sh                     # SSH, MariaDB, kernel, SSL/TLS, logrotate
└── config/
    └── nginx/
        └── snippets/
            ├── bot-filter.nginx        # Bot and AI crawler filtering
            ├── security.nginx          # Security headers
            ├── caching.nginx           # Browser caching rules
            ├── typo3-rewrite.nginx     # TYPO3 URL rewrites
            ├── method-filter.nginx     # HTTP method filtering
            ├── monit.nginx             # Example: reverse proxy for a local web UI (e.g. Monit on :2812)
            └── BasicAuth.nginx         # Basic auth with IP whitelist
```

## What Gets Installed

### Web Server Stack

- **Nginx** with dynamically compiled Brotli module (matched to installed nginx version)
- **PHP-FPM** — version depends on Ubuntu release (8.3 on 24.04, 8.1 on 22.04, 7.4 on 20.04¹)
- **MariaDB** — MySQL-compatible, automatically hardened
- **Redis** — page and section cache for TYPO3, secured with `requirepass`

### PHP Extensions

`fpm` `cli` `gd` `mysql` `xml` `mbstring` `intl` `yaml` `opcache` `curl` `zip` `soap` `apcu` `redis`

### Tools

- **Composer** — verified checksum install
- **Node.js v22** — via nvm, installed for `www-data`
- **ImageMagick** — image processing with AVIF support (via libheif)
- **Certbot** — Let's Encrypt SSL certificates
- **Zsh** — with oh-my-zsh and agnoster theme
- **Git, tig, jq** — development utilities

## Resource Tuning

`bin/tune-server.sh` calculates optimal settings based on available RAM and CPU. Safe to re-run after server rescaling (
e.g. Hetzner Cloud).

```bash
bin/tune-server.sh --dry-run   # Preview without applying
bin/tune-server.sh             # Apply interactively
```

| Service | Parameter                      | Formula                        |
|---------|--------------------------------|--------------------------------|
| PHP-FPM | `pm.max_children`              | `RAM × 40% ÷ 80 MB per worker` |
| PHP-FPM | `pm.start_servers`             | `max_children ÷ 4`             |
| PHP-FPM | `pm.min/max_spare_servers`     | derived from `max_children`    |
| MariaDB | `innodb_buffer_pool_size`      | `RAM × 35%`                    |
| MariaDB | `innodb_buffer_pool_instances` | `min(pool_GB, 8)`              |
| MariaDB | `max_connections`              | `RAM ÷ 4 MB`, max 500          |
| MariaDB | `thread_cache_size`            | CPU core count                 |
| MariaDB | `table_open_cache`             | `max_connections × 4`          |

PHP-FPM: modifies `pool.d/www.conf` (timestamped backup created before each run).
MariaDB: writes a clean drop-in at `/etc/mysql/mariadb.conf.d/99-tuning.conf`.

## TYPO3 Configuration

The installer creates:

- Installation path: `/var/www/typo3/`
- Database: `typo3_1` / DB user: `typo3` (20-char random password — uppercase, lowercase, digit, symbol)
- Admin user: `typo3-admin` (20-char random password — meets TYPO3 password policy)
- Redis: `requirepass` enabled (20-char random password)

All credentials are written to `/var/www/typo3/install-log-please-remove.log` (mode 600).

### Automated Setup

TYPO3 is set up automatically via `vendor/bin/typo3 setup` (native TYPO3 CLI, available since v12.4). No manual web
wizard needed. If the automated setup fails, `FIRST_INSTALL` is kept and the web wizard is available at
`http://domain/typo3/install.php`.

### Installed TYPO3 Extensions

**System extensions:** adminpanel, lowlevel, redirects, recycler, workspaces, linkvalidator, reports, opendocs,
scheduler

**Community extensions:** plan2net/webp (automatic WebP delivery)

**Dev dependencies:** typo3/coding-standards, ssch/typo3-rector

> These are installed to support TYPO3 updates and code quality checks directly on the server. To remove them from a
> purely production environment: `sudo -u www-data composer install --no-dev`

### additional.php — Override Behaviour

System settings are configured in `config/system/additional.php`. This file is loaded **after**
`config/system/settings.php` and always takes precedence.

> **Important for integrators:** Settings defined in `additional.php` cannot be changed through the TYPO3 Install Tool
> or Admin Panel. Any value saved there will be silently overridden on the next request. To change these settings, edit
`additional.php` directly on the server.

Settings locked in `additional.php`:

| Setting                   | Value                                | Reason                                                |
|---------------------------|--------------------------------------|-------------------------------------------------------|
| `SYS/fileCreateMask`      | `0660`                               | Files must not be world-readable                      |
| `SYS/folderCreateMask`    | `2770`                               | Setgid bit ensures group inheritance; no world access |
| `SYS/trustedHostsPattern` | derived from `DOMAIN` in `.env`      | Managed via environment variable                      |
| `DB/*`                    | from `.env`                          | Managed via environment variable                      |
| `GFX/processor`           | `ImageMagick`                        | Required for AVIF support                             |
| `GFX/processor_path`      | `/usr/bin/`                          | Standard path for ImageMagick on Ubuntu               |
| Redis cache backends      | `pages` (DB 0), `pagesection` (DB 1) | Requires `REDIS_PASS` from `.env`                     |

### Environment Configuration

Configuration via `.env` files:

- `.env` — Production
- `.env.development` — Development (auto-copied from `.env` after install)
- `.env.staging` — Staging (create manually)

```bash
PROJECT_NAME="My TYPO3 Site"
DOMAIN="example.com"

DB_DB="typo3_1"
DB_USER="typo3"
DB_PASS="generated-password"
DB_HOST="localhost"

ENCRYPTION_KEY="generated-key"
TYPO3_INSTALL_TOOL="argon2-hash"
REDIS_PASS="generated-password"

SMTP_SERVER="mail.example.com:587"
SMTP_USER="smtp-user"
SMTP_PASSWORD="smtp-password"
SMTP_TRANSPORT_ENCRYPT=1

DEFAULT_MAIL_FROM_ADDRESS="noreply@example.com"
DEFAULT_MAIL_FROM_NAME="TYPO3 CMS"
```

### TYPO3 Context

Set in `/etc/nginx/sites-available/typo3.nginx`:

```nginx
fastcgi_param TYPO3_CONTEXT Development;
#fastcgi_param TYPO3_CONTEXT Production/Staging;
#fastcgi_param TYPO3_CONTEXT Production;
```

The nginx configuration is the **single source of truth** for the TYPO3 context. Both the CLI shell and the Scheduler
cronjob derive their context from it automatically:

- **CLI** (`root` and `www-data`): `TYPO3_CONTEXT` is set on every login by reading the active nginx config. No manual
  `export` needed — switching context in nginx and running `nginx -t && systemctl reload nginx` takes effect on the next
  shell session.
- **Scheduler**: reads the context from nginx at runtime (see `/etc/cron.d/typo3-scheduler`).

```bash
# Example: switch to Production
nano /etc/nginx/sites-available/typo3.nginx
# Uncomment: fastcgi_param TYPO3_CONTEXT Production;
nginx -t && systemctl reload nginx
# Next CLI login: $TYPO3_CONTEXT is automatically "Production"
```

### Scheduler

A cronjob is installed automatically at `/etc/cron.d/typo3-scheduler`:

```
*/5 * * * * www-data TYPO3_CONTEXT=$(…nginx config…) php vendor/bin/typo3 scheduler:run
```

Output is logged to syslog (`logger -t typo3-scheduler`). Tasks must still be created in the TYPO3 backend — the cronjob
only triggers execution.

## Nginx

### Fileadmin Content Security Policy

Uploaded files are served statically — PHP is never executed inside `fileadmin/`. CSP headers are applied selectively:

```nginx
location ^~ /fileadmin/ {
    try_files $uri =404;

    # Block server-side executable file types
    location ~* \.(php[0-9s]?|phar|phtml|cgi|pl|py|sh|bash|rb)$ {
        deny all;
    }

    # Strict CSP only for file types that can execute active content in the browser
    location ~* \.(html?|xhtml|xml|svg|svgz|js|mjs)$ {
        add_header Content-Security-Policy "default-src 'none'; base-uri 'none'; form-action 'none'; sandbox" always;
        add_header X-Content-Type-Options "nosniff" always;
        try_files $uri =404;
    }
}
```

Binary media files (mp4, mp3, PDF, images) are served without CSP to avoid browser compatibility issues.

### Bot / AI Crawler Filtering

During installation, you choose between two modes:

**Staging** — blocks all AI crawlers and SEO scrapers. Suitable for training systems, client preview environments, or
any server that should not be indexed.

**Production** *(default)* — blocks abusive scrapers and Bytedance/TikTok (known for high-volume crawling that can cause
server load). Major AI assistants are allowed through so the site remains discoverable via ChatGPT, Claude, Perplexity,
and Gemini.

| Bot                              | Staging | Production     |
|----------------------------------|---------|----------------|
| Bytespider (Bytedance/TikTok)    | blocked | always blocked |
| AhrefsBot, SemrushBot, DotBot    | blocked | blocked        |
| GPTBot, OAI-SearchBot (ChatGPT)  | blocked | allowed        |
| ClaudeBot, anthropic-ai (Claude) | blocked | allowed        |
| PerplexityBot                    | blocked | allowed        |
| Google-Extended (Gemini)         | blocked | allowed        |
| Empty User-Agent                 | blocked | blocked        |

Access can be refined per-site via `robots.txt` without changing the Nginx config.

### Security Headers

- `X-Frame-Options: SAMEORIGIN`
- `X-Content-Type-Options: nosniff`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy`

### Compression

- **Brotli** — level 6 (primary, modern browsers)
- **Gzip** — level 6 (fallback)

Pre-compressed formats (WOFF2, AVIF, WebP, JPEG, PNG) are excluded from compression.

### Browser Caching

- **Versioned assets** (CSS/JS with timestamp): `max-age=31536000, immutable`
- **`_assets/`** (extension assets): 1 year
- **Images**: 30 days
- **Fonts**: 1 year

## Security Hardening

### SSH Hardening

Basic hardening runs automatically during installation. The interactive port change runs at the end via
`bin/harden-ssh.sh`.

```bash
bin/harden-ssh.sh --dry-run   # Preview without applying
bin/harden-ssh.sh             # Apply interactively (default port: 222)
bin/harden-ssh.sh --yes       # Non-interactive, use defaults
```

Settings applied: custom port, password auth disabled, key-only root login, X11 off, MaxAuthTries 3, LoginGraceTime 30s,
UFW rule added automatically.

**Hetzner note:** Disabling SSH password auth does not affect Hetzner's "Reset Root Password" feature (QEMU Guest
Agent). After a password reset, use the **Hetzner Cloud Console** (web KVM) for emergency access. Keep
`qemu-guest-agent` installed.

### MariaDB Security

- Random root password saved to `/root/.my.cnf` (mode 600)
- Anonymous users removed
- Remote root login disabled
- Test database removed

### Kernel Optimizations

Written to `/etc/sysctl.d/99-typo3.conf` (idempotent):

- TCP BBR congestion control
- Increased file descriptor and network buffer limits
- SYN flood protection
- ICMP redirect protection
- inotify watches increased for TYPO3 file monitoring

### SSL/TLS Hardening

Config snippet at `/etc/nginx/snippets/ssl-hardening.nginx`:

- TLS 1.2 and 1.3 only
- Strong ECDHE cipher suites (x25519 preferred)
- OCSP stapling
- HSTS ready (commented — enable deliberately, see inline comment)

## Post-Installation

### 1. SSL Certificate

```bash
certbot --nginx -d example.com -d www.example.com
```

### 2. Edit .env

```bash
sudo -u www-data nano /var/www/typo3/.env
```

### 3. Set TYPO3 Context to Production

```bash
nano /etc/nginx/sites-available/typo3.nginx
# Change: fastcgi_param TYPO3_CONTEXT Production;
nginx -t && systemctl reload nginx
```

### 4. Save and delete install log

```bash
cat /var/www/typo3/install-log-please-remove.log
rm /var/www/typo3/install-log-please-remove.log
```

### 5. Delete installation state files

`/root/.typo3-install-state` and `/root/.typo3-install-config` are used by the installer for resume support.
`/root/.typo3-install-config` contains all generated passwords in plaintext and should be deleted once the
installation is verified and all credentials have been saved.

> **Note:** Keep `/root/.typo3-install-config` as long as you might need to recover passwords — for example if `.env`
> files are accidentally deleted. Once you are certain the credentials are backed up elsewhere, delete the file.

```bash
rm /root/.typo3-install-state /root/.typo3-install-config
```

## MariaDB

Root password is saved to `/root/.my.cnf` — no password prompt needed as root:

```bash
mysql
mysql -e "SHOW DATABASES;"
grep password /root/.my.cnf   # Retrieve password explicitly
```

## TYPO3 CLI

`TYPO3_CONTEXT` is set automatically on login (derived from the nginx config). No manual `export` needed.

```bash
sudo -u www-data -s

typo3 cache:flush
typo3 database:updateschema
typo3 scheduler:run
```

## Redis

### Authentication

Redis is secured with `requirepass` during installation. The password is stored in `/var/www/typo3/.env` as
`REDIS_PASS`.

```bash
# Connect with password
redis-cli -a "$(grep REDIS_PASS /var/www/typo3/.env | cut -d= -f2 | tr -d '"')"

# Test
redis-cli -a "<password>" ping   # Expected: PONG
```

### Cache Configuration

The `pages` and `pagesection` caches are pre-configured in `additional.php` to use Redis (databases 0 and 1). No manual
`settings.yaml` entry needed.

> **Note:** Redis cache settings in `additional.php` cannot be changed via the TYPO3 Install Tool —
> see [additional.php — Override Behaviour](#additionalphp--override-behaviour).

To add further caches (e.g. `hash`, `rootline`), edit `config/system/additional.php` directly.

## Custom Extensions

```bash
cd /var/www/typo3/packages/
composer require "vendor/extension:@dev"
```

## PHP-FPM Slow Log

The slow log is enabled by default (threshold: 2 seconds). It records stack traces for requests that exceed the
threshold — there is no overhead for fast requests.

```bash
bin/toggle-php-slowlog.sh           # Toggle on/off
bin/toggle-php-slowlog.sh enable    # Enable (2s threshold)
bin/toggle-php-slowlog.sh disable   # Disable
bin/toggle-php-slowlog.sh status    # Show current state
```

Log location: `/var/log/phpX.Y-fpm-slow.log`

## Troubleshooting

```bash
nginx -t                          # Nginx config test
systemctl status php8.4-fpm       # PHP-FPM status (adjust version)
redis-cli ping                    # Expected: PONG (requires -a <password> after install)
php -m | grep redis               # PHP Redis extension loaded?
bin/tune-server.sh --dry-run      # Review current tuning recommendations
bin/toggle-php-slowlog.sh status  # Check slow log state
```

TYPO3 v13 with a custom backend entry point — check `config/system/settings.yaml`:

```yaml
backend:
  entryPoint: /admin
```

---

> ¹ **Ubuntu 20.04** reached end-of-life in April 2025. PHP 7.4 (default on 20.04) is EOL since November 2022 and
> incompatible with TYPO3 v13. Use Ubuntu 22.04 or 24.04 for new installations.
>
> **Ubuntu 22.04** ships nginx 1.18.0, which does not support `ssl_reject_handshake`. The TYPO3 Environment check *"
HTTP_HOST contained unexpected host"* will show a warning on 22.04 systems — this is a known limitation for
> legacy/staging use and does not affect functionality.

## License

MIT License

## Author

Oliver Thiele