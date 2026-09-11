#!/bin/bash

# bot-policy – manage nginx access rules for bots, crawlers, and search engines
#
# Lets a customer without Linux experience decide, per bot, whether it is
# unrestricted, blocked only on the site search (see settings.json search
# paths), or blocked entirely — without touching nginx config by hand.
# Edits always go to a draft first; nothing reaches the live nginx config
# until an explicit activation. See lib/storage.sh for the on-disk layout.
#
# Usage:
#   bin/bot-policy/bot-policy.sh                    Interactive menu
#   bin/bot-policy/bot-policy.sh --report            Print the draft report (proposal, not yet active)
#   bin/bot-policy/bot-policy.sh --report --active    Print the report for the currently live policy
#   bin/bot-policy/bot-policy.sh --activate           Activate the draft non-interactively (e.g. from a script)
#   bin/bot-policy/bot-policy.sh --seed=production    Seed from the built-in catalog if not yet initialized
#   bin/bot-policy/bot-policy.sh --seed=staging       Same, but AI crawlers start out blocked too

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
UTILS_FILE="${SCRIPT_DIR}/../../lib/utils.sh"
if [[ -f "${UTILS_FILE}" ]]; then
  # shellcheck source=../../lib/utils.sh
  source "${UTILS_FILE}"
fi

# shellcheck source=lib/storage.sh
source "${SCRIPT_DIR}/lib/storage.sh"
# shellcheck source=lib/report.sh
source "${SCRIPT_DIR}/lib/report.sh"
# shellcheck source=lib/menu.sh
source "${SCRIPT_DIR}/lib/menu.sh"

DEFAULT_CATALOG="${SCRIPT_DIR}/data/default-bots.json"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR This script must be run as root (reads/writes ${BOT_POLICY_DIR})" >&2
  exit 1
fi

REPORT=false
REPORT_ACTIVE=false
ACTIVATE=false
SEED_MODE=""

for arg in "$@"; do
  case "${arg}" in
    --report) REPORT=true ;;
    --active) REPORT_ACTIVE=true ;;
    --activate) ACTIVATE=true ;;
    --seed=*) SEED_MODE="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--report [--active]] [--activate] [--seed=production|staging]"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--report [--active]] [--activate] [--seed=production|staging]" >&2
      exit 1
      ;;
  esac
done

if [[ -n "${SEED_MODE}" ]]; then
  seedBotPolicyIfMissing "${SEED_MODE}" "${DEFAULT_CATALOG}"
  exit $?
fi

if [[ "${REPORT}" == "true" ]]; then
  if [[ "${REPORT_ACTIVE}" == "true" ]]; then
    generateBotPolicyReport "$(_botPolicyActiveFile)" "Aktiv"
  else
    generateBotPolicyReport "$(_botPolicyDraftFile)" "Entwurf (noch nicht aktiv)"
  fi
  exit $?
fi

if [[ "${ACTIVATE}" == "true" ]]; then
  activateBotPolicy
  exit $?
fi

# No flags: interactive use. Seed on first run so a standalone call (without
# install.sh ever having run) still has something to edit.
seedBotPolicyIfMissing "production" "${DEFAULT_CATALOG}"
runBotPolicyMenu
