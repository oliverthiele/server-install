#!/bin/bash

# setup-deploy-user.sh – create a dedicated deploy user instead of direct www-data SSH access
#
# Creates a personal login user (default: deploy) that
#   - logs in via SSH with its own key,
#   - is a member of the www-data group,
#   - may run any command as www-data without a password (sudo -u www-data ...).
# Optionally disables the direct SSH login of www-data afterwards.
#
# This separates "who logs in" (deploy, auditable) from "who owns the site"
# (www-data, no direct login). Safe to run multiple times — existing users
# are reconfigured, not duplicated.
#
# Usage:
#   bin/setup-deploy-user.sh            # Interactive mode
#   bin/setup-deploy-user.sh --dry-run  # Show planned changes without applying
#   bin/setup-deploy-user.sh --yes      # Non-interactive (defaults, www-data login stays enabled)

set -e

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"

# ── Constants ─────────────────────────────────────────────────────────────────

DEFAULT_DEPLOY_USER="deploy"
ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
WWW_AUTHORIZED_KEYS="/var/www/.ssh/authorized_keys"

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

echo "==============================================================="
echo "Deploy User Setup"
echo "==============================================================="
echo ""
echo "Creates a dedicated SSH login user that works on the TYPO3 site"
echo "via 'sudo -u www-data' instead of logging in as www-data directly."
echo ""

# ── Username selection ────────────────────────────────────────────────────────

if [[ "${AUTO_YES}" == "true" ]]; then
  deployUser="${DEFAULT_DEPLOY_USER}"
else
  read -rp "Deploy username [${DEFAULT_DEPLOY_USER}]: " input_user
  deployUser=${input_user:-${DEFAULT_DEPLOY_USER}}
fi

