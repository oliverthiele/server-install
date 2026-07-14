#!/bin/bash

# Nginx installation and configuration with Brotli

# Bot/crawler policy is managed by bin/bot-policy (per-bot rules stored as JSON
# under /etc/bot-policy/, see bin/bot-policy/lib/storage.sh). This function only
# seeds the catalog on first install — mode selects the initial rule for AI
# crawlers ("production" leaves them unrestricted, "staging" blocks them too,
# same behavior as the old hardcoded modes). Re-running is a no-op once the
# catalog exists, so later manual edits via bin/bot-policy survive re-installs.
writeBotFilterSnippet() {
  local mode="${1}"
  local scriptDirectoryNginx
  scriptDirectoryNginx="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  echo "INFO Seeding bot policy (mode: ${mode})"
  bash "${scriptDirectoryNginx}/bin/bot-policy/bot-policy.sh" "--seed=${mode}"
}

getNginxVersion() {
  nginxVersion=$(nginx -v 2>&1 | grep -oP '(?<=nginx/)[0-9.]+')
  echo "INFO Detected Nginx version: ${nginxVersion}"
  export nginxVersion
}

downloadNginxSource() {
  echo "INFO Downloading Nginx source for version ${nginxVersion}"
  cd /usr/local/src || exit

  # Download nginx source if not already present
  if [ ! -f "nginx-${nginxVersion}.tar.gz" ]; then
    wget "https://nginx.org/download/nginx-${nginxVersion}.tar.gz"
  else
    echo "INFO Nginx source tarball already exists"
  fi

  # Extract if not already extracted
  if [ ! -d "nginx-${nginxVersion}" ]; then
    tar -zxvf "nginx-${nginxVersion}.tar.gz"
  else
    echo "INFO Nginx source already extracted"
  fi

  # Clone ngx_brotli if not already present
  if [ ! -d "ngx_brotli" ]; then
    git clone https://github.com/google/ngx_brotli.git
    cd ngx_brotli || exit
    git submodule update --init
  else
    echo "INFO ngx_brotli already cloned"
    cd ngx_brotli || exit
    # Update submodules if they weren't initialized
    git submodule update --init 2>/dev/null || true
  fi
}

writeTypo3RewriteSnippet() {
  local targetFile="/etc/nginx/snippets/typo3-rewrite.nginx"

  if [ "${typo3MajorVersion}" -ge 14 ]; then
    echo "INFO Writing TYPO3 v14+ rewrite snippet"
    cat >"${targetFile}" <<'EOF'
# TYPO3 URL Rewrite Rules (v14+)

# In TYPO3 v14, backend and install tool requests are handled by the general
# location / catch-all (public/index.php). Backend assets are served from
# /_assets/ or the configured backend path — no /typo3/-specific rules needed.

# versionNumberInFilename - aligned with TYPO3 core
# Removes the timestamp from versioned files
# Pattern: filename.1234567890.ext -> filename.ext
# Supports: CSS, JS (including .mjs modules), images (including AVIF), fonts, JSON
rewrite "^(.*)\.(\d{10})\.(css|js|mjs|png|jpg|jpeg|gif|svg|avif|webp|woff|woff2|ttf|eot|otf|json)$" $1.$3 last;
EOF
  else
    echo "INFO Writing TYPO3 v12/v13 rewrite snippet"
    cat >"${targetFile}" <<'EOF'
# TYPO3 URL Rewrite Rules

# TYPO3 v13 allows custom backend routes via config.yaml (backend.entryPoint)
# This configuration assumes the default /typo3 route. Adjust if you use a custom backend path.

# TYPO3 v11+ Backend URLs (default /typo3 route)
location = /typo3 {
    rewrite ^ /typo3/;
}

# Allow access to all public resources in TYPO3 backend
location ~ ^/typo3/(.*/)?Resources/Public/ {
    allow all;
    break;
}

location /typo3/ {
    # Uncomment for basic auth protection of backend
    # include snippets/BasicAuth.nginx;
    try_files $uri /typo3/index.php$is_args$args;
}

# Install tool redirect
rewrite ^/typo3/install/$ /typo3/install.php permanent;

# versionNumberInFilename - aligned with TYPO3 core
# Removes the timestamp from versioned files
# Pattern: filename.1234567890.ext -> filename.ext
# Supports: CSS, JS (including .mjs modules), images (including AVIF), fonts, JSON
rewrite "^(.*)\.(\d{10})\.(css|js|mjs|png|jpg|jpeg|gif|svg|avif|webp|woff|woff2|ttf|eot|otf|json)$" $1.$3 last;
EOF
  fi
}

