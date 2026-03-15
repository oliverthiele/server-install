#!/bin/bash

# harden-ssh.sh – SSH hardening with interactive port configuration
#
# Checks for existing authorized_keys before disabling password auth.
# Changes SSH port, disables password-based login, applies best-practice settings.
# Safe to run multiple times. Run after initial setup or after server rebuild.
#
# HETZNER NOTE:
#   Password auth is disabled for SSH only. Hetzner's "Reset Root Password"
#   feature (via QEMU Guest Agent) continues to work. Use the Hetzner Cloud
#   Console (web browser KVM) for emergency access with the reset password.
#   Do NOT remove qemu-guest-agent if it is installed.
#
# Usage:
#   bin/harden-ssh.sh            # Interactive mode
#   bin/harden-ssh.sh --dry-run  # Show planned changes without applying
#   bin/harden-ssh.sh --yes      # Non-interactive (use defaults)

set -e

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"

# ── Constants ─────────────────────────────────────────────────────────────────

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
DEFAULT_SSH_PORT=222

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

# ── Authorized keys check ─────────────────────────────────────────────────────

KEY_COUNT=0
if [[ -f "${AUTHORIZED_KEYS}" ]] && [[ -s "${AUTHORIZED_KEYS}" ]]; then
  KEY_COUNT=$(grep -cE "^(ssh-|ecdsa-|sk-)" "${AUTHORIZED_KEYS}" 2>/dev/null || true)
fi

echo "==============================================================="
echo "SSH Hardening"
echo "==============================================================="
echo ""

if [[ ${KEY_COUNT} -eq 0 ]]; then
  echo ""
  echo "Disabling password auth without a working key would lock you out."
  echo "Add your public key first:"
  echo "  ssh-copy-id root@<server>"
  echo "  -- or --"
  echo "  echo 'ssh-rsa AAAA...' >> ${AUTHORIZED_KEYS}"
  die "No SSH public keys found in ${AUTHORIZED_KEYS}"
fi

echo "INFO Found ${KEY_COUNT} SSH key(s) in authorized_keys"
echo ""

# ── Current state ─────────────────────────────────────────────────────────────

CURRENT_PORT=$(grep -E "^Port " "${SSHD_CONFIG}" | awk '{print $2}' || true)
CURRENT_PORT=${CURRENT_PORT:-22}

echo "Current SSH port : ${CURRENT_PORT}"
echo ""

# ── Hetzner notice ────────────────────────────────────────────────────────────

echo "NOTE  Hetzner servers: After hardening, SSH password login is disabled."
echo "      Emergency access still works via:"
echo "      1. Hetzner Cloud Console (web KVM in your browser)"
echo "      2. Hetzner 'Reset Root Password' (QEMU Guest Agent) + Cloud Console"
echo "      => Keep qemu-guest-agent installed if present"
echo ""

# Warn if qemu-guest-agent is NOT installed
if ! dpkg -l qemu-guest-agent &>/dev/null; then
  warn "qemu-guest-agent is not installed."
  echo "      On Hetzner, install it for emergency recovery:"
  echo "        apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent"
  echo ""
fi

# ── Port selection ────────────────────────────────────────────────────────────

if [[ "${AUTO_YES}" == "true" ]]; then
  NEW_PORT=${DEFAULT_SSH_PORT}
else
  read -rp "New SSH port [${DEFAULT_SSH_PORT}]: " input_port
  NEW_PORT=${input_port:-${DEFAULT_SSH_PORT}}
fi

if ! [[ "${NEW_PORT}" =~ ^[0-9]+$ ]] || [[ "${NEW_PORT}" -lt 1 ]] || [[ "${NEW_PORT}" -gt 65535 ]]; then
  die "Invalid port: ${NEW_PORT}"
fi

# ── UFW detection ─────────────────────────────────────────────────────────────

UFW_ACTIVE=false
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
  UFW_ACTIVE=true
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Changes to be applied:"
echo "  Port                      : ${CURRENT_PORT} → ${NEW_PORT}"
echo "  PasswordAuthentication    : no"
echo "  ChallengeResponseAuth     : no"
echo "  PermitRootLogin           : prohibit-password  (key-based root login allowed)"
echo "  PubkeyAuthentication      : yes"
echo "  MaxAuthTries              : 3"
echo "  LoginGraceTime            : 30"
echo "  X11Forwarding             : no"
echo "  PermitEmptyPasswords      : no"
echo "  StrictModes               : yes"
if [[ "${UFW_ACTIVE}" == "true" ]]; then
  echo "  UFW                       : rule for port ${NEW_PORT}/tcp will be added"
