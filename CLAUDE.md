# ServerInstall – TYPO3 Installation Script

Bash-based installer for TYPO3 on Ubuntu servers. Supports TYPO3 v12 LTS and v13 LTS on Ubuntu 20.04, 22.04, and 24.04.

## Structure

```
install.sh          # Main entry point, orchestrates all steps
bin/
  tune-server.sh       # Resource tuning: PHP-FPM + MariaDB based on RAM/CPU (--dry-run supported)
  harden-ssh.sh        # Interactive SSH hardening: port change, key-only auth, UFW, Hetzner-aware
  setup-deploy-user.sh # Opt-in deploy user: own SSH login, sudo -u www-data, disable www-data login
  fix-permissions.sh   # Reset composerDirectory ownership/permissions to setPermissions() baseline
                       # (--dry-run supported); recovers from a deploy user working outside sudo -u www-data
  backup-database.sh   # Local DB dumps (operator-error safety net): excludes log/cache/session data,
                       # disk space check, retention, --install-cron for /etc/cron.d/typo3-db-backup
  check-image-processing.sh # Health check: GFX processor installed? WebP conversion works?
                       # 0-byte .webp leftovers? Run after site migrations (migrated settings.php
                       # may reference a processor that is not installed on this server)
  migrate-php-repo.sh  # Switches an existing server from ppa:ondrej/php to packages.sury.org
lib/
  config.sh         # setVariables() – interactive prompts for TYPO3 version, domain, email
  utils.sh          # getUbuntuVersionAndSetPhpVersion(), generatePassword(), confirmInstallation()
  system.sh         # installDependencies(), addPhpRepo(), installSoftware(), installComposer(), ...
  php.sh            # installPhpRedis(), optimizePhpSettings()
  nginx.sh          # configureNginx(), compileNginxWithBrotli(), configureBrotliInNginx()
  database.sh       # createDatabase(), cleanTargetDirectoryAndDatabase()
  security.sh       # hardenSSH(), secureMariaDB(), optimizeKernel(), configureSSLHardening(),
                    # configureUnattendedUpgrades()
  fail2ban.sh       # installFail2ban() – jails (port=http,https) + custom filters (SQLi/LFI, 4xx,
                    # login rate limit, TYPO3 FE login with 200/403 status filter)
  users.sh          # configureWwwUser(), setPermissions()
  typo3.sh          # installTypo3(), activateTypo3()
  state.sh          # saveConfig(), loadConfig(), markStepComplete(), isStepComplete()
config/
  nginx/snippets/   # Nginx snippet files (*.nginx) copied to /etc/nginx/snippets/
```

## Key Global Variables

| Variable         | Set in    | Description                                           |
|------------------|-----------|-------------------------------------------------------|
| `ubuntuVersion`  | utils.sh  | e.g. `24.04`                                          |
| `phpVersion`     | utils.sh  | e.g. `8.3` or `8.4`                                   |
| `requiresPhpPpa` | utils.sh  | `true` if the packages.sury.org PHP repository is needed (PHP 8.4 on 24.04) |
| `pathToPhpIni`   | utils.sh  | `/etc/php/${phpVersion}/fpm/php.ini`                  |
| `typo3Version`   | config.sh | e.g. `^13.4`                                          |
| `serverDomain`   | config.sh | Domain or `_` for IP-based setup                      |
| `nodeVersion`    | config.sh | Node.js major version for nvm installs, e.g. `24` (default) or `22` |
| `adminEmail`     | config.sh | Used for Certbot, TYPO3 admin BE user email           |

All variables are exported for use across sourced scripts.

## PHP Version Selection (Ubuntu 24.04)

Ubuntu 24.04 ships PHP 8.3 by default. PHP 8.4 requires the **packages.sury.org** repository — the successor
to the `ppa:ondrej/php` Launchpad PPA, which Ondřej Surý is discontinuing due to unreliable Launchpad build
infrastructure (see `bin/migrate-php-repo.sh` for switching already-installed servers).