writeRateLimitingLoginSnippet() {
  local targetFile="/etc/nginx/snippets/rate-limiting-login.nginx"

  # No frontend login configured: write a placeholder so the include in
  # typo3.nginx stays valid and the file documents how to enable it later.
  if [[ "${hasFrontendLogin:-true}" != 'true' ]]; then
    echo "INFO No frontend login — writing rate-limiting placeholder snippet"
    cat > "${targetFile}" <<'EOF'
# TYPO3 login rate limiting — NOT ACTIVE
# No frontend login was configured during installation.
#
# To enable later, add a location for your login page(s) and reload nginx:
#
# location ~ ^(/anmeldung/|/en/login/) {
#     limit_req zone=typo3_login burst=2 nodelay;
#     try_files $uri $uri/ /index.php$is_args$args;
# }
#
# Also enable the matching fail2ban jail — see [typo3-fe-login] in
# /etc/fail2ban/jail.local and /etc/fail2ban/filter.d/typo3-fe-login.conf.
EOF
    return 0
  fi

  echo "INFO Writing rate-limiting login snippet"

  [ -z "${typo3LoginPathDE}" ] && die "typo3LoginPathDE is not set — cannot write rate-limiting-login.nginx"
  [ -z "${typo3LoginPathEN}" ] && die "typo3LoginPathEN is not set — cannot write rate-limiting-login.nginx"
  [ -z "${phpVersion}" ]       && die "phpVersion is not set — cannot write rate-limiting-login.nginx"

  cat > "${targetFile}" <<EOF
# TYPO3 login rate limiting — generated during installation
# Paths: ${typo3LoginPathDE} (DE) and ${typo3LoginPathEN} (EN)
# Overwritten on each install run — do not edit manually.

# Applies rate limiting to TYPO3 frontend login paths.
# Exceeding the zone rate (see rate-limiting-zones.nginx) returns 429.
location ~ ^(${typo3LoginPathDE}|${typo3LoginPathEN}) {
    limit_req zone=typo3_login burst=2 nodelay;
    try_files \$uri \$uri/ /index.php\$is_args\$args;
}
EOF
}

