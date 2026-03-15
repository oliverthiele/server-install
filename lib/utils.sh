#!/bin/bash

# Utility functions for TYPO3 installation script

# Colors — only when stdout is a terminal (no escape codes in piped/logged output)
if [ -t 1 ]; then
  COLOR_RED='\033[0;31m'
  COLOR_YELLOW='\033[1;33m'
  COLOR_GREEN='\033[0;32m'
  COLOR_CYAN='\033[0;36m'
  COLOR_BOLD='\033[1m'
  COLOR_NC='\033[0m'
else
  COLOR_RED=''
  COLOR_YELLOW=''
  COLOR_GREEN=''
  COLOR_CYAN=''
  COLOR_BOLD=''
  COLOR_NC=''
fi
export COLOR_RED COLOR_YELLOW COLOR_GREEN COLOR_CYAN COLOR_BOLD COLOR_NC

# Print a yellow warning. Use for recoverable issues where installation continues.
# Usage: warn "message"  –or–  some_command || warn "message"
warn() {
  echo -e "${COLOR_YELLOW}WARN${COLOR_NC} $*"
}
export -f warn

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

# Exit with a red error message. Use for unrecoverable failures.
# Usage: some_command || die "Human-readable error message"
die() {
  echo ""
  echo -e "${COLOR_RED}${COLOR_BOLD}ERROR:${COLOR_NC} $*" >&2
  echo    "       Installation aborted. Fix the issue above and re-run — the installer will resume from the last completed step." >&2
  exit 1
}
export -f die

checkPrerequisites() {
  local errors=0
  local warnings=0

  # Display helpers — inline to avoid polluting global function namespace
  _pf_pass() { echo -e "  ${COLOR_GREEN}✓${COLOR_NC} $*"; }
  _pf_warn() { echo -e "  ${COLOR_YELLOW}!${COLOR_NC} $*"; warnings=$((warnings + 1)); }
  _pf_fail() { echo -e "  ${COLOR_RED}✗${COLOR_NC} $*"; errors=$((errors + 1)); }

  echo -e "${COLOR_CYAN}${COLOR_BOLD}Pre-flight checks${COLOR_NC}"
  echo    "───────────────────────────────────────────────────────────────"

  # ── 1. Ubuntu version ────────────────────────────────────────────────────────
  local ubuntu_version
  ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
  case "${ubuntu_version}" in
    24.04|22.04) _pf_pass "Ubuntu ${ubuntu_version} supported" ;;
    20.04)       _pf_warn "Ubuntu 20.04 reached end-of-life (April 2025) — use 22.04 or 24.04 for production" ;;
    *)           _pf_fail "Ubuntu ${ubuntu_version} not supported (supported: 20.04, 22.04, 24.04)" ;;
  esac

  # ── 2. SSH authorized_keys ───────────────────────────────────────────────────
  local key_count=0
  if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    key_count=$(grep -cE "^(ssh-|ecdsa-|sk-)" /root/.ssh/authorized_keys 2>/dev/null || echo 0)
  fi
  if [ "${key_count}" -gt 0 ]; then
    _pf_pass "SSH authorized_keys: ${key_count} key(s) found"
  else
    _pf_warn "No SSH public keys in /root/.ssh/authorized_keys — SSH hardening will skip disabling password auth (security risk)"
  fi

  # ── 3. Free disk space ───────────────────────────────────────────────────────
  local free_gb
  free_gb=$(df / --output=avail -BG 2>/dev/null | tail -1 | tr -d 'G ')
  if [ "${free_gb:-0}" -ge 4 ]; then
    _pf_pass "Disk space: ${free_gb} GB free on /"
  elif [ "${free_gb:-0}" -ge 2 ]; then
    _pf_warn "Disk space: ${free_gb} GB free — 4+ GB recommended (Brotli build + TYPO3 + packages)"
  else
    _pf_fail "Disk space: ${free_gb:-?} GB free — at least 2 GB required"
  fi

  # ── 4. RAM ───────────────────────────────────────────────────────────────────
  local ram_mb
  ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
  if [ "${ram_mb:-0}" -ge 2048 ]; then
    _pf_pass "RAM: ${ram_mb} MB"
  elif [ "${ram_mb:-0}" -ge 1024 ]; then
    _pf_warn "RAM: ${ram_mb} MB — 2+ GB recommended; PHP-FPM worker count will be limited"
  else
    _pf_warn "RAM: ${ram_mb:-?} MB — very limited; installation may succeed but performance will be poor"
  fi

  # ── 5. Internet connectivity ─────────────────────────────────────────────────
  if getent hosts archive.ubuntu.com > /dev/null 2>&1; then
    _pf_pass "Internet: DNS resolves (archive.ubuntu.com)"
  else
    _pf_fail "Internet: no connectivity or DNS failure — required for apt, Composer, and Brotli source download"
  fi

  # ── 6. Conflicting web server ────────────────────────────────────────────────
  if systemctl is-active apache2 > /dev/null 2>&1; then
    _pf_fail "Apache2 is running — conflicts with Nginx on ports 80/443 (stop or uninstall first)"
  elif dpkg -s apache2 > /dev/null 2>&1; then
    _pf_warn "Apache2 is installed but not running — may conflict if started later"
  else
    _pf_pass "No Apache2 conflict"
  fi

  if systemctl is-active nginx > /dev/null 2>&1; then
    local active_sites
    active_sites=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "^$" | wc -l)
    if [ "${active_sites}" -gt 0 ]; then
      _pf_warn "Nginx is running with ${active_sites} active site(s) — this installer will overwrite the site configuration"
    else
      _pf_pass "Nginx running (no active site configs)"
    fi
  else
    _pf_pass "No conflicting Nginx site configuration"
  fi

  # ── 7. Port conflicts ────────────────────────────────────────────────────────
  if ss -tlnp 2>/dev/null | grep -qE '\*:80\b|0\.0\.0\.0:80\b|\[::\]:80\b'; then
    _pf_warn "Port 80 is already in use — check: ss -tlnp | grep ':80'"
  fi
  if ss -tlnp 2>/dev/null | grep -qE '\*:443\b|0\.0\.0\.0:443\b|\[::\]:443\b'; then
    _pf_warn "Port 443 is already in use — check: ss -tlnp | grep ':443'"
  fi

  # ── Summary ──────────────────────────────────────────────────────────────────
  echo "───────────────────────────────────────────────────────────────"

  if [ "${errors}" -gt 0 ]; then
    echo -e "${COLOR_RED}${COLOR_BOLD}${errors} check(s) failed — fix the issues above before running the installer.${COLOR_NC}"
    exit 1
  elif [ "${warnings}" -gt 0 ]; then
    echo -e "${COLOR_YELLOW}${warnings} warning(s) — review above.${COLOR_NC}"
    echo ""
    read -rp "Continue anyway? [y/N] " _pf_confirm
    if [[ ! "${_pf_confirm}" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      echo "Aborted."
      exit 0
    fi
  else
    echo -e "${COLOR_GREEN}${COLOR_BOLD}All checks passed.${COLOR_NC}"
  fi
  echo ""
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
    die "Unsupported Ubuntu version: ${ubuntuVersion} — supported: 20.04, 22.04, 24.04"
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