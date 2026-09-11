#!/bin/bash

# setup-www-data-deploy-key.sh – Generate a dedicated outbound SSH key for www-data
#
# For `git pull` against a private repository (e.g. the site's own composer.json-managed
# codebase) run via `sudo -u www-data`. Keeps outbound git authentication independent of
# any individual deploy user's personal SSH key/agent — sudo does not (and should not)
# forward a deploy user's agent into the www-data session, so www-data needs its own
# credential for connections it initiates. Scope it to read-only access on whichever
# remote it's registered against.
#
# This is a separate, outbound-only key pair — it does NOT touch
# /var/www/.ssh/authorized_keys (inbound login as www-data).
#
# Safe to run multiple times: an existing key is left untouched, only ownership/
# permissions and the SSH config entry are re-applied.
#
# Usage:
#   bin/setup-www-data-deploy-key.sh            # Generate (if missing) and print the public key
#   bin/setup-www-data-deploy-key.sh --dry-run  # Show what would happen, without applying

set -e

# Load shared utilities/config (colors, warn, die, composerDirectory) — works both
# standalone and when called from install.sh
SCRIPT_DIR_DEPLOYKEY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR_DEPLOYKEY}/../lib/utils.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR_DEPLOYKEY}/../lib/config.sh"

WWW_SSH_DIR="/var/www/.ssh"
DEPLOY_KEY_FILE="${WWW_SSH_DIR}/id_ed25519"
SSH_CONFIG_FILE="${WWW_SSH_DIR}/config"

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

echo "==============================================================="
echo "www-data Deploy Key Setup"
echo "==============================================================="
echo ""

# ── Generate key (idempotent) ─────────────────────────────────────────────────

if [[ -f "${DEPLOY_KEY_FILE}" ]]; then
  echo "INFO Deploy key already exists: ${DEPLOY_KEY_FILE} (leaving it untouched)"
else
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: would generate ${DEPLOY_KEY_FILE} (ed25519, no passphrase)"
    exit 0
  fi

  mkdir -p "${WWW_SSH_DIR}"
  deployKeyComment="www-data@$(hostname -f 2>/dev/null || hostname)"
  sudo -u www-data ssh-keygen -t ed25519 -f "${DEPLOY_KEY_FILE}" -N "" -C "${deployKeyComment}" -q
  echo "INFO Deploy key generated: ${DEPLOY_KEY_FILE}"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: no further changes applied."
  exit 0
fi

# ── Ownership / permissions ───────────────────────────────────────────────────

chown www-data:www-data "${WWW_SSH_DIR}" "${DEPLOY_KEY_FILE}" "${DEPLOY_KEY_FILE}.pub"
chmod 0700 "${WWW_SSH_DIR}"
chmod 0600 "${DEPLOY_KEY_FILE}"
chmod 0644 "${DEPLOY_KEY_FILE}.pub"

# ── SSH config: pin www-data's outbound connections to this key only ─────────
# Without IdentitiesOnly, an OpenSSH client offers every key it can find first —
# harmless here, but explicit is safer once more keys show up in this directory.

if [[ ! -f "${SSH_CONFIG_FILE}" ]] || ! grep -q "IdentityFile ${DEPLOY_KEY_FILE}" "${SSH_CONFIG_FILE}" 2>/dev/null; then
  {
    echo "Host *"
    echo "    IdentityFile ${DEPLOY_KEY_FILE}"
    echo "    IdentitiesOnly yes"
  } >> "${SSH_CONFIG_FILE}"
  chown www-data:www-data "${SSH_CONFIG_FILE}"
  chmod 0600 "${SSH_CONFIG_FILE}"
  echo "INFO SSH config updated: ${SSH_CONFIG_FILE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==============================================================="
echo "Public key — register as a READ-ONLY deploy key on the git remote:"
echo "==============================================================="
cat "${DEPLOY_KEY_FILE}.pub"
echo ""
echo "  GitHub: Repo -> Settings -> Deploy keys -> Add deploy key (leave 'Allow write access' unchecked)"
echo "  GitLab: Repo -> Settings -> Repository -> Deploy keys"
echo ""
echo "The first connection to a new host asks to confirm its host key — that's an"
echo "interactive TOFU prompt, answer 'yes' once from the sudo -u www-data shell below."
echo ""
echo "Test after registering:"
echo "  sudo -u www-data -i"
echo "  ssh -T git@<host>"
echo "  git -C ${composerDirectory} pull"
echo "==============================================================="
