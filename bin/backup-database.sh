#!/bin/bash

# backup-database.sh – local MariaDB dumps as a safety net against operator errors
#
# SCOPE: This backup protects against OPERATOR ERRORS only — accidental deletions,
# broken deployments, failed updates. It does NOT protect against server compromise,
# ransomware, or data center failure: a backup on the same machine is worthless in
# those cases. Combine it with an off-site strategy the server cannot delete
# (pull-based backups, or push with append-only credentials + storage-side snapshots,
# e.g. restic to a Hetzner Storage Box; Hetzner Cloud Backups are also stored
# outside the server). See README section "Database Backup".
#
# What it does:
#   - Dumps every non-system database to ${BACKUP_DIRECTORY}, gzip-compressed
#   - Full schema of ALL tables, but no DATA for log/cache/session tables
#     (sys_log, sys_history, cache_*, be_sessions, fe_sessions — see below)
#   - Checks free disk space against the estimated dump size before writing
#   - Deletes dumps older than ${RETENTION_DAYS} days
#
# Credentials: read from /root/.my.cnf (written by the installer via secureMariaDB()).
#
# Usage:
#   bin/backup-database.sh                    # Run one backup now
#   bin/backup-database.sh --dry-run          # Show databases, sizes, excluded tables — no dump
#   bin/backup-database.sh --install-cron     # Install /etc/cron.d/typo3-db-backup (every 6 h) + run once
#   bin/backup-database.sh --install-cron=12  # Same, but every 12 hours (allowed: 1-24)

set -eo pipefail

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"

# ── Configuration (override via environment or edit here) ─────────────────────

BACKUP_DIRECTORY="${BACKUP_DIRECTORY:-/var/backups/mysql}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Tables whose DATA is excluded from the dump (schema is always included, so the
# tables exist — empty — after a restore and TYPO3 starts right away):
#   sys_log      – pure log, often the largest table, no restore value
#   sys_history  – editors' change history ("rollback" in the backend). Excluded by
#                  default to keep dumps small; REMOVE it from this list if your
#                  editors rely on record history after a restore.
#   be_sessions / fe_sessions – transient login sessions
EXCLUDED_TABLE_NAMES=(sys_log sys_history be_sessions fe_sessions)

# Same, as SQL LIKE patterns: all TYPO3 cache tables (rebuilt automatically)
EXCLUDED_TABLE_PATTERNS=('cache\_%')

# Estimated gzipped dump size = included data+index bytes * this factor.
# Real-world gzipped SQL dumps land at 15-40 % of table size; 50 % is conservative.
ESTIMATE_FACTOR_PERCENT=50
# Additional headroom that must remain free AFTER the dump (in MB)
HEADROOM_MB=200

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=false
INSTALL_CRON=false
CRON_INTERVAL_HOURS=6
for arg in "$@"; do
  case $arg in
    --dry-run)         DRY_RUN=true ;;
    --install-cron)    INSTALL_CRON=true ;;
    --install-cron=*)  INSTALL_CRON=true; CRON_INTERVAL_HOURS="${arg#*=}" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if ! [[ "${CRON_INTERVAL_HOURS}" =~ ^[0-9]+$ ]] || [[ ${CRON_INTERVAL_HOURS} -lt 1 ]] || [[ ${CRON_INTERVAL_HOURS} -gt 24 ]]; then
  die "Invalid cron interval: ${CRON_INTERVAL_HOURS} (allowed: 1-24 hours)"
fi

# ── Privilege and connectivity checks ─────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (reads /root/.my.cnf)"
fi

if ! mysql -N -B -e "SELECT 1" >/dev/null 2>&1; then
  die "Cannot connect to MariaDB — check /root/.my.cnf"
fi

# ── Helper: build SQL fragments from the exclusion lists ──────────────────────

# Comma-separated quoted list for IN (...): 'sys_log','sys_history',...
excludedNameList=""
for tableName in "${EXCLUDED_TABLE_NAMES[@]}"; do
  excludedNameList+=",'${tableName}'"
done
excludedNameList="${excludedNameList#,}"

# OR-chained LIKE conditions for the patterns
excludedLikeConditions=""
for tablePattern in "${EXCLUDED_TABLE_PATTERNS[@]}"; do
  excludedLikeConditions+=" OR table_name LIKE '${tablePattern}'"
done

# ── Install cron job (optional) ───────────────────────────────────────────────

if [[ "${INSTALL_CRON}" == "true" ]]; then
  cronFile="/etc/cron.d/typo3-db-backup"
  scriptPath="${SCRIPT_DIR}/backup-database.sh"
  logFile="/var/log/typo3-db-backup.log"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: would write ${cronFile} (every ${CRON_INTERVAL_HOURS} h, log: ${logFile})"
  else
    cat > "${cronFile}" <<EOF
# TYPO3 database backup — managed by ServerInstall (bin/backup-database.sh --install-cron)
# Local safety net against operator errors only — see README section "Database Backup".
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 */${CRON_INTERVAL_HOURS} * * * root ${scriptPath} >> ${logFile} 2>&1
EOF
    chmod 0644 "${cronFile}"
    echo "INFO Cron job installed: ${cronFile} (every ${CRON_INTERVAL_HOURS} h at minute 17)"
    echo "INFO Log file: ${logFile}"
  fi
