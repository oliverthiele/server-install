#!/bin/bash

# add-php-version.sh – Install an additional PHP version alongside the existing one
#
# Reads the installed modules of the currently active PHP-FPM version and installs
# the same modules for the new version. Applies settings from config/php-settings.sh.
# Does NOT switch the active PHP version in Nginx — that remains a deliberate
# manual step. Asks whether the CLI default (update-alternatives) should follow
# the new version; declining, or running without a terminal, keeps the previous
# CLI version pinned.
#
# Usage:
#   bin/add-php-version.sh <version>   e.g.: bin/add-php-version.sh 8.3
#   bin/add-php-version.sh --dry-run <version>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"

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

# ── Check if the packages.sury.org PHP repository is needed ──────────────────
# Required for every version other than 8.5 on Ubuntu 26.04, for PHP 8.4+ on
# Ubuntu 24.04, and for any version on Ubuntu 22.04/20.04 that is not in the
# default repositories.

REQUIRES_PHP_REPO=false
case "${UBUNTU_VERSION}" in
  26.04)
    # Ubuntu 26.04 ships PHP 8.5 only
    if [[ "${TARGET_VERSION}" != "8.5" ]]; then
      REQUIRES_PHP_REPO=true
    fi
    ;;
  24.04)
    if [[ "${TARGET_VERSION}" == "8.4" ]] || [[ "$(echo "${TARGET_VERSION} 8.4" | awk '{print ($1 > $2)}')" == "1" ]]; then
      REQUIRES_PHP_REPO=true
    fi
    ;;
  22.04|20.04)
    REQUIRES_PHP_REPO=true
    ;;
esac

if $REQUIRES_PHP_REPO; then
  if [[ -f /etc/apt/sources.list.d/php.list ]] && grep -q "packages.sury.org" /etc/apt/sources.list.d/php.list; then
    echo "INFO packages.sury.org PHP repository already configured"
  elif ! $DRY_RUN; then
    addPhpRepo "${TARGET_VERSION}"
  else
    echo "  [dry-run] Would add the packages.sury.org PHP repository"
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

BUILTIN_PACKAGES=()

for package in "${SOURCE_PACKAGES[@]}"; do
  target_package="${package/php${SOURCE_VERSION}-/php${TARGET_VERSION}-}"
  # OPcache is compiled into PHP itself since 8.5 — no php8.5-opcache package exists
  if [[ "${target_package}" == "php${TARGET_VERSION}-opcache" ]] \
    && [[ "$(echo "${TARGET_VERSION}" | awk '{print ($1 >= 8.5)}')" == "1" ]]; then
    BUILTIN_PACKAGES+=("${target_package}")
    continue
  fi
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

if [ "${#BUILTIN_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "  Built into PHP ${TARGET_VERSION}, no separate package needed:"
  for package in "${BUILTIN_PACKAGES[@]}"; do
    echo "    ${package}"
  done
fi
echo ""

if $DRY_RUN; then
  echo -e "${COLOR_YELLOW}Dry-run complete — no changes were made.${COLOR_NC}"
  echo    "Run without --dry-run to install."
  exit 0
fi

# Remember the CLI version before apt runs: in auto mode, update-alternatives
# switches /usr/bin/php to the highest-priority (newest) version on install.
PREVIOUS_CLI_VERSION=""
if command -v php &>/dev/null; then
  PREVIOUS_CLI_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
fi

# ── Install target PHP version and modules ────────────────────────────────────

echo "INFO Installing PHP ${TARGET_VERSION} and modules..."
apt --assume-yes install "${TARGET_PACKAGES[@]}" \
  || die "Package installation failed — check apt output above"

# ── CLI default ───────────────────────────────────────────────────────────────
# With one application per server, CLI and PHP-FPM should usually run the same
# version, so switching is the default answer. On servers hosting several
# applications, the previous CLI version can be kept.

CLI_SWITCHED=false
SWITCH_CLI=false
if [ -f "/usr/bin/php${TARGET_VERSION}" ]; then
  if [ -t 0 ]; then
    echo ""
    read -rp "Set PHP ${TARGET_VERSION} as the CLI default (previously: ${PREVIOUS_CLI_VERSION:-none})? [Y/n] " cliResponse
    if [[ ! "${cliResponse}" =~ ^[nN]$ ]]; then
      SWITCH_CLI=true
    fi
  else
    echo "INFO No terminal — keeping the previous CLI version"
  fi
fi

if $SWITCH_CLI; then
  if update-alternatives --set php "/usr/bin/php${TARGET_VERSION}"; then
    CLI_SWITCHED=true
  else
    warn "update-alternatives failed — CLI default unchanged"
  fi
elif [ -n "${PREVIOUS_CLI_VERSION}" ] && [ -f "/usr/bin/php${PREVIOUS_CLI_VERSION}" ]; then
  # Pin explicitly: auto mode may already point to the newly installed version
  if update-alternatives --set php "/usr/bin/php${PREVIOUS_CLI_VERSION}"; then
    echo "INFO CLI stays on PHP ${PREVIOUS_CLI_VERSION}"
  else
    warn "update-alternatives failed — check the CLI default with: php -v"
  fi
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
if $CLI_SWITCHED; then
  echo "  CLI default    : PHP ${TARGET_VERSION}"
else
  echo "  To set PHP ${TARGET_VERSION} as the CLI default later:"
  echo "    update-alternatives --set php /usr/bin/php${TARGET_VERSION}"
fi