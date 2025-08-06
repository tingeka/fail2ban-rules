#!/bin/bash

command -v fail2ban-client >/dev/null || { echo "fail2ban is not installed"; exit 1; }

set -u

# === Setup Logging ===
LOG_FILE="/var/log/fail2ban-deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Fail2Ban deployment started at $(date) ==="

# === Constants ===
REPO_BASE="https://raw.githubusercontent.com/tingeka/fail2ban-rules/main"
BACKUP_DIR="/etc/fail2ban/backup-$(date +%Y%m%d-%H%M%S)"

# === Defaults ===
SKIP_PROMPT=false
PROFILE=""
ZONE_ID=""
API_TOKEN=""
RULE_NAME=""

# === Argument Parsing ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            SKIP_PROMPT=true
            shift
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --zone-id)
            ZONE_ID="$2"
            shift 2
            ;;
        --api-token)
            API_TOKEN="$2"
            shift 2
            ;;
        --rule-name)
            RULE_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --profile <name> --zone-id <id> --api-token <token> [--yes]"
            exit 1
            ;;
    esac
done

# === Validation ===
if [[ -z "$PROFILE" ]]; then
    echo "✗ Error: --profile is required."
    exit 1
fi

if [[ -z "$ZONE_ID" || -z "$API_TOKEN" || -z "$RULE_NAME" ]]; then
    echo "✗ Error: --zone-id, --api-token, and --rule-name are required with profile '$PROFILE'."
    exit 1
fi

# === Function: Download with optional prompt ===
download_file() {
    local file_path=$1
    local repo_url=$2
    local permissions=$3

    if [ -f "$file_path" ] && [ "$SKIP_PROMPT" = false ]; then
        read -p "File '$file_path' already exists. Overwrite? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Skipping '$file_path'..."
            return 0
        fi
    fi

    echo "Downloading $file_path..."
    if curl -fsSL --retry 3 --retry-connrefused "$repo_url" -o "$file_path"; then
        echo "✓ Downloaded $file_path"
        if [ -n "$permissions" ]; then
            chmod "$permissions" "$file_path" 2>/dev/null || true
            echo "✓ Set permissions to $permissions for $file_path"
        fi
        chown root:root "$file_path" 2>/dev/null || true
        echo "✓ Set ownership to root:root for $file_path"
    else
        echo "✗ Failed to download $file_path"
        return 1
    fi
}

# === Backup Existing Config ===
echo "Creating backup..."
mkdir -p "$BACKUP_DIR"
cp -r /etc/fail2ban/jail.d/* "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/fail2ban/filter.d/* "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/fail2ban/action.d/* "$BACKUP_DIR/" 2>/dev/null || true
echo "✓ Backup created at: $BACKUP_DIR"

# === Download Profile-Specific Files ===
echo -e "\nApplying profile: $PROFILE"

case "$PROFILE" in
    "enfant")
        JAIL_FILE="/etc/fail2ban/jail.d/enfant.conf"
        download_file "/etc/fail2ban/jail.d/enfant.conf" "$REPO_BASE/jail.d/enfant.conf" "640"
        download_file "/etc/fail2ban/filter.d/et-wp-hard.conf" "$REPO_BASE/filter.d/et-wp-hard.conf" "644"
        download_file "/etc/fail2ban/filter.d/et-wp-soft.conf" "$REPO_BASE/filter.d/et-wp-soft.conf" "644"
        download_file "/etc/fail2ban/filter.d/et-wp-extra.conf" "$REPO_BASE/filter.d/et-wp-extra.conf" "644"
        ;;
    "posidonia")
        JAIL_FILE="/etc/fail2ban/jail.d/posidonia.conf"
        download_file "/etc/fail2ban/jail.d/posidonia.conf" "$REPO_BASE/jail.d/posidonia.conf" "640"
        download_file "/etc/fail2ban/filter.d/rp-wp-hard.conf" "$REPO_BASE/filter.d/rp-wp-hard.conf" "644"
        download_file "/etc/fail2ban/filter.d/rp-wp-soft.conf" "$REPO_BASE/filter.d/rp-wp-soft.conf" "644"
        download_file "/etc/fail2ban/filter.d/rp-wp-extra.conf" "$REPO_BASE/filter.d/rp-wp-extra.conf" "644"
        ;;
    *)
        echo "✗ Error: Unknown profile '$PROFILE'"
        exit 1
        ;;
esac

# === Download Common Files ===
echo "Downloading common files..."
download_file "/usr/local/bin/f2b-action-cloudflare-zone.sh" "$REPO_BASE/bin/f2b-action-cloudflare-zone.sh" "755"
download_file "/etc/fail2ban/filter.d/wordpress-wp-login.conf" "$REPO_BASE/filter.d/wordpress-wp-login.conf" "644"
download_file "/etc/fail2ban/filter.d/wordpress-xmlrpc.conf" "$REPO_BASE/filter.d/wordpress-xmlrpc.conf" "644"
download_file "/etc/fail2ban/filter.d/nginx-probing.conf" "$REPO_BASE/filter.d/nginx-probing.conf" "644"
download_file "/etc/fail2ban/action.d/cloudflare-zone.conf" "$REPO_BASE/action.d/cloudflare-zone.conf" "644"

# === Replace Placeholders ===
if [[ -f "$JAIL_FILE" ]]; then
    echo "Injecting zone ID and token into $JAIL_FILE..."
    sed -i "s|{{ZONE_ID}}|$ZONE_ID|g" "$JAIL_FILE"
    sed -i "s|{{API_TOKEN}}|$API_TOKEN|g" "$JAIL_FILE"
    sed -i "s|{{RULE_NAME}}|$RULE_NAME|g" "$JAIL_FILE"
    echo "✓ Injected zone ID, API token, and rule name into $JAIL_FILE"
else
    echo "✗ Jail file not found: $JAIL_FILE"
    exit 1
fi

# === Final Instructions ===
echo -e "\n✓ Deployment complete for profile '$PROFILE'"
echo "▶ Zone ID: $ZONE_ID"
echo "▶ API Token: [REDACTED]"
echo
echo "⚠ You may want to verify the config:"
echo "   fail2ban-client -d"
echo
echo "▶ To apply changes:"
echo "   systemctl restart fail2ban"
echo
echo "▶ To verify status:"
echo "   systemctl status fail2ban"
