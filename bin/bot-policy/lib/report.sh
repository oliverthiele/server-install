#!/bin/bash

# bot-policy: human-readable report generator
#
# Produces a German plain-text summary grouped by rule — meant to be copied
# straight into a customer email, either as a proposal (draft.json, before
# activation) or as a record of what is actually live (active.json).

_botPolicyReportSection() {
  local title="${1}"
  local rule="${2}"
  local policyFile="${3}"

  local entries
  entries=$(jq -r --arg rule "${rule}" '
    .bots[] | select(.rule == $rule)
    | "- " + .name
      + (if (.vendor // "") != "" then " (" + .vendor + ")" else "" end)
      + (if (.comment // "") != "" then ": " + .comment else "" end)
  ' "${policyFile}")

  echo "== ${title} =="
  if [[ -z "${entries}" ]]; then
    echo "(keine Einträge)"
  else
    echo "${entries}"
  fi
  echo ""
}

# Usage: generateBotPolicyReport <policyJsonFile> <label>
# label is shown in the header, e.g. "Entwurf (noch nicht aktiv)" or "Aktiv seit ..."
generateBotPolicyReport() {
  local policyFile="${1}"
  local label="${2:-Entwurf}"

  if [[ ! -f "${policyFile}" ]]; then
    echo "ERROR Policy file not found: ${policyFile}"
    return 1
  fi

  local updatedAt
  updatedAt=$(jq -r '.updated_at // "unbekannt"' "${policyFile}")

  echo "Bot- und Crawler-Regeln — ${label}"
  echo "Stand: ${updatedAt}"
  echo ""

  _botPolicyReportSection "Komplett gesperrt" "block_full" "${policyFile}"
  _botPolicyReportSection "Suche gesperrt (übrige Seite bleibt erreichbar)" "block_search" "${policyFile}"
  _botPolicyReportSection "Keine Einschränkung" "allow" "${policyFile}"
  _botPolicyReportSection "Immer erlaubt (Monitoring/Test-Tools)" "always_allow" "${policyFile}"
}
