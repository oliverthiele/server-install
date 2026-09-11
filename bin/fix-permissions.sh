#!/bin/bash

# fix-permissions.sh – Reset TYPO3 site file ownership/permissions to the
# baseline applied at install time (setPermissions() in lib/users.sh).
#
# Group-write access for deploy users depends on every file staying group-writable,
# but that drifts over time: setgid directories (2770) only make new files inherit
# the www-data *group* — the write bit itself comes from the umask of whoever
# creates the file. A package update, or a deploy user working directly instead of
# via `sudo -u www-data`, can leave files/directories that other www-data group
# members can no longer write to ("Permission denied" from git/composer). Run this
# to reset the whole tree back to the installer's baseline.
#
# Scope: the TYPO3 site directory only. Does not touch /var/www/.ssh/ — SSH
# credentials are unrelated to site file drift and out of scope here.
#
# Usage:
#   bin/fix-permissions.sh            # Apply
#   bin/fix-permissions.sh --dry-run  # Show what would change, without applying

set -e

# Load shared utilities/config (colors, warn, die, composerDirectory) — works both
# standalone and when called from install.sh
SCRIPT_DIR_FIXPERM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR_FIXPERM}/../lib/utils.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR_FIXPERM}/../lib/config.sh"
# shellcheck source=../lib/users.sh
source "${SCRIPT_DIR_FIXPERM}/../lib/users.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; echo "Usage: $0 [--dry-run]"; exit 1 ;;
  esac
done

# ── Root check ────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root"
fi

[[ -d "${composerDirectory}" ]] || die "Target directory not found: ${composerDirectory}"

echo "==============================================================="
echo "Fix TYPO3 File Permissions"
echo "==============================================================="
echo "Target: ${composerDirectory}"
echo ""

installLogFile="${composerDirectory}install-log-please-remove.md"

# ── Dry run ───────────────────────────────────────────────────────────────────

if [[ "${DRY_RUN}" == "true" ]]; then
  dirCount=$(find "${composerDirectory}" -type d ! -perm 2770 | wc -l | tr -d ' ')
  fileCount=$(find "${composerDirectory}" -type f ! -perm /u=x,g=x,o=x ! -perm 0660 | wc -l | tr -d ' ')
  ownerCount=$(find "${composerDirectory}" \( ! -user www-data -o ! -group www-data \) | wc -l | tr -d ' ')

  echo "DRY-RUN: no changes applied."
  echo "  Directories that would change to 2770 : ${dirCount}"
  echo "  Files that would change to 0660        : ${fileCount}"
  echo "  Paths with wrong owner/group           : ${ownerCount}"

  if [[ -f "${installLogFile}" ]]; then
    echo ""
    warn "${installLogFile} still exists — it would stay excluded from the 0660 sweep (kept at 0600), but should really be deleted once its credentials are noted."
  fi
  exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────

setPermissions

# setPermissions() sweeps every file under composerDirectory to 0660, including
# the credentials log if the operator never deleted it — restore its owner-only mode.
if [[ -f "${installLogFile}" ]]; then
  chmod 0600 "${installLogFile}"
  echo ""
  warn "${installLogFile} still exists and was reset to 0600 (owner-only) — it contains plaintext credentials. Delete it once noted: rm ${installLogFile}"
fi

echo ""
echo "==============================================================="
echo "Done."
echo "==============================================================="