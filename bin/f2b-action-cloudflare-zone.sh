#!/bin/bash
set -euo pipefail

CMD="${1:-}"
CF_ZONE_ID="${2:-}"
CF_API_TOKEN="${3:-}"
CF_RULE_NAME="${4:-}"
JAIL_NAME="${5:-}"

WORK_DIR="/var/run/fail2ban/cloudflare-zone"
RULESET_ID_FILE="${WORK_DIR}/cloudflare-zone-ruleset-id.txt"
LOCK_FILE="${WORK_DIR}/cloudflare-zone-lock"

mkdir -p "$WORK_DIR"

fetch_ruleset_id() {
  if [[ ! -f "$RULESET_ID_FILE" ]]; then
    local id
    id=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" | jq -r '.result.id')

    [[ -z "$id" ]] && {
      echo "f2b-cloudflare-zones: Unable to fetch ruleset ID" >&2
      exit 1
    }

    echo "$id" > "$RULESET_ID_FILE"
    echo "f2b-cloudflare-zones: Cached ruleset ID: $id" >&2
  fi
}

get_rule_data() {
  local ruleset_id rule_json rule_id
  ruleset_id=$(<"$RULESET_ID_FILE")

  rule_json=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/${ruleset_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" | jq --arg name "$CF_RULE_NAME" '.result.rules[] | select(.description == $name)')

  [[ -z "$rule_json" ]] && {
    echo "f2b-cloudflare-zones: Rule '${CF_RULE_NAME}' not found" >&2
    exit 1
  }

  rule_id=$(echo "$rule_json" | jq -r '.id')
  echo "$ruleset_id:$rule_id"
}

build_ip_expression() {
  local ip_list expr
  ip_list=$(fail2ban-client status "$JAIL_NAME" | awk -F':[[:space:]]+' '/Banned IP list/ { print $2 }' || true)

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

  local payload
  payload=$(jq -n \
    --arg action "block" \
    --arg expr "$expr" \
    --arg desc "$CF_RULE_NAME" \
    --argjson enabled true \
    '{action: $action, expression: $expr, description: $desc, enabled: $enabled}')

  local response
  response=$(curl -fsS -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/${ruleset_id}/rules/${rule_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "$payload")

  if echo "$response" | jq -e '.success' >/dev/null; then
    echo "f2b-cloudflare-zones: Rule updated successfully." >&2
  else
    echo "f2b-cloudflare-zones: CF update failed:" >&2
    echo "$response" | jq '.errors // .messages // .' >&2
  fi
}

case "$CMD" in
  start)
    fetch_ruleset_id
    ;;

  ban|unban)
    exec 200>"$LOCK_FILE"
    flock -x 200

    fetch_ruleset_id
    IFS=":" read -r RULESET_ID RULE_ID <<< "$(get_rule_data)"
    EXPR="$(build_ip_expression)"
    update_cf_rule "$EXPR" "$RULESET_ID" "$RULE_ID"
    ;;

  stop)
    rm -f "$RULESET_ID_FILE" "$LOCK_FILE"
    ;;

  *)
    echo "Usage: $0 {start|ban|unban|stop} <zone_id> <api_token> <rule_name> <jail_name>" >&2
    exit 1
    ;;
esac
