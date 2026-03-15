#!/bin/bash

# Security hardening for production servers

secureMariaDB() {
  echo "INFO Securing MariaDB installation"

  # Check if MariaDB is already secured (my.cnf exists and works)
  if [ -f /root/.my.cnf ]; then
    if mysql -e "SELECT 1;" >/dev/null 2>&1; then
      echo "INFO MariaDB is already secured with password authentication"
      # Load existing password from config
      mysqlRootPassword=$(grep "^password=" /root/.my.cnf | cut -d'=' -f2- | tr -d '"')
      export mysqlRootPassword
      return 0
    else
      echo "WARN Found .my.cnf but authentication failed, re-securing..."
      rm -f /root/.my.cnf
    fi
  fi

  # Generate random root password
  mysqlRootPassword=$(generatePassword)

  # Secure MariaDB installation (automated mysql_secure_installation)
  # Modern method for MariaDB 10.4+ (use ALTER USER instead of UPDATE)
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${mysqlRootPassword}';" 2>/dev/null || \
  mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${mysqlRootPassword}');"

  # Remove anonymous users
  mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true

  # Remove remote root login
  mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true

  # Remove test database
  mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
  mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true

  # Flush privileges
  mysql --user=root --password="${mysqlRootPassword}" -e "FLUSH PRIVILEGES;"

  # Save root password to file
  cat > /root/.my.cnf <<EOL
[client]
user=root
password="${mysqlRootPassword}"
EOL
  chmod 600 /root/.my.cnf

  echo "INFO MariaDB secured. Root password saved to /root/.my.cnf"

  export mysqlRootPassword
}

hardenSSH() {
  echo "INFO Applying basic SSH hardening (no port change)"

  # Check if root has SSH keys configured
  if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
    echo "WARN No SSH keys found in /root/.ssh/authorized_keys"
    echo "WARN Skipping password-auth disable to prevent lockout"
    echo "WARN Add your SSH key, then run: bin/harden-ssh.sh"
    return 0
  fi

  # Backup original config (only if not already backed up this session)
  if [ ! -f /etc/ssh/sshd_config.backup ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
  fi

  # Disable password authentication
  sed -i 's|^#*[[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication no|' /etc/ssh/sshd_config
  sed -i 's|^#*[[:space:]]*ChallengeResponseAuthentication[[:space:]].*|ChallengeResponseAuthentication no|' /etc/ssh/sshd_config

  # Keep PAM enabled (required for key-based auth on some systems)
  sed -i 's|^#*[[:space:]]*UsePAM[[:space:]].*|UsePAM yes|' /etc/ssh/sshd_config

  # Allow root login via key only
  sed -i 's|^#*[[:space:]]*PermitRootLogin[[:space:]].*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config

  # Disable X11 forwarding
  sed -i 's|^#*[[:space:]]*X11Forwarding[[:space:]].*|X11Forwarding no|' /etc/ssh/sshd_config

  # Limit authentication attempts and grace time
  sed -i 's|^#*[[:space:]]*MaxAuthTries[[:space:]].*|MaxAuthTries 3|' /etc/ssh/sshd_config
  sed -i 's|^#*[[:space:]]*LoginGraceTime[[:space:]].*|LoginGraceTime 30|' /etc/ssh/sshd_config
  sed -i 's|^#*[[:space:]]*PermitEmptyPasswords[[:space:]].*|PermitEmptyPasswords no|' /etc/ssh/sshd_config
  sed -i 's|^#*[[:space:]]*StrictModes[[:space:]].*|StrictModes yes|' /etc/ssh/sshd_config

  # Test and reload
  sshd -t
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || \
    echo "WARN Could not restart SSH automatically. Please restart manually."

  echo "INFO Basic SSH hardening applied (port unchanged)"
  echo "INFO For port change and full interactive hardening: bin/harden-ssh.sh"
}

optimizeKernel() {
  echo "INFO Applying kernel optimizations for production"

  # Write to a dedicated drop-in file instead of appending to /etc/sysctl.conf.
  # /etc/sysctl.d/*.conf is loaded automatically by sysctl --system and on boot.
  # Using cat > (overwrite) makes this call idempotent – safe to run multiple times.
  cat > /etc/sysctl.d/99-typo3.conf <<'EOL'
# TYPO3 Production Server Optimizations
# Managed by ServerInstall – do not edit manually.

# TCP BBR Congestion Control (better performance)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Increase system file descriptor limit
fs.file-max=2097152

# Increase network buffers
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# Increase max connections
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=8192

# Enable TCP Fast Open
net.ipv4.tcp_fastopen=3

# Reduce swappiness (prefer RAM over swap)
vm.swappiness=10

# Protect against SYN flood attacks
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_synack_retries=2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0

# Do not send ICMP redirects
net.ipv4.conf.all.send_redirects=0

# Increase inotify watches (for TYPO3 file monitoring)
fs.inotify.max_user_watches=524288

# TIME_WAIT socket optimization
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# Keepalive optimization
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
EOL

  # Apply all sysctl drop-in files (continue on error for optional parameters)
  sysctl --system 2>&1 | grep -v "^$" || echo "WARN Some kernel parameters could not be applied (this is usually harmless)"

  echo "INFO Kernel optimizations applied (config: /etc/sysctl.d/99-typo3.conf)"
}

setupLogrotate() {
  echo "INFO Setting up logrotate for TYPO3"

  # TYPO3 log rotation configuration
  cat > /etc/logrotate.d/typo3 <<'EOL'
/var/www/typo3/var/log/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0660 www-data www-data
    sharedscripts
    postrotate
        # Clear TYPO3 cache after log rotation
        su www-data -s /bin/bash -c "cd /var/www/typo3 && vendor/bin/typo3 cache:flush" > /dev/null 2>&1 || true
    endscript
}

/var/www/typo3/public/typo3temp/var/log/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0660 www-data www-data
}
EOL

  # Nginx log rotation (enhance default)
  cat > /etc/logrotate.d/nginx <<'EOL'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1 || true
    endscript
}
EOL

  # PHP-FPM log rotation
  cat > /etc/logrotate.d/php-fpm <<'EOL'
