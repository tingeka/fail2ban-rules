#!/bin/bash
set -euo pipefail

# Arguments (passed by Fail2Ban)
CMD="${1:-}"
CF_ZONE_ID="${2:-}"
CF_API_TOKEN="${3:-}"
CF_RULE_NAME="${4:-}"
JAIL_NAME="${5:-}"
IP_ADDR="${6:-}"

# Logging and working directories
LOGFILE="/var/log/fail2ban-cloudflare-zone.log"
WORK_DIR="/var/run/fail2ban/cloudflare-zone"
SAFE_ZONE_ID=$(echo "$CF_ZONE_ID" | tr -c 'a-zA-Z0-9' '_')
SAFE_RULE_NAME=$(echo "$CF_RULE_NAME" | tr -c 'a-zA-Z0-9' '_')
RULESET_ID_FILE="$WORK_DIR/cloudflare-zone-ruleset-id-${SAFE_ZONE_ID}.txt"
RULE_ID_FILE="$WORK_DIR/cloudflare-rule-id-${SAFE_ZONE_ID}-${SAFE_RULE_NAME}.txt"
BAN_LIST_FILE="$WORK_DIR/cloudflare-banned-ips-${SAFE_ZONE_ID}.txt"
LOCK_FILE="$WORK_DIR/cloudflare-zone-lock-${SAFE_ZONE_ID}.lock"
API_TIMEOUT=12

mkdir -p "$WORK_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [f2b-cloudflare-zone] $*" | tee -a "$LOGFILE" >&2
}

error_exit() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  log "Received termination signal, cleaning up..."
  exit 130
}
trap cleanup TERM INT

check_dependencies() {
  for cmd in curl jq flock; do
    command -v "$cmd" >/dev/null || error_exit "Missing required tool: $cmd"
  done
}

fetch_ruleset_id() {
  if [[ ! -f "$RULESET_ID_FILE" ]] || (( $(date +%s) - $(stat -c %Y "$RULESET_ID_FILE") > 3600 )); then
    log "Fetching ruleset ID"
    response=$(timeout $API_TIMEOUT curl -fsS \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint")
    id=$(echo "$response" | jq -r '.result.id // empty')
    [[ -n "$id" ]] || error_exit "Failed to get ruleset ID"
    echo "$id" > "$RULESET_ID_FILE"
    log "Cached ruleset ID: $id"
  else
    log "Using cached ruleset ID"
  fi
}

get_rule_id() {
  local ruleset_id
  ruleset_id=$(<"$RULESET_ID_FILE")
  if [[ ! -f "$RULE_ID_FILE" ]] || (( $(date +%s) - $(stat -c %Y "$RULE_ID_FILE") > 3600 )); then
    log "Fetching rule ID for '$CF_RULE_NAME'"
    response=$(timeout $API_TIMEOUT curl -fsS \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/$ruleset_id")
    rule_id=$(echo "$response" | jq -r --arg name "$CF_RULE_NAME" '.result.rules[] | select(.description == $name) | .id')
    [[ -n "$rule_id" ]] || error_exit "Failed to get rule ID"
    echo "$rule_id" > "$RULE_ID_FILE"
    log "Cached rule ID: $rule_id"
  else
    log "Using cached rule ID"
  fi
}

clear_cf_rule() {
  local ruleset_id rule_id response
  ruleset_id=$(<"$RULESET_ID_FILE")
  rule_id=$(<"$RULE_ID_FILE")
  log "Clearing Cloudflare rule to 'no bans'"
  response=$(timeout $API_TIMEOUT curl -fsS -X PATCH \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"action":"block","expression":"ip.src eq 0.0.0.0","description":"'"$CF_RULE_NAME"'","enabled":true}' \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/$ruleset_id/rules/$rule_id")
  [[ $(echo "$response" | jq -r '.success') == true ]] || error_exit "Failed to clear Cloudflare rule"
  log "Cloudflare rule cleared"
}

build_expression() {
  if [[ -s "$BAN_LIST_FILE" ]]; then
    paste -sd' ' "$BAN_LIST_FILE" | awk '{ printf("ip.src in {%s}\n", $0) }'
  else
    echo "ip.src eq 0.0.0.0"
  fi
}

update_cf_rule() {
  local expr ruleset_id rule_id response
  expr="$1"
  ruleset_id=$(<"$RULESET_ID_FILE")
  rule_id=$(<"$RULE_ID_FILE")
  log "Updating Cloudflare rule '$rule_id' with expr: $expr"
  response=$(timeout $API_TIMEOUT curl -fsS -X PATCH \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"action":"block","expression":"'"$expr"'","description":"'"$CF_RULE_NAME"'","enabled":true}' \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/$ruleset_id/rules/$rule_id")
  [[ $(echo "$response" | jq -r '.success') == true ]] || error_exit "Cloudflare update failed"
  log "Cloudflare rule updated successfully"
}

main() {
  check_dependencies

  case "$CMD" in
    start)
      fetch_ruleset_id
      get_rule_id
      clear_cf_rule
      # Do NOT touch BAN_LIST_FILE here
      exit 0
      ;;
    ban)
      exec 200>"$LOCK_FILE" && flock -x 200
      grep -Fxq "$IP_ADDR" "$BAN_LIST_FILE" 2>/dev/null || echo "$IP_ADDR" >> "$BAN_LIST_FILE"
      ;;
    unban)
      exec 200>"$LOCK_FILE" && flock -x 200
      if grep -Fxq "$IP_ADDR" "$BAN_LIST_FILE"; then
        grep -Fxv "$IP_ADDR" "$BAN_LIST_FILE" > "${BAN_LIST_FILE}.tmp"
        mv "${BAN_LIST_FILE}.tmp" "$BAN_LIST_FILE"
      fi
      ;;
    stop)
      log "Stopping and cleaning up"
      rm -f "$BAN_LIST_FILE" "$LOCK_FILE"
      exit 0
      ;;
    *)
      echo "Usage: $0 {start|ban|unban|stop} <zone_id> <api_token> <rule_name> <jail_name> <ip>" >&2
      exit 1
      ;;
  esac

  # on ban/unban, ensure IDs are cached then patch Cloudflare
  fetch_ruleset_id
  get_rule_id
  expr=$(build_expression)
  update_cf_rule "$expr"
}

main "$@"