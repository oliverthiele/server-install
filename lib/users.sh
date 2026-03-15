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
  cd "${composerDirectory}" || die "Cannot cd to ${composerDirectory}"
  echo "INFO Set permissions"

  find "${composerDirectory}" -type d -print0 | xargs -0 chmod 2770
  find "${composerDirectory}" -type f ! -perm /u=x,g=x,o=x -print0 | xargs -0 chmod 0660

  chown www-data:www-data /var/www/ -R

  # Permissions for special files
  if [ -f "/var/www/.ssh/authorized_keys" ]; then
    chown -h www-data:www-data /var/www/.ssh/authorized_keys
    chmod 0700 /var/www/.ssh/
    chmod 0600 /var/www/.ssh/authorized_keys
  fi

  # Make TYPO3 CLI executable
  chmod +x "${composerDirectory}vendor/typo3/cms-cli/typo3"

  # Old typo3cms file (TYPO3 v12)
  local typo3cmsFile="${composerDirectory}vendor/helhum/typo3-console/typo3cms"
  if test -f "${typo3cmsFile}"; then
    chmod +x "${typo3cmsFile}"
  fi
}

finish() {
  local ipAddress
  ipAddress=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  if [ -z "$ipAddress" ]; then
    ipAddress=$(hostname -I | awk '{print $1}')
  fi

  local baseUrl
  if [[ "${serverDomain}" != "_" ]]; then
    baseUrl="http://${serverDomain}"
  else
    baseUrl="http://${ipAddress}"
  fi

  local setupStatus
  if [ ! -f "${typo3PublicDirectory}/FIRST_INSTALL" ]; then
    setupStatus="Automated setup completed"
  else
    setupStatus="FIRST_INSTALL present — complete via web wizard (see Next Steps)"
  fi

  echo ""
  echo "======================================="
  echo "        INSTALLATION COMPLETE"
  echo "======================================="
  echo ""
  echo "TYPO3 Backend: ${baseUrl}/typo3"
  echo ""
  echo "Admin user:     typo3-admin"
  echo "Admin password: ${systemPass}"
  echo "DB password:    ${databasePassword}"
  if [ -n "${redisPassword:-}" ]; then
    echo "Redis password: ${redisPassword}"
  fi
  echo ""
  echo "Setup:  ${setupStatus}"
  echo ""
  echo "Credentials: ${composerDirectory}install-log-please-remove.log"
  echo "======================================="

  cat > "${composerDirectory}install-log-please-remove.log" <<EOL
# TYPO3 Server Installation Log
# Generated: $(date)
# DELETE THIS FILE after noting credentials – mode 600, www-data only

## TYPO3
    Version:        ${typo3Version}
    Path:           ${composerDirectory}
    Backend:        ${baseUrl}/typo3
    Admin user:     typo3-admin
    Admin password: ${systemPass}

## System user (SSH)
    User:     www-data
    Password: ${systemPass}

## Database
    Database: ${databaseName}
    User:     ${databaseUser}
    Password: ${databasePassword}
    Host:     localhost

## Redis
    Password: ${redisPassword:-not configured}

## Server
    IP:     ${ipAddress}
    Domain: ${serverDomain}
    Email:  ${adminEmail}

## Setup status
    ${setupStatus}

## Next steps
    1. certbot --nginx -d ${serverDomain} --email ${adminEmail}
    2. Set TYPO3_CONTEXT to Production in /etc/nginx/sites-available/typo3.nginx
    3. Configure SMTP in /var/www/typo3/.env
    4. DELETE THIS FILE: rm ${composerDirectory}install-log-please-remove.log
EOL

  chown www-data: "${composerDirectory}install-log-please-remove.log"
  chmod 0600 "${composerDirectory}install-log-please-remove.log"
}

printNextSteps() {
  local ipAddress
  ipAddress=$(hostname -I | awk '{print $1}')

  local baseUrl
  if [[ "${serverDomain}" != "_" ]]; then
    baseUrl="http://${serverDomain}"
  else
    baseUrl="http://${ipAddress}"
  fi

  echo ""
  echo "======================================="
  echo "             NEXT STEPS"
  echo "======================================="
  echo ""

  if [ -f "${typo3PublicDirectory}/FIRST_INSTALL" ]; then
    echo "  ! Automated TYPO3 setup failed — complete via web wizard:"
    echo "    ${baseUrl}/typo3/install.php"
    echo ""
  fi

  local step=1
  if [[ "${serverDomain}" != "_" ]]; then
    echo "  ${step}. SSL certificate (DNS must point to this server first):"
    echo "     certbot --nginx -d ${serverDomain} --email ${adminEmail}"
    echo ""
    step=$((step + 1))
  fi

  echo "  ${step}. Switch TYPO3_CONTEXT to Production (after SSL is working):"
  echo "     nano /etc/nginx/sites-available/typo3.nginx"
  echo "     → Uncomment: fastcgi_param TYPO3_CONTEXT Production;"
  echo "     → nginx -t && systemctl reload nginx"
  echo ""
  step=$((step + 1))

  echo "  ${step}. Configure SMTP in /var/www/typo3/.env"
  echo ""
  step=$((step + 1))

  echo "  ${step}. Delete installation log after saving credentials:"
  echo "     rm ${composerDirectory}install-log-please-remove.log"
  echo ""

  echo "State files (safe to delete after successful install):"
  echo "  rm ${STATE_FILE} ${CONFIG_FILE}"
  echo "======================================="
}