When PHP 8.4 is selected:

- `requiresPhpPpa=true` is set and persisted in the state config
- `addPhpRepo()` in `system.sh` installs the sury.org keyring + apt source before package installation
  (idempotent — skips if already configured). Also called from `bin/add-php-version.sh` when adding a PHP
  version that needs it, so the repo-setup logic exists in one place only.
- After `apt install`, `update-alternatives --set php /usr/bin/php8.4` pins the CLI version (prevents a newer
  PHP from becoming the default)
- `installPhpRedis()` uses `apt install php8.4-redis` (packages.sury.org provides current packages, no pecl
  needed)

For PHP 8.3 on Ubuntu 24.04 without the extra repository: php-redis is installed via `pecl` due to outdated
Ubuntu packages.

## State / Resume

Installation progress is tracked in:

- `/root/.typo3-install-state` – completed steps with timestamps
- `/root/.typo3-install-config` – all configuration variables including `REQUIRES_PHP_PPA` (persisted key name;
  now gates the packages.sury.org repository, not a PPA)

Interrupted installations can be resumed; each step is guarded by `isStepComplete`.

## Nginx

The TYPO3 site config is written to `/etc/nginx/sites-available/typo3.nginx`.
PHP-FPM socket path is dynamic: `unix:/var/run/php/php${phpVersion}-fpm.sock`
Nginx is compiled with Brotli (dynamic module) from source to match the installed nginx version.

`/fileadmin/` uses `location ^~ /fileadmin/` with a strict CSP (`default-src 'none'`) to prevent
execution of uploaded files. The `^~` modifier stops PHP-FPM regex from matching fileadmin requests.
The recycler block is nested inside the fileadmin location.

## File Permissions

`setPermissions()` in `users.sh` sets the site tree to `2770` (dirs, setgid) / `0660` (files),
owned `www-data:www-data`. The setgid bit only makes new files inherit the `www-data` **group** —
the write bit comes from the creating process's **umask**, not from the setgid bit. A deploy user
who is a `www-data` group member but works directly (not via `sudo -u www-data`) can therefore
create group-unwritable files, breaking write access for `www-data` (and other group members)
afterwards. `bin/fix-permissions.sh` re-applies the `setPermissions()` baseline standalone
(sources `config.sh` + `users.sh`, `--dry-run` supported); it excludes `install-log-please-remove.md`
from the `0660` sweep (kept at `0600` — plaintext credentials) and does not touch `/var/www/.ssh/`.

## Resource Tuning

`bin/tune-server.sh` reads RAM and CPU cores, calculates optimal values, and writes:

- PHP-FPM: modifies `/etc/php/${phpVersion}/fpm/pool.d/www.conf` (backup created before each run)
- MariaDB: clean drop-in at `/etc/mysql/mariadb.conf.d/99-tuning.conf` (safe to overwrite)

The installer asks at the end whether to run tuning immediately. Can also be run standalone at any time,
e.g. after rescaling a Hetzner Cloud server.

## SSH Hardening

Two-layer approach:

**Step 3 (automatic, non-interactive):** `hardenSSH()` in `security.sh` applies basic hardening during
installation (disable password auth, X11 off, MaxAuthTries, etc.) — but does **not** change the port.
Skipped silently if no authorized_keys are present.

**End of install (interactive):** `bin/harden-ssh.sh` handles the port change (default: 222) with
interactive confirmation. Can also be run standalone at any time.

### Hetzner specifics

- `PasswordAuthentication no` disables SSH password login only — Hetzner's "Reset Root Password"
  (QEMU Guest Agent) continues to work independently
- After a password reset, emergency access is via the **Hetzner Cloud Console** (web KVM), not SSH
- `qemu-guest-agent` must remain installed; the script warns if it is missing
- The script checks for UFW and opens the new port automatically if UFW is active