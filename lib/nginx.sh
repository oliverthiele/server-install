#!/bin/bash

# Nginx installation and configuration with Brotli

writeBotFilterSnippet() {
  local mode="${1}"
  local targetFile="/etc/nginx/snippets/bot-filter.nginx"

  echo "INFO Writing bot-filter snippet (mode: ${mode})"

  if [[ "${mode}" == "staging" ]]; then
    cat > "${targetFile}" <<'EOL'
# Bot and AI Crawler Filter – STAGING mode
# All AI crawlers and SEO scrapers are blocked.
# This system is not intended to be indexed.

# Block SEO scrapers
if ($http_user_agent ~* (AhrefsBot|SemrushBot|DotBot|MJ12bot|Sogou|BLEXBot|Baiduspider)) {
    return 444;
}

# Block all AI crawlers
if ($http_user_agent ~* (GPTBot|ChatGPT-User|OAI-SearchBot|CCBot|anthropic-ai|ClaudeBot|Claude-Web|cohere-ai|PerplexityBot|Omgilibot|Bytespider|FacebookBot|Applebot-Extended|Google-Extended|Amazonbot|YouBot|ImagesiftBot)) {
    return 444;
}

# Block empty User-Agent (common for scrapers)
if ($http_user_agent = "") {
    return 444;
}
EOL

  else
    cat > "${targetFile}" <<'EOL'
# Bot and AI Crawler Filter – PRODUCTION mode
# Abusive scrapers and Bytedance are blocked.
# Major AI assistants (ChatGPT, Claude, Perplexity, Gemini) are allowed
# so the site remains discoverable via AI search tools.

# Always block: Bytedance/TikTok (history of abusive crawling causing server load)
if ($http_user_agent ~* (Bytespider)) {
    return 444;
}

# Block SEO scrapers (not search engines, purely commercial data harvesting)
if ($http_user_agent ~* (AhrefsBot|SemrushBot|DotBot|MJ12bot|Sogou|BLEXBot|Baiduspider|Omgilibot)) {
    return 444;
}

# Block empty User-Agent (common for scrapers)
if ($http_user_agent = "") {
    return 444;
}

# Allowed AI crawlers (no explicit block needed, listed here for documentation):
# GPTBot, OAI-SearchBot (ChatGPT/OpenAI)
# ClaudeBot, anthropic-ai (Claude/Anthropic)
# PerplexityBot (Perplexity)
# Google-Extended (Gemini/Google AI)
# Note: control access per-site via robots.txt if needed
EOL
  fi
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

compileNginxWithBrotli() {
  echo "INFO Compiling Nginx with Brotli module for version ${nginxVersion}"

  # Check if Brotli modules are already installed
  if [ -f "/usr/share/nginx/modules/ngx_http_brotli_filter_module.so" ] && \
     [ -f "/usr/share/nginx/modules/ngx_http_brotli_static_module.so" ]; then
    echo "INFO Brotli modules already compiled and installed"
    return 0
  fi

  cd /usr/local/src/nginx-${nginxVersion} || exit
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
  if [ -z "${serverDomain}" ]; then
    echo "ERROR: serverDomain is not set. Cannot configure nginx."
    exit 1
  fi

  if [ -z "${typo3PublicDirectory}" ]; then
    echo "ERROR: typo3PublicDirectory is not set. Cannot configure nginx."
    exit 1
  fi

  if [ -z "${phpVersion}" ]; then
    echo "ERROR: phpVersion is not set. Cannot configure nginx."
    exit 1
  fi

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
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cp -f "${SCRIPT_DIR}/config/nginx/snippets/"*.nginx /etc/nginx/snippets/

  # Write bot-filter snippet based on selected mode
  writeBotFilterSnippet "${botFilterMode:-production}"

  # Remove default site
  if [ -f "/etc/nginx/sites-available/default" ]; then
    rm /etc/nginx/sites-available/default
  fi

  if [ -L "/etc/nginx/sites-enabled/default" ]; then
    rm /etc/nginx/sites-enabled/default
  fi

  # Create TYPO3 site configuration
  cat >/etc/nginx/sites-available/typo3.nginx <<EOL
# Default HTTP server: reject requests with unknown Host headers
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

server {
    listen 80;
    listen [::]:80;

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
    include /etc/nginx/snippets/security.nginx;
    include /etc/nginx/snippets/caching.nginx;
    include /etc/nginx/snippets/typo3-rewrite.nginx;
    include /etc/nginx/snippets/method-filter.nginx;

    # Monit Web Interface (uncomment if Monit is installed)
    # include /etc/nginx/snippets/monit.nginx;

    # Main location
    location / {
        # Uncomment for basic auth during development
        # auth_basic "Restricted";
        # auth_basic_user_file /var/www/typo3/.htpasswd;

        try_files \$uri \$uri/ /index.php?\$args;
    }

    # WebP Extension support
    location ~* ^.+\.(png|gif|jpe?g)$ {
        add_header Vary "Accept";
        add_header Cache-Control "public, no-transform";
        try_files \$uri\$webp_suffix \$uri =404;
    }

    # Fileadmin: uploaded files are served statically, never executed as PHP.
    # ^~ stops regex matching, so the PHP-FPM location does not apply here.
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

        # Strict CSP only for file types that can run active content in the browser
        location ~* \.(html?|xhtml|xml|svg|svgz|js|mjs)\$ {
            add_header Content-Security-Policy "default-src 'none'; base-uri 'none'; form-action 'none'; sandbox" always;
            add_header X-Content-Type-Options "nosniff" always;
            try_files \$uri =404;
        }
    }

    # PHP-FPM configuration
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        try_files \$fastcgi_script_name =404;

        set \$path_info \$fastcgi_path_info;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_index index.php;
        include fastcgi.conf;

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

  # Test nginx configuration
  nginx -t

  service nginx restart
}