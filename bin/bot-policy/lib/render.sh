#!/bin/bash

# bot-policy: nginx snippet renderer
#
# Reads the bot policy (active.json) and the tool settings (settings.json)
# and renders the nginx bot-filter snippet.
#
# nginx "if" directives must never be nested (documented as unreliable), so
# the renderer emits flat flag variables that are combined via string
# concatenation and compared once ($a$b = "11") — the same technique the
# previous hand-written snippet used with a single flag variable.

# --- Validation helpers -----------------------------------------------------

# User-agent fragments are maintained as PRE-ESCAPED PCRE in the JSON file
# (e.g. "Indy\\.Library", "Go!Zilla") — the tool does NOT escape them itself.
# This whitelist is the security boundary: a fragment can never contain an
# unescaped regex metacharacter, so it cannot close the surrounding
# alternation group, add an empty "|" branch (which would match every
# request), or smuggle nginx string syntax ($, ") into the generated config.
_validateUserAgentPatternFragment() {
  local fragment="${1}"
  # Literal characters:      A-Z a-z 0-9 space _ - / ! : @ , =
  # Escaped metacharacters:  \. \+ \? \* \( \) \[ \] \{ \} \| \^ \-
  # Forbidden even escaped:  $ " ' ` ; # and all control characters
  # ($ and " would interfere with nginx quoted-string parsing)
  local allowedPattern='^([A-Za-z0-9 _/!:@,=-]|\\[].+?*()[{}|^-])+$'

  if (( ${#fragment} < 3 )); then
    # 1-2 character fragments would match a huge share of legitimate traffic
    return 1
  fi

  [[ "${fragment}" =~ ${allowedPattern} ]]
}

_validateSearchPath() {
  local searchPath="${1}"
  # Literal absolute URL path only — no regex, no query string. The charset
  # excludes every PCRE metacharacter except "." and everything that nginx
  # string parsing is sensitive to ($, ", spaces, braces, semicolons).
  local allowedPattern='^/[A-Za-z0-9/._~%-]+$'

  [[ "${searchPath}" =~ ${allowedPattern} ]]
}

_escapeSearchPathForRegex() {
  # "." is the only PCRE metacharacter the validated search-path charset
  # can still contain — everything else is already excluded by the whitelist
  printf '%s' "${1}" | sed 's/\./\\./g'
}

# Validate the whole policy file. Fails fast with an ERROR message and a
# non-zero return code; the caller must not write any output file then.
_validateBotPolicy() {
  local policyFile="${1}"

  if ! jq -e '.bots | type == "array"' "${policyFile}" >/dev/null 2>&1; then
    echo "ERROR ${policyFile}: missing or invalid top-level 'bots' array"
    return 1
  fi

  local missingIdCount
  missingIdCount=$(jq '[.bots[] | select((has("id") | not) or (.id | type != "string"))] | length' "${policyFile}")
  if (( missingIdCount > 0 )); then
    echo "ERROR ${policyFile}: ${missingIdCount} bot entry/entries without a string 'id'"
    return 1
  fi

  local duplicateIds
  duplicateIds=$(jq -r '.bots | group_by(.id) | map(select(length > 1) | .[0].id) | join(", ")' "${policyFile}")
  if [[ -n "${duplicateIds}" ]]; then
    echo "ERROR ${policyFile}: duplicate bot id(s): ${duplicateIds}"
    return 1
  fi

  local invalidRuleIds
  invalidRuleIds=$(jq -r '[.bots[] | select(.rule | IN("allow", "block_search", "block_full", "always_allow") | not) | .id] | join(", ")' "${policyFile}")
  if [[ -n "${invalidRuleIds}" ]]; then
    echo "ERROR ${policyFile}: invalid 'rule' value for bot(s): ${invalidRuleIds}"
    return 1
  fi

  # Exactly one entry may claim the empty user agent — two entries with
  # different rules would make the resulting policy ambiguous
  local emptyUaCount
  emptyUaCount=$(jq '[.bots[] | select(.matches_empty_user_agent == true)] | length' "${policyFile}")
  if (( emptyUaCount > 1 )); then
    echo "ERROR ${policyFile}: more than one bot entry has matches_empty_user_agent=true"
    return 1
  fi

  local botIds botId fragments fragment matchesEmptyUa
  mapfile -t botIds < <(jq -r '.bots[].id' "${policyFile}")

  for botId in "${botIds[@]}"; do
    if [[ ! "${botId}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "ERROR Invalid bot id '${botId}' (allowed: lowercase letters, digits, hyphens)"
      return 1
    fi

    mapfile -t fragments < <(jq -r --arg id "${botId}" \
      '.bots[] | select(.id == $id) | .user_agent_patterns[]?' "${policyFile}")
    matchesEmptyUa=$(jq -r --arg id "${botId}" \
      '.bots[] | select(.id == $id) | .matches_empty_user_agent // false' "${policyFile}")

    if (( ${#fragments[@]} == 0 )) && [[ "${matchesEmptyUa}" != "true" ]]; then
      echo "ERROR Bot '${botId}': no user_agent_patterns and matches_empty_user_agent is not true"
      return 1
    fi

    for fragment in "${fragments[@]}"; do
      if ! _validateUserAgentPatternFragment "${fragment}"; then
        echo "ERROR Bot '${botId}': unsafe or too short user_agent_pattern fragment: '${fragment}'"
        echo "ERROR Allowed: A-Za-z0-9 space _ - / ! : @ , = plus backslash-escaped regex metacharacters, minimum 3 characters"
        return 1
      fi
    done
  done

  return 0
}

# --- Rendering --------------------------------------------------------------

# Combine the user_agent_patterns of all bots with the given rule into ONE
# PCRE alternation. An empty result means the caller must omit the whole
# matcher block — an empty "(?:)" group would match every request.
_collectUserAgentAlternation() {
  local policyFile="${1}"
  local rule="${2}"

  jq -r --arg rule "${rule}" \
    '[.bots[] | select(.rule == $rule) | .user_agent_patterns[]?] | unique | join("|")' \
    "${policyFile}"
}

_getEmptyUserAgentRule() {
  local policyFile="${1}"

  jq -r '[.bots[] | select(.matches_empty_user_agent == true) | .rule] | first // "none"' \
    "${policyFile}"
}

# Render the nginx bot-filter snippet.
#
# Usage: renderBotFilterSnippet <policyJsonFile> <settingsJsonFile> [targetFile]
#
# targetFile defaults to nginx_snippet_path from settings.json. The function
# only writes the file — running "nginx -t" and reloading nginx is the
# caller's responsibility (apply step), so a broken policy can never take
# down a running configuration.
renderBotFilterSnippet() {
  local policyFile="${1}"
  local settingsFile="${2}"
  local targetFile="${3:-}"

  if [[ ! -f "${policyFile}" ]]; then
    echo "ERROR Policy file not found: ${policyFile}"
    return 1
  fi
  if [[ ! -f "${settingsFile}" ]]; then
    echo "ERROR Settings file not found: ${settingsFile}"
    return 1
  fi
  if ! jq empty "${policyFile}" 2>/dev/null; then
    echo "ERROR Policy file is not valid JSON: ${policyFile}"
    return 1
  fi
  if ! jq empty "${settingsFile}" 2>/dev/null; then
    echo "ERROR Settings file is not valid JSON: ${settingsFile}"
    return 1
  fi

  if [[ -z "${targetFile}" ]]; then
    targetFile=$(jq -r '.nginx_snippet_path // "/etc/nginx/snippets/bot-filter.nginx"' "${settingsFile}")
  fi

  _validateBotPolicy "${policyFile}" || return 1

  # --- Search paths (literal prefixes from settings.json) ---
  local searchPaths=() searchPath escapedSearchPaths=()
  mapfile -t searchPaths < <(jq -r '.search_paths[]?' "${settingsFile}")

  for searchPath in "${searchPaths[@]}"; do
    if ! _validateSearchPath "${searchPath}"; then
      echo "ERROR Invalid search path in ${settingsFile}: '${searchPath}'"
      echo "ERROR Allowed: absolute literal path, characters A-Za-z0-9 / . _ ~ % -"
      return 1
    fi
    escapedSearchPaths+=("$(_escapeSearchPathForRegex "${searchPath}")")
  done

  local searchPathAlternation=""
  if (( ${#escapedSearchPaths[@]} > 0 )); then
    searchPathAlternation=$(IFS='|'; printf '%s' "${escapedSearchPaths[*]}")
  fi

  # --- Collect one alternation per rule ---
  local blockFullAlternation blockSearchAlternation alwaysAllowAlternation emptyUaRule
  blockFullAlternation=$(_collectUserAgentAlternation "${policyFile}" "block_full")
  blockSearchAlternation=$(_collectUserAgentAlternation "${policyFile}" "block_search")
  alwaysAllowAlternation=$(_collectUserAgentAlternation "${policyFile}" "always_allow")
  emptyUaRule=$(_getEmptyUserAgentRule "${policyFile}")

  if [[ -n "${blockSearchAlternation}" || "${emptyUaRule}" == "block_search" ]] \
    && [[ -z "${searchPathAlternation}" ]]; then
    echo "WARNING block_search bots are configured but settings.json has no search_paths"
    echo "WARNING block_search rules will be no-ops until search_paths are configured"
  fi

  local countAllow countBlockSearch countBlockFull countAlwaysAllow
  countAllow=$(jq '[.bots[] | select(.rule == "allow")] | length' "${policyFile}")
  countBlockSearch=$(jq '[.bots[] | select(.rule == "block_search")] | length' "${policyFile}")
  countBlockFull=$(jq '[.bots[] | select(.rule == "block_full")] | length' "${policyFile}")
  countAlwaysAllow=$(jq '[.bots[] | select(.rule == "always_allow")] | length' "${policyFile}")

  # Write to a temp file in the target directory, then move atomically —
  # nginx never sees a half-written include file
  local temporaryFile
  temporaryFile=$(mktemp "${targetFile}.XXXXXX") || {
    echo "ERROR Cannot create temporary file next to ${targetFile}"
    return 1
  }

  local generatedAt
  generatedAt=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat > "${temporaryFile}" <<EOF
# Bot and Crawler Policy Filter
#
# GENERATED FILE — DO NOT EDIT MANUALLY.
# Manual changes are overwritten on the next bot-policy apply.
# Edit the policy via bin/bot-policy instead.
#
# Generated at: ${generatedAt}
# Policy file:  ${policyFile}
# Rules: ${countBlockFull} block_full, ${countBlockSearch} block_search, ${countAlwaysAllow} always_allow, ${countAllow} allow (unrestricted)
EOF

  cat >> "${temporaryFile}" <<'EOF'

set $bot_block_full 0;
set $bot_block_search 0;
set $bot_search_request 0;
EOF

  if [[ -n "${blockFullAlternation}" ]]; then
    cat >> "${temporaryFile}" <<EOF

# Rule "block_full": blocked on every URL
if (\$http_user_agent ~* "(?:${blockFullAlternation})") {
    set \$bot_block_full 1;
}
EOF
  fi

  if [[ -n "${blockSearchAlternation}" && -n "${searchPathAlternation}" ]]; then
    cat >> "${temporaryFile}" <<EOF

# Rule "block_search": blocked on the configured search URLs only
if (\$http_user_agent ~* "(?:${blockSearchAlternation})") {
    set \$bot_block_search 1;
}
EOF
  fi

  if [[ "${emptyUaRule}" == "block_full" || "${emptyUaRule}" == "block_search" ]]; then
    local emptyUaVariable="bot_block_full"
    if [[ "${emptyUaRule}" == "block_search" ]]; then
      emptyUaVariable="bot_block_search"
    fi
    cat >> "${temporaryFile}" <<EOF

# Empty User-Agent (rule "${emptyUaRule}"): common for cheap scrapers
if (\$http_user_agent = "") {
    set \$${emptyUaVariable} 1;
}
EOF
  fi

  if [[ -n "${searchPathAlternation}" ]]; then
    cat >> "${temporaryFile}" <<EOF

# Search request detection — literal path prefixes from settings.json,
# matched case-sensitively against \$request_uri (includes the query string)
if (\$request_uri ~ "^(?:${searchPathAlternation})") {
    set \$bot_search_request 1;
}
EOF
  fi

  if [[ -n "${alwaysAllowAlternation}" ]]; then
    cat >> "${temporaryFile}" <<EOF

# Rule "always_allow": monitoring and E2E test tools override every block,
# even if their User-Agent accidentally matched a block pattern above
if (\$http_user_agent ~* "(?:${alwaysAllowAlternation})") {
    set \$bot_block_full 0;
    set \$bot_block_search 0;
}
EOF
  fi

  cat >> "${temporaryFile}" <<'EOF'

# Final decision — flags are combined via string concatenation because
# nested "if" directives are unreliable in nginx. The combined value is
# precomputed into its own variable first: comparing "$a$b" directly in an
# "if" condition is rejected by nginx as an "invalid condition" — the
# concatenation must happen in a "set" statement, the "if" then only ever
# compares one single variable.
set $bot_block_search_and_path "${bot_block_search}${bot_search_request}";

if ($bot_block_full = 1) {
    return 444;
}

if ($bot_block_search_and_path = "11") {
    return 444;
}
EOF

  chmod 644 "${temporaryFile}"
  mv "${temporaryFile}" "${targetFile}"

  echo "INFO Bot filter snippet written: ${targetFile}"
  echo "INFO Run 'nginx -t' and reload nginx to activate the new policy"
}
