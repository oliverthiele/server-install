#!/bin/bash

# TYPO3 installation and configuration

installTypo3() {
  echo "INFO Install TYPO3 ${typo3Version}"

  chown www-data:www-data /var/www/ -R

  cd "${wwwRoot}" || die "Cannot cd to ${wwwRoot}"

  # Check if TYPO3 directory already exists
  if [ -d "/var/www/typo3" ] && [ -f "/var/www/typo3/composer.json" ]; then
    echo "INFO TYPO3 directory already exists - skipping create-project"
    echo "INFO Continuing with existing installation"
  else
    # Remove directory if it exists but is incomplete
    if [ -d "/var/www/typo3" ]; then
      warn "Removing incomplete TYPO3 directory"
      rm -rf /var/www/typo3
    fi

    sudo -i -H -u www-data composer create-project "typo3/cms-base-distribution:${typo3Version}" /var/www/typo3/ \
      || die "composer create-project failed — check Composer output above"
  fi

  cd "${composerDirectory}" || die "Cannot cd to ${composerDirectory}"

  # Add Extension directory for custom extensions and sitepackages
  mkdir -p packages

  # Configure local repository if not already configured
  if ! grep -q '"type": "path"' "${composerDirectory}composer.json" 2>/dev/null; then
    sudo -i -H -u www-data composer --file="${composerDirectory}composer.json" config repositories.local '{"type": "path", "url": "./packages/*"}'
  fi

  # Install dotenv for environment configuration
  echo "INFO Installing dotenv"
  sudo -u www-data sh -c "cd ${composerDirectory} && composer require vlucas/phpdotenv --no-interaction" || warn "dotenv installation had issues, continuing..."

  # Install recommended system extensions
  echo "INFO Installing system extensions"
  sudo -u www-data sh -c "cd ${composerDirectory} && composer require --no-interaction \
      typo3/cms-adminpanel:${typo3Version} \
      typo3/cms-lowlevel:${typo3Version} \
      typo3/cms-redirects:${typo3Version} \
      typo3/cms-recycler:${typo3Version} \
      typo3/cms-workspaces:${typo3Version} \
      typo3/cms-linkvalidator:${typo3Version} \
      typo3/cms-reports:${typo3Version} \
      typo3/cms-opendocs:${typo3Version} \
      typo3/cms-scheduler:${typo3Version}" || warn "Some system extensions had issues, continuing..."

  # Install useful extensions
  echo "INFO Installing useful extensions"
  sudo -u www-data sh -c "cd ${composerDirectory} && composer require --no-interaction plan2net/webp" || warn "webp extension had issues, continuing..."

  # Add dev packages
  echo "INFO Installing dev dependencies"
  sudo -u www-data sh -c "cd ${composerDirectory} && composer require --dev --no-interaction --with-all-dependencies typo3/coding-standards ssch/typo3-rector" || warn "Dev dependencies had issues, continuing..."

  # Setup coding standards (only if typo3-coding-standards is installed)
  if [ -f "${composerDirectory}vendor/bin/typo3-coding-standards" ]; then
    echo "INFO Setting up coding standards"
    sudo -u www-data sh -c "cd ${composerDirectory} && composer exec typo3-coding-standards setup project" || warn "Coding standards setup had issues, continuing..."
  fi

  # Install typo3-console for automated installation and CLI tasks
  echo "INFO Installing typo3-console"
  sudo -u www-data sh -c "cd ${composerDirectory} && composer require --no-interaction helhum/typo3-console" || warn "typo3-console installation had issues, continuing..."

  # Set permissions
  find "${composerDirectory}" -type d -print0 | xargs -0 chmod 2770
  find "${composerDirectory}" -type f ! -perm /u=x,g=x,o=x -print0 | xargs -0 chmod 0660

  chown www-data:www-data /var/www/ -R

  # Add CLI aliases for www-data user
  if test -f "${composerDirectory}vendor/bin/typo3cms"; then
    echo "alias typo3cms='${composerDirectory}vendor/bin/typo3cms'" >>/var/www/.zshrc
  fi

  if test -f "${composerDirectory}vendor/bin/typo3"; then
    echo "alias typo3='${composerDirectory}vendor/bin/typo3'" >>/var/www/.zshrc
  fi

  # Auto-set TYPO3_CONTEXT from active nginx configuration.
  # Nginx is the single source of truth for the context — switching from
  # Development to Production in typo3.nginx and reloading nginx automatically
  # applies to the next CLI session without a manual 'export TYPO3_CONTEXT=...'.
  for zshrcFile in /var/www/.zshrc /root/.zshrc; do
    cat >>"${zshrcFile}" <<'EOZSH'

# Auto-set TYPO3_CONTEXT from active nginx site configuration
if [ -f "/etc/nginx/sites-available/typo3.nginx" ]; then
    _typo3_context=$(grep -E '^\s*fastcgi_param TYPO3_CONTEXT' /etc/nginx/sites-available/typo3.nginx | awk '{print $3}' | tr -d ';' | head -1)
    if [ -n "${_typo3_context}" ]; then
        export TYPO3_CONTEXT="${_typo3_context}"
    fi
    unset _typo3_context
fi
EOZSH
  done
}

