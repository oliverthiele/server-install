#!/bin/bash

# add-php-version.sh – Install an additional PHP version alongside the existing one
#
# Reads the installed modules of the currently active PHP-FPM version and installs
# the same modules for the new version. Applies settings from config/php-settings.sh.
# Does NOT switch the active PHP version in Nginx or update-alternatives — that
# remains a deliberate manual step.
#
# Usage:
#   bin/add-php-version.sh <version>   e.g.: bin/add-php-version.sh 8.3
#   bin/add-php-version.sh --dry-run <version>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
TARGET_VERSION=""

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    [0-9]*.[0-9]*) TARGET_VERSION="$arg" ;;
    *) echo "Unknown argument: $arg"; echo "Usage: $0 [--dry-run] <version>"; exit 1 ;;
  esac
done

if [ -z "${TARGET_VERSION}" ]; then
  echo "Usage: $0 [--dry-run] <version>"
  echo "Example: $0 8.3"
  exit 1
fi

# ── Root check ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root"
fi

# ── Detect source PHP version (active in Nginx, fallback to newest installed) ─

SOURCE_VERSION=""

if command -v nginx &>/dev/null && nginx -t &>/dev/null 2>&1; then
  SOURCE_VERSION=$(
    nginx -T 2>/dev/null \
      | grep -oP '(?<=fastcgi_pass unix:/var/run/php/php)[0-9]+\.[0-9]+(?=-fpm\.sock)' \
      | sort -uV | tail -1
  )
fi

