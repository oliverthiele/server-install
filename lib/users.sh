#!/bin/bash

# User configuration and permissions

configureWwwUser() {
  echo "INFO Configure www-data user"

  echo "www-data:${systemPass}" | chpasswd

  if [ ! -d "/var/www/.ssh/" ]; then
    mkdir /var/www/.ssh/
    if [ -f "/root/.ssh/authorized_keys" ]; then
      cp -ap /root/.ssh/authorized_keys /var/www/.ssh/authorized_keys
    fi
  fi
}

setPermissions() {
  cd ${composerDirectory} || exit
  echo "INFO Set permissions"

  find ${composerDirectory} -type d -print0 | xargs -0 chmod 2770
  find ${composerDirectory} -type f ! -perm /u=x,g=x,o=x -print0 | xargs -0 chmod 0660

  chown www-data: /var/www/ -R

  # Permissions for special files
  if [ -f "/var/www/.ssh/authorized_keys" ]; then
    chown -h www-data: /var/www/.ssh/authorized_keys
    chmod 0700 /var/www/.ssh/
    chmod 0600 /var/www/.ssh/authorized_keys
  fi

  # Make TYPO3 CLI executable
  chmod +x ${composerDirectory}vendor/typo3/cms-cli/typo3

  # Old typo3cms file (TYPO3 v12)
  typo3cmsFile=${composerDirectory}vendor/helhum/typo3-console/typo3cms
  if test -f "$typo3cmsFile"; then
    chmod +x $typo3cmsFile
  fi
}

finish() {
  ipAddress=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

  # Fallback if eth0 doesn't exist (might be ens33, enp0s3, etc.)
  if [ -z "$ipAddress" ]; then
    ipAddress=$(hostname -I | awk '{print $1}')
  fi

  echo "======================================="
  echo "====         INSTALLATION         ===="
  echo "====          COMPLETE            ===="
  echo "======================================="
  echo ""
  echo "TYPO3 Version: ${typo3Version}"
  echo "TYPO3 User: typo3-admin"
  echo "TYPO3 Password / SSH password (www-data): ${systemPass}"
  echo "Database Password: ${databasePassword}"
  echo "Admin Email: ${adminEmail}"
  echo ""

  if [[ "${serverDomain}" != "_" ]]; then
    echo "Domain: ${serverDomain}"
    echo "Please finish the installation in your browser: http://${serverDomain}"
  else
    echo "IP Address: ${ipAddress}"
    echo "Please finish the installation in your browser: http://${ipAddress}"
  fi

  echo ""
  echo "All credentials are saved in: ${composerDirectory}install-log-please-remove.log"
  echo ""
  echo "======================================="
  echo "Next steps:"
  echo "======================================="
  echo ""

  if [[ "${serverDomain}" != "_" ]]; then
    echo "  1. Setup SSL certificate:"
    echo "     certbot --nginx -d ${serverDomain} --email ${adminEmail}"
    echo ""
  else
    echo "  1. Setup domain in /var/www/typo3/.env"
    echo "     Then run: certbot --nginx -d yourdomain.com --email ${adminEmail}"
    echo ""
  fi

  echo "  2. Configure TYPO3 in /var/www/typo3/.env"
  echo "     - Set DOMAIN=${serverDomain}"
  echo "     - Configure SMTP settings"
  echo ""
  echo "  3. Change TYPO3_CONTEXT to Production in:"
  echo "     /etc/nginx/sites-available/typo3.nginx"
  echo "     (Change line: fastcgi_param TYPO3_CONTEXT Production;)"
  echo ""
  echo "  4. Remove FIRST_INSTALL file:"
  echo "     rm ${typo3PublicDirectory}FIRST_INSTALL"
  echo ""

  if [[ "${monitInstalled}" == "true" ]]; then
    echo "  5. Monit is installed:"
    echo "     - Web interface: http://localhost:2812/"
    echo "     - To expose via Nginx, uncomment monit.nginx in site config"
    echo ""
  fi

  echo "  6. Delete installation log:"
  echo "     rm ${composerDirectory}install-log-please-remove.log"
  echo ""
  echo "======================================="

  cat >${composerDirectory}install-log-please-remove.log <<EOL
# TYPO3 Server Installation Log
# Generated: $(date)

## TYPO3:
    Version: ${typo3Version}
    Path: ${composerDirectory}
    Admin User: typo3-admin
    Admin Password: ${systemPass}

## System User (SSH):
    User: www-data
    Password: ${systemPass}

## Database:
    Database: ${databaseName}
    User: ${databaseUser}
    Password: ${databasePassword}
    Host: localhost

## Server:
    IP Address: ${ipAddress}
    Domain: ${serverDomain}
    Admin Email: ${adminEmail}

## SSL Setup:
    Run: certbot --nginx -d ${serverDomain} --email ${adminEmail}

## Monit:
    Installed: ${monitInstalled}
$(if [[ "${monitInstalled}" == "true" ]]; then echo "    Web Interface: http://localhost:2812/"; fi)

## Important Next Steps:
    1. Configure domain in /var/www/typo3/.env
    2. Setup SSL certificate with certbot
    3. Change TYPO3_CONTEXT to Production in nginx config
    4. Remove FIRST_INSTALL file: rm ${typo3PublicDirectory}FIRST_INSTALL
    5. DELETE THIS FILE after noting down the credentials!

## Security:
    - This file contains sensitive information
    - Store passwords in a secure password manager
    - Delete this file immediately after setup
EOL

  chown www-data: ${composerDirectory}install-log-please-remove.log
  chmod 0600 ${composerDirectory}install-log-please-remove.log
}