activateTypo3() {
  echo "INFO Activate TYPO3 installation"

  # Create FIRST_INSTALL file to enable setup
  cd "${typo3PublicDirectory}" || die "Cannot cd to ${typo3PublicDirectory}"
  touch FIRST_INSTALL

  # Create .env example file
  cat >/var/www/typo3/.env.example <<'EOL'
PROJECT_NAME=""
# Domain without scheme (used for trustedHostPattern)
DOMAIN=""

DB_DB=""
DB_USER=""
DB_PASS=""
DB_HOST="localhost"

ENCRYPTION_KEY=""
TYPO3_INSTALL_TOOL=""
REDIS_PASS=""

SMTP_SERVER=""
SMTP_USER=""
SMTP_PASSWORD=""
# Bool: 0 / 1
SMTP_TRANSPORT_ENCRYPT=0

DEFAULT_MAIL_FROM_ADDRESS=""
DEFAULT_MAIL_FROM_NAME=""
DEFAULT_MAIL_REPLY_TO_ADDRESS=""
DEFAULT_MAIL_REPLY_TO_NAME=""
EOL

  # Create .env files with actual values
  # Set default mail from address based on domain
  if [[ "${serverDomain}" != "_" ]]; then
    defaultMailFrom="noreply@${serverDomain}"
  else
    defaultMailFrom=""
  fi

  # Generate TYPO3 Install Tool password hash (Argon2id)
  echo "INFO Generating TYPO3 Install Tool password hash"
  installToolHash=$(php -r "echo password_hash('${systemPass}', PASSWORD_ARGON2ID);")

  cat >/var/www/typo3/.env <<EOL
PROJECT_NAME="TYPO3 CMS"
# Domain without scheme (used for trustedHostPattern)
DOMAIN="${serverDomain}"

DB_DB="${databaseName}"
DB_USER="${databaseUser}"
DB_PASS="${databasePassword}"
DB_HOST="localhost"

ENCRYPTION_KEY="${encryptionKey}"
TYPO3_INSTALL_TOOL="${installToolHash}"
REDIS_PASS="${redisPassword}"

SMTP_SERVER=""
SMTP_USER=""
SMTP_PASSWORD=""
# Bool: 0 / 1
SMTP_TRANSPORT_ENCRYPT=0

DEFAULT_MAIL_FROM_ADDRESS="${defaultMailFrom}"
DEFAULT_MAIL_FROM_NAME="TYPO3 CMS"
DEFAULT_MAIL_REPLY_TO_ADDRESS=""
DEFAULT_MAIL_REPLY_TO_NAME=""
EOL

  # Copy for development environment
  cp -ap /var/www/typo3/.env /var/www/typo3/.env.development

  # Set ownership
  chown www-data:www-data /var/www/typo3/.env*

  # Create settings directory as www-data to preserve ownership from Composer install
  sudo -u www-data mkdir -p "${pathSettings}"

  # Create additional.php configuration
  cat >"${pathAdditionalSettings}" <<'EOPHP'
<?php

declare(strict_types=1);

defined('TYPO3') or die();

use TYPO3\CMS\Core\Core\Environment;

$context = Environment::getContext();

/**
 * Load environment variables with fallback
 * Tries dotenv first, falls back to manual parsing if unavailable or fails
 */
$envPath = dirname(__DIR__, 2);
$envFile = '.env';

// Determine env file based on context
if ($context->isDevelopment()) {
    $envFile = '.env.development';
} elseif ($context->isProduction() && $context->__toString() === 'Production/Staging') {
    $envFile = '.env.staging';
}

// Try to load with dotenv (recommended)
if (class_exists('\Dotenv\Dotenv')) {
    try {
        $dotenv = \Dotenv\Dotenv::createImmutable($envPath, $envFile);
        $dotenv->load();
    } catch (\Exception $e) {
        // Fallback to manual parsing
        $envFilePath = $envPath . '/' . $envFile;
        if (file_exists($envFilePath)) {
            $lines = file($envFilePath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($lines as $line) {
                if (strpos(trim($line), '#') === 0) {
                    continue;
                }
                if (strpos($line, '=') !== false) {
                    [$key, $value] = explode('=', $line, 2);
                    $key = trim($key);
                    $value = trim($value, " \t\n\r\0\x0B\"'");
                    $_ENV[$key] = $value;
                    putenv("$key=$value");
                }
            }
        }
    }
}

/**
 * System configuration (applies to all environments)
 *
 * NOTE: Settings configured here override anything saved via the TYPO3 Install
 * Tool or Admin Panel, because additional.php is always loaded last and takes
 * precedence over config/system/settings.php. Changes made through the TYPO3
 * backend will appear to be saved but will be silently overridden on the next
 * request. To change these values, edit this file directly.
 */
$GLOBALS['TYPO3_CONF_VARS']['SYS']['folderCreateMask'] = '2770';
$GLOBALS['TYPO3_CONF_VARS']['SYS']['fileCreateMask'] = '0660';
$GLOBALS['TYPO3_CONF_VARS']['SYS']['UTF8filesystem'] = 'en_US.UTF-8';
$GLOBALS['TYPO3_CONF_VARS']['SYS']['systemLocale'] = 'en_US.UTF-8';

// Image processing: use ImageMagick (supports AVIF via libheif; GraphicsMagick does not)
$GLOBALS['TYPO3_CONF_VARS']['GFX']['processor_enabled'] = true;
$GLOBALS['TYPO3_CONF_VARS']['GFX']['processor_path'] = '/usr/bin/';
$GLOBALS['TYPO3_CONF_VARS']['GFX']['processor'] = 'ImageMagick';
$GLOBALS['TYPO3_CONF_VARS']['GFX']['processor_effects'] = true;

// Set trustedHostsPattern from DOMAIN if available
$domain = $_ENV['DOMAIN'] ?? getenv('DOMAIN') ?: '';
if (!$domain || $domain === '_') {
    // No domain or IP-based installation: allow all hosts
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = '.*';
} else {
    // Domain-based installation: restrict to specific domain
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = preg_quote($domain, '/');
}

/**
 * Context-specific configuration
 */
if ($context->isProduction() && $context->__toString() === 'Production') {
    $GLOBALS['TYPO3_CONF_VARS']['BE']['debug'] = '';
    $GLOBALS['TYPO3_CONF_VARS']['FE']['debug'] = '';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['devIPmask'] = '';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['displayErrors'] = '0';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['exceptionalErrors'] = '4096';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['sitename'] = '[Production] TYPO3 CMS';
} elseif ($context->isDevelopment()) {
    $GLOBALS['TYPO3_CONF_VARS']['BE']['debug'] = '1';
    $GLOBALS['TYPO3_CONF_VARS']['FE']['debug'] = '1';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['devIPmask'] = '*';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['displayErrors'] = '1';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['exceptionalErrors'] = '12290';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['sitename'] = '[Dev] TYPO3 CMS';
    // trustedHostsPattern is set above based on $domain from .env.development
} elseif ($context->isProduction() && $context->__toString() === 'Production/Staging') {
    $GLOBALS['TYPO3_CONF_VARS']['BE']['debug'] = '';
    $GLOBALS['TYPO3_CONF_VARS']['FE']['debug'] = '';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['devIPmask'] = '';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['displayErrors'] = '0';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['exceptionalErrors'] = '4096';
    $GLOBALS['TYPO3_CONF_VARS']['SYS']['sitename'] = '[Staging] TYPO3 CMS';
}

/**
 * Database configuration
 */
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['driver'] = 'mysqli';
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['dbname'] = $_ENV['DB_DB'] ?? getenv('DB_DB') ?: '';
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['user'] = $_ENV['DB_USER'] ?? getenv('DB_USER') ?: '';
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['password'] = $_ENV['DB_PASS'] ?? getenv('DB_PASS') ?: '';
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['host'] = $_ENV['DB_HOST'] ?? getenv('DB_HOST') ?: 'localhost';
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['port'] = 3306;
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['charset'] = 'utf8mb4';
// Use modern defaultTableOptions for TYPO3 v13+ (backward compatible with v12)
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default']['defaultTableOptions'] = [
    'charset' => 'utf8mb4',
    'collation' => 'utf8mb4_unicode_ci',
];

/**
 * Mail configuration
 * Only set if values are provided
 */
$smtpServer = $_ENV['SMTP_SERVER'] ?? getenv('SMTP_SERVER') ?: '';
if ($smtpServer) {
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['transport'] = 'smtp';
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['transport_smtp_server'] = $smtpServer;
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['transport_smtp_username'] = $_ENV['SMTP_USER'] ?? getenv('SMTP_USER') ?: '';
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['transport_smtp_password'] = $_ENV['SMTP_PASSWORD'] ?? getenv('SMTP_PASSWORD') ?: '';
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['transport_smtp_encrypt'] = (bool)($_ENV['SMTP_TRANSPORT_ENCRYPT'] ?? getenv('SMTP_TRANSPORT_ENCRYPT') ?: '');
}

// Default mail from address
$defaultMailFrom = $_ENV['DEFAULT_MAIL_FROM_ADDRESS'] ?? getenv('DEFAULT_MAIL_FROM_ADDRESS') ?: '';
if ($defaultMailFrom) {
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['defaultMailFromAddress'] = $defaultMailFrom;
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['defaultMailFromName'] = $_ENV['DEFAULT_MAIL_FROM_NAME'] ?? getenv('DEFAULT_MAIL_FROM_NAME') ?: 'TYPO3 CMS';
}

// Reply-To address
$replyToAddress = $_ENV['DEFAULT_MAIL_REPLY_TO_ADDRESS'] ?? getenv('DEFAULT_MAIL_REPLY_TO_ADDRESS') ?: '';
if ($replyToAddress) {
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['defaultMailReplyToAddress'] = $replyToAddress;
    $GLOBALS['TYPO3_CONF_VARS']['MAIL']['defaultMailReplyToName'] = $_ENV['DEFAULT_MAIL_REPLY_TO_NAME'] ?? getenv('DEFAULT_MAIL_REPLY_TO_NAME') ?: '';
}

/**
 * DDEV support
 */
if (getenv('IS_DDEV_PROJECT') === 'true') {
    $GLOBALS['TYPO3_CONF_VARS'] = array_replace_recursive(
        $GLOBALS['TYPO3_CONF_VARS'],
        [
            'DB' => [
                'Connections' => [
                    'Default' => [
                        'dbname' => 'db',
                        'driver' => 'mysqli',
                        'host' => 'db',
                        'password' => 'db',
                        'port' => '3306',
                        'user' => 'db',
                        'charset' => 'utf8mb4',
                        'tableoptions' => [
                            'charset' => 'utf8mb4',
                            'collate' => 'utf8mb4_unicode_ci',
                        ],
                    ],
                ],
            ],
            'GFX' => [
                'processor' => 'ImageMagick',
                'processor_path' => '/usr/bin/',
                'processor_path_lzw' => '/usr/bin/',
            ],
            'MAIL' => [
                'transport' => 'smtp',
                'transport_smtp_encrypt' => false,
                'transport_smtp_server' => 'localhost:1025',
            ],
            'SYS' => [
                'trustedHostsPattern' => '.*.*',
                'devIPmask' => '*',
                'displayErrors' => 1,
                'systemLocale' => 'C.UTF-8'
            ],
        ]
    );
}

/**
 * Redis cache configuration
 * Requires Redis authentication (requirepass configured during installation).
 * Password is read from REDIS_PASS in the .env file.
 * To disable Redis for a specific cache, remove the corresponding entries
 * from config/system/settings.yaml — additional.php takes precedence.
 */
$redisPassword = $_ENV['REDIS_PASS'] ?? getenv('REDIS_PASS') ?: '';
$redisConnectionOptions = [
    'hostname' => 'localhost',
    'port'     => 6379,
    'password' => $redisPassword,
];

$GLOBALS['TYPO3_CONF_VARS']['SYS']['caching']['cacheConfigurations']['pages']['backend'] =
    \TYPO3\CMS\Core\Cache\Backend\RedisBackend::class;
$GLOBALS['TYPO3_CONF_VARS']['SYS']['caching']['cacheConfigurations']['pages']['options'] =
    array_merge($redisConnectionOptions, ['database' => 0]);

$GLOBALS['TYPO3_CONF_VARS']['SYS']['caching']['cacheConfigurations']['pagesection']['backend'] =
    \TYPO3\CMS\Core\Cache\Backend\RedisBackend::class;
$GLOBALS['TYPO3_CONF_VARS']['SYS']['caching']['cacheConfigurations']['pagesection']['options'] =
    array_merge($redisConnectionOptions, ['database' => 1]);

/**
 * TYPO3 Install Tool Password
 * Managed from .env (TYPO3_INSTALL_TOOL = argon2id hash of the install tool password).
 * additional.php takes precedence over settings.php, so this is always the active value.
 */
$installToolPassword = $_ENV['TYPO3_INSTALL_TOOL'] ?? getenv('TYPO3_INSTALL_TOOL') ?: '';
if ($installToolPassword) {
    $GLOBALS['TYPO3_CONF_VARS']['BE']['installToolPassword'] = $installToolPassword;
}
EOPHP

  # Set ownership of settings
  chown www-data:www-data "${pathAdditionalSettings}"
  chmod 660 "${pathAdditionalSettings}"

  # Run TYPO3 automated setup
  # Uses the native TYPO3 CLI 'setup' command (available since TYPO3 v12.4).
  # Does not require helhum/typo3-console — both v12 and v13 are covered.
  echo "INFO Running automated TYPO3 setup"
  echo "CMD: sudo -u www-data php ${composerDirectory}vendor/bin/typo3 setup --no-interaction ..."

  setup_success=false
  if sudo -u www-data php "${composerDirectory}vendor/bin/typo3" setup \
    --no-interaction \
    --driver=mysqli \
    --host=localhost \
    --port=3306 \
    --dbname="${databaseName}" \
    --username="${databaseUser}" \
    --password="${databasePassword}" \
    --admin-username="typo3-admin" \
    --admin-user-password="${systemPass}" \
    --admin-email="${adminEmail}" \
    --project-name="TYPO3 CMS" \
    --create-site="http://${serverDomain}/" \
    --server-type=other; then
    setup_success=true
  fi

  if $setup_success; then
    echo -e "${COLOR_GREEN}INFO TYPO3 setup completed successfully${COLOR_NC}"
    if [ -f "${typo3PublicDirectory}/FIRST_INSTALL" ]; then
      rm "${typo3PublicDirectory}/FIRST_INSTALL"
      echo -e "${COLOR_GREEN}INFO FIRST_INSTALL removed${COLOR_NC}"
    fi
    # Set admin email and real name in the database
    # Escape single quotes for MySQL string literals (' → '') to prevent SQL injection
    local safeEmail="${adminEmail//\'/\'\'}"
    local realNameSql=""
    if [[ -n "${adminRealName:-}" ]]; then
      local safeRealName="${adminRealName//\'/\'\'}"
      realNameSql=", realName = '${safeRealName}'"
    fi
    mysql -u"${databaseUser}" -p"${databasePassword}" "${databaseName}" \
      -e "UPDATE be_users SET email = '${safeEmail}'${realNameSql} WHERE username = 'typo3-admin';" \
      || warn "Could not update BE user — set email/name manually in TYPO3 backend"
  else
    echo ""
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}WARN Automated TYPO3 setup failed.${COLOR_NC}"
    echo -e "     FIRST_INSTALL kept — complete setup via the web wizard:"
    echo -e "     ${COLOR_BOLD}http://${serverDomain}/typo3/install.php${COLOR_NC}"
    echo ""
    echo    "     Or retry manually as www-data:"
    echo    "     sudo -u www-data php ${composerDirectory}vendor/bin/typo3 setup"
  fi

  echo ""
  echo "==============================================================="
  echo "TYPO3 Installation Completed!"
  echo "==============================================================="
  echo "Admin User: typo3-admin"
  echo "Admin Password: ${systemPass}"
  echo "Install Tool Password: ${systemPass}"
  echo ""
  echo "Next steps:"
  echo "1. Access TYPO3 Backend: http://${serverDomain}/typo3"
  echo "2. Configure SSL certificate (recommended)"
  echo "3. Set up SMTP for email sending (edit .env file)"
  echo "==============================================================="
}

setupScheduler() {
  echo "INFO Setting up TYPO3 Scheduler cronjob (every 5 minutes)"

  # TYPO3_CONTEXT is read at runtime from the nginx config — the same
  # source of truth used by the web server and the CLI shell profile.
  cat > /etc/cron.d/typo3-scheduler <<'EOL'
# TYPO3 Scheduler – runs every 5 minutes.
# TYPO3_CONTEXT is derived from the active nginx configuration at runtime.
*/5 * * * * www-data TYPO3_CONTEXT=$(grep -E '^\s*fastcgi_param TYPO3_CONTEXT' /etc/nginx/sites-available/typo3.nginx 2>/dev/null | awk '{print $3}' | tr -d ';' | head -1) /usr/bin/php /var/www/typo3/vendor/bin/typo3 scheduler:run 2>&1 | /usr/bin/logger -t typo3-scheduler
EOL
  chmod 644 /etc/cron.d/typo3-scheduler
  echo "INFO TYPO3 Scheduler cronjob installed (/etc/cron.d/typo3-scheduler)"
}