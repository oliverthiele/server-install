#!/bin/bash

# Toggle PHP-FPM slow log on/off
#
# The slow log records stack traces for requests exceeding the configured
# threshold. There is no measurable overhead for fast requests.
#
# Usage:
#   bin/toggle-php-slowlog.sh            # Toggle current state
#   bin/toggle-php-slowlog.sh enable     # Enable (threshold: 2s)
#   bin/toggle-php-slowlog.sh disable    # Disable
#   bin/toggle-php-slowlog.sh status     # Show current state
#
# Log location: /var/log/phpX.Y-fpm-slow.log

set -e

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
SCRIPT_DIR_TOGGLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR_TOGGLE}/../lib/utils.sh"

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root"
fi

# Detect active PHP-FPM pool config
POOL_CONF=$(find /etc/php/ -maxdepth 4 -name "www.conf" -path "*/fpm/pool.d/*" 2>/dev/null | head -1)
if [ -z "${POOL_CONF}" ]; then
  die "No PHP-FPM pool config found under /etc/php/*/fpm/pool.d/www.conf"
fi

PHP_VERSION=$(echo "${POOL_CONF}" | grep -oP '/etc/php/\K[0-9]+\.[0-9]+')
SLOW_LOG="/var/log/php${PHP_VERSION}-fpm-slow.log"

get_current_timeout() {
  grep -E "^request_slowlog_timeout\s*=" "${POOL_CONF}" | awk -F'=' '{print $2}' | tr -d ' ' | head -1
}

enable_slowlog() {
  if grep -qE "^[;[:space:]]*slowlog\s*=" "${POOL_CONF}"; then
    sed -i "s|^[;[:space:]]*slowlog\s*=.*|slowlog = ${SLOW_LOG}|" "${POOL_CONF}"
  else
    echo "slowlog = ${SLOW_LOG}" >> "${POOL_CONF}"
  fi
  if grep -qE "^[;[:space:]]*request_slowlog_timeout\s*=" "${POOL_CONF}"; then
    sed -i "s|^[;[:space:]]*request_slowlog_timeout\s*=.*|request_slowlog_timeout = 2s|" "${POOL_CONF}"
  else
    echo "request_slowlog_timeout = 2s" >> "${POOL_CONF}"
  fi
  "/usr/sbin/php-fpm${PHP_VERSION}" --test || die "PHP-FPM config invalid — not reloading (check ${POOL_CONF})"
  systemctl reload "php${PHP_VERSION}-fpm"
  echo "INFO Slow log enabled (threshold: 2s, log: ${SLOW_LOG})"
}

disable_slowlog() {
  if grep -qE "^request_slowlog_timeout\s*=" "${POOL_CONF}"; then
    sed -i "s|^request_slowlog_timeout\s*=.*|request_slowlog_timeout = 0|" "${POOL_CONF}"
  fi
  "/usr/sbin/php-fpm${PHP_VERSION}" --test || die "PHP-FPM config invalid — not reloading (check ${POOL_CONF})"
  systemctl reload "php${PHP_VERSION}-fpm"
  echo "INFO Slow log disabled"
}

show_status() {
  local timeout
  timeout=$(get_current_timeout)
  echo "PHP version:  ${PHP_VERSION}"
  echo "Pool config:  ${POOL_CONF}"
  echo "Log file:     ${SLOW_LOG}"
  if [[ "${timeout}" == "0" || -z "${timeout}" ]]; then
    echo "Status:       disabled (request_slowlog_timeout = ${timeout:-0})"
  else
    echo "Status:       enabled  (request_slowlog_timeout = ${timeout})"
  fi
}

ACTION="${1:-toggle}"

case "${ACTION}" in
  enable)
    enable_slowlog
    ;;
  disable)
    disable_slowlog
    ;;
  status)
    show_status
    ;;
  toggle)
    timeout=$(get_current_timeout)
    if [[ "${timeout}" == "0" || -z "${timeout}" ]]; then
      enable_slowlog
    else
      disable_slowlog
    fi
    ;;
  *)
    echo "Usage: $0 [enable|disable|status|toggle]"
    exit 1
    ;;
esac