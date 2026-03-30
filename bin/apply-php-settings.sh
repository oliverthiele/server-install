#!/bin/bash

# apply-php-settings.sh – Apply central PHP settings to all installed PHP versions
#
# Reads config/php-settings.sh and writes all values to the php.ini (FPM) and
# the PHP-FPM pool config of every installed PHP version. Ensures that all PHP
# versions on the server share the same upload limits, memory settings, and
# OPcache configuration.
#
# Safe to run multiple times. Run after editing config/php-settings.sh or after
# adding a new PHP version via bin/add-php-version.sh.
#
# Usage:
#   bin/apply-php-settings.sh            # Apply settings to all PHP versions
#   bin/apply-php-settings.sh --dry-run  # Show what would be changed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"
# shellcheck source=../config/php-settings.sh
source "${SCRIPT_DIR}/../config/php-settings.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; echo "Usage: $0 [--dry-run]"; exit 1 ;;
  esac
done

# ── Root check ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root"
fi

# ── Detect all installed PHP-FPM versions ─────────────────────────────────────

PHP_VERSIONS=()
for phpIni in /etc/php/*/fpm/php.ini; do
  [ -f "${phpIni}" ] || continue
  version=$(echo "${phpIni}" | grep -oP '/etc/php/\K[0-9]+\.[0-9]+')
  PHP_VERSIONS+=("${version}")
done

if [ "${#PHP_VERSIONS[@]}" -eq 0 ]; then
  die "No PHP-FPM installations found under /etc/php/*/fpm/php.ini"
fi

echo -e "${COLOR_CYAN}${COLOR_BOLD}PHP Settings — applying to ${#PHP_VERSIONS[*]} version(s): ${PHP_VERSIONS[*]}${COLOR_NC}"
if $DRY_RUN; then
  echo -e "${COLOR_YELLOW}Dry-run mode — no changes will be written${COLOR_NC}"
fi
echo "───────────────────────────────────────────────────────────────"

# ── Helper: set a value in php.ini ────────────────────────────────────────────

# Sets a php.ini directive regardless of its current value or comment state.
# Handles: active setting, commented-out setting, or missing entirely.
set_php_ini_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  if $DRY_RUN; then
    local current
    current=$(grep -E "^[;[:space:]]*${key}\s*=" "${file}" | tail -1 | sed 's/^[;[:space:]]*//')
    if [ -n "${current}" ]; then
      echo "  ${key}: ${current} → ${key} = ${value}"
    else
      echo "  ${key}: (not set) → ${key} = ${value}"
    fi
    return
  fi

  if grep -qE "^[;[:space:]]*${key}\s*=" "${file}"; then
    sed -i "s|^[;[:space:]]*${key}\s*=.*|${key} = ${value}|" "${file}"
  else
    echo "${key} = ${value}" >> "${file}"
  fi
}

# ── Helper: set a value in the FPM pool config ────────────────────────────────

set_fpm_pool_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  if $DRY_RUN; then
    local current
    current=$(grep -E "^[;[:space:]]*${key}\s*=" "${file}" | tail -1 | sed 's/^[;[:space:]]*//')
    if [ -n "${current}" ]; then
      echo "  ${key}: ${current} → ${key} = ${value}"
    else
      echo "  ${key}: (not set) → ${key} = ${value}"
    fi
    return
  fi

  if grep -qE "^[;[:space:]]*${key}\s*=" "${file}"; then
    sed -i "s|^[;[:space:]]*${key}\s*=.*|${key} = ${value}|" "${file}"
  else
    echo "${key} = ${value}" >> "${file}"
  fi
}

# ── Apply settings to each PHP version ────────────────────────────────────────

for version in "${PHP_VERSIONS[@]}"; do
  phpIni="/etc/php/${version}/fpm/php.ini"
  fpmPoolConfig="/etc/php/${version}/fpm/pool.d/www.conf"

  echo ""
  echo -e "${COLOR_BOLD}PHP ${version}${COLOR_NC}"

  if [ ! -f "${phpIni}" ]; then
    warn "php.ini not found: ${phpIni} — skipping"
    continue
  fi
  if [ ! -f "${fpmPoolConfig}" ]; then
    warn "FPM pool config not found: ${fpmPoolConfig} — skipping slow log settings"
  fi

  echo "  php.ini: ${phpIni}"
  set_php_ini_value "max_execution_time"          "${PHP_MAX_EXECUTION_TIME}"                  "${phpIni}"
  set_php_ini_value "max_input_time"              "${PHP_MAX_INPUT_TIME}"                      "${phpIni}"
  set_php_ini_value "max_input_vars"              "${PHP_MAX_INPUT_VARS}"                      "${phpIni}"
  set_php_ini_value "memory_limit"                "${PHP_MEMORY_LIMIT}"                        "${phpIni}"
  set_php_ini_value "post_max_size"               "${PHP_POST_MAX_SIZE}"                       "${phpIni}"
  set_php_ini_value "upload_max_filesize"         "${PHP_UPLOAD_MAX_FILESIZE}"                 "${phpIni}"
  set_php_ini_value "max_file_uploads"            "${PHP_MAX_FILE_UPLOADS}"                    "${phpIni}"
  set_php_ini_value "opcache.enable"              "${PHP_OPCACHE_ENABLE}"                      "${phpIni}"
  set_php_ini_value "opcache.memory_consumption"      "${PHP_OPCACHE_MEMORY_CONSUMPTION}"      "${phpIni}"
  set_php_ini_value "opcache.interned_strings_buffer" "${PHP_OPCACHE_INTERNED_STRINGS_BUFFER}" "${phpIni}"
  set_php_ini_value "opcache.max_accelerated_files"   "${PHP_OPCACHE_MAX_ACCELERATED_FILES}"   "${phpIni}"
  set_php_ini_value "opcache.revalidate_freq"         "${PHP_OPCACHE_REVALIDATE_FREQ}"         "${phpIni}"

  if [ -f "${fpmPoolConfig}" ]; then
    echo "  pool:   ${fpmPoolConfig}"
    set_fpm_pool_value "slowlog"                  "/var/log/php${version}-fpm-slow.log"        "${fpmPoolConfig}"
    set_fpm_pool_value "request_slowlog_timeout"  "${PHP_FPM_SLOW_LOG_TIMEOUT}"                "${fpmPoolConfig}"
  fi

  if ! $DRY_RUN; then
    if "/usr/sbin/php-fpm${version}" --test 2>/dev/null; then
      service "php${version}-fpm" restart
      echo -e "  ${COLOR_GREEN}✓ php${version}-fpm restarted${COLOR_NC}"
    else
      warn "PHP-FPM ${version} config invalid — not restarting (run: /usr/sbin/php-fpm${version} --test)"
    fi
  fi
done

echo ""
echo "───────────────────────────────────────────────────────────────"
if $DRY_RUN; then
  echo -e "${COLOR_YELLOW}Dry-run complete — no changes were written.${COLOR_NC}"
  echo    "Run without --dry-run to apply."
else
  echo -e "${COLOR_GREEN}${COLOR_BOLD}Done.${COLOR_NC} Settings applied to ${#PHP_VERSIONS[*]} PHP version(s)."
  echo    "To change settings: edit config/php-settings.sh and re-run this script."
fi