writeBackendIpRestrictionSnippet() {
  local targetFile="/etc/nginx/snippets/backend-ip-restriction.nginx"

  echo "INFO Writing backend IP restriction snippet (disabled by default)"

  [ -z "${phpVersion}" ] && die "phpVersion is not set — cannot write backend-ip-restriction.nginx"

  cat > "${targetFile}" <<EOF
# TYPO3 Backend IP Restriction — OPTIONAL, disabled by default
#
# Restricts /typo3/ (backend + install tool routes) to an IP allowlist.
# Useful when the backend is only used from known locations (office, VPN).
# This is an additional layer — it does not replace strong backend passwords
# and MFA, and it does not protect the frontend.
#
# HOW TO ENABLE:
#   1. Replace the example IPs below with your own (office, VPN, home).
#      The examples use RFC 5737/3849 documentation ranges — they match nobody.
#   2. Uncomment the include line in /etc/nginx/sites-available/typo3.nginx.
#   3. TYPO3 v12/v13 only: comment out the "location /typo3/" and
#      "location ~ ^/typo3/(.*/)?Resources/Public/" blocks in
#      /etc/nginx/snippets/typo3-rewrite.nginx — this snippet replaces them.
#      If you forget this, "nginx -t" fails with a duplicate location error
#      (intentional: better a loud error than a silently bypassed allowlist).
#   4. nginx -t && systemctl reload nginx
#
# Backend assets under /typo3/ are also IP-restricted — that is intended.

location = /typo3 {
    return 301 /typo3/;
}

location ^~ /typo3/ {
    # Replace with your allowed IPs / ranges:
    allow 203.0.113.10;        # example: office IP
    allow 198.51.100.0/24;     # example: VPN range
    # allow 2001:db8::/32;     # example: IPv6 range
    deny all;

    try_files \$uri \$uri/ /index.php\$is_args\$args;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        try_files \$fastcgi_script_name =404;

        set \$path_info \$fastcgi_path_info;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_index index.php;
        include fastcgi.conf;

        fastcgi_buffer_size 32k;
        fastcgi_buffers 8 16k;

        fastcgi_connect_timeout 240s;
        fastcgi_read_timeout    240s;
        fastcgi_send_timeout    240s;

        # TYPO3 Context — must match the value in the main PHP location block
        fastcgi_param TYPO3_CONTEXT Development;
        #fastcgi_param TYPO3_CONTEXT Production/Staging;
        #fastcgi_param TYPO3_CONTEXT Production;

        fastcgi_pass unix:/var/run/php/php${phpVersion}-fpm.sock;
    }
}
EOF
}

compileNginxWithBrotli() {
  echo "INFO Compiling Nginx with Brotli module for version ${nginxVersion}"

  # Check if Brotli modules are already installed
  if [ -f "/usr/share/nginx/modules/ngx_http_brotli_filter_module.so" ] && \
     [ -f "/usr/share/nginx/modules/ngx_http_brotli_static_module.so" ]; then
    echo "INFO Brotli modules already compiled and installed"
    return 0
  fi

  cd "/usr/local/src/nginx-${nginxVersion}" || exit
  ./configure --with-compat --add-dynamic-module=../ngx_brotli
  make modules

  echo "INFO Copying Brotli modules to Nginx modules directory"
  cp objs/ngx_http_brotli_filter_module.so /usr/share/nginx/modules/
  cp objs/ngx_http_brotli_static_module.so /usr/share/nginx/modules/

  chmod 644 /usr/share/nginx/modules/ngx_http_brotli_*
}

configureBrotliInNginx() {
  echo "INFO Configuring Brotli in Nginx"

  mkdir -p /etc/nginx/modules

  if ! grep -q "load_module modules/ngx_http_brotli_filter_module.so;" /etc/nginx/nginx.conf; then
    sed -i '1iload_module modules/ngx_http_brotli_filter_module.so;' /etc/nginx/nginx.conf
  fi

  if ! grep -q "load_module modules/ngx_http_brotli_static_module.so;" /etc/nginx/nginx.conf; then
    sed -i '1iload_module modules/ngx_http_brotli_static_module.so;' /etc/nginx/nginx.conf
  fi
}

