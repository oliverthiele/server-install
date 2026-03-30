#!/bin/bash

# PHP configuration and optimization

# Load central PHP settings
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/php-settings.sh
source "${SCRIPT_DIR}/../config/php-settings.sh"

installPhpRedis() {
  echo "INFO Install/Configure php-redis"

  # Check if redis extension is already loaded
  if php -m | grep -q "^redis$"; then
    echo "INFO php-redis is already installed and loaded"
    return 0
  fi

  if [[ "${requiresPhpPpa}" == 'true' ]]; then
    # ondrej/php PPA provides up-to-date php-redis packages for all PHP versions
    echo "INFO Installing php${phpVersion}-redis via ondrej/php PPA"
    apt --assume-yes install "php${phpVersion}-redis"
    service "php${phpVersion}-fpm" restart
  elif [[ "${phpVersion}" == "8.3" && "${ubuntuVersion}" == "24.04" ]]; then
    # For PHP 8.3 on Ubuntu 24.04, the apt package php-redis is outdated
    # Use pecl for TYPO3 v13 compatibility
    echo "INFO Installing php-redis via pecl for PHP 8.3 (TYPO3 v13 compatibility)"

    apt --assume-yes install "php${phpVersion}-dev" php-pear

    if pecl list | grep -q "^redis"; then
      echo "INFO pecl redis package already installed, skipping installation"
    else
      printf "\n" | pecl install redis
    fi

    # Enable redis extension (idempotent - won't fail if already exists)
    if [ ! -f "/etc/php/${phpVersion}/mods-available/redis.ini" ]; then
      echo "extension=redis.so" >"/etc/php/${phpVersion}/mods-available/redis.ini"
    fi
    phpenmod redis

    service "php${phpVersion}-fpm" restart
    echo "INFO php-redis installed via pecl successfully"
  else
    # For older Ubuntu versions, use the standard apt package
    apt --assume-yes install php-redis
    service "php${phpVersion}-fpm" restart
  fi
}

optimizePhpSettings() {
  echo "INFO Optimize PHP ${phpVersion} settings in ${pathToPhpIni}"

  # Sets a php.ini directive regardless of its current value or comment state.
  # Handles three cases: active setting, commented-out setting, or missing entirely.
  # Usage: set_php_ini_value "key" "value" "/path/to/php.ini"
  set_php_ini_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    if grep -qE "^[;[:space:]]*${key}\s*=" "${file}"; then
      sed -i "s|^[;[:space:]]*${key}\s*=.*|${key} = ${value}|" "${file}"
    else
      echo "${key} = ${value}" >> "${file}"
    fi
  }

  set_php_ini_value "pcre.jit"                    "${PHP_PCRE_JIT}"                    "${pathToPhpIni}"
  set_php_ini_value "max_execution_time"          "${PHP_MAX_EXECUTION_TIME}"          "${pathToPhpIni}"
  set_php_ini_value "max_input_time"              "${PHP_MAX_INPUT_TIME}"              "${pathToPhpIni}"
  set_php_ini_value "max_input_vars"              "${PHP_MAX_INPUT_VARS}"              "${pathToPhpIni}"
  set_php_ini_value "memory_limit"                "${PHP_MEMORY_LIMIT}"                "${pathToPhpIni}"
  set_php_ini_value "post_max_size"               "${PHP_POST_MAX_SIZE}"               "${pathToPhpIni}"
  set_php_ini_value "upload_max_filesize"         "${PHP_UPLOAD_MAX_FILESIZE}"         "${pathToPhpIni}"
  set_php_ini_value "max_file_uploads"            "${PHP_MAX_FILE_UPLOADS}"            "${pathToPhpIni}"

  # OPcache optimizations
  set_php_ini_value "opcache.enable"                  "${PHP_OPCACHE_ENABLE}"                  "${pathToPhpIni}"
  set_php_ini_value "opcache.memory_consumption"      "${PHP_OPCACHE_MEMORY_CONSUMPTION}"      "${pathToPhpIni}"
  set_php_ini_value "opcache.interned_strings_buffer" "${PHP_OPCACHE_INTERNED_STRINGS_BUFFER}" "${pathToPhpIni}"
  set_php_ini_value "opcache.max_accelerated_files"   "${PHP_OPCACHE_MAX_ACCELERATED_FILES}"   "${pathToPhpIni}"
  set_php_ini_value "opcache.revalidate_freq"         "${PHP_OPCACHE_REVALIDATE_FREQ}"         "${pathToPhpIni}"

  # PHP-FPM slow log: records requests exceeding the configured threshold.
  # Has no overhead for fast requests — only a time check at request end.
  # Toggle on/off anytime with: bin/toggle-php-slowlog.sh
  if grep -qE "^[;[:space:]]*slowlog\s*=" "${fpmPoolConfig}"; then
    sed -i "s|^[;[:space:]]*slowlog\s*=.*|slowlog = /var/log/php${phpVersion}-fpm-slow.log|" "${fpmPoolConfig}"
  else
    echo "slowlog = /var/log/php${phpVersion}-fpm-slow.log" >> "${fpmPoolConfig}"
  fi
  if grep -qE "^[;[:space:]]*request_slowlog_timeout\s*=" "${fpmPoolConfig}"; then
    sed -i "s|^[;[:space:]]*request_slowlog_timeout\s*=.*|request_slowlog_timeout = ${PHP_FPM_SLOW_LOG_TIMEOUT}|" "${fpmPoolConfig}"
  else
    echo "request_slowlog_timeout = ${PHP_FPM_SLOW_LOG_TIMEOUT}" >> "${fpmPoolConfig}"
  fi

  "/usr/sbin/php-fpm${phpVersion}" --test || die "PHP-FPM config invalid — not restarting (check /etc/php/${phpVersion}/fpm/pool.d/www.conf)"
  service "php${phpVersion}-fpm" restart
}