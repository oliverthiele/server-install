#!/bin/bash

# System installation and configuration

installDependencies() {
  echo "INFO Install necessary build dependencies"

  # Ubuntu 26.04 removed libpcre3 — use libpcre2-dev instead (nginx 1.21.5+ supports PCRE2)
  local pcrePackages
  case "${ubuntuVersion}" in
    26.04) pcrePackages="libpcre2-dev" ;;
    *)     pcrePackages="libpcre3 libpcre3-dev" ;;
  esac

  apt update
  apt install -y build-essential "${pcrePackages}" zlib1g zlib1g-dev libssl-dev wget git libbrotli-dev
}

# Adds the packages.sury.org PHP repository — successor to the ondrej/php Launchpad PPA,
# which Ondřej Surý is discontinuing due to unreliable Launchpad build infrastructure.
# Idempotent — skips if the repository is already configured.
# Usage: addPhpRepo [versionLabel]  – versionLabel is only used for the log message.
addPhpRepo() {
  local versionLabel="${1:-${phpVersion:-}}"
  local suryList="/etc/apt/sources.list.d/php.list"
  local suryKeyring="/usr/share/keyrings/debsuryorg-archive-keyring.gpg"

  if [[ -f "${suryList}" ]] && grep -q "packages.sury.org" "${suryList}"; then
    echo "INFO packages.sury.org PHP repository already configured"
    return
  fi

  echo "INFO Adding packages.sury.org PHP repository${versionLabel:+ for PHP ${versionLabel}}"
  apt update
  apt --assume-yes install lsb-release ca-certificates curl

  local keyringDeb
  keyringDeb="$(mktemp --suffix=.deb)"
  curl -sSLf -o "${keyringDeb}" https://packages.sury.org/debsuryorg-archive-keyring.deb \
    || die "Download of debsuryorg-archive-keyring.deb failed"
  dpkg -i "${keyringDeb}"
  rm -f "${keyringDeb}"

  echo "deb [signed-by=${suryKeyring}] https://packages.sury.org/php/ $(lsb_release -sc) main" > "${suryList}"
  apt update
}

installSoftware() {
  echo "INFO Install System (nginx, php ${phpVersion}, MySQL, Redis, ...)"

  if [[ "${requiresPhpPpa}" == 'true' ]]; then
    addPhpRepo "${phpVersion}"
  fi

  # Install AVIF shared library before php-gd so GD AVIF support is available at runtime.
  # Package name varies by Ubuntu version; silently skipped if unavailable (e.g. 20.04).
  case "${ubuntuVersion}" in
    26.04|24.04) apt --assume-yes install libavif16 ;;
    22.04)       apt --assume-yes install libavif13 ;;
  esac

  apt --assume-yes install nginx-full apache2-utils \
    "php${phpVersion}"-{fpm,cli,common,curl,zip,gd,mysql,xml,mbstring,intl,yaml,soap,apcu,fileinfo} \
    redis-server mariadb-server \
    imagemagick libheif1 ghostscript \
    git tig zip unzip argon2 file zsh zsh-syntax-highlighting \
    dos2unix jq webp brotli \
    update-notifier-common

  # Document indexing tools for TYPO3 indexed_search, ke_search, and FAL metadata extraction:
  # poppler-utils: pdftotext / pdfinfo — PDF full-text indexing
  # catdoc:        catdoc / xls2csv / catppt — Word, Excel, PowerPoint text extraction
  # exiftool:      read IPTC / XMP / GPS metadata from uploaded images and documents
  apt --assume-yes install poppler-utils catdoc libimage-exiftool-perl

  # php-opcache is a separate package on Ubuntu 22.04/24.04 but bundled in php-common on 26.04
  apt --assume-yes install "php${phpVersion}-opcache" \
    || warn "php${phpVersion}-opcache not found — opcache is likely bundled in php${phpVersion}-common on this system"

  if [[ "${requiresPhpPpa}" == 'true' ]]; then
    echo "INFO Setting PHP ${phpVersion} as default CLI via update-alternatives"
    update-alternatives --set php "/usr/bin/php${phpVersion}"
  fi

  if [[ "${ubuntuVersion}" =~ ^20.04$|^22.04$|^24.04$|^26.04$ ]]; then
    installCertbot
  fi
}

installCertbot() {
  echo "Install Lets Encrypt certbot"
  apt --assume-yes install certbot python3-certbot-nginx
}

