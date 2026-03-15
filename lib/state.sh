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

# Save configuration for resume capability
saveConfig() {
  cat > "${CONFIG_FILE}" <<EOL
# TYPO3 Installation Configuration
# This file allows resuming installation after interruption

# System
UBUNTU_VERSION="${ubuntuVersion}"
PHP_VERSION="${phpVersion}"
REQUIRES_PHP_PPA="${requiresPhpPpa}"

# TYPO3
TYPO3_VERSION="${typo3Version}"
TYPO3_CLI_NAME="${typo3CliName}"

# Paths
WWW_ROOT="${wwwRoot}"
COMPOSER_DIRECTORY="${composerDirectory}"
TYPO3_PUBLIC_DIRECTORY="${typo3PublicDirectory}"
PATH_SETTINGS="${pathSettings}"
PATH_ADDITIONAL_SETTINGS="${pathAdditionalSettings}"

# Domain & Email
SERVER_DOMAIN="${serverDomain}"
ADMIN_EMAIL="${adminEmail}"
BOT_FILTER_MODE="${botFilterMode}"

# System Password
SYSTEM_PASS="${systemPass}"

# Database (if already created)
DATABASE_USER="${databaseUser:-}"
DATABASE_PASSWORD="${databasePassword:-}"
DATABASE_NAME="${databaseName:-}"
DATABASE_HOST="${databaseHost:-localhost}"
ENCRYPTION_KEY="${encryptionKey:-}"
REDIS_PASS="${redisPassword:-}"
EOL
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
    typo3CliName="${TYPO3_CLI_NAME}"
    wwwRoot="${WWW_ROOT}"
    composerDirectory="${COMPOSER_DIRECTORY}"
    typo3PublicDirectory="${TYPO3_PUBLIC_DIRECTORY}"
    pathSettings="${PATH_SETTINGS}"
    pathAdditionalSettings="${PATH_ADDITIONAL_SETTINGS}"
    serverDomain="${SERVER_DOMAIN}"
    adminEmail="${ADMIN_EMAIL}"
    botFilterMode="${BOT_FILTER_MODE:-production}"
    systemPass="${SYSTEM_PASS}"
    databaseUser="${DATABASE_USER}"
    databasePassword="${DATABASE_PASSWORD}"
    databaseName="${DATABASE_NAME}"
    databaseHost="${DATABASE_HOST}"
    encryptionKey="${ENCRYPTION_KEY}"
    redisPassword="${REDIS_PASS}"

    # Export variables for use in other scripts
    export ubuntuVersion phpVersion requiresPhpPpa typo3Version typo3CliName
    export wwwRoot composerDirectory typo3PublicDirectory
    export pathSettings pathAdditionalSettings
    export serverDomain adminEmail botFilterMode systemPass
    export databaseUser databasePassword databaseName databaseHost encryptionKey redisPassword

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
  total_steps=12

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