if ! [[ "${deployUser}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  die "Invalid username: ${deployUser} (lowercase letters, digits, - and _ only)"
fi

case "${deployUser}" in
  root|www-data|nobody|daemon)
    die "Refusing to reconfigure system user '${deployUser}' — choose a dedicated name"
    ;;
esac

userExists=false
if id "${deployUser}" &>/dev/null; then
  userExists=true
  echo "INFO User '${deployUser}' already exists — settings will be re-applied (idempotent)"
fi

# ── SSH key source ────────────────────────────────────────────────────────────

# The deploy user needs at least one SSH public key. Default: copy root's
# authorized_keys (the person installing the server is usually the deployer).
rootKeyCount=0
if [[ -f "${ROOT_AUTHORIZED_KEYS}" ]] && [[ -s "${ROOT_AUTHORIZED_KEYS}" ]]; then
  rootKeyCount=$(grep -cE "^(ssh-|ecdsa-|sk-)" "${ROOT_AUTHORIZED_KEYS}" 2>/dev/null || true)
fi

keySource=""
customPublicKey=""

if [[ "${AUTO_YES}" == "true" ]]; then
  [[ ${rootKeyCount} -eq 0 ]] && die "No keys in ${ROOT_AUTHORIZED_KEYS} — cannot continue non-interactively"
  keySource="root"
else
  if [[ ${rootKeyCount} -gt 0 ]]; then
    echo "Found ${rootKeyCount} SSH key(s) in ${ROOT_AUTHORIZED_KEYS}."
    read -rp "Copy root's authorized_keys to ${deployUser}? [Y/n] " copy_response
    if [[ ! "${copy_response}" =~ ^[nN]$ ]]; then
      keySource="root"
    fi
  fi

  if [[ -z "${keySource}" ]]; then
    echo "Paste the SSH public key for ${deployUser} (single line, 'ssh-ed25519 AAAA... comment'):"
    read -r customPublicKey
    if ! [[ "${customPublicKey}" =~ ^(ssh-|ecdsa-|sk-) ]]; then
      die "That does not look like an SSH public key — aborting, no changes made"
    fi
    keySource="custom"
  fi
fi

# ── Ask about disabling direct www-data SSH login ─────────────────────────────

disableWwwLogin=false
wwwKeyCount=0
if [[ -f "${WWW_AUTHORIZED_KEYS}" ]] && [[ -s "${WWW_AUTHORIZED_KEYS}" ]]; then
  wwwKeyCount=$(grep -cE "^(ssh-|ecdsa-|sk-)" "${WWW_AUTHORIZED_KEYS}" 2>/dev/null || true)
fi

if [[ "${AUTO_YES}" != "true" ]] && [[ ${wwwKeyCount} -gt 0 ]]; then
  echo ""
  echo "www-data currently has ${wwwKeyCount} SSH key(s) and can be logged into directly."
  echo "Recommended: disable this once the ${deployUser} login is confirmed working."
  echo "A backup of the key file is kept, so this can be undone."
  read -rp "Disable direct www-data SSH login now? [y/N] " disable_response
  if [[ "${disable_response}" =~ ^[yY]$ ]]; then
    disableWwwLogin=true
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

sshPort=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
sshPort=${sshPort:-22}

echo ""
echo "Changes to be applied:"
if [[ "${userExists}" == "true" ]]; then
  echo "  User                : ${deployUser} (exists — reconfigure)"
else
  echo "  User                : ${deployUser} (create, shell: zsh if available)"
fi
echo "  Group membership    : www-data"
if [[ "${keySource}" == "root" ]]; then
  echo "  SSH keys            : copy ${rootKeyCount} key(s) from root"
else
  echo "  SSH keys            : 1 pasted public key"
fi
echo "  Sudo rule           : /etc/sudoers.d/${deployUser} — ${deployUser} ALL=(www-data) NOPASSWD: ALL"
if [[ "${disableWwwLogin}" == "true" ]]; then
  echo "  www-data SSH login  : disabled (authorized_keys emptied, backup kept)"
else
  echo "  www-data SSH login  : unchanged"
fi
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: no changes applied."
  exit 0
fi

if [[ "${AUTO_YES}" != "true" ]]; then
  read -rp "Apply deploy user setup? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
    echo "INFO Aborted – no changes made."
    exit 0
  fi
fi

# ── Create or update the user ─────────────────────────────────────────────────

loginShell="/bin/bash"
if [[ -x /bin/zsh ]]; then
  loginShell="/bin/zsh"
fi

if [[ "${userExists}" == "true" ]]; then
  usermod -aG www-data "${deployUser}"
else
  useradd -m -s "${loginShell}" -G www-data -c "TYPO3 deploy user" "${deployUser}"
  echo "INFO User ${deployUser} created"
fi

deployHome=$(getent passwd "${deployUser}" | cut -d: -f6)
[[ -d "${deployHome}" ]] || die "Home directory ${deployHome} does not exist"

# oh-my-zsh: reuse root's setup if present (same pattern as www-data in lib/system.sh)
if [[ "${loginShell}" == "/bin/zsh" ]] && [[ -d /root/.oh-my-zsh ]] && [[ ! -d "${deployHome}/.oh-my-zsh" ]]; then
  cp -a /root/.oh-my-zsh /root/.zshrc "${deployHome}/"
  echo "cd /var/www/typo3/" >> "${deployHome}/.zshrc"
  chown -R "${deployUser}:${deployUser}" "${deployHome}/.oh-my-zsh" "${deployHome}/.zshrc"
fi

# ── SSH keys ──────────────────────────────────────────────────────────────────

mkdir -p "${deployHome}/.ssh"
if [[ "${keySource}" == "root" ]]; then
  cp "${ROOT_AUTHORIZED_KEYS}" "${deployHome}/.ssh/authorized_keys"
else
  echo "${customPublicKey}" > "${deployHome}/.ssh/authorized_keys"
fi
chmod 0700 "${deployHome}/.ssh"
chmod 0600 "${deployHome}/.ssh/authorized_keys"
chown -R "${deployUser}:${deployUser}" "${deployHome}/.ssh"
echo "INFO SSH keys installed for ${deployUser}"

# ── Sudo rule (validated before install — a broken sudoers file locks out sudo) ──

sudoersFile="/etc/sudoers.d/${deployUser}"
sudoersTmp=$(mktemp)
cat > "${sudoersTmp}" <<EOF
# Allow ${deployUser} to run any command as www-data without a password.
# Managed by ServerInstall (bin/setup-deploy-user.sh).
${deployUser} ALL=(www-data) NOPASSWD: ALL
EOF

if ! visudo -cf "${sudoersTmp}" >/dev/null; then
  rm -f "${sudoersTmp}"
  die "Generated sudoers rule failed validation — no changes to sudo configuration"
fi

install -m 0440 -o root -g root "${sudoersTmp}" "${sudoersFile}"
rm -f "${sudoersTmp}"
echo "INFO Sudo rule installed: ${sudoersFile}"

# ── Optionally disable direct www-data SSH login ──────────────────────────────

if [[ "${disableWwwLogin}" == "true" ]]; then
  backupFile="${WWW_AUTHORIZED_KEYS}.disabled.$(date +%Y%m%d-%H%M%S)"
  mv "${WWW_AUTHORIZED_KEYS}" "${backupFile}"
  touch "${WWW_AUTHORIZED_KEYS}"
  chown www-data:www-data "${WWW_AUTHORIZED_KEYS}"
  chmod 0600 "${WWW_AUTHORIZED_KEYS}"
  echo "INFO www-data SSH login disabled (backup: ${backupFile})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==============================================================="
echo "Deploy User Setup Complete"
echo "==============================================================="
echo ""
echo "  Login          : ssh -p ${sshPort} ${deployUser}@<server>"
echo "  Work as site   : sudo -u www-data -i        (interactive shell)"
echo "                   sudo -u www-data composer install"
echo "                   sudo -u www-data vendor/bin/typo3 cache:flush"
echo ""
echo "  IMPORTANT: test the ${deployUser} SSH login in a second terminal"
echo "  before closing this session."
if [[ "${disableWwwLogin}" != "true" ]] && [[ ${wwwKeyCount} -gt 0 ]]; then
  echo ""
  echo "  Direct www-data SSH login is still enabled. Once ${deployUser}"
  echo "  works, disable it by re-running: bin/setup-deploy-user.sh"
fi
echo "==============================================================="