configureNginx() {
  echo "INFO Configure Nginx for TYPO3"

  # Ensure required variables are set
  [ -z "${serverDomain}" ]         && die "serverDomain is not set — cannot configure nginx"
  [ -z "${typo3PublicDirectory}" ] && die "typo3PublicDirectory is not set — cannot configure nginx"
  [ -z "${phpVersion}" ]           && die "phpVersion is not set — cannot configure nginx"

  # Basic security settings
  sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf

  # Set secure SSL protocols
  sed -i 's/ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.2 TLSv1.3;/' /etc/nginx/nginx.conf

  # Disable default gzip settings in nginx.conf (we'll set them in brotli.conf)
  sed -i 's/^\s*gzip on;/# gzip on; # Configured in brotli.conf/' /etc/nginx/nginx.conf
  sed -i 's/^\s*gzip_/# gzip_/' /etc/nginx/nginx.conf

  # Brotli compression settings
  cat >/etc/nginx/conf.d/brotli.conf <<'EOL'
# Brotli configuration (preferred over gzip for modern browsers)
brotli on;
brotli_comp_level 6;
brotli_types
    text/plain
    text/css
    text/javascript
    text/xml
    text/x-component
    application/javascript
    application/json
    application/ld+json
    application/manifest+json
    application/schema+json
    application/vnd.geo+json
    application/geo+json
    application/xml
    application/xml+rss
    application/atom+xml
    application/rss+xml
    image/svg+xml
    image/x-icon;

# Gzip configuration (fallback for older browsers)
gzip on;
gzip_comp_level 6;
gzip_min_length 256;
gzip_proxied any;
gzip_vary on;
gzip_types
    text/plain
    text/css
    text/javascript
    text/xml
    text/x-component
    application/javascript
    application/json
    application/ld+json
    application/manifest+json
    application/schema+json
    application/vnd.geo+json
    application/geo+json
    application/xml
    application/xml+rss
    application/atom+xml
    application/rss+xml
    image/svg+xml
    image/x-icon;
EOL

  # WebP configuration
  cat >/etc/nginx/conf.d/webp.conf <<'EOL'
# WebP support
# https://packagist.org/packages/plan2net/webp

map $http_accept $webpok {
    default   0;
    "~*webp"  1;
}

map $http_cf_cache_status $iscf {
    default   1;
    ""        0;
}

map $webpok$iscf $webp_suffix {
    11          "";
    10          ".webp";
    01          "";
    00          "";
}
EOL

  # Copy snippets from repository to nginx snippets directory
  echo "INFO Copy Nginx snippets"
  local scriptDirectoryNginx
  scriptDirectoryNginx="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cp -f "${scriptDirectoryNginx}/config/nginx/snippets/"*.nginx /etc/nginx/snippets/

  # Write version-specific TYPO3 rewrite snippet
  writeTypo3RewriteSnippet

  # Write bot-filter snippet based on selected mode
  writeBotFilterSnippet "${botFilterMode:-production}"

  # Write login rate-limiting snippet with configured login paths
  writeRateLimitingLoginSnippet

  # Write backend IP restriction snippet (opt-in — include stays commented out)
  writeBackendIpRestrictionSnippet

  # Add rate-limiting zones include to nginx.conf http block (before sites-enabled)
  if ! grep -q "rate-limiting-zones.nginx" /etc/nginx/nginx.conf; then
    sed -i \
      's|^\(\s*\)include /etc/nginx/sites-enabled/\*;|\1include /etc/nginx/snippets/rate-limiting-zones.nginx;\n\1include /etc/nginx/sites-enabled/*;|' \
      /etc/nginx/nginx.conf
    echo "INFO Added rate-limiting-zones.nginx to nginx.conf"
  fi

  # Remove default site
  if [ -f "/etc/nginx/sites-available/default" ]; then
    rm /etc/nginx/sites-available/default
  fi

  if [ -L "/etc/nginx/sites-enabled/default" ]; then
    rm /etc/nginx/sites-enabled/default
  fi

  # Prepare conditional BasicAuth snippet include
  local basicAuthInclude
  if [[ "${enableBasicAuth:-false}" == 'true' ]]; then
    basicAuthInclude="include /etc/nginx/snippets/BasicAuth.nginx;"
  else
    basicAuthInclude="# include /etc/nginx/snippets/BasicAuth.nginx;"
  fi

  # When serverDomain=_, the TYPO3 block must be the default_server.
  # Separate catch-all blocks with server_name _ would conflict: nginx ignores the TYPO3
  # block and returns 444 for all requests, making the site unreachable.
  local serverListenDirectives
  local catchAllConfig

  if [[ "${serverDomain}" == "_" ]]; then
    serverListenDirectives="listen 80 default_server;
    listen [::]:80 default_server;"
    catchAllConfig=""
  else
    serverListenDirectives="listen 80;
    listen [::]:80;"
    catchAllConfig="# Default HTTP server: reject requests with unknown Host headers
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

# Default HTTPS server: reject TLS handshake for unknown Host headers
# Requires nginx >= 1.19.4 – Ubuntu 24.04 ships nginx 1.24.0
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}

