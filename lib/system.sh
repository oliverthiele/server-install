#!/bin/bash

# System installation and configuration

installDependencies() {
  echo "INFO Install necessary build dependencies"
  apt update
  apt install -y build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev wget git libbrotli-dev
}

addPhpPpa() {
  echo "INFO Adding ondrej/php PPA for PHP ${phpVersion}"
  apt --assume-yes install software-properties-common
  add-apt-repository --yes ppa:ondrej/php
  apt update
}

installSoftware() {
  echo "INFO Install System (nginx, php ${phpVersion}, MySQL, Redis, ...)"

  if [[ "${requiresPhpPpa}" == 'true' ]]; then
    addPhpPpa
  fi

  apt --assume-yes install nginx-full apache2-utils \
    php${phpVersion}-{fpm,cli,common,curl,zip,gd,mysql,xml,mbstring,intl,yaml,opcache,soap,apcu} \
    redis-server mariadb-server \
    graphicsmagick ghostscript git tig zip unzip catdoc argon2 file zsh zsh-syntax-highlighting \
    dos2unix jq webp brotli \
    update-notifier-common

  if [[ "${requiresPhpPpa}" == 'true' ]]; then
    echo "INFO Setting PHP ${phpVersion} as default CLI via update-alternatives"
    update-alternatives --set php /usr/bin/php${phpVersion}
  fi

  if [[ "${ubuntuVersion}" =~ ^20.04$|^22.04$|^24.04$ ]]; then
    installCertbot
  fi
}

installCertbot() {
  echo "Install Lets Encrypt certbot"
  apt --assume-yes install certbot python3-certbot-nginx
}

installAdditionalSoftware() {
  local monitResponseRegex='^([yY][eE][sS]|[yY])$'
  read -rp "Do you want to install monit? [y/N] " response
  if [[ "$response" =~ $monitResponseRegex ]]; then
    apt --assume-yes install monit

    # Configure Monit with admin email
    if [[ -n "${adminEmail}" ]]; then
      echo "INFO Configuring Monit with admin email: ${adminEmail}"

      # Set alert email in monitrc
      if ! grep -q "set alert ${adminEmail}" /etc/monit/monitrc; then
        sed -i "/^#.*set alert.*not on.*{.*instance.*}/a set alert ${adminEmail}" /etc/monit/monitrc
      fi

      # Enable web interface on localhost:2812
      sed -i 's/# set httpd port 2812 and/set httpd port 2812 and/' /etc/monit/monitrc
      sed -i 's/#     use address localhost/    use address localhost/' /etc/monit/monitrc
      sed -i 's/#     allow localhost/    allow localhost/' /etc/monit/monitrc

      systemctl restart monit

      echo "INFO Monit installed and configured. Web interface available at http://localhost:2812/"
      echo "INFO To enable Monit in Nginx, uncomment the monit.nginx snippet in your site config"
    fi

    export monitInstalled="true"
  else
    export monitInstalled="false"
  fi
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
    echo "WARN Could not fetch latest nvm version from GitHub, using fallback ${fallback_version}" >&2
    echo "${fallback_version}"
  fi
}

installNode() {
  local nvmVersion
  nvmVersion=$(getNvmVersion)
  echo "INFO Installing nvm ${nvmVersion} for root"

  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${nvmVersion}/install.sh" | bash

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  nvm install 22
  nvm use 22
}

installNodeForWwwData() {
  local nvmVersion
  nvmVersion=$(getNvmVersion)
  echo "INFO Installing nvm ${nvmVersion} for www-data"

  sudo -u www-data -i bash <<EOF
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${nvmVersion}/install.sh" | bash

  export NVM_DIR="\$HOME/.nvm"
  [ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

  nvm install 22
  nvm use 22
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
    echo "WARN ${zshrcPath} not found – skipping plugin configuration"
    return 0
  fi

  # Remove the built-in git plugin – git aliases conflict with custom setups.
  # Removes "git" as a standalone word inside plugins=(...), then collapses extra spaces.
  sed -i 's/\(plugins=([^)]*\)\bgit\b[[:space:]]*/\1/' "${zshrcPath}"
  sed -i 's/plugins=( /plugins=(/'                      "${zshrcPath}"
}