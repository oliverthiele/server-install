#!/bin/bash

# bot-policy: storage layer
#
# Owns the on-disk state under BOT_POLICY_DIR:
#   settings.json     — search paths + nginx snippet target path
#   draft.json         — working copy edited by the TUI, never touches nginx
#   active.json          — last activated policy (source of truth for the live nginx snippet)
#   history/<ts>.json      — snapshot of active.json taken on every activation (audit trail, manual rollback)
#
# draft.json / active.json are deliberately separate files (not a single file with
# a "draft" flag per bot) so that "activate" is a single atomic copy — no risk of
# a half-edited bot leaking into the live policy.

BOT_POLICY_DIR="${BOT_POLICY_DIR:-/etc/bot-policy}"

# shellcheck source=./render.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/render.sh"

_botPolicyDraftFile() { echo "${BOT_POLICY_DIR}/draft.json"; }
_botPolicyActiveFile() { echo "${BOT_POLICY_DIR}/active.json"; }
_botPolicySettingsFile() { echo "${BOT_POLICY_DIR}/settings.json"; }
_botPolicyHistoryDir() { echo "${BOT_POLICY_DIR}/history"; }

# Seed active.json/draft.json/settings.json from the repository default catalog.
# No-op if active.json already exists — an existing installation's manual edits
# (or a resumed install.sh run) must never be overwritten.
#
# Usage: seedBotPolicyIfMissing <production|staging> <path-to-default-bots.json>
seedBotPolicyIfMissing() {
  local mode="${1:-production}"
  local repoSeed="${2}"

  if [[ -f "$(_botPolicyActiveFile)" ]]; then
    echo "INFO Bot policy already initialized at ${BOT_POLICY_DIR} — leaving untouched"
    return 0
  fi

  if [[ ! -f "${repoSeed}" ]]; then
    echo "ERROR Seed catalog not found: ${repoSeed}"
    return 1
  fi

  mkdir -p "${BOT_POLICY_DIR}" "$(_botPolicyHistoryDir)"

  local seeded
  if [[ "${mode}" == "staging" ]]; then
    # Staging: block ai-crawler bots too — a system not meant to be public
    # should not be trained on or indexed by AI crawlers either.
    seeded=$(jq '.bots |= map(if .category == "ai-crawler" and .rule == "allow" then .rule = "block_full" else . end)
                 | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "${repoSeed}")
  else
    seeded=$(jq '.updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "${repoSeed}")
  fi

  echo "${seeded}" > "$(_botPolicyActiveFile)"
  echo "${seeded}" > "$(_botPolicyDraftFile)"

  if [[ ! -f "$(_botPolicySettingsFile)" ]]; then
    cat > "$(_botPolicySettingsFile)" <<'EOF'
{
  "schema_version": 1,
  "search_paths": [],
  "nginx_snippet_path": "/etc/nginx/snippets/bot-filter.nginx"
}
EOF
  fi

  chmod 600 "$(_botPolicyActiveFile)" "$(_botPolicyDraftFile)" "$(_botPolicySettingsFile)"

  echo "INFO Bot policy seeded at ${BOT_POLICY_DIR} (mode: ${mode})"

  # First seed only — render the live snippet immediately so a fresh
  # install ends up with a working bot-filter.nginx, same as before this
  # tool existed. Later edits stay in draft.json until an explicit activate.
  local targetFile
  targetFile=$(jq -r '.nginx_snippet_path // "/etc/nginx/snippets/bot-filter.nginx"' "$(_botPolicySettingsFile)")
  renderBotFilterSnippet "$(_botPolicyActiveFile)" "$(_botPolicySettingsFile)" "${targetFile}"
}

# List bots from a policy file as tab-separated lines: id, name, rule, category
listBots() {
  local policyFile="${1:-$(_botPolicyDraftFile)}"
  jq -r '.bots[] | [.id, .name, .rule, .category] | @tsv' "${policyFile}"
}

# Print full metadata for one bot as JSON (for display in the TUI)
getBot() {
  local policyFile="${1}"
  local botId="${2}"
  jq -e --arg id "${botId}" '.bots[] | select(.id == $id)' "${policyFile}"
}

# Change the rule of one bot in draft.json. Fails if the bot id does not exist.
setBotRule() {
  local botId="${1}"
  local rule="${2}"
  local draftFile; draftFile="$(_botPolicyDraftFile)"

  if [[ "${rule}" != "allow" && "${rule}" != "block_search" && "${rule}" != "block_full" && "${rule}" != "always_allow" ]]; then
    echo "ERROR Invalid rule: ${rule}"
    return 1
  fi

  if ! jq -e --arg id "${botId}" '.bots[] | select(.id == $id)' "${draftFile}" >/dev/null; then
    echo "ERROR Unknown bot id: ${botId}"
    return 1
  fi

  local updated
  updated=$(jq --arg id "${botId}" --arg rule "${rule}" \
    '(.bots[] | select(.id == $id) | .rule) = $rule
     | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "${draftFile}")
  echo "${updated}" > "${draftFile}"
}

# Add a new bot to draft.json. user_agent_patterns is passed as one
# comma-separated string and split here; every fragment is validated before
# the bot is written (fail fast, draft.json stays untouched on error).
#
# Usage: addBot <id> <name> <category> <rule> <userAgentPatternsCommaSeparated> [vendor] [infoUrl] [comment]
addBot() {
  local botId="${1}"
  local name="${2}"
  local category="${3}"
  local rule="${4}"
  local userAgentPatternsCsv="${5}"
  local vendor="${6:-}"
  local infoUrl="${7:-}"
  local comment="${8:-}"
  local draftFile; draftFile="$(_botPolicyDraftFile)"

  if [[ ! "${botId}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR Invalid id '${botId}' (allowed: lowercase letters, digits, hyphens)"
    return 1
  fi

  if jq -e --arg id "${botId}" '.bots[] | select(.id == $id)' "${draftFile}" >/dev/null; then
    echo "ERROR Bot id already exists: ${botId}"
    return 1
  fi

  if [[ "${rule}" != "allow" && "${rule}" != "block_search" && "${rule}" != "block_full" && "${rule}" != "always_allow" ]]; then
    echo "ERROR Invalid rule: ${rule}"
    return 1
  fi

  local -a fragments=()
  IFS=',' read -ra fragments <<< "${userAgentPatternsCsv}"

  if [[ "${#fragments[@]}" -eq 0 ]]; then
    echo "ERROR At least one user-agent pattern is required"
    return 1
  fi

  local fragment
  for fragment in "${fragments[@]}"; do
    fragment="$(echo -n "${fragment}" | xargs)" # trim whitespace
    if ! _validateUserAgentPatternFragment "${fragment}"; then
      echo "ERROR Unsafe or too short user-agent pattern: '${fragment}'"
      echo "ERROR Allowed: A-Za-z0-9 space _ - / ! : @ , = plus backslash-escaped regex metacharacters, minimum 3 characters"
      return 1
    fi
  done

  local patternsJson
  patternsJson=$(printf '%s\n' "${fragments[@]}" | jq -R . | jq -s .)

  local newBot
  newBot=$(jq -n \
    --arg id "${botId}" --arg name "${name}" --arg vendor "${vendor}" \
    --arg infoUrl "${infoUrl}" --arg category "${category}" --arg rule "${rule}" \
    --arg comment "${comment}" --argjson patterns "${patternsJson}" \
    '{id: $id, name: $name, vendor: $vendor, info_url: $infoUrl, category: $category,
      respects_robots_txt: false, is_security_scanner: false, is_hacking_tool: false,
      user_agent_patterns: $patterns, matches_empty_user_agent: false,
      rule: $rule, source: "custom", comment: $comment}')

  local updated
  updated=$(jq --argjson bot "${newBot}" \
    '.bots += [$bot] | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "${draftFile}")
  echo "${updated}" > "${draftFile}"
}

# Remove a custom bot from draft.json. Built-in bots (source != "custom")
# cannot be removed — disable them via "block_full" instead, so the catalog
# stays consistent if the seed is ever re-imported.
removeBot() {
  local botId="${1}"
  local draftFile; draftFile="$(_botPolicyDraftFile)"

  local source
  source=$(jq -r --arg id "${botId}" '.bots[] | select(.id == $id) | .source // "built-in"' "${draftFile}")

  if [[ -z "${source}" ]]; then
    echo "ERROR Unknown bot id: ${botId}"
    return 1
  fi
  if [[ "${source}" != "custom" ]]; then
    echo "ERROR '${botId}' is a built-in bot and cannot be removed — set its rule to block_full instead"
    return 1
  fi

  local updated
  updated=$(jq --arg id "${botId}" \
    '.bots |= map(select(.id != $id)) | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "${draftFile}")
  echo "${updated}" > "${draftFile}"
}

listSearchPaths() {
  jq -r '.search_paths[]?' "$(_botPolicySettingsFile)"
}

addSearchPath() {
  local searchPath="${1}"
  local settingsFile; settingsFile="$(_botPolicySettingsFile)"

  if ! _validateSearchPath "${searchPath}"; then
    echo "ERROR Invalid search path: '${searchPath}'"
    echo "ERROR Allowed: absolute literal path, characters A-Za-z0-9 / . _ ~ % -"
    return 1
  fi

  local updated
  updated=$(jq --arg path "${searchPath}" \
    '.search_paths = ((.search_paths // []) + [$path] | unique)' "${settingsFile}")
  echo "${updated}" > "${settingsFile}"
}

removeSearchPath() {
  local searchPath="${1}"
  local settingsFile; settingsFile="$(_botPolicySettingsFile)"

  local updated
  updated=$(jq --arg path "${searchPath}" \
    '.search_paths = ((.search_paths // []) - [$path])' "${settingsFile}")
  echo "${updated}" > "${settingsFile}"
}

# Diff draft.json against active.json: prints "<id> <activeRule> -> <draftRule>"
# for every bot whose rule differs, plus bots only present in one of the files.
diffDraftAgainstActive() {
  local draftFile; draftFile="$(_botPolicyDraftFile)"
  local activeFile; activeFile="$(_botPolicyActiveFile)"

  jq -n --slurpfile draft "${draftFile}" --slurpfile active "${activeFile}" '
    ($draft[0].bots | map({key: .id, value: .rule}) | from_entries) as $d
    | ($active[0].bots | map({key: .id, value: .rule}) | from_entries) as $a
    | ($d | keys) + ($a | keys) | unique | sort
    | map(select($d[.] != $a[.]))
    | map("\(.): \($a[.] // "—") -> \($d[.] // "removed")")
    | .[]' -r
}

# Activate draft.json: snapshot the current active.json to history/, copy
# draft.json over active.json, re-render the nginx snippet, test it, and
# reload nginx. On any failure, active.json and the nginx snippet are rolled
# back to their pre-activation state — a broken draft can never take down a
# running server. Mirrors the backup/test/restore pattern in bin/harden-ssh.sh.
activateBotPolicy() {
  local draftFile; draftFile="$(_botPolicyDraftFile)"
  local activeFile; activeFile="$(_botPolicyActiveFile)"
  local settingsFile; settingsFile="$(_botPolicySettingsFile)"
  local historyDir; historyDir="$(_botPolicyHistoryDir)"

  if [[ ! -f "${draftFile}" ]]; then
    echo "ERROR No draft found: ${draftFile}"
    return 1
  fi

  _validateBotPolicy "${draftFile}" || return 1

  local targetFile
  targetFile=$(jq -r '.nginx_snippet_path // "/etc/nginx/snippets/bot-filter.nginx"' "${settingsFile}")

  mkdir -p "${historyDir}"

  local activeBackup="" nginxBackup=""
  if [[ -f "${activeFile}" ]]; then
    cp "${activeFile}" "${historyDir}/$(date +%Y%m%d-%H%M%S).json"
    activeBackup="${activeFile}.pre-activate"
    cp "${activeFile}" "${activeBackup}"
  fi
  if [[ -f "${targetFile}" ]]; then
    nginxBackup="${targetFile}.pre-activate"
    cp "${targetFile}" "${nginxBackup}"
  fi

  cp "${draftFile}" "${activeFile}"

  if ! renderBotFilterSnippet "${activeFile}" "${settingsFile}" "${targetFile}"; then
    echo "ERROR Rendering failed — rolling back"
    [[ -n "${activeBackup}" ]] && mv "${activeBackup}" "${activeFile}"
    [[ -n "${nginxBackup}" ]] && mv "${nginxBackup}" "${targetFile}"
    return 1
  fi

  local nginxTestLog; nginxTestLog=$(mktemp)
  if ! nginx -t >"${nginxTestLog}" 2>&1; then
    echo "ERROR nginx config test failed:"
    cat "${nginxTestLog}"
    rm -f "${nginxTestLog}"
    [[ -n "${activeBackup}" ]] && mv "${activeBackup}" "${activeFile}"
    if [[ -n "${nginxBackup}" ]]; then
      mv "${nginxBackup}" "${targetFile}"
    else
      rm -f "${targetFile}"
    fi
    echo "ERROR Rolled back — previous bot policy is still active, nothing was reloaded"
    return 1
  fi
  rm -f "${nginxTestLog}"

  rm -f "${activeBackup}" "${nginxBackup}"

  systemctl reload nginx
  echo "INFO Bot policy activated and nginx reloaded"
}
