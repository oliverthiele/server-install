#!/bin/bash

# tune-server.sh – PHP-FPM and MariaDB resource tuning
#
# Reads available RAM and CPU cores, then calculates and applies optimal settings.
# Detects which PHP-FPM version(s) Nginx actively uses (via nginx -T) and sets
# the primary version automatically. Secondary versions are configured individually.
# Safe to run multiple times. Run after server rescaling.
#
# Usage:
#   bin/tune-server.sh            # Interactive mode
#   bin/tune-server.sh --dry-run  # Show recommendations without applying

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
SCRIPT_DIR_TUNE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR_TUNE}/../lib/utils.sh"

# ── Tuning ratios (adjust if needed) ──────────────────────────────────────────

PHP_WORKER_MB=80      # Estimated RAM per PHP-FPM worker (TYPO3: ~80 MB)
PHP_RAM_RATIO=40      # % of total RAM reserved for the primary PHP-FPM version
MARIADB_RAM_RATIO=35  # % of total RAM for InnoDB buffer pool

# ── Constants ─────────────────────────────────────────────────────────────────

STATE_CONFIG="/root/.typo3-install-config"
MARIADB_TUNING_CONF="/etc/mysql/mariadb.conf.d/99-tuning.conf"

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

PHP_POOL_CONFS=()
PHP_VERSIONS=()

for conf in /etc/php/*/fpm/pool.d/www.conf; do
  [ -f "$conf" ] || continue
  version=$(echo "$conf" | grep -oP '/etc/php/\K[0-9]+\.[0-9]+')
  PHP_POOL_CONFS+=("$conf")
  PHP_VERSIONS+=("$version")
done

if [ "${#PHP_POOL_CONFS[@]}" -eq 0 ]; then
  die "No PHP-FPM pool configs found under /etc/php/*/fpm/pool.d/www.conf"
fi

VERSION_COUNT="${#PHP_POOL_CONFS[@]}"

# ── Detect PHP-FPM versions referenced in Nginx (nginx -T expands all includes) ──

NGINX_PHP_VERSIONS=()
if command -v nginx &>/dev/null && nginx -t &>/dev/null 2>&1; then
  mapfile -t NGINX_PHP_VERSIONS < <(
    nginx -T 2>/dev/null \
      | grep -oP '(?<=fastcgi_pass unix:/var/run/php/php)[0-9]+\.[0-9]+(?=-fpm\.sock)' \
      | sort -uV
  )
fi

# ── Determine primary PHP version ─────────────────────────────────────────────

PRIMARY_VERSION=""

# ── Show detection results and determine primary ───────────────────────────────

echo ""
echo "============================================================"
echo "  PHP-FPM Version Detection"
echo "============================================================"

echo "  Installed PHP-FPM versions:"
for ver in "${PHP_VERSIONS[@]}"; do
  echo "    - PHP ${ver}"
done
echo ""

if [ "${#NGINX_PHP_VERSIONS[@]}" -eq 1 ]; then
  # Nginx uses exactly one version – auto-select, no question needed
  PRIMARY_VERSION="${NGINX_PHP_VERSIONS[0]}"
  echo "  Nginx uses PHP ${PRIMARY_VERSION} exclusively (detected via nginx -T)."
  [ "${VERSION_COUNT}" -gt 1 ] && echo "  Other installed versions will be treated as secondary."

elif [ "${#NGINX_PHP_VERSIONS[@]}" -gt 1 ]; then
  echo "  Nginx references multiple PHP-FPM versions: ${NGINX_PHP_VERSIONS[*]}"

elif [ "${#NGINX_PHP_VERSIONS[@]}" -eq 0 ]; then
  echo "  No PHP-FPM socket detected in Nginx config (nginx -T)."
fi

if [ -z "$PRIMARY_VERSION" ]; then
  # Build a default suggestion from multiple sources (priority order):
  # 1. Nginx (multiple versions referenced → pick newest)
  # 2. Installer state config
  # 3. Current PHP CLI version
  # 4. Newest installed PHP-FPM
  DEFAULT_VERSION=""
  if [ "${#NGINX_PHP_VERSIONS[@]}" -gt 1 ]; then
    DEFAULT_VERSION="${NGINX_PHP_VERSIONS[-1]}"
  fi
  if [ -z "$DEFAULT_VERSION" ] && [ -f "${STATE_CONFIG}" ]; then
    DEFAULT_VERSION=$(grep "^PHP_VERSION=" "${STATE_CONFIG}" | cut -d'=' -f2 | tr -d '"')
  fi
  if [ -z "$DEFAULT_VERSION" ] && command -v php &>/dev/null; then
    DEFAULT_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
  fi
  if [ -z "$DEFAULT_VERSION" ]; then
    DEFAULT_VERSION="${PHP_VERSIONS[-1]}"
  fi

  echo ""
  read -rp "  Which PHP version is the primary (main web app)? [${DEFAULT_VERSION}] " input
  PRIMARY_VERSION="${input:-$DEFAULT_VERSION}"
