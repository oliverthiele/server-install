# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-03-14

Initial public release. A fully automated TYPO3 server installer for Ubuntu 20.04,
22.04, and 24.04 — from bare root server to a production-ready TYPO3 installation
in a single script run.

### Added

**Core installer**
- Interactive prompts for TYPO3 version (v12.4 LTS / v13.4 LTS), domain, admin email,
  admin real name, and bot filter mode
- Resume support: interrupted installations can be continued from the last completed step
  (`/root/.typo3-install-state`, `/root/.typo3-install-config`)
- Pre-flight checks: Ubuntu version, SSH keys, disk space, RAM, internet connectivity,
  port conflicts
- Colorized output with `warn` / `die` helpers; colors disabled automatically in
  non-terminal contexts (e.g. piped/logged output)

**System**
- Nginx compiled from source with Brotli dynamic module (matched to installed Nginx version)
- PHP 8.3 (Ubuntu default) or PHP 8.4 via ondrej/php PPA — selected interactively
- MariaDB, Redis, ImageMagick (with AVIF support via libheif1), Ghostscript, Node.js via nvm,
  Composer, Zsh + Oh My Zsh + zsh-syntax-highlighting
- AVIF shared library (`libavif16` / `libavif13`) installed before php-gd for full GD AVIF support
- Let's Encrypt Certbot with nginx plugin

**PHP**
- Optimized `php.ini` settings: memory, upload limits, OPcache, realpath cache
- php-redis installed via `apt` (PHP 8.4 + ondrej PPA) or `pecl` (PHP 8.3 without PPA)
- PHP-FPM config validated with `--test` before every restart

**Nginx**
- TYPO3-optimized site config with FastCGI caching headers, security headers, gzip + Brotli
- Strict CSP for `/fileadmin/` (`default-src 'none'`) to prevent execution of uploaded files;
  recycler block nested inside the fileadmin location
- Bot filter with two modes: staging (block all AI crawlers) and production (block abusive
  bots, allow ChatGPT, Claude, Perplexity, Gemini; Bytespider always blocked)
- Dynamic PHP-FPM socket path (`php${version}-fpm.sock`)
- `TYPO3_CONTEXT` auto-detected from nginx config in Zsh shell profile

**Security**
- SSH hardening (non-interactive): password auth disabled, X11 off, MaxAuthTries 3,
  LoginGraceTime 30s — skipped silently if no authorized_keys are present
- `bin/harden-ssh.sh`: interactive SSH port change (default: 222), UFW rule added
  automatically; Hetzner QEMU Guest Agent compatibility preserved
- SSL/TLS: TLS 1.2/1.3, ECDHE-only ciphers, `ssl_ecdh_curve X25519:secp384r1:secp256r1`
  for SSL Labs Key Exchange 100; HSTS kept commented with explanation (risky on shared subdomains)
- MariaDB hardened: random root password in `/root/.my.cnf` (mode 600), anonymous users
  removed, remote root login disabled
- Redis secured with `requirepass`; password stored in `.env`
- Kernel hardening: connection queues, TIME_WAIT reuse, SYN flood protection

**TYPO3**
- Automated setup via native `typo3 setup` CLI (available since v12.4, no typo3_console required)
- Graceful fallback: if automated setup fails, `FIRST_INSTALL` is kept and the web wizard
  is available; retry command shown
- `config/system/additional.php` with full `.env` integration (vlucas/phpdotenv):
  DB credentials, encryption key, Install Tool password (argon2id hash), Redis password,
  SMTP, mail defaults, trusted hosts pattern
- Separate `.env.development` and `.env.staging` support
- ImageMagick explicitly configured as GFX processor (supports AVIF; GraphicsMagick does not)
- Redis cache backends pre-configured for `pages` and `pagesection` caches
- DDEV override block in `additional.php` for local development
- `BE.installToolPassword` set from `.env` in `additional.php` — single source of truth,
  independent of `settings.php`
- Scheduler cronjob (`/etc/cron.d/typo3-scheduler`) with dynamic `TYPO3_CONTEXT` from nginx
- Admin user email and real name set in `be_users` after successful setup
- System extensions installed: adminpanel, lowlevel, redirects, recycler, workspaces,
  linkvalidator, reports, opendocs, scheduler
- `helhum/typo3-console` installed for CLI tasks (database:updateschema, etc.)
- `plan2net/webp` installed for WebP image conversion
- Dev dependencies: typo3/coding-standards, ssch/typo3-rector
- Local Composer repository (`packages/`) pre-configured for sitepackage development
- Zsh aliases for `typo3` and `typo3cms` CLI commands

**Password generation**
- 20-character cryptographically secure passwords via `/dev/urandom` with rejection sampling
  (no modulo bias); guarantees at least one uppercase, lowercase, digit, and symbol —
  satisfies TYPO3's default password policy

**Resource tuning (`bin/tune-server.sh`)**
- Calculates optimal PHP-FPM worker count and MariaDB buffer pool based on available RAM and CPU
- `--dry-run` mode shows recommendations without applying them
- PHP-FPM pool config updated in place (backup created before each run)
- MariaDB tuning written as clean drop-in (`/etc/mysql/mariadb.conf.d/99-tuning.conf`)
- pm.* constraint assertion to catch invalid calculated values
- Config validated with `--test` before PHP-FPM restart

**Post-install**
- Credentials written to `/var/www/typo3/install-log-please-remove.log` (mode 600, www-data only)
- Colorized "INSTALLATION COMPLETE" summary with all credentials and numbered next steps
- ShellCheck CI workflow (GitHub Actions)

[1.0.0]: https://github.com/oliverthiele/server-install/releases/tag/v1.0.0