/var/log/php*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        /usr/lib/php/php-fpm-socket-helper reload >/dev/null 2>&1 || true
    endscript
}
EOL

  echo "INFO Logrotate configured for TYPO3, Nginx, and PHP-FPM"
}

configureSSLHardening() {
  echo "INFO Preparing SSL/TLS hardening configuration"

  # Create DH parameters for stronger SSL (takes a while)
  if [ ! -f /etc/nginx/dhparam.pem ]; then
    echo "INFO Generating DH parameters (this may take several minutes)..."
    openssl dhparam -out /etc/nginx/dhparam.pem 2048
  fi

  # Create SSL hardening snippet
  cat > /etc/nginx/snippets/ssl-hardening.nginx <<'EOL'
# SSL/TLS Hardening Configuration
# Include this in your SSL server block

# SSL protocols - only TLS 1.2 and 1.3
ssl_protocols TLSv1.2 TLSv1.3;

# Strong cipher suites (prioritize modern ciphers)
ssl_prefer_server_ciphers on;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';

# DH parameters
ssl_dhparam /etc/nginx/dhparam.pem;

# SSL session cache (performance)
ssl_session_cache shared:SSL:50m;
ssl_session_timeout 1d;
ssl_session_tickets off;

# OCSP Stapling (performance + privacy)
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;

# HSTS (uncomment after SSL is working!)
# add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
EOL

  echo "INFO SSL hardening snippet created at /etc/nginx/snippets/ssl-hardening.nginx"
  echo "INFO To enable: Include this snippet in your SSL server block after SSL certificate is installed"
}

increaseLimits() {
  echo "INFO Increasing system limits for production"

  # Write to a dedicated drop-in file instead of appending to /etc/security/limits.conf.
  # /etc/security/limits.d/*.conf is loaded automatically by PAM (pam_limits.so).
  # Using cat > (overwrite) makes this call idempotent – safe to run multiple times.
  cat > /etc/security/limits.d/99-typo3.conf <<'EOL'
# TYPO3 Production Server Limits
# Managed by ServerInstall – do not edit manually.

www-data soft nofile 65535
www-data hard nofile 65535
www-data soft nproc 4096
www-data hard nproc 4096

root soft nofile 65535
root hard nofile 65535

* soft nofile 65535
* hard nofile 65535
EOL

  # PAM limits – append only if not already present (common-session is not a drop-in)
  if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
  fi

  echo "INFO System limits increased (config: /etc/security/limits.d/99-typo3.conf)"
}

secureRedis() {
  echo "INFO Securing Redis with password authentication"

  redisPassword=$(generatePassword)

  local redisConf="/etc/redis/redis.conf"

  # Set requirepass (uncomment if commented, otherwise append)
  if grep -qE "^#?\s*requirepass" "${redisConf}"; then
    sed -i "s|^#*\s*requirepass.*|requirepass ${redisPassword}|" "${redisConf}"
  else
    echo "requirepass ${redisPassword}" >> "${redisConf}"
  fi

  # Bind to localhost only (belt-and-suspenders alongside firewall)
  if grep -qE "^bind " "${redisConf}"; then
    sed -i "s|^bind .*|bind 127.0.0.1 ::1|" "${redisConf}"
  fi

  systemctl restart redis-server

  export redisPassword
  echo "INFO Redis secured with requirepass. Password saved to .env as REDIS_PASS."
}