fi

echo ""
echo "  Primary:   PHP ${PRIMARY_VERSION}"
for ver in "${PHP_VERSIONS[@]}"; do
  [ "$ver" = "$PRIMARY_VERSION" ] && continue
  echo "  Secondary: PHP ${ver}"
done
echo "============================================================"

# ── Ask for secondary version worker counts ───────────────────────────────────

declare -A SECONDARY_MAX_CHILDREN

for ver in "${PHP_VERSIONS[@]}"; do
  [ "$ver" = "$PRIMARY_VERSION" ] && continue
  echo ""
  if printf '%s\n' "${NGINX_PHP_VERSIONS[@]}" | grep -qx "$ver"; then
    echo "  PHP ${ver} [secondary, referenced in Nginx]"
    default_workers=4
  else
    echo "  PHP ${ver} [secondary, not referenced in Nginx]"
    default_workers=0
  fi
  read -rp "  Max workers for PHP ${ver}? (0 = stop and disable service) [${default_workers}] " sec_input
  SECONDARY_MAX_CHILDREN["$ver"]="${sec_input:-$default_workers}"
done

# ── Read system resources ─────────────────────────────────────────────────────

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPU_CORES=$(nproc)

# ── Calculate primary PHP-FPM values ─────────────────────────────────────────

PHP_MAX_CHILDREN=$(( TOTAL_RAM_MB * PHP_RAM_RATIO / 100 / PHP_WORKER_MB ))
[ "${PHP_MAX_CHILDREN}" -lt 2 ] && PHP_MAX_CHILDREN=2

PHP_START_SERVERS=$(( PHP_MAX_CHILDREN / 4 ))
[ "${PHP_START_SERVERS}" -lt 1 ] && PHP_START_SERVERS=1

PHP_MIN_SPARE=$(( PHP_MAX_CHILDREN / 4 ))
[ "${PHP_MIN_SPARE}" -lt 1 ] && PHP_MIN_SPARE=1

PHP_MAX_SPARE=$(( PHP_MAX_CHILDREN / 2 ))
[ "${PHP_MAX_SPARE}" -lt 2 ] && PHP_MAX_SPARE=2

# PHP-FPM requires: min_spare_servers <= start_servers <= max_spare_servers
if [ "${PHP_MIN_SPARE}" -gt "${PHP_START_SERVERS}" ] || [ "${PHP_START_SERVERS}" -gt "${PHP_MAX_SPARE}" ]; then
  die "Internal error: calculated PHP-FPM values violate constraint (min_spare <= start_servers <= max_spare): min=${PHP_MIN_SPARE} start=${PHP_START_SERVERS} max=${PHP_MAX_SPARE} — adjust tuning ratios"
fi

# ── Calculate MariaDB values ──────────────────────────────────────────────────

INNODB_BUFFER_POOL_MB=$(( TOTAL_RAM_MB * MARIADB_RAM_RATIO / 100 ))

INNODB_BUFFER_POOL_INSTANCES=$(( INNODB_BUFFER_POOL_MB / 1024 ))
[ "${INNODB_BUFFER_POOL_INSTANCES}" -lt 1 ] && INNODB_BUFFER_POOL_INSTANCES=1
[ "${INNODB_BUFFER_POOL_INSTANCES}" -gt 8 ] && INNODB_BUFFER_POOL_INSTANCES=8

MAX_CONNECTIONS=$(( TOTAL_RAM_MB / 4 ))
[ "${MAX_CONNECTIONS}" -gt 500 ] && MAX_CONNECTIONS=500
[ "${MAX_CONNECTIONS}" -lt 50 ]  && MAX_CONNECTIONS=50

THREAD_CACHE_SIZE="${CPU_CORES}"
TABLE_OPEN_CACHE=$(( MAX_CONNECTIONS * 4 ))
[ "${TABLE_OPEN_CACHE}" -lt 400 ] && TABLE_OPEN_CACHE=400

# ── Display summary ───────────────────────────────────────────────────────────

get_pool_value() {
  local key="$1" conf="$2"
  grep "^${key}\s*=" "${conf}" | awk -F= '{print $2}' | tr -d ' ' || echo "?"
}

