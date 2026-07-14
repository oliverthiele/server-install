# TYPO3 Server Installation Script

[![TYPO3](https://img.shields.io/badge/TYPO3-12.4_|_13.4_|_14-orange.svg)](https://typo3.org/)
[![PHP](https://img.shields.io/badge/PHP-8.1_|_8.3_|_8.4-blue.svg)](https://php.net/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04_|_24.04_|_26.04-E95420.svg)](https://ubuntu.com/)
[![Nginx](https://img.shields.io/badge/Nginx-Brotli-009639.svg)](https://nginx.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![shellcheck](https://github.com/oliverthiele/server-install/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/oliverthiele/server-install/actions/workflows/shellcheck.yml)

Automated bash installer for TYPO3 on Ubuntu Server. Sets up a complete production stack — Nginx with Brotli, PHP-FPM,
MariaDB, Redis, SSL hardening — and installs TYPO3 v12, v13, or v14 via Composer in one interactive run. Interrupted
installations can be resumed at any step.

> **Designed for fresh servers only.** This script is intended for newly provisioned Ubuntu servers with no existing
> web server, PHP installation, or TYPO3. Existing Nginx, Apache, or PHP configurations **will be overwritten without
> warning.** Do not run this on a server with active services or existing websites.

## Features

| Category            | Details                                                                             |
|---------------------|-------------------------------------------------------------------------------------|
| **TYPO3**           | v12.4 LTS, v13.4 LTS and v14 (interactive selection)                                |
| **Ubuntu**          | 22.04, 24.04, 26.04 (recommended) — 20.04 legacy¹                                   |
| **PHP**             | 8.1 / 8.3 / 8.4 — packages.sury.org repository for PHP 8.4 on 24.04                 |
| **Web server**      | Nginx with dynamically compiled Brotli module                                       |
| **Database**        | MariaDB with automated hardening                                                    |
| **Cache**           | Redis with `requirepass` authentication, page and section cache pre-configured      |
| **Security**        | SSH hardening, fileadmin CSP, SSL/TLS, HTTP method filtering, kernel hardening      |
| **fail2ban**        | SSH + nginx jails, TYPO3 login filter, rate-limit bans, IP allowlist                |
| **Auto updates**    | Unattended security upgrades (no automatic reboots)                                 |
| **Performance**     | TCP BBR, Brotli + Gzip, browser caching, OPcache tuning, PHP-FPM slow log           |
| **Scheduler**       | TYPO3 Scheduler cronjob pre-configured (every 5 min, `/etc/cron.d/typo3-scheduler`) |
| **CLI context**     | `TYPO3_CONTEXT` auto-set from nginx config on every shell login (root + www-data)   |
| **Resume support**  | Interrupted installations resume at the last completed step                         |
| **Resource tuning** | `bin/tune-server.sh` — PHP-FPM + MariaDB tuned to server RAM/CPU                    |
| **SSH hardening**   | `bin/harden-ssh.sh` — interactive port change, key-only auth, Hetzner-aware         |
| **Deploy user**     | `bin/setup-deploy-user.sh` — dedicated SSH login with `sudo -u www-data` (opt-in)   |
| **DB backup**       | `bin/backup-database.sh` — local dumps every 6 h (operator-error safety net)        |
| **Slow log**        | `bin/toggle-php-slowlog.sh` — enable/disable PHP-FPM slow log (threshold 2s)        |

## Requirements

| Requirement          | Details                                                                           |
|----------------------|-----------------------------------------------------------------------------------|
| OS                   | Ubuntu 22.04, 24.04, or 26.04 LTS (fresh installation, nothing else running)     |
| RAM                  | 2 GB minimum recommended                                                          |
| Disk                 | 4 GB free on `/`                                                                  |
| Internet             | Required (apt, Composer, GitHub for Brotli source)                                |
| SSH key              | Public key in `/root/.ssh/authorized_keys` before running                         |
| Conflicting services | No Apache2, no existing Nginx site configs, ports 80/443 free                     |

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

The installer runs interactively and asks for: TYPO3 version, PHP version, domain, admin email, bot filter mode,
BasicAuth, frontend login (paths for rate limiting + fail2ban, skippable), static fail2ban IP allowlist, and
Node.js version (24 or 22). At the end it optionally runs
`bin/tune-server.sh`, `bin/harden-ssh.sh`, `bin/setup-deploy-user.sh`, and `bin/backup-database.sh --install-cron`.

## Project Structure

```
server-install/
├── install.sh                             # Main entry point, orchestrates all steps
├── bin/
│   ├── tune-server.sh                     # Resource tuning (PHP-FPM + MariaDB)
│   ├── harden-ssh.sh                      # Interactive SSH hardening (port change, key-only auth)
│   ├── setup-deploy-user.sh               # Dedicated deploy user instead of direct www-data SSH login
│   ├── backup-database.sh                 # Local DB dumps: excludes, space check, retention, cron
│   ├── check-image-processing.sh          # GFX processor + WebP conversion health (run after migrations)
│   ├── add-php-version.sh                 # Install an additional PHP version side by side
│   ├── apply-php-settings.sh              # Re-apply optimized PHP settings after updates
│   ├── migrate-php-repo.sh                # Switch existing servers from ppa:ondrej/php to packages.sury.org
│   ├── toggle-php-slowlog.sh              # Enable/disable PHP-FPM slow log
│   └── bot-policy/                        # Bot/crawler/search-engine rule management (whiptail TUI)
│       ├── bot-policy.sh                  # Entry point: --report / --activate / --seed / interactive menu
│       ├── lib/                           # storage.sh, render.sh, menu.sh, report.sh
│       └── data/default-bots.json         # Built-in catalog (~55 bots, seeded into /etc/bot-policy/)
├── lib/
│   ├── state.sh                           # Resume support: saveConfig(), loadConfig(), isStepComplete()
│   ├── config.sh                          # Interactive prompts: TYPO3 version, domain, email, bot filter
│   ├── utils.sh                           # generatePassword(), getUbuntuVersionAndSetPhpVersion()
│   ├── system.sh                          # System packages, Composer, PHP repository, Node.js, Zsh
│   ├── php.sh                             # PHP-FPM settings, OPcache, php-redis
│   ├── database.sh                        # MariaDB: create database and user
│   ├── nginx.sh                           # Nginx + Brotli, site config, fileadmin CSP
│   ├── typo3.sh                           # TYPO3 Composer install, activation, .env setup
│   ├── users.sh                           # www-data user, SSH keys, file permissions
│   ├── security.sh                        # SSH, MariaDB, kernel, SSL/TLS, logrotate, unattended upgrades
│   └── fail2ban.sh                        # fail2ban jails and custom filters (nginx, TYPO3 login)
└── config/
    └── nginx/
        └── snippets/
            ├── bot-filter.nginx           # Generated by bin/bot-policy — placeholder only, do not edit
            ├── exploit-filter.nginx       # SQL injection / path traversal / spam query filtering
            ├── typo3-security-filter.nginx # TYPO3-specific attack signatures
            ├── security.nginx             # Security headers
            ├── caching.nginx              # Browser caching rules
            ├── typo3-rewrite.nginx        # TYPO3 URL rewrites
            ├── method-filter.nginx        # HTTP method filtering
            ├── rate-limiting-zones.nginx  # limit_req zones (http context)
            ├── rate-limiting-login.nginx  # Rate limiting for TYPO3 login paths
            ├── backend-ip-restriction.nginx # Opt-in: IP allowlist for /typo3/ (disabled by default)
            ├── monit.nginx                # Example: reverse proxy for a local web UI (e.g. Monit on :2812)
            └── BasicAuth.nginx            # Basic auth with IP whitelist
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
- **Node.js 24 LTS** — via nvm, installed for `www-data` (22 selectable for legacy frontend builds)
- **ImageMagick** — image processing with AVIF support (via libheif)
- **Ghostscript** — PDF rendering backend for ImageMagick
- **poppler-utils** — `pdftotext` / `pdfinfo` for TYPO3 indexed_search and ke_search PDF indexing
- **catdoc** — `catdoc` / `xls2csv` / `catppt` for Word, Excel, PowerPoint text extraction (indexed_search, ke_search)
- **exiftool** — IPTC / XMP / GPS metadata extraction from uploaded images and documents (FAL)
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

All credentials are written to `/var/www/typo3/install-log-please-remove.md` (mode 600).

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

Bot and crawler rules are managed by `bin/bot-policy/bot-policy.sh`, a standalone whiptail TUI — no manual editing
of `/etc/nginx/snippets/bot-filter.nginx` required (it is a generated file, overwritten on every activation).

During installation, the built-in catalog (`bin/bot-policy/data/default-bots.json`, ~55 bots/crawlers/search engines
with vendor info and short background) is seeded into `/etc/bot-policy/` according to the chosen mode:

**Staging** — blocks all AI crawlers and SEO scrapers/aggressive crawlers too. Suitable for training systems, client
preview environments, or any server that should not be indexed.

**Production** *(default)* — blocks abusive scrapers and SEO/scraping tools. Major AI assistants (ChatGPT, Claude,
Perplexity, Gemini, ...) are allowed through so the site remains discoverable via AI search.

Each bot has one of four rules:

| Rule           | Effect                                                                          |
|----------------|----------------------------------------------------------------------------------|
| Allow          | No restriction                                                                    |
| Block search   | Blocked only on the configured site-search URL(s), rest of the site stays crawlable |
| Block full     | Blocked everywhere (`444`)                                                        |
| Always allow   | Overrides every other rule — used for uptime monitoring (HetrixTools) and E2E test runners (Playwright) |

"Block search" exists for bots that are otherwise fine to allow but have caused excessive load against the site
search (e.g. a Solr-backed TYPO3 search) — it avoids either fully blocking a bot or leaving an expensive endpoint
open to it. Configure the search URL path(s) via the tool's "Such-Pfade verwalten" menu.

Changes go to a draft first — nothing reaches the live nginx config until an explicit "Einstellungen aktivieren",
which backs up the previous state, tests with `nginx -t`, and rolls back automatically on failure. Run
`bin/bot-policy/bot-policy.sh --report` for a customer-ready plain-text summary of the current draft (add `--active`
for the live state), or `--activate` to apply non-interactively.

```
bin/bot-policy/bot-policy.sh                    # Interactive menu
bin/bot-policy/bot-policy.sh --report            # Report of the draft (not yet active)
bin/bot-policy/bot-policy.sh --report --active   # Report of the live policy
bin/bot-policy/bot-policy.sh --activate          # Apply the draft non-interactively
```

### Backend IP Restriction (opt-in)

`/etc/nginx/snippets/backend-ip-restriction.nginx` restricts `/typo3/` to an IP allowlist (office, VPN). It is
generated on every install but **disabled by default** — the include line in `typo3.nginx` is commented out and the
example IPs use RFC 5737 documentation ranges that match nobody.

To enable: edit the allowlist in the snippet, uncomment the include in
`/etc/nginx/sites-available/typo3.nginx`, and follow the TYPO3 v12/v13 note inside the snippet (the
`location /typo3/` block in `typo3-rewrite.nginx` must be commented out — `nginx -t` fails loudly if you forget).

This is an additional layer for setups where backend users work from known networks. It does not replace strong
backend passwords or MFA.

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
- **Images**: 30 days (with WebP variant delivery — pre-generated `.webp` files from plan2net/webp are
  served automatically when the browser accepts them)
- **Fonts**: 1 year
- **Media / PDF**: 7 days

The `^~ /fileadmin/` security location stops nginx regex matching, so the general caching rules do not
apply there — the fileadmin block therefore contains its own nested cache locations (images 30 days,
fonts 1 year, media/PDF 7 days, SVG with CSP + 30 days). Security rules (recycler, executable files,
CSP) always take precedence over caching.

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

### Deploy User (opt-in)

By default the installer copies root's SSH key to `www-data`, which allows direct SSH login as the site owner.
`bin/setup-deploy-user.sh` provides a stricter alternative: a dedicated login user (default: `deploy`) with its own
SSH key, membership in the `www-data` group, and a sudo rule limited to running commands as `www-data`:

```bash
bin/setup-deploy-user.sh --dry-run   # Preview without applying
bin/setup-deploy-user.sh             # Interactive (asks for username and SSH key)
```

After the deploy login is confirmed working, the script can disable the direct `www-data` SSH login (the key file
is backed up, so this is reversible). Daily work then looks like:

```bash
ssh -p 222 deploy@server
sudo -u www-data -i                      # interactive shell as www-data
sudo -u www-data composer install        # single commands
```

The sudo rule is written to `/etc/sudoers.d/deploy` and validated with `visudo -cf` before installation.

### fail2ban

Installed and enabled during installation. All nginx jails ban on ports `http,https` only — a web attack never
locks an IP out of SSH. The installer asks for **static** `ignoreip` entries (company office with fixed IP, or a
VPN server admins connect through) — never add dynamic home/mobile IPs, as stale entries whitelist strangers once
the provider reassigns them. Entries can be added later in `/etc/fail2ban/jail.local` + `systemctl reload fail2ban`.

The `typo3-fe-login` jail and the login rate limiting are only configured when the installer question "Will this
site have a frontend login?" is answered with yes; otherwise a placeholder snippet documents how to enable both
later.

| Jail                    | Watches                                        | maxretry | bantime |
|-------------------------|------------------------------------------------|----------|---------|
| `sshd`                  | SSH login failures (systemd journal)           | 3        | 24 h    |
| `nginx-http-auth`       | BasicAuth failures                             | 3        | 1 h     |
| `nginx-botsearch`       | Requests for known bot/scanner paths           | 2        | 24 h    |
| `nginx-limit-req`       | nginx `limit_req` violations (error log)       | 5        | 1 h     |
| `nginx-sqli-lfi`        | SQL injection, LFI, XSS, recon probes          | 1        | 24 h    |
| `nginx-4xx`             | Repeated 4xx responses (400/404 excluded)      | 20       | 1 h     |
| `nginx-login-ratelimit` | 429 responses from login rate limiting         | 3        | 6 h     |
| `typo3-fe-login`        | Failed TYPO3 frontend logins (status 200/403)¹ | 5        | 6 h     |

¹ Only when a frontend login was configured during installation.

The `typo3-fe-login` filter only counts POST requests answered with status 200 or 403 — successful logins redirect
with 302/303 and are never counted, so users who log in several times in a row are not banned. The SQLi/LFI filter
matches case-insensitively and additionally bans single requests to paths that never exist on a TYPO3 site
(`wp-login.php`, `xmlrpc.php`, `/.env`, `/.git/`, phpMyAdmin).

Useful commands:

```bash
fail2ban-client status                        # list jails
fail2ban-client status typo3-fe-login         # banned IPs of one jail
fail2ban-client set typo3-fe-login unbanip 203.0.113.10
```

### Unattended Security Upgrades

`unattended-upgrades` is installed and enabled: security updates from the Ubuntu security pocket are applied
automatically every day. Automatic reboots are explicitly disabled — kernel updates are installed, but the reboot
remains a manual decision (`/var/run/reboot-required` signals when one is pending).

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
cat /var/www/typo3/install-log-please-remove.md
rm /var/www/typo3/install-log-please-remove.md
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

## Database Backup

> **Scope: operator errors only.** These dumps live on the same machine — they protect against accidental
> deletions, broken deployments, and failed updates, but **not** against server compromise, ransomware, or data
> center failure. For that you need backups the server itself cannot delete: either pull-based (a backup host
> fetches the dumps), or push with append-only credentials plus storage-side snapshots (e.g. restic/borg to a
> Hetzner Storage Box with snapshots enabled). Hetzner Cloud Backups are also stored outside the server — they
> cannot be deleted from within it as long as no Hetzner API token is stored on the machine.

`bin/backup-database.sh` dumps every non-system database to `/var/backups/mysql/` (gzip, mode 600):

```bash
bin/backup-database.sh                   # Run one backup now
bin/backup-database.sh --dry-run         # Show databases, sizes, excluded tables — no dump
bin/backup-database.sh --install-cron    # Install cron (every 6 h) and run an initial backup
bin/backup-database.sh --install-cron=12 # Same, every 12 hours
```

The installer offers `--install-cron` at the end of a run. The cron job logs to `/var/log/typo3-db-backup.log`
and runs at minute 17 to avoid top-of-the-hour load.

**What is excluded:** the dump always contains the **schema of all tables**, but no **data** for `sys_log`
(pure log, often the largest table), `sys_history` (editors' change history — remove it from
`EXCLUDED_TABLE_NAMES` in the script if your editors rely on record rollback after a restore), `cache_*`
(rebuilt automatically), and `be_sessions` / `fe_sessions` (transient). After a restore all tables exist —
the excluded ones are simply empty — and TYPO3 starts right away.

**Disk space check:** before each dump the script estimates the compressed size (50 % of the included
data+index bytes — conservative; real dumps are usually smaller) and skips the dump with a non-zero exit code
if free space would drop below 200 MB headroom.

**Retention:** dumps older than 7 days are deleted (`RETENTION_DAYS`, override via environment or edit the
script). With the 6-hour default this keeps at most 28 dumps per database.

Restore:

```bash
gunzip < /var/backups/mysql/<database>-<timestamp>.sql.gz | mysql <database>
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
bin/check-image-processing.sh     # GFX processor + WebP conversion health
```

### Image Processing / Broken WebP Images

A `settings.php` brought along by a site migration can reference a graphics processor (e.g. GraphicsMagick)
that is not installed on this server. TYPO3 then silently fails every **new** image processing — existing
`_processed_` files keep working, so the breakage stays invisible until an editor uploads a new image.
plan2net/webp additionally leaves 0-byte `.webp` files behind, which nginx serves as broken images to
WebP-capable browsers.

`bin/check-image-processing.sh` detects this: it verifies the configured processor binary exists, runs a
real JPEG→WebP test conversion, checks PHP GD WebP support, and counts 0-byte `.webp` leftovers under
`fileadmin` (exit code 1 if anything fails — suitable for monitoring). **Run it after every site migration.**

**`ondrej/php` PPA: "Repository ... changed its 'Label' value ... Use https://packages.sury.org/php/ instead"**

Ondřej Surý is migrating PHP packages from the Launchpad PPA to `packages.sury.org`, since Launchpad's
build infrastructure has become unreliable. `apt update` refuses the changed Release metadata until
acknowledged:

```bash
apt update --allow-releaseinfo-change-label   # silences the warning, PPA stays in use
bin/migrate-php-repo.sh --dry-run             # review the switch to packages.sury.org
bin/migrate-php-repo.sh                       # switch the server's PHP source permanently
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