configureImageMagick() {
  echo "INFO Configuring ImageMagick policy for PDF/PS/EPS support (required for TYPO3)"

  local policyFile=""
  for policyDir in /etc/ImageMagick-7 /etc/ImageMagick-6 /etc/ImageMagick; do
    if [ -f "${policyDir}/policy.xml" ]; then
      policyFile="${policyDir}/policy.xml"
      break
    fi
  done

  if [ -z "${policyFile}" ]; then
    warn "ImageMagick policy.xml not found — PDF/PS/EPS thumbnails may not work in TYPO3"
    return 0
  fi

  # Ubuntu restricts PDF/PS/EPS processing by default due to historic Ghostscript vulnerabilities.
  # TYPO3 requires these formats for document thumbnails and previews.
  for pattern in PDF PS PS2 PS3 EPS XPS; do
    sed -i "s#<policy domain=\"coder\" rights=\"none\" pattern=\"${pattern}\"[[:space:]]*/>#<policy domain=\"coder\" rights=\"read|write\" pattern=\"${pattern}\"/>#g" "${policyFile}"
  done

  echo "INFO ImageMagick policy updated in ${policyFile}: PDF/PS/EPS/XPS enabled"

  # AppArmor profile for Ghostscript (/etc/apparmor.d/gs) restricts file access
  # even for root. Without /var/www/ in the allow list, Ghostscript cannot read
  # TYPO3 files for PDF/AI thumbnail generation.
  local gsAppArmorProfile="/etc/apparmor.d/gs"
  local gsLocalOverride="/etc/apparmor.d/local/gs"

  if [ ! -f "${gsAppArmorProfile}" ]; then
    echo "INFO No Ghostscript AppArmor profile found — skipping"
    return 0
  fi

  echo "INFO Adding /var/www/ to Ghostscript AppArmor local override"
  mkdir -p /etc/apparmor.d/local

  if ! grep -q '/var/www/\*\*' "${gsLocalOverride}" 2>/dev/null; then
    cat >> "${gsLocalOverride}" << 'EOAPPARMOR'
/var/www/** r,
/tmp/magick-** rw,
EOAPPARMOR
  fi

  apparmor_parser -r "${gsAppArmorProfile}" \
    || warn "Failed to reload Ghostscript AppArmor profile — PDF thumbnails may not work"

  echo "INFO Ghostscript AppArmor profile reloaded"
}


installComposer() {
  echo "Install composer from https://getcomposer.org"

  EXPECTED_CHECKSUM="$(wget -q -O - https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
    echo >&2 'ERROR: Invalid installer checksum'
    rm composer-setup.php
    exit 1
  fi

  php composer-setup.php --quiet
  RESULT=$?
  rm composer-setup.php
  if [ $RESULT -eq 0 ]; then
    echo 'Composer installation was successful'
  else
    echo 'Composer Setup Result:' $RESULT
  fi

  mv composer.phar /usr/local/bin/composer
}

getNvmVersion() {
  # Fetch the latest nvm release tag from GitHub API.
  # Falls back to a known-good version if the API is unreachable.
  local fallback_version="v0.40.4"
  local version

  version=$(curl -sf https://api.github.com/repos/nvm-sh/nvm/releases/latest \
    | grep '"tag_name"' \
    | cut -d'"' -f4)

  if [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${version}"
  else
    warn "Could not fetch latest nvm version from GitHub, using fallback ${fallback_version}"
    echo "${fallback_version}"
  fi
}

installNode() {
  local nvmVersion
  nvmVersion=$(getNvmVersion)
  echo "INFO Installing nvm ${nvmVersion} for root (Node.js ${nodeVersion:-24})"

  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${nvmVersion}/install.sh" | bash

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  nvm install "${nodeVersion:-24}"
  nvm use "${nodeVersion:-24}"
}

installNodeForWwwData() {
  local nvmVersion
  nvmVersion=$(getNvmVersion)
  echo "INFO Installing nvm ${nvmVersion} for www-data (Node.js ${nodeVersion:-24})"

  sudo -u www-data -i bash <<EOF
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${nvmVersion}/install.sh" | bash

  export NVM_DIR="\$HOME/.nvm"
  [ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

  nvm install ${nodeVersion:-24}
  nvm use ${nodeVersion:-24}
EOF
}

activateZshShell() {
  chsh -s /bin/zsh root

  if [ ! -d "/root/.oh-my-zsh" ]; then
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | zsh
    sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="agnoster"/g' /root/.zshrc
  fi

  if ! grep -q "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ~/.zshrc; then
    echo "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >>/root/.zshrc
  fi

  configureZshPlugins

  chsh -s /bin/zsh www-data
  cp -ap /root/.oh-my-zsh /root/.zshrc /var/www/

  echo "cd /var/www/typo3/" >>/var/www/.zshrc
  chown www-data /var/www/ -R
}

configureZshPlugins() {
  local zshrcPath="/root/.zshrc"

  if [ ! -f "${zshrcPath}" ]; then
    warn "${zshrcPath} not found – skipping plugin configuration"
    return 0
  fi

  # Remove the built-in git plugin – git aliases conflict with custom setups.
  # Removes "git" as a standalone word inside plugins=(...), then collapses extra spaces.
  sed -i 's/\(plugins=([^)]*\)\bgit\b[[:space:]]*/\1/' "${zshrcPath}"
  sed -i 's/plugins=( /plugins=(/'                      "${zshrcPath}"
}