CURRENT_BUFFER_POOL="(none)"
if [ -f "${MARIADB_TUNING_CONF}" ]; then
  CURRENT_BUFFER_POOL=$(grep "^innodb_buffer_pool_size" "${MARIADB_TUNING_CONF}" \
    | awk -F= '{print $2}' | tr -d ' ' || echo "(none)")
fi

SECONDARY_TOTAL_MB=0
for ver in "${!SECONDARY_MAX_CHILDREN[@]}"; do
  [ "${SECONDARY_MAX_CHILDREN[$ver]}" -gt 0 ] \
    && SECONDARY_TOTAL_MB=$(( SECONDARY_TOTAL_MB + SECONDARY_MAX_CHILDREN["$ver"] * PHP_WORKER_MB ))
done
PHP_PRIMARY_MB=$(( PHP_MAX_CHILDREN * PHP_WORKER_MB ))
TOTAL_ESTIMATED_MB=$(( PHP_PRIMARY_MB + SECONDARY_TOTAL_MB + INNODB_BUFFER_POOL_MB ))

echo ""
echo "============================================================"
echo "  Server Resource Tuning"
echo "============================================================"
echo "  System:  ${TOTAL_RAM_MB} MB RAM  |  ${CPU_CORES} CPU cores"
echo ""

for i in "${!PHP_POOL_CONFS[@]}"; do
  conf="${PHP_POOL_CONFS[$i]}"
  ver="${PHP_VERSIONS[$i]}"
  cur_max=$(get_pool_value "pm.max_children"      "$conf")
  cur_sta=$(get_pool_value "pm.start_servers"     "$conf")
  cur_min=$(get_pool_value "pm.min_spare_servers" "$conf")
  cur_msp=$(get_pool_value "pm.max_spare_servers" "$conf")

  if [ "$ver" = "$PRIMARY_VERSION" ]; then
    echo "  PHP ${ver}  [primary]  (${conf})"
    printf "  %-26s  %6s  →  %s\n" "pm.max_children"       "${cur_max}" "${PHP_MAX_CHILDREN}"
    printf "  %-26s  %6s  →  %s\n" "pm.start_servers"      "${cur_sta}" "${PHP_START_SERVERS}"
    printf "  %-26s  %6s  →  %s\n" "pm.min_spare_servers"  "${cur_min}" "${PHP_MIN_SPARE}"
    printf "  %-26s  %6s  →  %s\n" "pm.max_spare_servers"  "${cur_msp}" "${PHP_MAX_SPARE}"
  else
    sec_max="${SECONDARY_MAX_CHILDREN[$ver]}"
    if [ "${sec_max}" -eq 0 ]; then
      echo "  PHP ${ver}  [secondary → will be disabled]"
      printf "  %-26s  %6s  →  %s\n" "service" "active" "stopped + disabled"
    else
      sec_start=$(( sec_max / 2 < 1 ? 1 : sec_max / 2 ))
      sec_spare=$(( sec_max / 2 < 1 ? 1 : sec_max / 2 ))
      echo "  PHP ${ver}  [secondary]  (${conf})"
      printf "  %-26s  %6s  →  %s\n" "pm.max_children"       "${cur_max}" "${sec_max}"
      printf "  %-26s  %6s  →  %s\n" "pm.start_servers"      "${cur_sta}" "${sec_start}"
      printf "  %-26s  %6s  →  %s\n" "pm.min_spare_servers"  "${cur_min}" "1"
      printf "  %-26s  %6s  →  %s\n" "pm.max_spare_servers"  "${cur_msp}" "${sec_spare}"
    fi
  fi
  echo ""
done

echo "  MariaDB  (${MARIADB_TUNING_CONF})"
printf "  %-26s  %6s  →  %s\n" "innodb_buffer_pool_size"      "${CURRENT_BUFFER_POOL}"  "${INNODB_BUFFER_POOL_MB}M"
printf "  %-26s  %6s  →  %s\n" "innodb_buffer_pool_instances" "-"                       "${INNODB_BUFFER_POOL_INSTANCES}"
printf "  %-26s  %6s  →  %s\n" "max_connections"              "-"                       "${MAX_CONNECTIONS}"
printf "  %-26s  %6s  →  %s\n" "thread_cache_size"            "-"                       "${THREAD_CACHE_SIZE}"
printf "  %-26s  %6s  →  %s\n" "table_open_cache"             "-"                       "${TABLE_OPEN_CACHE}"
echo ""
echo "  Memory estimate:  PHP-FPM ~$(( PHP_PRIMARY_MB + SECONDARY_TOTAL_MB ))M  +  MariaDB ~${INNODB_BUFFER_POOL_MB}M  =  ~${TOTAL_ESTIMATED_MB}M / ${TOTAL_RAM_MB}M total"
echo "============================================================"

