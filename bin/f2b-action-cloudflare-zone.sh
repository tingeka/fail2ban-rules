#!/bin/bash
set -euo pipefail

CMD="${1:-}"
CF_ZONE_ID="${2:-}"
CF_API_TOKEN="${3:-}"
CF_RULE_NAME="${4:-}"
JAIL_NAME="${5:-}"

LOGFILE="/var/log/fail2ban-cloudflare-zone.log"

WORK_DIR="/var/run/fail2ban/cloudflare-zone"

SAFE_ZONE_ID=$(echo "$CF_ZONE_ID" | tr -c 'a-zA-Z0-9' '_')
SAFE_RULE_NAME=$(echo "$CF_RULE_NAME" | tr -c 'a-zA-Z0-9' '_')

RULESET_ID_FILE="${WORK_DIR}/cloudflare-zone-ruleset-id-${SAFE_ZONE_ID}.txt"
RULE_ID_FILE="${WORK_DIR}/cloudflare-rule-id-${SAFE_ZONE_ID}-${SAFE_RULE_NAME}.txt"
LOCK_FILE="${WORK_DIR}/cloudflare-zone-lock-${SAFE_ZONE_ID}.lock"

mkdir -p "$WORK_DIR"

# Logging function
log() {
  local msg="$*"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [f2b-cloudflare-zone] $msg" | tee -a "$LOGFILE" >&2
}

fetch_ruleset_id() {
  if [[ ! -f "$RULESET_ID_FILE" ]]; then
    local id
    log "Fetching ruleset ID from Cloudflare API"
    id=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" | jq -r '.result.id')

    [[ -z "$id" ]] && {
      echo "f2b-action-cloudflare-zone: Unable to fetch ruleset ID" >&2
      log "ERROR: Unable to fetch ruleset ID"
      exit 1
    }

    echo "$id" > "$RULESET_ID_FILE"
    echo "f2b-action-cloudflare-zone: Cached ruleset ID: $id" >&2
    log "Cached ruleset ID: $id"
  else
    log "Using cached ruleset ID from $RULESET_ID_FILE"
  fi
}

get_rule_data() {
  if [[ -f "$RULE_ID_FILE" ]]; then
    local cached_rule_id
    cached_rule_id=$(<"$RULE_ID_FILE")
    if [[ -n "$cached_rule_id" ]]; then
      ruleset_id=$(<"$RULESET_ID_FILE")
      echo "$ruleset_id:$cached_rule_id"
      return 0
    fi
  fi

  local ruleset_id rule_json rule_id
  ruleset_id=$(<"$RULESET_ID_FILE")

  log "Fetching rule data for rule name '$CF_RULE_NAME'"
  rule_json=$(curl --max-time 15 -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/${ruleset_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" | jq --arg name "$CF_RULE_NAME" '.result.rules[] | select(.description == $name)')

  if [[ -z "$rule_json" ]]; then
    log "ERROR: Rule '${CF_RULE_NAME}' not found"
    exit 1
  fi

  rule_id=$(echo "$rule_json" | jq -r '.id')
  echo "$rule_id" > "$RULE_ID_FILE"
  echo "$ruleset_id:$rule_id"
}

build_ip_expression() {
  local ip_list expr
  ip_list=$(fail2ban-client status "$JAIL_NAME" | awk -F':[[:space:]]+' '/Banned IP list/ { print $2 }' || true)

  log "Building IP expression from banned IP list: $ip_list"
  
  echo "$ip_list" \
    | tr ' ' '\n' \
    | grep -E '(^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+$)' \
    | sort -u \
    | paste -sd ' ' - \
    | awk '{print "ip.src in {" $0 "}"}'
}

update_cf_rule() {
  local expr="$1"
  local ruleset_id="$2"
  local rule_id="$3"

  log "Updating Cloudflare rule ID $rule_id with expression: $expr"
  local payload
  payload=$(jq -n \
    --arg action "block" \
    --arg expr "$expr" \
    --arg desc "$CF_RULE_NAME" \
    --argjson enabled true \
    '{action: $action, expression: $expr, description: $desc, enabled: $enabled}')

    # Run the curl PATCH in background, redirect output to logfile
  update_cf_rule() {
  local expr="$1"
  local ruleset_id="$2"
  local rule_id="$3"

  log "Updating Cloudflare rule ID $rule_id with expression: $expr"

  local payload
  payload=$(jq -n \
    --arg action "block" \
    --arg expr "$expr" \
    --arg desc "$CF_RULE_NAME" \
    --argjson enabled true \
    '{action: $action, expression: $expr, description: $desc, enabled: $enabled}')

  {
      echo "$(date '+%Y-%m-%d %H:%M:%S') [f2b-cloudflare-zone] [Background] Sending PATCH request to Cloudflare API"
      local response
      response=$(curl -fsS -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/${ruleset_id}/rules/${rule_id}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "$payload")

      echo "$(date '+%Y-%m-%d %H:%M:%S') [f2b-cloudflare-zone] [Background] CF response: $response"

      if echo "$response" | jq -e '.success' >/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [f2b-cloudflare-zone] [Background] Rule updated successfully."
      else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [f2b-cloudflare-zone] [Background] ERROR: CF update failed:"
        echo "$response" | jq '.errors // .messages // .'
      fi
    } >>"$LOGFILE" 2>&1 &
  }
}

case "$CMD" in
  start)
    log "Command: start"
    fetch_ruleset_id
    get_rule_data
    ;;

  ban|unban)
    log "Command: $CMD"
    exec 200>"$LOCK_FILE"
    flock -x -w 10 200 || {
      log "Could not acquire lock, exiting."
      exit 1
    }

    if [[ ! -f "$RULESET_ID_FILE" || ! -f "$RULE_ID_FILE" ]]; then
      log "Cache files missing, please run start command first."
      exit 1
    fi

    RULESET_ID=$(<"$RULESET_ID_FILE")
    RULE_ID=$(<"$RULE_ID_FILE")
    EXPR="$(build_ip_expression)"
    update_cf_rule "$EXPR" "$RULESET_ID" "$RULE_ID"
  ;;

  stop)
    log "Command: stop - cleaning up"
    rm -f "$RULESET_ID_FILE" "$LOCK_FILE"
    ;;

  *)
    echo "Usage: $0 {start|ban|unban|stop} <zone_id> <api_token> <rule_name> <jail_name>" >&2
    exit 1
    ;;
esac
