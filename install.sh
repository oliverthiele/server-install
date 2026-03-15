#!/bin/bash

###############################################################################
# TYPO3 Installation Script
# Supports TYPO3 v12 LTS and v13 LTS
# Optimized for Ubuntu 20.04, 22.04, and 24.04
###############################################################################

# Get script directory — must come first so utils.sh can be sourced early
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load utils first: provides color variables, die(), and warn() for all checks below
source "${SCRIPT_DIR}/lib/utils.sh"

# Root check – must run before any system-level operations
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root — use: sudo ./install.sh"
fi

###############################################################################
# Load remaining modules
###############################################################################

source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/system.sh"
source "${SCRIPT_DIR}/lib/php.sh"
source "${SCRIPT_DIR}/lib/database.sh"
source "${SCRIPT_DIR}/lib/nginx.sh"
source "${SCRIPT_DIR}/lib/typo3.sh"
source "${SCRIPT_DIR}/lib/users.sh"
source "${SCRIPT_DIR}/lib/security.sh"

# Reboot check – Ubuntu writes this file after kernel or libc updates.
# Placed after source so warn() and color variables are available.
if [ -f /var/run/reboot-required ]; then
  warn "A system reboot is required before running this installer."
  echo "     This usually means a kernel or core library was updated."
  echo "     Please reboot and re-run the script:"
  echo "       reboot"
  echo ""
  echo "     To skip this check (not recommended): touch /tmp/skip-reboot-check && ./install.sh"
  if [ ! -f /tmp/skip-reboot-check ]; then
    exit 1
  fi
  warn "Reboot check skipped."
fi

###############################################################################
# Pre-installation instructions
###############################################################################

cat <<'EOF'
===============================================================
TYPO3 Server Installation Script
===============================================================

Designed for FRESH Ubuntu servers — no existing web server,
no existing PHP, no existing TYPO3. Existing configs WILL be
overwritten without further warning.

Before running this script, ensure you have:

  1. A freshly installed Ubuntu 22.04 or 24.04
  2. Updated the system and rebooted:
       apt update && apt --assume-yes dist-upgrade && apt --assume-yes autoremove
       reboot
  3. Added your SSH public key to /root/.ssh/authorized_keys
       (required for key-only login after SSH hardening)

===============================================================
EOF

checkPrerequisites

###############################################################################
# Main installation flow
###############################################################################

echo "==============================================================="
echo "Starting TYPO3 Installation..."
echo "==============================================================="

# Initialize state management
initState

# Check for previous installation
if askContinuePrevious; then
  echo "INFO Resuming from previous installation state"
else
  echo "INFO Starting fresh installation"
fi

# Step 1: Detect system and set variables
if ! isStepComplete "system_detection"; then
  getUbuntuVersionAndSetPhpVersion
  setVariables
  confirmInstallation
  cleanTargetDirectoryAndDatabase
  saveConfig
  markStepComplete "system_detection"
fi

# Step 2: Install system dependencies
if ! isStepComplete "dependencies"; then
  installDependencies
  installSoftware
  installComposer
  markStepComplete "dependencies"
fi

# Step 3: System hardening (early optimizations)
if ! isStepComplete "system_hardening"; then
  increaseLimits
  optimizeKernel
  hardenSSH
  markStepComplete "system_hardening"
fi

# Step 4: Setup PHP
if ! isStepComplete "php_setup"; then
  installPhpRedis
  optimizePhpSettings
  markStepComplete "php_setup"
fi

# Step 5: Setup Database and Redis
if ! isStepComplete "database_setup"; then
  createDatabase
  secureMariaDB
  secureRedis
  saveConfig  # Save database + Redis credentials
  markStepComplete "database_setup"
fi

# Step 6: Setup Zsh shell
if ! isStepComplete "zsh_setup"; then
  locale-gen de_DE.UTF-8
  activateZshShell
  markStepComplete "zsh_setup"
fi

# Step 7: Install TYPO3
if ! isStepComplete "typo3_install"; then
  installTypo3
  activateTypo3
  setupScheduler
  markStepComplete "typo3_install"
fi

# Step 8: Setup Nginx with Brotli
if ! isStepComplete "nginx_setup"; then
  getNginxVersion
  downloadNginxSource
  compileNginxWithBrotli
  configureBrotliInNginx
  configureNginx
  markStepComplete "nginx_setup"
fi

# Step 9: SSL/TLS and logging configuration
if ! isStepComplete "ssl_and_logging"; then
  configureSSLHardening
  setupLogrotate
  markStepComplete "ssl_and_logging"
fi

# Step 10: Setup users and permissions
if ! isStepComplete "users_and_permissions"; then
  configureWwwUser
  setPermissions
  markStepComplete "users_and_permissions"
fi

# Step 11: Install Node.js for www-data (for frontend builds)
if ! isStepComplete "nodejs_install"; then
  installNodeForWwwData
  markStepComplete "nodejs_install"
fi

# Step 12: Finish
if ! isStepComplete "finalization"; then
  finish
  markStepComplete "finalization"
fi


# Optional: tune PHP-FPM and MariaDB to match server resources
echo ""
read -rp "Run resource tuning now (PHP-FPM + MariaDB)? [Y/n] " tune_response
if [[ ! "${tune_response}" =~ ^([nN])$ ]]; then
  bash "${SCRIPT_DIR}/bin/tune-server.sh"
else
  echo "INFO Skipped. Run manually anytime: bin/tune-server.sh"
  echo "INFO Dry-run preview:               bin/tune-server.sh --dry-run"
fi

# Optional: full SSH hardening (port change + interactive confirmation)
echo ""
echo "SSH port change and full hardening (recommended for production)."
echo "Requires authorized_keys to be set up. Port 222 is the default."
read -rp "Run SSH hardening now? [Y/n] " ssh_response
if [[ ! "${ssh_response}" =~ ^([nN])$ ]]; then
  bash "${SCRIPT_DIR}/bin/harden-ssh.sh"
else
  echo "INFO Skipped. Run manually anytime: bin/harden-ssh.sh"
  echo "INFO Dry-run preview:               bin/harden-ssh.sh --dry-run"
fi

# Show all remaining TODOs at the very end — after tuning and SSH hardening
printNextSteps