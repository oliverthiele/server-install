#!/bin/bash

# bot-policy: whiptail-based interactive TUI
#
# All edits here write to draft.json only (via storage.sh) — nothing reaches
# the live nginx config until "Einstellungen aktivieren" is chosen.

_ensureBotPolicyDependencies() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v whiptail >/dev/null 2>&1 || missing+=(whiptail)

  if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ $EUID -ne 0 ]]; then
      echo "ERROR Missing dependencies (${missing[*]}) and not running as root to install them" >&2
      return 1
    fi
    echo "INFO Installing missing dependencies: ${missing[*]}"
    apt-get update -qq && apt-get install -y "${missing[@]}"
  fi
}

_botPolicyRuleLabel() {
  case "${1}" in
    allow) echo "Keine Einschränkung" ;;
    block_search) echo "Suche gesperrt" ;;
    block_full) echo "Komplett gesperrt" ;;
    always_allow) echo "Immer erlaubt" ;;
    *) echo "${1}" ;;
  esac
}

_botPolicyMenuListBots() {
  local draftFile; draftFile="$(_botPolicyDraftFile)"
  local -a menuItems=()
  local id name rule category

  while IFS=$'\t' read -r id name rule category; do
    menuItems+=("${id}" "$(printf '%-30s [%s]' "${name}" "$(_botPolicyRuleLabel "${rule}")")")
  done < <(listBots "${draftFile}")

  if [[ ${#menuItems[@]} -eq 0 ]]; then
    whiptail --msgbox "Keine Bots vorhanden." 8 60
    return
  fi

  local selected
  selected=$(whiptail --title "Bots" --menu "Bot auswählen (Regel bearbeiten)" 22 78 14 "${menuItems[@]}" 3>&1 1>&2 2>&3) || return
  _botPolicyMenuEditBot "${selected}"
}

_botPolicyMenuEditBot() {
  local botId="${1}"
  local draftFile; draftFile="$(_botPolicyDraftFile)"
  local botJson
  botJson=$(getBot "${draftFile}" "${botId}") || { whiptail --msgbox "Bot nicht gefunden." 8 40; return; }

  local name vendor category infoUrl respectsRobots isScanner isHacking comment currentRule
  name=$(jq -r '.name' <<< "${botJson}")
  vendor=$(jq -r '.vendor // ""' <<< "${botJson}")
  category=$(jq -r '.category // ""' <<< "${botJson}")
  infoUrl=$(jq -r '.info_url // ""' <<< "${botJson}")
  respectsRobots=$(jq -r '.respects_robots_txt // false' <<< "${botJson}")
  isScanner=$(jq -r '.is_security_scanner // false' <<< "${botJson}")
  isHacking=$(jq -r '.is_hacking_tool // false' <<< "${botJson}")
  comment=$(jq -r '.comment // ""' <<< "${botJson}")
  currentRule=$(jq -r '.rule' <<< "${botJson}")

  local respectsRobotsLabel="nein / unbekannt"
  [[ "${respectsRobots}" == "true" ]] && respectsRobotsLabel="ja"
  local isScannerLabel="nein"
  [[ "${isScanner}" == "true" ]] && isScannerLabel="ja"
  local isHackingLabel="nein"
  [[ "${isHacking}" == "true" ]] && isHackingLabel="ja"

  local infoText
  infoText="Name: ${name}
Anbieter: ${vendor:-unbekannt}
Kategorie: ${category}
Info-URL: ${infoUrl:--}
Respektiert robots.txt: ${respectsRobotsLabel}
Security-Scanner: ${isScannerLabel}
Bekannt für Missbrauch/Hacking: ${isHackingLabel}
Notiz: ${comment:--}"

  whiptail --title "${name}" --msgbox "${infoText}" 16 70

  local allowOn="OFF" searchOn="OFF" fullOn="OFF" alwaysOn="OFF"
  case "${currentRule}" in
    allow) allowOn="ON" ;;
    block_search) searchOn="ON" ;;
    block_full) fullOn="ON" ;;
    always_allow) alwaysOn="ON" ;;
  esac

  local newRule
  newRule=$(whiptail --title "${name} – Regel wählen" --radiolist \
    "Aktuelle Regel: $(_botPolicyRuleLabel "${currentRule}")" 16 70 4 \
    "allow" "Keine Einschränkung" "${allowOn}" \
    "block_search" "Nur Suche sperren" "${searchOn}" \
    "block_full" "Komplett sperren" "${fullOn}" \
    "always_allow" "Immer erlauben (Monitoring/Test)" "${alwaysOn}" \
    3>&1 1>&2 2>&3) || return

  if [[ "${newRule}" != "${currentRule}" ]]; then
    setBotRule "${botId}" "${newRule}"
    whiptail --msgbox "Regel für ${name} auf \"$(_botPolicyRuleLabel "${newRule}")\" gesetzt (im Entwurf — noch nicht aktiv)." 8 70
  fi
}

