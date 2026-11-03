#!/bin/bash

# setup-apt-security-source.sh – Read Ubuntu security updates from the official archive as well,
#                                 and keep the apt sources of the Ubuntu archive family signed
#
# 1. Security archive. Provider mirrors (Hetzner and others) can trail the official Ubuntu archive
#    by hours, sometimes by more than a day. For a critical fix that gap is the time a server stays
#    exposed. This script adds the official "<codename>-security" pocket as a second source next to
#    the mirror. apt installs the highest version it finds, so the fix arrives as soon as Canonical
#    publishes it; once the mirror has caught up nothing changes.
#
#    It inspects the sources already configured and fits the entry to the system: suite from the
#    Ubuntu codename, host security.ubuntu.com (ports.ubuntu.com on non-x86), the same components the
#    system already reads, the Ubuntu archive keyring. Nothing is added if an official host already
#    serves the pocket (a stock Ubuntu install does).
#
# 2. Signed-By. The Hetzner image ships mirror entries without a Signed-By line, so every
#    `apt update` prints "Missing Signed-By in the sources.list(5) entry". The script lists those
#    entries (Ubuntu archive family only; third-party sources bring their own key) and, if asked,
#    adds the Ubuntu archive keyring.
#
# Every change is tested: apt update must show no new problem, a simulated dist-upgrade must work and,
# for Signed-By, the configured package sources must be unchanged. A failed test rolls the change back.
# Safe to run multiple times. install.sh calls the same functions on a fresh server.
#
# Usage:
#   bin/setup-apt-security-source.sh                   # Interactive: asks before each change
#   bin/setup-apt-security-source.sh --dry-run         # Show the planned changes without applying
#   bin/setup-apt-security-source.sh --yes             # Add the security archive without asking
#   bin/setup-apt-security-source.sh --fix-signed-by   # Also add the missing Signed-By lines (no prompt)
#   bin/setup-apt-security-source.sh --remove          # Remove the security archive entry again
#
# --yes alone never touches the existing source files; editing them needs --fix-signed-by or a
# "y" at the prompt.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
AUTO_YES=false
FIX_SIGNED_BY=false
REMOVE=false
for arg in "$@"; do
  case $arg in
    --dry-run)       DRY_RUN=true ;;
    --yes|-y)        AUTO_YES=true ;;
    --fix-signed-by) FIX_SIGNED_BY=true ;;
    --remove)        REMOVE=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Privilege check ───────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root"
fi

SOURCE_FILE="/etc/apt/sources.list.d/ubuntu-security.sources"

echo "==============================================================="
echo "Ubuntu apt sources: official security archive and Signed-By"
echo "==============================================================="
echo ""

# ── Remove ────────────────────────────────────────────────────────────────────

if [[ "${REMOVE}" == "true" ]]; then
  if [[ ! -f "${SOURCE_FILE}" ]]; then
    echo "INFO ${SOURCE_FILE} does not exist — nothing to remove."
    exit 0
  fi
  if ! grep -q "^# Managed by ServerInstall" "${SOURCE_FILE}"; then
    die "${SOURCE_FILE} was not written by this script — remove it by hand if intended"
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: would remove ${SOURCE_FILE} and run apt update."
    exit 0
  fi
  rm -f "${SOURCE_FILE}"
  echo "INFO Removed ${SOURCE_FILE}"
  apt-get update
  exit 0
fi

# ── 1. Security archive ───────────────────────────────────────────────────────

echo "── 1. Official security archive ──"
if [[ "${DRY_RUN}" == "true" ]]; then
  addUbuntuSecuritySource --dry-run || true
  echo "DRY-RUN: security archive not changed."
elif [[ "${AUTO_YES}" == "true" ]]; then
  # No prompt: the function prints its own plan, so the plan is not shown twice
  addUbuntuSecuritySource || die "The official security archive was not added (see the warning above)"
else
  addUbuntuSecuritySource --dry-run || true
  case "${ubuntuSecurityAction}" in
    add|update)
      read -rp "Add the official security archive? [y/N] " apply
      if [[ "${apply}" =~ ^[yY]$ ]]; then
        addUbuntuSecuritySource || die "The official security archive was not added (see the warning above)"
      else
        echo "INFO Security archive skipped."
      fi
      ;;
  esac
fi
echo ""

# ── 2. Signed-By ──────────────────────────────────────────────────────────────

echo "── 2. Signed-By on Ubuntu archive sources ──"
MISSING="$(listSourcesWithoutSignedBy)"
if [[ -z "${MISSING}" ]]; then
  echo "INFO All Ubuntu archive sources have Signed-By."
else
  echo "Sources without Signed-By (apt prints 'Missing Signed-By' on every update):"
  printf '%s\n' "${MISSING}" | sed 's/^/     /'
  echo ""
  if [[ "${DRY_RUN}" == "true" ]]; then
    addSignedByToUbuntuSources --dry-run
  else
    fix="n"
    if [[ "${FIX_SIGNED_BY}" == "true" ]]; then
      fix="y"
    elif [[ "${AUTO_YES}" != "true" ]]; then
      # Defaults to no: this script runs on servers already in use (install.sh asks [Y/n] on a fresh one)
      read -rp "Add Signed-By (Ubuntu archive keyring) and test apt afterwards? [y/N] " fix
    else
      echo "INFO --yes does not edit existing source files. Run with --fix-signed-by to add the lines."
    fi
    if [[ "${fix}" =~ ^[yY]$ ]]; then
      addSignedByToUbuntuSources || die "Signed-By could not be added (rolled back)"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: no changes applied."
else
  echo "Check where a package would come from, for example:  apt-cache policy libc6"
  echo "Remove the security archive entry again:             bin/setup-apt-security-source.sh --remove"
fi
