#!/bin/bash

# migrate-php-repo.sh – Switch the PHP package source from the ondrej/php Launchpad PPA
#                        to Ondřej Surý's own repository at packages.sury.org
#
# Background: Launchpad's build infrastructure has become unreliable, so Ondřej Surý is
# moving PHP package builds off Launchpad. Servers still using ppa:ondrej/php will start
# seeing an apt error on the next `apt update`:
#   E: Repository '...ondrej/php...' changed its 'Label' value from 'PPA for PHP' to
#      'Use https://packages.sury.org/php/ instead'
#
# This script performs the switch described at https://packages.sury.org/php/README.txt:
# installs the sury.org keyring + apt source, then removes the old PPA. Safe to re-run.
#
# Usage:
#   bin/migrate-php-repo.sh            # Interactive mode
#   bin/migrate-php-repo.sh --dry-run  # Show planned changes without applying
#   bin/migrate-php-repo.sh --yes      # Non-interactive

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
AUTO_YES=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  AUTO_YES=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Privilege check ───────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root"
fi

# ── Detect current state ──────────────────────────────────────────────────────

SURY_LIST="/etc/apt/sources.list.d/php.list"
SURY_KEYRING="/usr/share/keyrings/debsuryorg-archive-keyring.gpg"

mapfile -t PPA_FILES < <(grep -rl "ondrej" /etc/apt/sources.list.d/ 2>/dev/null || true)

SURY_ACTIVE=false
if [[ -f "${SURY_LIST}" ]] && grep -q "packages.sury.org" "${SURY_LIST}"; then
  SURY_ACTIVE=true
fi

echo "==============================================================="
echo "PHP Repository Migration: ondrej/php PPA -> packages.sury.org"
echo "==============================================================="
echo ""

if [[ "${#PPA_FILES[@]}" -eq 0 ]] && [[ "${SURY_ACTIVE}" == "true" ]]; then
  echo "INFO Already migrated — ${SURY_LIST} is active and no ondrej PPA source remains."
  exit 0
fi

if [[ "${#PPA_FILES[@]}" -eq 0 ]] && [[ "${SURY_ACTIVE}" == "false" ]]; then
  echo "INFO No ondrej/php PPA source found — this server is not affected. Nothing to do."
  exit 0
fi

echo "Found ondrej/php PPA source(s):"
for file in "${PPA_FILES[@]}"; do
  echo "  ${file}"
done
echo ""

CODENAME=$(lsb_release -sc)
echo "Changes to be applied:"
echo "  1. Install prerequisites   : lsb-release ca-certificates curl"
echo "  2. Install keyring         : ${SURY_KEYRING}"
echo "  3. Write apt source        : ${SURY_LIST} (packages.sury.org/php ${CODENAME})"
echo "  4. Remove old PPA source(s): ${PPA_FILES[*]}"
echo "  5. Run apt update"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: no changes applied."
  exit 0
fi

# ── Confirmation ──────────────────────────────────────────────────────────────

if [[ "${AUTO_YES}" != "true" ]]; then
  read -rp "Apply PHP repository migration? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
    echo "INFO Aborted – no changes made."
    exit 0
  fi
fi

# ── Add packages.sury.org ─────────────────────────────────────────────────────

addPhpRepo

# ── Remove old PPA ────────────────────────────────────────────────────────────

echo "INFO Removing ondrej/php PPA..."
if command -v add-apt-repository &>/dev/null; then
  add-apt-repository --yes --remove ppa:ondrej/php \
    || warn "add-apt-repository --remove failed — removing source file(s) directly"
fi

# Belt and braces: add-apt-repository may not catch every file (e.g. manually created ones)
for file in "${PPA_FILES[@]}"; do
  if [[ -f "${file}" ]]; then
    rm -f "${file}"
    echo "INFO Removed ${file}"
  fi
done

# ── Refresh package index ─────────────────────────────────────────────────────

echo "INFO Running apt update..."
apt-get update

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==============================================================="
echo "Migration Complete"
echo "==============================================================="
echo ""
echo "  PHP packages now come from: https://packages.sury.org/php/"
echo ""
echo "  Review available upgrades:"
echo "    apt list --upgradable 2>/dev/null | grep -E '^php'"
echo "  Apply them:"
echo "    apt upgrade"
echo "==============================================================="