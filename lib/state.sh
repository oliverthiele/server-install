#!/bin/bash

# Installation state management
# Tracks progress and allows resuming after failures

STATE_FILE="/root/.typo3-install-state"
CONFIG_FILE="/root/.typo3-install-config"

# Initialize state management
initState() {
  if [ ! -f "${STATE_FILE}" ]; then
    echo "# TYPO3 Installation State" > "${STATE_FILE}"
    echo "# Auto-generated - do not edit manually" >> "${STATE_FILE}"
    echo "INSTALL_START_TIME=$(date +%s)" >> "${STATE_FILE}"
  fi
}

# Write one KEY=value line with shell quoting (printf %q).
# The config file is re-read via source in loadConfig() — without quoting,
# a generated password containing $ (e.g. "...S*$kt") would be mangled by
# variable expansion and every consumer after a resume would use a wrong value.
_configLine() {
  printf '%s=%q\n' "$1" "$2"
}

# Save configuration for resume capability
saveConfig() {
  {
    echo "# TYPO3 Installation Configuration"
    echo "# This file allows resuming installation after interruption."
    echo "# Values are shell-quoted (printf %q) so special characters in"
    echo "# generated passwords (\$, *, !) survive re-sourcing in loadConfig()."
    echo ""
    echo "# System"
    _configLine UBUNTU_VERSION            "${ubuntuVersion}"
    _configLine PHP_VERSION               "${phpVersion}"
    _configLine REQUIRES_PHP_PPA          "${requiresPhpPpa}"
    echo ""
    echo "# TYPO3"
    _configLine TYPO3_VERSION             "${typo3Version}"
    _configLine TYPO3_MAJOR_VERSION       "${typo3MajorVersion}"
    _configLine TYPO3_CLI_NAME            "${typo3CliName}"
    echo ""
    echo "# Paths"
    _configLine WWW_ROOT                  "${wwwRoot}"
    _configLine COMPOSER_DIRECTORY        "${composerDirectory}"
    _configLine TYPO3_PUBLIC_DIRECTORY    "${typo3PublicDirectory}"
    _configLine PATH_SETTINGS             "${pathSettings}"
    _configLine PATH_ADDITIONAL_SETTINGS  "${pathAdditionalSettings}"
    echo ""
    echo "# Domain & Email"
    _configLine SERVER_DOMAIN             "${serverDomain}"
    _configLine ADMIN_EMAIL               "${adminEmail}"
    _configLine ADMIN_REAL_NAME           "${adminRealName:-}"
    _configLine BOT_FILTER_MODE           "${botFilterMode}"
    _configLine ENABLE_BASIC_AUTH         "${enableBasicAuth:-false}"
    _configLine BASIC_AUTH_USER           "${basicAuthUser:-}"
    _configLine BASIC_AUTH_PASSWORD       "${basicAuthPassword:-}"
    echo ""
    echo "# System Password"
    _configLine SYSTEM_PASS               "${systemPass}"
    echo ""
    echo "# Database (if already created)"
    _configLine DATABASE_USER             "${databaseUser:-}"
    _configLine DATABASE_PASSWORD         "${databasePassword:-}"
    _configLine DATABASE_NAME             "${databaseName:-}"
    _configLine DATABASE_HOST             "${databaseHost:-localhost}"
    _configLine ENCRYPTION_KEY            "${encryptionKey:-}"
    _configLine REDIS_PASS                "${redisPassword:-}"
    echo ""
    echo "# fail2ban / rate limiting"
    _configLine HAS_FRONTEND_LOGIN        "${hasFrontendLogin:-true}"
    _configLine TYPO3_LOGIN_PATH_DE       "${typo3LoginPathDE:-}"
    _configLine TYPO3_LOGIN_PATH_EN       "${typo3LoginPathEN:-}"
    _configLine FAIL2BAN_IGNOREIP         "${fail2banIgnoreIp:-}"
    echo ""
    echo "# Node.js (frontend builds via nvm)"
    _configLine NODE_VERSION              "${nodeVersion:-24}"
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

# Load saved configuration
loadConfig() {
  if [ -f "${CONFIG_FILE}" ]; then
    echo "INFO Found existing installation configuration"
    source "${CONFIG_FILE}"

    # Map uppercase variables to lowercase (script uses lowercase internally)
    ubuntuVersion="${UBUNTU_VERSION}"
    phpVersion="${PHP_VERSION}"
    requiresPhpPpa="${REQUIRES_PHP_PPA}"
    typo3Version="${TYPO3_VERSION}"
    typo3MajorVersion="${TYPO3_MAJOR_VERSION}"
    typo3CliName="${TYPO3_CLI_NAME}"

    # Re-source TYPO3 requirements so PHP version constraints are available after resume
    local requirementsFile
    requirementsFile="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../config/requirements/typo3-v${typo3MajorVersion}.sh"
    if [ -f "${requirementsFile}" ]; then
      # shellcheck source=../config/requirements/typo3-v13.sh
      source "${requirementsFile}"
      export TYPO3_PHP_MIN TYPO3_PHP_MAX TYPO3_PHP_RECOMMENDED TYPO3_PHP_WARN_BELOW TYPO3_PHP_WARN_MSG
    fi
    wwwRoot="${WWW_ROOT}"
    composerDirectory="${COMPOSER_DIRECTORY}"
    typo3PublicDirectory="${TYPO3_PUBLIC_DIRECTORY}"
    pathSettings="${PATH_SETTINGS}"
    pathAdditionalSettings="${PATH_ADDITIONAL_SETTINGS}"
    serverDomain="${SERVER_DOMAIN}"
    adminEmail="${ADMIN_EMAIL}"
    adminRealName="${ADMIN_REAL_NAME:-}"
    botFilterMode="${BOT_FILTER_MODE:-production}"
    enableBasicAuth="${ENABLE_BASIC_AUTH:-false}"
    basicAuthUser="${BASIC_AUTH_USER:-}"
    basicAuthPassword="${BASIC_AUTH_PASSWORD:-}"
    systemPass="${SYSTEM_PASS}"
    databaseUser="${DATABASE_USER}"
    databasePassword="${DATABASE_PASSWORD}"
    databaseName="${DATABASE_NAME}"
    databaseHost="${DATABASE_HOST}"
    encryptionKey="${ENCRYPTION_KEY}"
    redisPassword="${REDIS_PASS}"
    # Older config files predate HAS_FRONTEND_LOGIN and always had login paths —
    # default to true with the old path defaults so a resume behaves as before.
    hasFrontendLogin="${HAS_FRONTEND_LOGIN:-true}"
    if [[ "${hasFrontendLogin}" == 'true' ]]; then
      typo3LoginPathDE="${TYPO3_LOGIN_PATH_DE:-/anmeldung/}"
      typo3LoginPathEN="${TYPO3_LOGIN_PATH_EN:-/en/login/}"
    else
      typo3LoginPathDE=''
      typo3LoginPathEN=''
    fi
    fail2banIgnoreIp="${FAIL2BAN_IGNOREIP:-}"
    nodeVersion="${NODE_VERSION:-24}"

    # Export variables for use in other scripts
    export ubuntuVersion phpVersion requiresPhpPpa typo3Version typo3MajorVersion typo3CliName
    export wwwRoot composerDirectory typo3PublicDirectory
    export pathSettings pathAdditionalSettings
    export serverDomain adminEmail adminRealName botFilterMode systemPass
    export enableBasicAuth basicAuthUser basicAuthPassword
    export databaseUser databasePassword databaseName databaseHost encryptionKey redisPassword
    export hasFrontendLogin typo3LoginPathDE typo3LoginPathEN fail2banIgnoreIp
    export nodeVersion

    # Also export path to php.ini for PHP configuration
    export pathToPhpIni="/etc/php/${phpVersion}/fpm/php.ini"

    echo "INFO Configuration loaded successfully"
    return 0
  fi
  return 1
}

# Mark a step as completed
markStepComplete() {
  local step_name="$1"
  local timestamp; timestamp=$(date +%s)

  if ! grep -q "^STEP_${step_name}=" "${STATE_FILE}"; then
    echo "STEP_${step_name}=${timestamp}" >> "${STATE_FILE}"
    echo "INFO Step '${step_name}' marked as complete"
  fi
}

# Check if a step is already completed
isStepComplete() {
  local step_name="$1"

  if [ -f "${STATE_FILE}" ] && grep -q "^STEP_${step_name}=" "${STATE_FILE}"; then
    echo "INFO Step '${step_name}' already completed - skipping"
    return 0
  fi
  return 1
}

# Show installation progress
showProgress() {
  if [ ! -f "${STATE_FILE}" ]; then
    echo "INFO No previous installation found"
    return
  fi

  echo "==============================================================="
  echo "Installation Progress:"
  echo "==============================================================="

  local total_steps=0
  local completed_steps=0

  # Count completed steps
  completed_steps=$(grep -c "^STEP_" "${STATE_FILE}" 2>/dev/null || echo "0")
  # Remove any whitespace/newlines and ensure it's a valid integer
  completed_steps=$(echo "${completed_steps}" | tr -d '\n\r\t ' | grep -o '[0-9]*' | head -n1)
  # Default to 0 if empty
  completed_steps=${completed_steps:-0}

  # Define total expected steps (adjust as needed)
  total_steps=13

  if [ "${completed_steps}" -gt 0 ]; then
    echo "Completed: ${completed_steps}/${total_steps} steps"
    echo ""
    echo "Already completed steps:"
    grep "^STEP_" "${STATE_FILE}" 2>/dev/null | sed 's/STEP_/  - /g' | sed 's/=.*//'
    echo ""
  fi

  echo "==============================================================="
}

# Clean up state files (for fresh installation)
cleanState() {
  if [ -f "${STATE_FILE}" ]; then
    rm -f "${STATE_FILE}"
    echo "INFO Installation state cleared"
  fi

  if [ -f "${CONFIG_FILE}" ]; then
    rm -f "${CONFIG_FILE}"
    echo "INFO Installation config cleared"
  fi

  # Remove legacy .env.temp if it exists from an older installation run
  if [ -f /root/.env.temp ]; then
    rm -f /root/.env.temp
    echo "INFO Legacy .env.temp removed"
  fi
}

# Ask user if they want to continue previous installation
askContinuePrevious() {
  if [ -f "${STATE_FILE}" ]; then
    # Check if there are actually completed steps (not just initialized)
    local step_count; step_count=$(grep -c "^STEP_" "${STATE_FILE}" 2>/dev/null || echo "0")
    # Remove any whitespace/newlines and ensure it's a valid integer
    step_count=$(echo "${step_count}" | tr -d '\n\r\t ' | grep -o '[0-9]*' | head -n1)
    # Default to 0 if empty
    step_count=${step_count:-0}

    if [ "${step_count}" -gt 0 ]; then
      echo ""
      echo "==============================================================="
      echo "PREVIOUS INSTALLATION DETECTED"
      echo "==============================================================="
      showProgress
      echo ""

      read -p "Do you want to continue the previous installation? [Y/n] " -n 1 -r
      echo ""

      if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "INFO Starting fresh installation..."
        cleanState
        return 1
      else
        echo "INFO Resuming previous installation..."
        loadConfig
        return 0
      fi
    fi
  fi
  return 1
}