fi
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: no changes applied."
  exit 0
fi

# ── Confirmation ──────────────────────────────────────────────────────────────

if [[ "${AUTO_YES}" != "true" ]]; then
  warn "This applies immediately and changes the SSH port."
  echo "        Open a second terminal and keep it ready before confirming."
  echo ""
  read -rp "Apply SSH hardening? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
    echo "INFO Aborted – no changes made."
    exit 0
  fi
fi

# ── Helper: set or replace a directive in sshd_config ────────────────────────

set_sshd_option() {
  local key="$1"
  local value="$2"
  if grep -qE "^#*[[:space:]]*${key}[[:space:]]" "${SSHD_CONFIG}"; then
    sed -i "s|^#*[[:space:]]*${key}[[:space:]].*|${key} ${value}|" "${SSHD_CONFIG}"
  else
    echo "${key} ${value}" >> "${SSHD_CONFIG}"
  fi
}

# ── Backup ────────────────────────────────────────────────────────────────────

BACKUP="${SSHD_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
cp "${SSHD_CONFIG}" "${BACKUP}"
echo "INFO Backup: ${BACKUP}"

# ── Apply settings ────────────────────────────────────────────────────────────

set_sshd_option "Port"                          "${NEW_PORT}"
set_sshd_option "PasswordAuthentication"        "no"
set_sshd_option "ChallengeResponseAuthentication" "no"
set_sshd_option "PermitRootLogin"               "prohibit-password"
set_sshd_option "PubkeyAuthentication"          "yes"
set_sshd_option "MaxAuthTries"                  "3"
set_sshd_option "LoginGraceTime"                "30"
set_sshd_option "X11Forwarding"                 "no"
set_sshd_option "PermitEmptyPasswords"          "no"
set_sshd_option "StrictModes"                   "yes"
set_sshd_option "UsePAM"                        "yes"

# Protocol 2 is the default in modern OpenSSH but make it explicit
if ! grep -qE "^Protocol " "${SSHD_CONFIG}"; then
  echo "Protocol 2" >> "${SSHD_CONFIG}"
fi

# ── UFW: open new port ────────────────────────────────────────────────────────

if [[ "${UFW_ACTIVE}" == "true" ]]; then
  echo "INFO UFW: adding rule for port ${NEW_PORT}/tcp"
  ufw allow "${NEW_PORT}/tcp" comment "SSH"
  # Note: port 22 rule (if present) is intentionally left in UFW.
  # SSH no longer listens on it, so it is harmless. Remove manually if desired:
  #   ufw delete allow 22/tcp
fi

# ── Config test ───────────────────────────────────────────────────────────────

echo "INFO Testing SSH configuration..."
if ! sshd -t; then
  cp "${BACKUP}" "${SSHD_CONFIG}"
  echo "INFO Backup restored. No changes applied."
  die "SSH config test failed — backup restored"
fi

# ── Restart SSH ───────────────────────────────────────────────────────────────

echo "INFO Restarting SSH service..."
if systemctl is-active --quiet ssh 2>/dev/null; then
  systemctl restart ssh
elif systemctl is-active --quiet sshd 2>/dev/null; then
  systemctl restart sshd
else
  # Try starting the service if not currently active
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || {
    warn "Could not restart SSH automatically – please restart manually:"
    echo "     systemctl restart ssh"
  }
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==============================================================="
echo "SSH Hardening Complete"
echo "==============================================================="
echo ""
echo "  SSH port  : ${NEW_PORT}"
echo "  Connect   : ssh -p ${NEW_PORT} root@<server>"
echo ""
echo "  Hetzner emergency access:"
echo "  - Cloud Console (web browser KVM) in your Hetzner panel"
echo "  - Reset password via 'Reset Root Password' in the panel,"
echo "    then log in via Cloud Console (SSH password login is now off)"
echo ""
if [[ "${UFW_ACTIVE}" == "true" ]]; then
  echo "  UFW: port ${NEW_PORT}/tcp opened."
  if ufw status | grep -q "^22/tcp\|^22 "; then
    echo "  UFW: old port 22 rule is still present (harmless – nothing listens on it)."
    echo "       Remove manually if desired: ufw delete allow 22/tcp"
  fi
  echo ""
fi
echo "  Config backup : ${BACKUP}"
echo "==============================================================="