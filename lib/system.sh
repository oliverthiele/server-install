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

# Backups of system files this installer edits go to ${BACKUP_ROOT}/<timestamp>/<original path>,
# never next to the original: apt reads every file in /etc/apt/sources.list.d/ and prints a notice
# for each name it does not know (<file>.bak-<timestamp> is not on its list of ignored suffixes).
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/ServerInstall}"

# Timestamp for one backup run, the name of the folder under ${BACKUP_ROOT}. One format for every
# script, so the folders sort by time.
backupTimestamp() {
  date +%Y%m%d-%H%M%S
}

# Prints the backup path of <file> for <timestamp>, e.g.
# /var/backups/ServerInstall/20261027-222020/etc/apt/sources.list.d/hetzner-mirror.sources
# Usage: backupPath <timestamp> <absolute file path>
backupPath() {
  printf '%s%s' "${BACKUP_ROOT}/${1}" "${2}"
}

# Copies <file> to its backupPath (mode 700 directories, only root reads the backups) and prints
# that path. Returns 1 if the copy could not be made.
# Usage: backupFileForRollback <timestamp> <absolute file path>
backupFileForRollback() {
  local backupFile
  backupFile="$(backupPath "${1}" "${2}")"
  mkdir -p "$(dirname "${backupFile}")" || return 1
  chmod 700 "${BACKUP_ROOT}" "${BACKUP_ROOT}/${1}" 2>/dev/null || true
  cp -p "${2}" "${backupFile}" || return 1
  printf '%s' "${backupFile}"
}

# Adds the official Ubuntu security archive as an additional apt source.
#
# Provider mirrors (Hetzner and others) can trail the official archive by hours, sometimes more
# than a day. For a critical fix that is the difference between patched and exposed, so the
# "<codename>-security" pocket is also read from Canonical directly. apt takes the highest version
# across all sources: once the mirror has caught up nothing changes, until then the fix comes from
# the official archive. Only the security pocket is added, never -updates or -backports.
#
# Checks the existing sources first (apt-get indextargets reads deb822 and one-line files alike):
#   - not Ubuntu                                  -> nothing to do
#   - an official host already serves the pocket  -> nothing to do
#   - otherwise writes /etc/apt/sources.list.d/ubuntu-security.sources, with the suite, the
#     components and the host (security.ubuntu.com, ports.ubuntu.com on non-x86) fitted to the system
# Runs apt-get update afterwards and rolls the file back if that fails. Idempotent.
#
# Usage: addUbuntuSecuritySource [--dry-run]
# Sets ubuntuSecurityAction to one of: unsupported, present, current, foreign, add, update
# Returns 1 if the source could not be added, or if ubuntu-security.sources exists without the
# "Managed by ServerInstall" header (foreign).
addUbuntuSecuritySource() {
  local dryRun="false"
  [[ "${1:-}" == "--dry-run" ]] && dryRun="true"

  local sourceFile="/etc/apt/sources.list.d/ubuntu-security.sources"
  local keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  # [.] instead of \. — awk -v would process the escape and warn
  local officialHostPattern='^https?://(security|archive|ports)[.]ubuntu[.]com/'
  ubuntuSecurityAction="none"

  local distroId codename architecture archiveUri suite components existingTargets
  distroId="$(. /etc/os-release && echo "${ID:-}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  architecture="$(dpkg --print-architecture)"

  if [[ "${distroId}" != "ubuntu" ]] || [[ -z "${codename}" ]]; then
    echo "INFO Not Ubuntu (${distroId:-unknown}) — official security archive not added"
    ubuntuSecurityAction="unsupported"
    return 0
  fi

  case "${architecture}" in
    amd64|i386) archiveUri="https://security.ubuntu.com/ubuntu" ;;
    *)          archiveUri="https://ports.ubuntu.com/ubuntu-ports" ;;
  esac
  suite="${codename}-security"

  # $(SITE) is the full URI of a source, e.g. https://mirror.hetzner.com/ubuntu/security
  # shellcheck disable=SC2016
  existingTargets="$(apt-get indextargets --format '$(SITE) $(RELEASE) $(COMPONENT)' 2>/dev/null | sort -u || true)"

  # Same components as the security pocket the system already reads, so universe stays covered
  components="$(printf '%s\n' "${existingTargets}" \
    | awk -v suite="${suite}" '$2 == suite { print $3 }' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  components="${components:-main restricted universe multiverse}"

  local managedContent
  managedContent="# Managed by ServerInstall (bin/setup-apt-security-source.sh).
