#!/usr/bin/env bash

# Restart NUC via Hue smart plug
# Als zowel ping naar Proxmox NUC als HTTP-check van Home Assistant falen.
# Dit script draait elke 5 minuten via cron. Na 3 opeenvolgende failures
# (dus ongeveer 15 minuten) zal de NUC herstarten via de Hue smart plug.

# API key aanmaken door knop op de HUE bridge in te drukken en dan deze curl uit te voeren:
# curl -k -X POST "https://192.168.x.y/api" -H "Content-Type: application/json" \
# -d '{"devicetype":"hue-nuc-watchdog"}'

# PLUG_ID achterhaal je met:
# curl -k "https://192.168.x.y/api/abcdef1234567890abcdef1234567890abcdef12/lights" | jq

set -u

# Hue Bridge instellingen
BRIDGE_IP="192.168.x.y"
HUE_API_KEY="abcdef1234567890abcdef1234567890abcdef12"
PLUG_ID="18"

# Te monitoren NUC en als extra systemen een VM. In dit geval Home Assistant.
NUC_IP="10.0.x.y"
HA_URL="http://192.168.x.y:8123/lovelace/0"

# Watchdog instellingen
FAIL_LIMIT=3              # 3 opeenvolgende failures = bij cron */5 ongeveer 15 minuten
POWER_OFF_SECONDS=5       # Hoe lang de plug uit blijft
COOLDOWN_SECONDS=1800     # Minimale tijd tussen twee herstarts, in seconden

# Timeouts
PING_COUNT=3
PING_TIMEOUT=2
HTTP_TIMEOUT=8

# State files
STATE_DIR="/var/tmp/hue-nuc-watchdog"
FAIL_COUNT_FILE="${STATE_DIR}/both_fail_count"
LAST_RESTART_FILE="${STATE_DIR}/last_restart"

mkdir -p "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

get_fail_count() {
  if [[ -f "$FAIL_COUNT_FILE" ]]; then
    cat "$FAIL_COUNT_FILE"
  else
    echo 0
  fi
}

set_fail_count() {
  echo "$1" > "$FAIL_COUNT_FILE"
}

get_last_restart() {
  if [[ -f "$LAST_RESTART_FILE" ]]; then
    cat "$LAST_RESTART_FILE"
  else
    echo 0
  fi
}

set_last_restart_now() {
  date +%s > "$LAST_RESTART_FILE"
}

hue_set_plug() {
  local state="$1"

  curl -k -sS -X PUT "https://${BRIDGE_IP}/api/${HUE_API_KEY}/lights/${PLUG_ID}/state" \
    -H "Content-Type: application/json" \
    -d "{\"on\":${state}}" >/dev/null
}

check_nuc() {
  ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$NUC_IP" >/dev/null 2>&1
}

check_home_assistant() {
  local http_code

  http_code="$(curl -sS -L \
    --connect-timeout "$HTTP_TIMEOUT" \
    --max-time "$HTTP_TIMEOUT" \
    -o /dev/null \
    -w "%{http_code}" \
    "$HA_URL" 2>/dev/null || echo "000")"

  # Beschouw 2xx, 3xx, 401 en 403 als "reageert".
  # 401/403 kan voorkomen als Home Assistant auth vereist.
  [[ "$http_code" =~ ^2|^3 ]] || [[ "$http_code" == "401" ]] || [[ "$http_code" == "403" ]]
}

restart_nuc_via_plug() {
  log "Herstart NUC via Hue smart plug: plug uit"
  hue_set_plug false

  sleep "$POWER_OFF_SECONDS"

  log "Plug weer aan"
  hue_set_plug true

  set_last_restart_now
  set_fail_count 0

  log "Power-cycle uitgevoerd"
}

main() {
  local nuc_ok=0
  local ha_ok=0

  if check_nuc; then
    nuc_ok=1
    log "OK: Proxmox NUC reageert op ping: ${NUC_IP}"
  else
    log "FAIL: Proxmox NUC reageert niet op ping: ${NUC_IP}"
  fi

  if check_home_assistant; then
    ha_ok=1
    log "OK: Home Assistant reageert: ${HA_URL}"
  else
    log "FAIL: Home Assistant reageert niet: ${HA_URL}"
  fi

  # Belangrijk:
  # Alleen als BEIDE falen, verhogen we de failure counter.
  # Als één van beide nog reageert, resetten we de teller.
  if [[ "$nuc_ok" -eq 0 && "$ha_ok" -eq 0 ]]; then
    local fail_count
    fail_count="$(get_fail_count)"
    fail_count=$((fail_count + 1))
    set_fail_count "$fail_count"

    log "Beide checks falen. Failure count: ${fail_count}/${FAIL_LIMIT}"
  else
    log "Minstens één check reageert nog. Failure count reset naar 0"
    set_fail_count 0
    exit 0
  fi

  if [[ "$fail_count" -lt "$FAIL_LIMIT" ]]; then
    log "Nog geen herstart; beide moeten ${FAIL_LIMIT} opeenvolgende runs falen"
    exit 1
  fi

  local now
  local last_restart
  local elapsed

  now="$(date +%s)"
  last_restart="$(get_last_restart)"
  elapsed=$((now - last_restart))

  if [[ "$elapsed" -lt "$COOLDOWN_SECONDS" ]]; then
    log "Geen herstart: cooldown actief. Nog $((COOLDOWN_SECONDS - elapsed)) seconden"
    exit 1
  fi

  restart_nuc_via_plug
}

main "$@"
