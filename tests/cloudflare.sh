#!/bin/bash

# CONFIGURATION — replace these with your actual values
CF_ZONE_ID=""
CF_API_TOKEN=""
CF_RULE_NAME="Fail2Ban-Dynamic-Ban-List"
IP_TO_BAN="1.2.3.4, 1.2.3.5, 1.2.5.6"

# WORK DIR
TMPDIR="./tmp/f2b-cloudflare-test"
mkdir -p "$TMPDIR"

CF_RULESET_ID_FILE="$TMPDIR/ruleset-id.txt"
CF_RULESET_FILE="$TMPDIR/ruleset.json"
CF_IP_LIST_FILE="$TMPDIR/ips.txt"
CF_LOCK_FILE="$TMPDIR/lock"

set -euo pipefail

echo "=== [1] Fetching Cloudflare ruleset for zone: $CF_ZONE_ID ==="
RULESET_METADATA=$(curl -fsS -X GET \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint" \
  -H "Authorization: Bearer $CF_API_TOKEN")

RULESET_ID=$(echo "$RULESET_METADATA" | jq -r '.result.id')
echo "$RULESET_ID" > "$CF_RULESET_ID_FILE"

RULESET=$(curl -fsS -X GET \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/$RULESET_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN")
echo "$RULESET" > "$CF_RULESET_FILE"

echo "[✓] Ruleset ID: $RULESET_ID"
echo

echo "=== [2] Banning IP(s): $IP_TO_BAN ==="

exec 200>"$CF_LOCK_FILE"
flock 200

> "$CF_IP_LIST_FILE"

# Normalize and write IPs to file
if [[ "$IP_TO_BAN" == *","* ]]; then
  echo "$IP_TO_BAN" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' >> "$CF_IP_LIST_FILE"
else
  echo "$IP_TO_BAN" >> "$CF_IP_LIST_FILE"
fi

sort -u "$CF_IP_LIST_FILE" -o "$CF_IP_LIST_FILE"

# Build a space-separated list of IPs (no commas, no quotes)
FULL_IP_LIST_SPACE=$(paste -sd " " "$CF_IP_LIST_FILE")
[ -z "$FULL_IP_LIST_SPACE" ] && FULL_IP_LIST_SPACE="127.0.0.1"

NEW_EXPR="ip.src in {$FULL_IP_LIST_SPACE}"

# Extract rule from ruleset
RULE_JSON=$(echo "$RULESET" | jq --arg name "$CF_RULE_NAME" '.result.rules[] | select(.description == $name)')
if [ -z "$RULE_JSON" ]; then
  echo "[ERROR] Rule with description '$CF_RULE_NAME' not found." >&2
  exit 1
fi

RULE_ID=$(echo "$RULE_JSON" | jq -r '.id')
RULE_VERSION=$(echo "$RULE_JSON" | jq -r '.version')

echo "[✓] Rule ID: $RULE_ID"
echo "[✓] Current version: $RULE_VERSION"
echo "[✓] New expression: $NEW_EXPR"
echo

# Build the full patch payload, including description
PATCH_PAYLOAD=$(jq -n \
  --arg action      "block" \
  --arg expr        "$NEW_EXPR" \
  --arg desc        "$CF_RULE_NAME" \
  --argjson enabled true \
  '{
     action:      $action,
     expression:  $expr,
     description: $desc,
     enabled:     $enabled
   }'
)

echo "[DEBUG] PATCH payload:"
echo "$PATCH_PAYLOAD" | jq '.'

RESPONSE=$(curl -fsS -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/$RULESET_ID/rules/$RULE_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "$(echo "$PATCH_PAYLOAD" | jq -c '.')")

echo "$RESPONSE" > "$TMPDIR/patch-response.json"

if echo "$RESPONSE" | jq -e '.success' > /dev/null; then
  echo "[✓] Rule updated successfully."
else
  echo "[ERROR] Failed to update rule:"
  echo "$RESPONSE" | jq '.errors // .messages // .'
  exit 1
fi

echo "=== Done ==="