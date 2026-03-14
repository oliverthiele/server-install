#!/bin/bash

###############################################################################
# TYPO3 Installation Script
# Supports TYPO3 v12 LTS and v13 LTS
# Optimized for Ubuntu 20.04, 22.04, and 24.04
###############################################################################

# Exit on error
set -e

# Root check – must run before any system-level operations
if [[ $EUID -ne 0 ]]; then
  echo "ERROR This script must be run as root."
  echo "      Use: sudo ./install.sh"
  exit 1
fi

# Reboot check – Ubuntu writes this file after kernel or libc updates
if [ -f /var/run/reboot-required ]; then
  echo "WARN A system reboot is required before running this installer."
  echo "     This usually means a kernel or core library was updated."
  echo "     Please reboot and re-run the script:"
  echo "       reboot"
  echo ""
  echo "     To skip this check (not recommended): touch /tmp/skip-reboot-check && ./install.sh"
  if [ ! -f /tmp/skip-reboot-check ]; then
    exit 1
  fi
  echo "WARN Reboot check skipped."
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Trap to clean up on exit
trap 'echo "Script exited with error. Cleaning up..."; cleanup' EXIT

###############################################################################
# Load modules
###############################################################################

source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/system.sh"
source "${SCRIPT_DIR}/lib/php.sh"
source "${SCRIPT_DIR}/lib/database.sh"
source "${SCRIPT_DIR}/lib/nginx.sh"
source "${SCRIPT_DIR}/lib/typo3.sh"
source "${SCRIPT_DIR}/lib/users.sh"
source "${SCRIPT_DIR}/lib/security.sh"

###############################################################################
# Pre-installation instructions
###############################################################################

cat <<'EOF'
===============================================================
TYPO3 Installation Script
===============================================================

Before executing this script, ensure you have:

1. Updated your system:
   $ apt update && apt --assume-yes dist-upgrade && apt --assume-yes autoremove
   $ reboot

2. If using VirtualBox, disable IPv6:
   $ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
   $ sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1

===============================================================
EOF

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

# Step 5: Setup Database
if ! isStepComplete "database_setup"; then
  createDatabase
  secureMariaDB
  saveConfig  # Save database credentials
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

# Step 12: Optional software
if ! isStepComplete "optional_software"; then
  installAdditionalSoftware
  markStepComplete "optional_software"
fi

# Step 13: Finish
if ! isStepComplete "finalization"; then
  finish
  markStepComplete "finalization"
fi

echo ""
echo "==============================================================="
echo "Installation completed successfully!"
echo "==============================================================="

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
echo "You can safely delete the state files:"
echo "  rm ${STATE_FILE}"
echo "  rm ${CONFIG_FILE}"
echo "==============================================================="

echo "==============================================================="
echo "End of script..."
echo "==============================================================="

trap - EXIT
cleanup