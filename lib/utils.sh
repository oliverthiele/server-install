#!/bin/bash

# Utility functions for TYPO3 installation script

generatePassword() {
  # Uses /dev/urandom via openssl for cryptographically secure randomness.
  # Rejection sampling avoids modulo bias when mapping bytes to charset indices.
  local charset='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-*!@$%_'
  local charset_length=${#charset}
  # Highest byte value that maps evenly onto the charset (avoids modulo bias)
  local rejection_threshold=$(( (256 / charset_length) * charset_length ))
  local target_length=20
  local password=""

  while [ ${#password} -lt ${target_length} ]; do
    local hex_byte
    hex_byte=$(openssl rand -hex 1)
    local decimal=$(( 16#${hex_byte} ))
    # Discard bytes above the rejection threshold to prevent bias
    if [ ${decimal} -lt ${rejection_threshold} ]; then
      local index=$(( decimal % charset_length ))
      password+="${charset:${index}:1}"
    fi
  done

  echo "${password}"
}

cleanup() {
  echo "Cleanup complete."
}

getUbuntuVersionAndSetPhpVersion() {
  ubuntuVersion=$(lsb_release -rs)
  echo "Ubuntu: ${ubuntuVersion}"

  # Determine default PHP version based on Ubuntu release
  case "${ubuntuVersion}" in
  '24.04') defaultPhpVersion='8.3' ;;
  '22.04') defaultPhpVersion='8.1' ;;
  '20.04') defaultPhpVersion='7.4' ;;
  *)
    echo "ERROR Unsupported Ubuntu version: ${ubuntuVersion}"
    echo "      Supported: 20.04, 22.04, 24.04"
    exit 1
    ;;
  esac

  # Ask user which PHP version to install
  echo "---------------------------------------"
  echo "Default PHP version for Ubuntu ${ubuntuVersion}: ${defaultPhpVersion}"
  echo "Select PHP version to install:"
  echo "  1) PHP ${defaultPhpVersion} (default, from Ubuntu repositories)"

  if [[ "${ubuntuVersion}" == "24.04" ]]; then
    echo "  2) PHP 8.4 (requires ondrej/php PPA, includes current php-redis)"
    read -rp 'Option [1]: ' phpChoice
    case "${phpChoice}" in
    2)
      phpVersion='8.4'
      requiresPhpPpa='true'
      ;;
    *)
      phpVersion="${defaultPhpVersion}"
      requiresPhpPpa='false'
      ;;
    esac
  else
    phpVersion="${defaultPhpVersion}"
    requiresPhpPpa='false'
  fi

  pathToPhpIni="/etc/php/${phpVersion}/fpm/php.ini"
  echo "PHP Version: ${phpVersion}"
  echo "Path to php.ini: ${pathToPhpIni}"

  export ubuntuVersion phpVersion pathToPhpIni requiresPhpPpa
}

confirmInstallation() {
  read -rp "Install TYPO3 in '${composerDirectory}' with PHP ${phpVersion}. Is this correct [y/N] " response
  case "$response" in
  [yY][eE][sS] | [yY])
    echo "Start the installation"
    ;;
  *)
    echo "Installation cancelled by user. Exiting..."
    exit
    ;;
  esac
}