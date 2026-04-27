#!/bin/bash

# Configuration variables and version selection

SCRIPT_DIR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default paths
wwwRoot='/var/www/'
composerDirectory="${wwwRoot}typo3/"
typo3PublicDirectory="${composerDirectory}public/"

selectTypo3Version() {
  echo "Select the TYPO3 version to be installed:"
  echo "  1) TYPO3 v12.4 LTS"
  echo "  2) TYPO3 v13.4 LTS (default)"
  echo "  3) TYPO3 v14.3 LTS"
  read -rp 'Option [2]: ' typo3Option

  case ${typo3Option} in
  1)
    typo3Version='^12.4'
    typo3MajorVersion='12'
    ;;
  3)
    typo3Version='^14.3'
    typo3MajorVersion='14'
    ;;
  *)
    typo3Version='^13.4'
    typo3MajorVersion='13'
    ;;
  esac

  echo "TYPO3 Version ${typo3Version}"
  echo ""

  # Load PHP requirements for the selected TYPO3 version
  local requirementsFile="${SCRIPT_DIR_CONFIG}/../config/requirements/typo3-v${typo3MajorVersion}.sh"
  if [ -f "${requirementsFile}" ]; then
    # shellcheck source=../config/requirements/typo3-v13.sh
    source "${requirementsFile}"
  else
    warn "No requirements file found for TYPO3 v${typo3MajorVersion} — PHP version selection will use defaults"
  fi

  export typo3Version typo3MajorVersion
  export TYPO3_PHP_MIN TYPO3_PHP_MAX TYPO3_PHP_RECOMMENDED TYPO3_PHP_WARN_BELOW TYPO3_PHP_WARN_MSG
}

setVariables() {
  # Set paths (same structure for v12 and v13)
  pathSettings="${composerDirectory}config/system/"
  pathAdditionalSettings="${pathSettings}additional.php"
  typo3CliName='typo3'

  systemPass=$(generatePassword)
  echo "System Password: ${systemPass}"
  echo ""

  # Domain configuration
  echo "---------------------------------------"
  read -rp 'Enter domain (e.g., example.com) or leave empty for IP-based setup: ' serverDomain
  if [[ -z "${serverDomain}" ]]; then
    serverDomain="_"
    echo "Using IP-based setup (no domain)"
  else
    echo "Domain: ${serverDomain}"
  fi
  echo ""

  # Administrator Email
  echo "---------------------------------------"
  read -rp 'Enter administrator email (for Certbot and TYPO3 backend user): ' adminEmail
  while [[ ! "${adminEmail}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo "Invalid email format!"
    read -rp 'Enter administrator email: ' adminEmail
  done
  echo "Admin Email: ${adminEmail}"
  echo ""

  # TYPO3 backend admin real name (stored in be_users.realName)
  echo "---------------------------------------"
  while true; do
    read -rp 'Enter TYPO3 admin real name (e.g. "Jane Doe") [leave empty to skip]: ' adminRealName
    if [[ -z "${adminRealName}" ]]; then
      break
    elif [[ ${#adminRealName} -gt 80 ]]; then
      echo "Name too long (max 80 characters)."
    elif [[ ! "${adminRealName}" =~ ^[[:print:]]+$ ]]; then
      echo "Name contains invalid characters."
    else
      break
    fi
  done
  echo ""

  # Bot filter mode
  echo "---------------------------------------"
  echo "Select bot filter mode:"
  echo "  1) Staging  – block all AI crawlers and SEO scrapers (no indexing)"
  echo "  2) Production – block abusive bots only, allow major AI assistants"
  echo "     (ChatGPT, Claude, Perplexity, Gemini — for discoverability)"
  echo "     Bytespider (Bytedance/TikTok) is always blocked due to abusive crawling."
  read -rp 'Option [2]: ' botFilterOption
  case "${botFilterOption}" in
  1)
    botFilterMode='staging'
    echo "Bot filter: staging (all AI crawlers blocked)"
    ;;
  *)
    botFilterMode='production'
    echo "Bot filter: production (abusive bots blocked, AI assistants allowed)"
    ;;
  esac
  echo ""

  # HTTP Basic Authentication (optional, recommended until go-live)
  echo "---------------------------------------"
  echo "Enable HTTP Basic Authentication?"
  echo "  Protects the site with a username/password until it goes live."
  echo "  Trusted private networks (10.x, 172.16.x, 192.168.x) bypass the password."
  read -rp "Enable BasicAuth? [y/N]: " basicAuthOption
  if [[ "${basicAuthOption}" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    enableBasicAuth='true'
    read -rp "BasicAuth username [admin]: " basicAuthUser
    if [[ -z "${basicAuthUser}" ]]; then
      basicAuthUser='admin'
    fi
    basicAuthPassword=$(generatePassword)
    echo "BasicAuth enabled — Username: ${basicAuthUser}"
  else
    enableBasicAuth='false'
    basicAuthUser=''
    basicAuthPassword=''
    echo "BasicAuth disabled."
  fi
  echo ""

  # Export variables for use in other modules
  export wwwRoot composerDirectory typo3PublicDirectory
  export typo3CliName pathSettings pathAdditionalSettings systemPass
  export serverDomain adminEmail adminRealName botFilterMode
  export enableBasicAuth basicAuthUser basicAuthPassword
}