"
  fi

  # Create TYPO3 site configuration
  cat >/etc/nginx/sites-available/typo3.nginx <<EOL
${catchAllConfig}server {
    ${serverListenDirectives}

    charset utf-8;

    root ${typo3PublicDirectory};
    index index.html index.php;
    server_name ${serverDomain};

    port_in_redirect off;
    server_name_in_redirect off;
    client_max_body_size 64M;
    client_header_buffer_size 32k;
    large_client_header_buffers 16 512k;

    # Include optimizations
    # Note: brotli.conf is auto-loaded from /etc/nginx/conf.d/ in http context
    include /etc/nginx/snippets/bot-filter.nginx;
    include /etc/nginx/snippets/exploit-filter.nginx;
    include /etc/nginx/snippets/typo3-security-filter.nginx;
    include /etc/nginx/snippets/security.nginx;
    include /etc/nginx/snippets/caching.nginx;
    include /etc/nginx/snippets/typo3-rewrite.nginx;
    include /etc/nginx/snippets/method-filter.nginx;

    # HTTP Basic Authentication (disable after go-live: comment out and reload nginx)
    ${basicAuthInclude}

    # Monit Web Interface (uncomment if Monit is installed)
    # include /etc/nginx/snippets/monit.nginx;

    # TYPO3 backend IP allowlist (opt-in — edit the snippet first, see instructions inside)
    # include /etc/nginx/snippets/backend-ip-restriction.nginx;

    # Login rate limiting (paths and zones defined during installation)
    include /etc/nginx/snippets/rate-limiting-login.nginx;

    # Main location
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # NOTE: WebP variant delivery (\$webp_suffix) is handled inside caching.nginx —
    # regex locations are matched in include order, so it must live in the same
    # location that sets the image cache headers.

    # Fileadmin: uploaded files are served statically, never executed as PHP.
    # ^~ stops regex matching, so the PHP-FPM location does not apply here.
    # This also stops the caching.nginx regex locations — cache headers must
    # therefore be set in nested locations below (order matters: the security
    # blocks come first so deny rules and CSP always win over caching).
    # CSP is only added for file types that can execute active content in the browser.
    # Binary media files (mp4, mp3, pdf, images, etc.) are served without CSP headers
    # to avoid browser compatibility issues (e.g. video playback failing silently).
    location ^~ /fileadmin/ {
        try_files \$uri =404;

        # Block access to deleted files in Recycler directories
        location ~ _recycler_ {
            deny all;
            access_log off;
            log_not_found off;
        }

        # Block direct access to server-side executable file types
        location ~* \.(php[0-9s]?|phar|phtml|cgi|pl|py|sh|bash|rb)\$ {
            deny all;
        }

        # Strict CSP only for file types that can run active content in the browser.
        # Cached 30 days like other static assets (SVG logos/icons live here).
        location ~* \.(html?|xhtml|xml|svg|svgz|js|mjs)\$ {
            add_header Content-Security-Policy "default-src 'none'; base-uri 'none'; form-action 'none'; sandbox" always;
            add_header X-Content-Type-Options "nosniff" always;
            expires 30d;
            add_header Cache-Control "public";
            try_files \$uri =404;
        }

        # Bitmap images: cache headers + WebP variant delivery
        # (plan2net/webp writes .webp files next to originals in _processed_)
        location ~* \.(png|gif|jpe?g)\$ {
            expires 30d;
            add_header Cache-Control "public, no-transform";
            add_header Vary "Accept, Accept-Encoding";
            try_files \$uri\$webp_suffix \$uri =404;
        }

        # Other image formats
        location ~* \.(webp|avif|ico)\$ {
            expires 30d;
            add_header Cache-Control "public, no-transform";
            try_files \$uri =404;
        }

        # Fonts
        location ~* \.(woff2?|ttf|otf|eot)\$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
            try_files \$uri =404;
        }

        # Media files and documents
        location ~* \.(mp4|webm|ogg|ogv|mov|mp3|pdf)\$ {
            expires 7d;
            add_header Cache-Control "public";
            try_files \$uri =404;
        }
    }

    # ── Security: deny sensitive files and directories ────────────────────────
    # Composer metadata — never in public/ for Composer installs, but protects
    # during migrations where a legacy install may exist temporarily.
    location ~* composer\.(?:json|lock)$                         { deny all; }

    # TYPO3 configuration files that must never be publicly accessible
    location ~* flexform[^.]*\.xml$                              { deny all; }
    location ~* locallang[^.]*\.(?:xml|xlf)$                    { deny all; }
    location ~* ext_conf_template\.txt$                          { deny all; }
    location ~* ext_typoscript_.*\.txt$                          { deny all; }

    # Sensitive file extensions (config, logs, SQL dumps, TypeScript source maps, etc.)
    location ~* \.(?:bak|co?nf|cfg|ya?ml|ts|typoscript|tsconfig|dist|fla|in[ci]|log|sh|sql|sqlite)$ {
        deny all;
    }

    # TYPO3 temp directory (alongside recycler which is handled inside fileadmin)
    location ~ _temp_/                                           { deny all; }

    # Extension private files: Configuration, Resources/Private, Tests, docs
    location ~ (?:typo3/sysext|typo3/ext)/[^/]+/(?:Configuration|Resources/Private|Tests?|docs?)/ {
        deny all;
    }

    # Vendor directory at webroot level.
    # In Composer installations, vendor/ is outside public/ and never matched here.
    # This rule protects against accidentally exposed vendor/ during legacy migrations.
    # NOTE: Does NOT block nested vendor/ paths (e.g. Resources/Public/vendor/bootstrap/)
    # which are served via /_assets/ in TYPO3 v12+ and never match this pattern.
    location ~ ^/vendor/                                         { deny all; }

    # PHP-FPM configuration
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        try_files \$fastcgi_script_name =404;

        set \$path_info \$fastcgi_path_info;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_index index.php;
        include fastcgi.conf;

        # Buffer sizes recommended by TYPO3 documentation
        fastcgi_buffer_size 32k;
        fastcgi_buffers 8 16k;

        fastcgi_connect_timeout 240s;
        fastcgi_read_timeout    240s;
        fastcgi_send_timeout    240s;

        # TYPO3 Context (adjust as needed)
        fastcgi_param TYPO3_CONTEXT Development;
        #fastcgi_param TYPO3_CONTEXT Production/Staging;
        #fastcgi_param TYPO3_CONTEXT Production;

        fastcgi_pass unix:/var/run/php/php${phpVersion}-fpm.sock;
    }

    # Deny access to .htaccess files
    location ~ /\.ht {
        deny all;
    }

    # Deny access to hidden files (except .well-known for Let's Encrypt)
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ ^/\.well-known/ {
        allow all;
    }
}
EOL

  ln -sfT /etc/nginx/sites-available/typo3.nginx /etc/nginx/sites-enabled/typo3.nginx

  # Create .htpasswd before nginx -t so the include does not cause a config error
  setupBasicAuth

  # Test nginx configuration
  nginx -t

  service nginx restart
}

setupBasicAuth() {
  if [[ "${enableBasicAuth:-false}" != 'true' ]]; then
    return 0
  fi

  echo "INFO Setting up HTTP Basic Authentication"
  htpasswd -bc /var/www/typo3/.htpasswd "${basicAuthUser}" "${basicAuthPassword}" \
    || die "Failed to create .htpasswd — check that apache2-utils is installed"

  chown www-data:www-data /var/www/typo3/.htpasswd
  chmod 640 /var/www/typo3/.htpasswd
  echo "INFO .htpasswd created for user '${basicAuthUser}'"
}