# The official Ubuntu security archive, in addition to the provider mirror configured elsewhere.
# apt uses the highest version found in any source, so a security fix is available as soon as
# Canonical publishes it, not when the mirror has caught up.
Types: deb
URIs: ${archiveUri}
Suites: ${suite}
Components: ${components}
Signed-By: ${keyring}"

  if [[ -f "${sourceFile}" ]]; then
    if [[ "$(cat "${sourceFile}")" == "${managedContent}" ]]; then
      echo "INFO Official Ubuntu security archive already configured (${sourceFile})"
      ubuntuSecurityAction="current"
      return 0
    fi
    # Same rule as --remove: a file this installer did not write is left alone
    if ! grep -q "^# Managed by ServerInstall" "${sourceFile}"; then
      warn "${sourceFile} exists but was not written by ServerInstall — left unchanged"
      ubuntuSecurityAction="foreign"
      return 1
    fi
    ubuntuSecurityAction="update"
  elif printf '%s\n' "${existingTargets}" \
    | awk -v suite="${suite}" -v pattern="${officialHostPattern}" \
        '$2 == suite && $1 ~ pattern { found = 1 } END { exit !found }'; then
    echo "INFO ${suite} is already read from an official Ubuntu host — nothing to add"
    ubuntuSecurityAction="present"
    return 0
  else
    ubuntuSecurityAction="add"
  fi

  if [[ "${codename}" == "focal" ]]; then
    warn "Ubuntu 20.04 is out of standard support: ${suite} gets no new fixes. Security updates need Ubuntu Pro (ESM)."
  fi

  if [[ ! -f "${keyring}" ]]; then
    warn "${keyring} not found (package ubuntu-keyring) — official security archive not added"
    return 1
  fi

  echo "INFO Official Ubuntu security archive (${ubuntuSecurityAction}): ${sourceFile}"
  echo "     ${archiveUri} ${suite} (${components})"

  if [[ "${dryRun}" == "true" ]]; then
    echo "DRY-RUN: would write ${sourceFile}:"
    printf '%s\n' "${managedContent}" | sed 's/^/     | /'
    return 0
  fi

  # Problems apt reports today are not the new source's fault — remember them for the comparison
  local baselineProblems
  baselineProblems="$(aptUpdateProblems)"

  local backupFile=""
  if [[ -f "${sourceFile}" ]]; then
    backupFile="$(backupFileForRollback "$(backupTimestamp)" "${sourceFile}")" || {
      warn "Could not back up ${sourceFile} — nothing changed"
      return 1
    }
  fi
  printf '%s\n' "${managedContent}" > "${sourceFile}"
  chmod 644 "${sourceFile}"

  echo "INFO Testing apt with the new source..."
  if ! aptSourcesHealthy "${baselineProblems}"; then
    warn "apt does not work cleanly with the new source — rolling back"
    if [[ -n "${backupFile}" ]]; then
      cp -p "${backupFile}" "${sourceFile}"
    else
      rm -f "${sourceFile}"
    fi
    apt-get update >/dev/null 2>&1 || warn "apt update still fails after the rollback — check /etc/apt/sources.list.d/"
    return 1
  fi
  echo "INFO Official Ubuntu security archive added"
}

# Filters error and warning lines from apt output on stdin, sorted. apt up to 2.9.1 writes them as
# "E:" / "W:", later versions as "Error:" / "Warning:" (APT::Output-Version), so both are matched.
# Notices ("N:" / "Notice:", e.g. "Missing Signed-By") are not problems and are left out.
filterAptProblems() {
  grep -E '^(E|W|Error|Warning):' | sort -u || true
}

# Error and warning lines of apt-get update, sorted. Compared before and after a source change:
# only problems that are new count against the change.
aptUpdateProblems() {
  apt-get update 2>&1 | filterAptProblems
}

# Tests that apt still works after a change to the sources:
#   1. apt-get update succeeds and reports no error or warning line that was not there before
#   2. a simulated dist-upgrade (apt-get -s) runs through, i.e. the package lists are usable
# Usage: aptSourcesHealthy "<output of aptUpdateProblems before the change>"
# Returns 1 on any failure and prints the reason. Sets aptMissingSignedByNotes to the number of
# "Missing Signed-By" notes in the update output.
aptSourcesHealthy() {
  local baseline="${1:-}" output status=0 problems newProblems
  output="$(apt-get update 2>&1)" || status=$?
  problems="$(printf '%s\n' "${output}" | filterAptProblems)"

  if (( status != 0 )); then
    warn "apt-get update failed (exit ${status}):"
    printf '%s\n' "${problems}" | sed 's/^/     /'
    return 1
  fi

  newProblems="$(comm -13 <(printf '%s\n' "${baseline}" | sort -u) <(printf '%s\n' "${problems}" | sort -u) \
    | grep -v '^$' || true)"
  if [[ -n "${newProblems}" ]]; then
    warn "apt-get update reports new problems:"
    printf '%s\n' "${newProblems}" | sed 's/^/     /'
    return 1
  fi

  if ! apt-get -s dist-upgrade >/dev/null 2>&1; then
    warn "apt-get -s dist-upgrade (simulation) failed"
    return 1
  fi

  aptMissingSignedByNotes="$(printf '%s\n' "${output}" | grep -c 'Missing Signed-By' || true)"
  echo "INFO apt-get update is clean and apt-get -s dist-upgrade works (Missing Signed-By notes: ${aptMissingSignedByNotes})"
}

