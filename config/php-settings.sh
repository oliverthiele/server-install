#!/bin/bash

# PHP settings — applied to all installed PHP versions.
# Used by lib/php.sh during installation and by bin/apply-php-settings.sh
# to synchronize settings across multiple PHP versions.
#
# Edit this file to change PHP settings centrally, then run:
#   bin/apply-php-settings.sh

# General
PHP_MAX_EXECUTION_TIME="240"
PHP_MAX_INPUT_TIME="120"
PHP_MAX_INPUT_VARS="10000"
PHP_MEMORY_LIMIT="256M"

# File uploads
PHP_POST_MAX_SIZE="200M"
PHP_UPLOAD_MAX_FILESIZE="200M"
PHP_MAX_FILE_UPLOADS="200"

# OPcache
PHP_OPCACHE_ENABLE="1"
PHP_OPCACHE_MEMORY_CONSUMPTION="256"
PHP_OPCACHE_INTERNED_STRINGS_BUFFER="16"
PHP_OPCACHE_MAX_ACCELERATED_FILES="20000"
PHP_OPCACHE_REVALIDATE_FREQ="60"

# PHP-FPM slow log
PHP_FPM_SLOW_LOG_TIMEOUT="2s"