_botPolicyMenuAddBot() {
  local id name category rule uaPatterns vendor infoUrl comment

  id=$(whiptail --inputbox "Eindeutige ID (Kleinbuchstaben, Ziffern, Bindestriche):" 10 70 3>&1 1>&2 2>&3) || return
  [[ -z "${id}" ]] && return

  name=$(whiptail --inputbox "Anzeigename:" 10 70 3>&1 1>&2 2>&3) || return
  [[ -z "${name}" ]] && return

  category=$(whiptail --title "Kategorie" --menu "Kategorie wählen:" 18 70 8 \
    "ai-crawler" "KI-Crawler" \
    "search-engine" "Suchmaschine" \
    "seo-tool" "SEO-Tool / kommerzieller Scraper" \
    "scraper" "Sonstiger Scraper" \
    "security-scanner" "Security-Scanner" \
    "monitoring" "Monitoring" \
    "testing" "Test-Tool" \
    "other" "Sonstiges" \
    3>&1 1>&2 2>&3) || return

  uaPatterns=$(whiptail --inputbox "User-Agent-Muster (mehrere mit Komma trennen, z.B. FooBot,foo-crawler). Sonderzeichen müssen als Regex escaped sein (z.B. Indy\\.Library):" 12 70 3>&1 1>&2 2>&3) || return
  if [[ -z "${uaPatterns}" ]]; then
    whiptail --msgbox "Mindestens ein User-Agent-Muster erforderlich." 8 60
    return
  fi

  rule=$(whiptail --title "Regel" --radiolist "Regel wählen:" 16 70 4 \
    "allow" "Keine Einschränkung" ON \
    "block_search" "Nur Suche sperren" OFF \
    "block_full" "Komplett sperren" OFF \
    "always_allow" "Immer erlauben" OFF \
    3>&1 1>&2 2>&3) || return

  vendor=$(whiptail --inputbox "Anbieter (optional):" 10 70 3>&1 1>&2 2>&3) || vendor=""
  infoUrl=$(whiptail --inputbox "Info-URL (optional):" 10 70 3>&1 1>&2 2>&3) || infoUrl=""
  comment=$(whiptail --inputbox "Notiz (optional):" 10 70 3>&1 1>&2 2>&3) || comment=""

  local output
  if ! output=$(addBot "${id}" "${name}" "${category}" "${rule}" "${uaPatterns}" "${vendor}" "${infoUrl}" "${comment}" 2>&1); then
    whiptail --msgbox "Fehler:\n${output}" 14 70
  else
    whiptail --msgbox "Bot \"${name}\" wurde zum Entwurf hinzugefügt (noch nicht aktiv)." 8 70
  fi
}