# Sources whose packages are signed with the Ubuntu archive key: Canonical's archives and the Hetzner
# mirrors. [.] instead of \. because awk -v would process the escape and warn.
ubuntuArchiveSourcePattern() {
  printf '%s\n' '(^|[ \t])https?://(([a-z0-9-]+[.])?(archive|security|ports)[.]ubuntu[.]com|mirror[.]hetzner[.](com|de))/ubuntu'
}

# Lists apt sources of the Ubuntu archive family that have no Signed-By (one "file: entry" line each).
# Without it apt prints "Missing Signed-By in the sources.list(5) entry" on every update and trusts
# the global keyring. Third-party sources (nodesource, sury, ...) bring their own key and are not listed.
# Reads deb822 (*.sources) and one-line (*.list, sources.list) files; changes nothing.
listSourcesWithoutSignedBy() {
  local pattern file
  pattern="$(ubuntuArchiveSourcePattern)"
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [[ -f "${file}" ]] || continue
    case "${file}" in
      *.sources)
        awk -v file="${file}" -v pattern="${pattern}" '
          function flush() {
            if (uris ~ pattern && !signed && !disabled) print file ": " uris
            uris = ""; signed = 0; disabled = 0
          }
          /^[ \t]*$/ { flush(); next }
          /^#/ { next }
          tolower($1) == "uris:" { uris = $0; sub(/^[^:]*:[ \t]*/, "", uris) }
          tolower($1) == "signed-by:" { signed = 1 }
          tolower($1) == "enabled:" && tolower($2) == "no" { disabled = 1 }
          END { flush() }
        ' "${file}"
        ;;
      *)
        awk -v file="${file}" -v pattern="${pattern}" '
          /^[ \t]*deb(-src)?[ \t]/ && $0 ~ pattern && $0 !~ /signed-by=/ { print file ": " $0 }
        ' "${file}"
        ;;
    esac
  done
}

