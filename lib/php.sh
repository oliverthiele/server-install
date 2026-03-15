#!/bin/bash

# PHP configuration and optimization

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

  set_php_ini_value "max_execution_time"          "240"     "${pathToPhpIni}"
  set_php_ini_value "max_input_time"              "120"     "${pathToPhpIni}"
  set_php_ini_value "max_input_vars"              "10000"   "${pathToPhpIni}"
  set_php_ini_value "memory_limit"                "256M"    "${pathToPhpIni}"
  set_php_ini_value "post_max_size"               "200M"    "${pathToPhpIni}"
  set_php_ini_value "upload_max_filesize"         "200M"    "${pathToPhpIni}"
  set_php_ini_value "max_file_uploads"            "200"     "${pathToPhpIni}"

  # OPcache optimizations
  set_php_ini_value "opcache.enable"                  "1"      "${pathToPhpIni}"
  set_php_ini_value "opcache.memory_consumption"      "256"    "${pathToPhpIni}"
  set_php_ini_value "opcache.interned_strings_buffer" "16"     "${pathToPhpIni}"
  set_php_ini_value "opcache.max_accelerated_files"   "20000"  "${pathToPhpIni}"
  set_php_ini_value "opcache.revalidate_freq"         "60"     "${pathToPhpIni}"

  # PHP-FPM slow log: records requests exceeding 2s.
  # Has no overhead for fast requests — only a time check at request end.
  # Toggle on/off anytime with: bin/toggle-php-slowlog.sh
  if grep -qE "^[;[:space:]]*slowlog\s*=" "${fpmPoolConfig}"; then
    sed -i "s|^[;[:space:]]*slowlog\s*=.*|slowlog = /var/log/php${phpVersion}-fpm-slow.log|" "${fpmPoolConfig}"
  else
    echo "slowlog = /var/log/php${phpVersion}-fpm-slow.log" >> "${fpmPoolConfig}"
  fi
  if grep -qE "^[;[:space:]]*request_slowlog_timeout\s*=" "${fpmPoolConfig}"; then
    sed -i "s|^[;[:space:]]*request_slowlog_timeout\s*=.*|request_slowlog_timeout = 2s|" "${fpmPoolConfig}"
  else
    echo "request_slowlog_timeout = 2s" >> "${fpmPoolConfig}"
  fi

  "/usr/sbin/php-fpm${phpVersion}" --test || die "PHP-FPM config invalid — not restarting (check /etc/php/${phpVersion}/fpm/pool.d/www.conf)"
  service "php${phpVersion}-fpm" restart
}