if $DRY_RUN; then
  echo "  DRY RUN – no changes applied."
  echo "============================================================"
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────────

echo ""
read -rp "Apply these settings? [y/N] " response
[[ ! "${response}" =~ ^([yY][eE][sS]|[yY])$ ]] && { echo "Cancelled."; exit 0; }

# ── Apply PHP-FPM settings ────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d%H%M%S)

for i in "${!PHP_POOL_CONFS[@]}"; do
  conf="${PHP_POOL_CONFS[$i]}"
  ver="${PHP_VERSIONS[$i]}"

  backup="${conf}.bak.${TIMESTAMP}"
  cp "${conf}" "${backup}" || die "Failed to create backup: ${backup}"
  echo "INFO PHP ${ver}: backup created: ${backup}"

  if [ "$ver" = "$PRIMARY_VERSION" ]; then
    max_ch="${PHP_MAX_CHILDREN}"
    start="${PHP_START_SERVERS}"
    min_sp="${PHP_MIN_SPARE}"
    max_sp="${PHP_MAX_SPARE}"
  else
    max_ch="${SECONDARY_MAX_CHILDREN[$ver]}"
    if [ "${max_ch}" -eq 0 ]; then
      systemctl stop "php${ver}-fpm"    2>/dev/null && echo "INFO PHP ${ver}: service stopped"   || true
      systemctl disable "php${ver}-fpm" 2>/dev/null && echo "INFO PHP ${ver}: service disabled"  || true
      continue
    fi
    start=$(( max_ch / 2 < 1 ? 1 : max_ch / 2 ))
    min_sp=1
    max_sp=$(( max_ch / 2 < 1 ? 1 : max_ch / 2 ))
  fi

  sed -i "s/^pm\.max_children\s*=.*/pm.max_children = ${max_ch}/"           "${conf}"
  sed -i "s/^pm\.start_servers\s*=.*/pm.start_servers = ${start}/"          "${conf}"
  sed -i "s/^pm\.min_spare_servers\s*=.*/pm.min_spare_servers = ${min_sp}/" "${conf}"
  sed -i "s/^pm\.max_spare_servers\s*=.*/pm.max_spare_servers = ${max_sp}/" "${conf}"

  echo "INFO PHP ${ver}: pool config updated"
done

# ── Apply MariaDB settings (clean drop-in, overwrites previous tuning) ─────────

cat > "${MARIADB_TUNING_CONF}" <<EOL
# MariaDB resource tuning – generated by bin/tune-server.sh
# Date:   $(date +%Y-%m-%d)
# System: ${TOTAL_RAM_MB} MB RAM, ${CPU_CORES} CPU cores
#
# Re-run bin/tune-server.sh after server rescaling.

[mysqld]

# InnoDB buffer pool: ${MARIADB_RAM_RATIO}% of total RAM
innodb_buffer_pool_size      = ${INNODB_BUFFER_POOL_MB}M
innodb_buffer_pool_instances = ${INNODB_BUFFER_POOL_INSTANCES}

# Connections
max_connections   = ${MAX_CONNECTIONS}
thread_cache_size = ${THREAD_CACHE_SIZE}

# Table cache
table_open_cache  = ${TABLE_OPEN_CACHE}
EOL

echo "INFO MariaDB tuning config written to ${MARIADB_TUNING_CONF}"

# ── Restart services ──────────────────────────────────────────────────────────

echo ""
read -rp "Restart all PHP-FPM versions and MariaDB now? [Y/n] " restart_response
if [[ ! "${restart_response}" =~ ^([nN])$ ]]; then
  for ver in "${PHP_VERSIONS[@]}"; do
    [ "$ver" != "$PRIMARY_VERSION" ] \
      && [ "${SECONDARY_MAX_CHILDREN[$ver]:-1}" -eq 0 ] \
      && continue  # already stopped above
    if ! "/usr/sbin/php-fpm${ver}" --test; then
      warn "php${ver}-fpm config invalid — skipping restart"
      continue
    fi
    systemctl restart "php${ver}-fpm"
    echo "INFO php${ver}-fpm restarted"
  done
  systemctl restart mariadb
  echo "INFO mariadb restarted"
fi

echo ""
echo "Done. Run 'bin/tune-server.sh --dry-run' anytime to review current recommendations."