# Adds the Ubuntu archive keyring as Signed-By to the sources listed by listSourcesWithoutSignedBy.
# Edits the files in place after a backup (backupFileForRollback, outside /etc/apt), then tests apt:
# the configured index targets must be unchanged, apt-get update must show no new problem and a
# simulated dist-upgrade must work (aptSourcesHealthy). On any failure every file is restored.
#
# Usage: addSignedByToUbuntuSources [--dry-run]
# Returns 1 if the change was rolled back or could not be made.
addSignedByToUbuntuSources() {
  local dryRun="false"
  [[ "${1:-}" == "--dry-run" ]] && dryRun="true"

  local keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  local distroId pattern
  distroId="$(. /etc/os-release && echo "${ID:-}")"
  if [[ "${distroId}" != "ubuntu" ]]; then
    echo "INFO Not Ubuntu (${distroId:-unknown}) — Signed-By not touched"
    return 0
  fi

  local -a files=()
  mapfile -t files < <(listSourcesWithoutSignedBy | cut -d: -f1 | sort -u)
  if (( ${#files[@]} == 0 )); then
    echo "INFO All Ubuntu archive sources already have Signed-By"
    return 0
  fi

  if [[ ! -f "${keyring}" ]]; then
    warn "${keyring} not found (package ubuntu-keyring) — Signed-By not added"
    return 1
  fi

  pattern="$(ubuntuArchiveSourcePattern)"
  echo "INFO Signed-By: ${keyring} would be added to:"
  printf '     %s\n' "${files[@]}"
  if [[ "${dryRun}" == "true" ]]; then
    echo "DRY-RUN: no files changed."
    return 0
  fi

  local targetsBefore baselineProblems timestamp file backupFile failed="false"
  # shellcheck disable=SC2016
  targetsBefore="$(apt-get indextargets --format '$(SITE) $(RELEASE) $(COMPONENT)' 2>/dev/null | sort -u || true)"
  baselineProblems="$(aptUpdateProblems)"
  timestamp="$(backupTimestamp)"

  local -a changedFiles=()
  for file in "${files[@]}"; do
    if ! backupFile="$(backupFileForRollback "${timestamp}" "${file}")"; then
      warn "Could not back up ${file} — restoring what was changed so far"
      failed="true"
      break
    fi
    changedFiles+=("${file}")
    case "${file}" in
      *.sources)
        # Append the line to every matching stanza that has none
        awk -v key="${keyring}" -v pattern="${pattern}" '
          function flush(   i) {
            for (i = 1; i <= count; i++) print buffer[i]
            if (count > 0 && uris ~ pattern && !signed && !disabled) print "Signed-By: " key
            count = 0; uris = ""; signed = 0; disabled = 0
          }
          /^[ \t]*$/ { flush(); print; next }
          { buffer[++count] = $0 }
          /^#/ { next }
          tolower($1) == "uris:" { uris = $0; sub(/^[^:]*:[ \t]*/, "", uris) }
          tolower($1) == "signed-by:" { signed = 1 }
          tolower($1) == "enabled:" && tolower($2) == "no" { disabled = 1 }
          END { flush() }
        ' "${backupFile}" > "${file}"
        ;;
      *)
        # deb [options] uri ...  ->  deb [options signed-by=key] uri ...
        awk -v key="${keyring}" -v pattern="${pattern}" '
          /^[ \t]*deb(-src)?[ \t]/ && $0 ~ pattern && $0 !~ /signed-by=/ {
            if (match($0, /\[[^]]*\]/)) {
              options = substr($0, RSTART, RLENGTH)
              sub(/\]$/, " signed-by=" key "]", options)
              $0 = substr($0, 1, RSTART - 1) options substr($0, RSTART + RLENGTH)
            } else {
              sub(/^[ \t]*deb(-src)?/, "& [signed-by=" key "]")
            }
          }
          { print }
        ' "${backupFile}" > "${file}"
        ;;
    esac
    echo "INFO Signed-By added in ${file} (backup: ${backupFile})"
  done

  if [[ "${failed}" == "false" ]]; then
    echo "INFO Testing apt with the changed sources..."
    local targetsAfter
    # shellcheck disable=SC2016
    targetsAfter="$(apt-get indextargets --format '$(SITE) $(RELEASE) $(COMPONENT)' 2>/dev/null | sort -u || true)"
    if [[ "${targetsAfter}" != "${targetsBefore}" ]]; then
      warn "The configured package sources changed (a source was lost or added) — a Signed-By edit must not do that"
      failed="true"
    elif ! aptSourcesHealthy "${baselineProblems}"; then
      failed="true"
    fi
  fi

  if [[ "${failed}" == "true" ]]; then
    warn "Rolling back the Signed-By changes"
    for file in "${changedFiles[@]}"; do
      cp -p "$(backupPath "${timestamp}" "${file}")" "${file}"
    done
    apt-get update >/dev/null 2>&1 || warn "apt update still fails after the rollback — check /etc/apt/sources.list.d/"
    return 1
  fi
  echo "INFO Signed-By added and apt tested"
}

# Interactive step for install.sh: list Ubuntu archive sources without Signed-By, ask, then add it.
# Defaults to yes ([Y/n]): on a fresh server the change is tested and rolled back on failure.
# bin/setup-apt-security-source.sh defaults to no ([y/N]), because it runs on servers already in use.
offerSignedByFix() {
  local missing answer
  missing="$(listSourcesWithoutSignedBy)"
  if [[ -z "${missing}" ]]; then
    return 0
  fi

  echo "INFO apt sources without Signed-By (apt prints 'Missing Signed-By' on every update):"
  printf '%s\n' "${missing}" | sed 's/^/     /'
  if [[ ! -t 0 ]]; then
    echo "INFO Not interactive — run later: bin/setup-apt-security-source.sh --fix-signed-by"
    return 0
  fi
  read -rp "Add Signed-By (Ubuntu archive keyring) to these sources and test apt afterwards? [Y/n] " answer
  if [[ "${answer}" =~ ^[nN]$ ]]; then
    echo "INFO Skipped. Run later: bin/setup-apt-security-source.sh --fix-signed-by"
    return 0
  fi
  addSignedByToUbuntuSources || warn "Signed-By not added — the sources are unchanged"
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

  # OPcache is compiled into PHP itself since 8.5 — no php8.5-opcache package exists
  if [[ "$(echo "${phpVersion}" | awk '{print ($1 < 8.5)}')" == "1" ]]; then
    apt --assume-yes install "php${phpVersion}-opcache" \
      || warn "php${phpVersion}-opcache could not be installed — check the apt output above"
  else
    echo "INFO OPcache is built into PHP ${phpVersion}, no separate package needed"
  fi

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