_botPolicyMenuRemoveBot() {
  local draftFile; draftFile="$(_botPolicyDraftFile)"
  local -a menuItems=()
  local id name

  while IFS=$'\t' read -r id name; do
    menuItems+=("${id}" "${name}")
  done < <(jq -r '.bots[] | select(.source == "custom") | [.id, .name] | @tsv' "${draftFile}")

  if [[ ${#menuItems[@]} -eq 0 ]]; then
    whiptail --msgbox "Keine benutzerdefinierten Bots vorhanden. Eingebaute Bots werden über \"Komplett sperren\" deaktiviert statt entfernt." 10 70
    return
  fi

  local selected
  selected=$(whiptail --title "Bot entfernen" --menu "Welchen benutzerdefinierten Bot entfernen?" 20 70 10 "${menuItems[@]}" 3>&1 1>&2 2>&3) || return

  if whiptail --yesno "Bot \"${selected}\" wirklich aus dem Entwurf entfernen?" 8 60; then
    removeBot "${selected}"
  fi
}

_botPolicyMenuSearchPaths() {
  while true; do
    local current
    current=$(listSearchPaths | paste -sd', ' -)

    local choice
    choice=$(whiptail --title "Such-Pfade" --menu "Aktuell konfiguriert: ${current:-keine}" 16 74 3 \
      "1" "Such-Pfad hinzufügen" \
      "2" "Such-Pfad entfernen" \
      "0" "Zurück" \
      3>&1 1>&2 2>&3) || break

    case "${choice}" in
      1)
        local newPath
        newPath=$(whiptail --inputbox "Such-Pfad, absolut und mit führendem/abschließendem Slash (z.B. /suche/):" 10 70 3>&1 1>&2 2>&3) || continue
        local output
        if ! output=$(addSearchPath "${newPath}" 2>&1); then
          whiptail --msgbox "Fehler:\n${output}" 10 70
        fi
        ;;
      2)
        local -a menuItems=()
        local searchPath
        while IFS= read -r searchPath; do
          menuItems+=("${searchPath}" "")
        done < <(listSearchPaths)

        if [[ ${#menuItems[@]} -eq 0 ]]; then
          whiptail --msgbox "Keine Such-Pfade konfiguriert." 8 50
          continue
        fi

        local selected
        selected=$(whiptail --title "Such-Pfad entfernen" --menu "Zu entfernender Pfad:" 16 70 8 "${menuItems[@]}" 3>&1 1>&2 2>&3) || continue
        removeSearchPath "${selected}"
        ;;
      0) break ;;
    esac
  done
}

_botPolicyMenuDiff() {
  local diffOutput
  diffOutput=$(diffDraftAgainstActive)

  if [[ -z "${diffOutput}" ]]; then
    whiptail --msgbox "Entwurf und aktive Konfiguration sind identisch." 8 60
    return
  fi

  local temporaryFile; temporaryFile=$(mktemp)
  { echo "Unterschiede Entwurf -> Aktiv:"; echo ""; echo "${diffOutput}"; } > "${temporaryFile}"
  whiptail --title "Unterschiede" --textbox "${temporaryFile}" 22 78
  rm -f "${temporaryFile}"
}

_botPolicyMenuReport() {
  local policyFile="${1}"
  local label="${2}"

  local temporaryFile; temporaryFile=$(mktemp)
  generateBotPolicyReport "${policyFile}" "${label}" > "${temporaryFile}"
  whiptail --title "Report" --textbox "${temporaryFile}" 24 78
  rm -f "${temporaryFile}"
}

_botPolicyMenuActivate() {
  local diffOutput
  diffOutput=$(diffDraftAgainstActive)

  local confirmText
  if [[ -n "${diffOutput}" ]]; then
    confirmText="Folgende Änderungen werden aktiv:\n\n${diffOutput}\n\nJetzt aktivieren und nginx neu laden?"
  else
    confirmText="Keine Änderungen gegenüber der aktiven Konfiguration. Trotzdem neu rendern und nginx neu laden?"
  fi

  if whiptail --title "Aktivieren" --yesno "${confirmText}" 20 78; then
    local output
    if output=$(activateBotPolicy 2>&1); then
      whiptail --title "Aktiviert" --msgbox "${output}" 12 70
    else
      whiptail --title "Fehler — Rollback durchgeführt" --msgbox "${output}" 16 78
    fi
  fi
}

# Public entry point
runBotPolicyMenu() {
  _ensureBotPolicyDependencies || return 1

  while true; do
    local choice
    choice=$(whiptail --title "Bot-Policy" --menu "Bot- und Crawler-Regeln verwalten" 20 78 10 \
      "1" "Bots anzeigen / Regel ändern" \
      "2" "Bot hinzufügen" \
      "3" "Benutzerdefinierten Bot entfernen" \
      "4" "Such-Pfade verwalten" \
      "5" "Entwurf vs. aktiv – Unterschiede anzeigen" \
      "6" "Report anzeigen (Entwurf)" \
      "7" "Report anzeigen (aktiv)" \
      "8" "Einstellungen aktivieren" \
      "0" "Beenden" \
      3>&1 1>&2 2>&3) || break

    case "${choice}" in
      1) _botPolicyMenuListBots ;;
      2) _botPolicyMenuAddBot ;;
      3) _botPolicyMenuRemoveBot ;;
      4) _botPolicyMenuSearchPaths ;;
      5) _botPolicyMenuDiff ;;
      6) _botPolicyMenuReport "$(_botPolicyDraftFile)" "Entwurf (noch nicht aktiv)" ;;
      7) _botPolicyMenuReport "$(_botPolicyActiveFile)" "Aktiv" ;;
      8) _botPolicyMenuActivate ;;
      0) break ;;
    esac
  done
}