if [ -z "${SOURCE_VERSION}" ]; then
  # Fallback: newest installed PHP-FPM version
  SOURCE_VERSION=$(
    for phpIni in /etc/php/*/fpm/php.ini; do
      echo "${phpIni}" | grep -oP '/etc/php/\K[0-9]+\.[0-9]+'
    done | sort -V | tail -1
  )
fi

if [ -z "${SOURCE_VERSION}" ]; then
  die "Could not detect an installed PHP-FPM version to use as module source"
fi

echo -e "${COLOR_CYAN}${COLOR_BOLD}Add PHP version${COLOR_NC}"
echo "───────────────────────────────────────────────────────────────"
echo "  Target version : PHP ${TARGET_VERSION}"
echo "  Source version : PHP ${SOURCE_VERSION} (module reference)"
if $DRY_RUN; then
  echo -e "  ${COLOR_YELLOW}Dry-run mode — no changes will be made${COLOR_NC}"
fi
echo ""

# ── Check if target version is already installed ──────────────────────────────

if [ -f "/etc/php/${TARGET_VERSION}/fpm/php.ini" ]; then
  echo -e "${COLOR_YELLOW}WARN PHP ${TARGET_VERSION} is already installed.${COLOR_NC}"
  echo    "     Run bin/apply-php-settings.sh to synchronize settings."
  exit 0
fi

# ── Detect Ubuntu version ─────────────────────────────────────────────────────

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")

# ── Check if ondrej/php PPA is needed ────────────────────────────────────────
# Required for PHP 8.4+ on Ubuntu 24.04, and for any version on Ubuntu 22.04/20.04
# that is not in the default repositories.

REQUIRES_PPA=false
case "${UBUNTU_VERSION}" in
  24.04)
    if [[ "${TARGET_VERSION}" == "8.4" ]] || [[ "$(echo "${TARGET_VERSION} 8.4" | awk '{print ($1 > $2)}')" == "1" ]]; then
      REQUIRES_PPA=true
    fi
    ;;
  22.04|20.04)
    REQUIRES_PPA=true
    ;;
esac

if $REQUIRES_PPA; then
  if ! grep -r "ondrej/php" /etc/apt/sources.list.d/ &>/dev/null; then
    echo "INFO ondrej/php PPA required for PHP ${TARGET_VERSION} on Ubuntu ${UBUNTU_VERSION}"
    if ! $DRY_RUN; then
      apt --assume-yes install software-properties-common
      add-apt-repository --yes ppa:ondrej/php
      apt update
    else
      echo "  [dry-run] Would add ppa:ondrej/php and run apt update"
    fi
  else
    echo "INFO ondrej/php PPA already configured"
  fi
fi

# ── Collect installed modules from source version ─────────────────────────────

echo "INFO Reading installed modules from PHP ${SOURCE_VERSION}..."

mapfile -t SOURCE_PACKAGES < <(
  dpkg -l "php${SOURCE_VERSION}-*" 2>/dev/null \
    | awk '/^ii/ {print $2}' \
    | grep -v "^php${SOURCE_VERSION}-fpm$"
)

if [ "${#SOURCE_PACKAGES[@]}" -eq 0 ]; then
  warn "No modules found for PHP ${SOURCE_VERSION} — installing base packages only"
fi

# Map package names to target version
TARGET_PACKAGES=()
SKIPPED_PACKAGES=()

for package in "${SOURCE_PACKAGES[@]}"; do
  target_package="${package/php${SOURCE_VERSION}-/php${TARGET_VERSION}-}"
  # Check if the target package exists in apt
  if apt-cache show "${target_package}" &>/dev/null 2>&1; then
    TARGET_PACKAGES+=("${target_package}")
  else
    SKIPPED_PACKAGES+=("${target_package}")
  fi
done

# Always include fpm and cli
TARGET_PACKAGES+=("php${TARGET_VERSION}-fpm" "php${TARGET_VERSION}-cli")

# Deduplicate
mapfile -t TARGET_PACKAGES < <(printf '%s\n' "${TARGET_PACKAGES[@]}" | sort -u)

echo ""
echo "  Packages to install (${#TARGET_PACKAGES[@]}):"
for package in "${TARGET_PACKAGES[@]}"; do
  echo "    ${package}"
done

if [ "${#SKIPPED_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo -e "  ${COLOR_YELLOW}Packages not available for PHP ${TARGET_VERSION} (skipped):${COLOR_NC}"
  for package in "${SKIPPED_PACKAGES[@]}"; do
    echo "    ${package}"
  done
fi
echo ""

if $DRY_RUN; then
  echo -e "${COLOR_YELLOW}Dry-run complete — no changes were made.${COLOR_NC}"
  echo    "Run without --dry-run to install."
  exit 0
fi

# ── Install target PHP version and modules ────────────────────────────────────

echo "INFO Installing PHP ${TARGET_VERSION} and modules..."
apt --assume-yes install "${TARGET_PACKAGES[@]}" \
  || die "Package installation failed — check apt output above"

# Pin CLI version if PPA is used (prevents newer version from becoming default)
if $REQUIRES_PPA && [ -f "/usr/bin/php${TARGET_VERSION}" ]; then
  update-alternatives --set php "/usr/bin/php${TARGET_VERSION}" 2>/dev/null || true
fi

# ── Apply central PHP settings ────────────────────────────────────────────────

echo "INFO Applying settings from config/php-settings.sh..."
"${SCRIPT_DIR}/apply-php-settings.sh" \
  || warn "apply-php-settings.sh reported issues — check output above"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "───────────────────────────────────────────────────────────────"
echo -e "${COLOR_GREEN}${COLOR_BOLD}PHP ${TARGET_VERSION} installed successfully.${COLOR_NC}"
echo ""
echo "  PHP-FPM socket : /var/run/php/php${TARGET_VERSION}-fpm.sock"
echo ""
echo "  To switch Nginx to PHP ${TARGET_VERSION}:"
echo "    Edit /etc/nginx/sites-available/typo3.nginx"
echo "    Change: fastcgi_pass unix:/var/run/php/php${SOURCE_VERSION}-fpm.sock;"
echo "    To:     fastcgi_pass unix:/var/run/php/php${TARGET_VERSION}-fpm.sock;"
echo "    Then:   nginx -t && systemctl reload nginx"
echo ""
echo "  To set PHP ${TARGET_VERSION} as the CLI default:"
echo "    update-alternatives --set php /usr/bin/php${TARGET_VERSION}"