fi

# ── Collect databases ─────────────────────────────────────────────────────────

databaseNames=()
while IFS= read -r databaseName; do
  case "${databaseName}" in
    information_schema|performance_schema|mysql|sys) continue ;;
  esac
  databaseNames+=("${databaseName}")
done < <(mysql -N -B -e "SHOW DATABASES")

if [[ ${#databaseNames[@]} -eq 0 ]]; then
  warn "No non-system databases found — nothing to back up"
  exit 0
fi

# ── Prepare backup directory ──────────────────────────────────────────────────

if [[ "${DRY_RUN}" != "true" ]]; then
  mkdir -p "${BACKUP_DIRECTORY}"
  chmod 0700 "${BACKUP_DIRECTORY}"
fi

timestamp=$(date +%Y%m%d-%H%M%S)
exitCode=0

# ── Dump each database ────────────────────────────────────────────────────────

for databaseName in "${databaseNames[@]}"; do

  # Tables from the exclusion lists that actually exist in this database
  excludedTables=()
  while IFS= read -r tableName; do
    [[ -n "${tableName}" ]] && excludedTables+=("${tableName}")
  done < <(mysql -N -B -e "SELECT table_name FROM information_schema.tables \
    WHERE table_schema='${databaseName}' \
    AND (table_name IN (${excludedNameList})${excludedLikeConditions});")

  # Size of the data that WILL be dumped (data + index of included tables)
  includedBytes=$(mysql -N -B -e "SELECT COALESCE(SUM(data_length+index_length),0) \
    FROM information_schema.tables \
    WHERE table_schema='${databaseName}' \
    AND NOT (table_name IN (${excludedNameList})${excludedLikeConditions});")

  estimatedDumpBytes=$(( includedBytes * ESTIMATE_FACTOR_PERCENT / 100 ))
  requiredBytes=$(( estimatedDumpBytes + HEADROOM_MB * 1024 * 1024 ))

  # Free space on the filesystem holding the backup directory (parent if not created yet)
  spaceCheckPath="${BACKUP_DIRECTORY}"
  [[ -d "${spaceCheckPath}" ]] || spaceCheckPath=$(dirname "${BACKUP_DIRECTORY}")
  freeBytes=$(( $(df -Pk "${spaceCheckPath}" | awk 'NR==2 {print $4}') * 1024 ))

  targetFile="${BACKUP_DIRECTORY}/${databaseName}-${timestamp}.sql.gz"

  echo "INFO Database ${databaseName}: $((includedBytes / 1024 / 1024)) MB included data," \
    "estimated dump ~$((estimatedDumpBytes / 1024 / 1024)) MB," \
    "free $((freeBytes / 1024 / 1024)) MB"
  if [[ ${#excludedTables[@]} -gt 0 ]]; then
    echo "INFO Data excluded (schema kept): ${excludedTables[*]}"
  fi

  if [[ ${freeBytes} -lt ${requiredBytes} ]]; then
    warn "Not enough free space for ${databaseName}: need ~$((requiredBytes / 1024 / 1024)) MB" \
      "(incl. ${HEADROOM_MB} MB headroom), have $((freeBytes / 1024 / 1024)) MB — skipping"
    exitCode=1
    continue
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: would write ${targetFile}"
    continue
  fi

  # --ignore-table arguments for the data pass
  ignoreTableArguments=()
  for tableName in "${excludedTables[@]}"; do
    ignoreTableArguments+=("--ignore-table=${databaseName}.${tableName}")
  done

  # Two passes into one file:
  #   1. schema of ALL tables (+ routines/events/triggers) — excluded tables exist after restore
  #   2. data of all tables except the excluded ones
  # --single-transaction: consistent InnoDB snapshot without locking
  # --quick: row-by-row streaming instead of buffering whole tables in RAM
  if {
    mysqldump --single-transaction --quick --no-data --routines --events --triggers "${databaseName}"
    mysqldump --single-transaction --quick --no-create-info --skip-triggers \
      "${ignoreTableArguments[@]}" "${databaseName}"
  } | gzip -6 > "${targetFile}"; then
    chmod 0600 "${targetFile}"
    echo "INFO Backup written: ${targetFile} ($(du -h "${targetFile}" | cut -f1))"
  else
    rm -f "${targetFile}"
    warn "Dump of ${databaseName} FAILED — incomplete file removed"
    exitCode=1
  fi
done

# ── Retention: delete old dumps ───────────────────────────────────────────────

if [[ "${DRY_RUN}" != "true" ]]; then
  deletedCount=$(find "${BACKUP_DIRECTORY}" -maxdepth 1 -name "*.sql.gz" \
    -mtime "+${RETENTION_DAYS}" -print -delete | wc -l | tr -d ' ')
  if [[ "${deletedCount}" -gt 0 ]]; then
    echo "INFO Retention: deleted ${deletedCount} dump(s) older than ${RETENTION_DAYS} days"
  fi
fi

if [[ ${exitCode} -ne 0 ]]; then
  warn "Backup finished with errors (see above)"
fi
exit "${exitCode}"
