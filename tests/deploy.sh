#!/bin/bash

# ==============================================================================
# This is a test version of the fail2ban deployment script.
# It is designed to verify the download logic and file paths
# without modifying any system directories or files.
#
# It downloads files to a local 'downloads' directory.
# ==============================================================================

set -u

# === Setup Logging ===
# Log file is now local to the script's execution directory
LOG_FILE="./tests_deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Test download script started at $(date) ==="

# === Constants ===
# Repository base URL remains the same
REPO_BASE="https://raw.githubusercontent.com/tingeka/fail2ban-rules/main"
# Local base directory for downloads
DOWNLOAD_BASE_DIR="./tmp"

# === Defaults ===
# Same arguments as the original script
SKIP_PROMPT=false
PROFILE="enfant"
ZONE_ID="test_zone_id"
API_TOKEN="test_api_token"

# === Argument Parsing ===
# Argument parsing is identical to the original script
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
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --profile <name> --zone-id <id> --api-token <token> [--yes]"
            exit 1
            ;;
    esac
done

# === Validation ===
# Validation logic is kept to match the original script's behavior
if [[ -z "$PROFILE" ]]; then
    echo "✗ Error: --profile is required."
    exit 1
fi

if [[ -z "$ZONE_ID" || -z "$API_TOKEN" ]]; then
    echo "✗ Error: --zone-id and --api-token are required with profile '$PROFILE'."
    echo "→ You must either:"
    echo "   1. Provide them via CLI: --zone-id ... --api-token ..."
    echo "   2. Manually update the placeholders in: /etc/fail2ban/jail.d/${PROFILE}.conf"
    # Exit here to simulate the original script's behavior without making changes.
    # We won't be using these values in this test script.
    exit 1
fi

# === Function: Download with optional prompt ===
# Modified to create local directories and save files locally
download_file() {
    local relative_path=$1
    local repo_url=$2
    local permissions=$3

    local local_file_path="$DOWNLOAD_BASE_DIR/$relative_path"
    local local_dir=$(dirname "$local_file_path")

    # Ensure the local directory exists
    mkdir -p "$local_dir"

    if [ -f "$local_file_path" ] && [ "$SKIP_PROMPT" = false ]; then
        read -p "File '$local_file_path' already exists. Overwrite? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Skipping '$local_file_path'..."
            return 0
        fi
    fi

    echo "Downloading to $local_file_path..."
    if curl -fsSL --retry 3 --retry-connrefused "$repo_url" -o "$local_file_path"; then
        echo "✓ Downloaded $local_file_path"
        # Permissions are not set in this test script as it's not a deployment
        # and we don't want to rely on the user having sudo permissions.
    else
        echo "✗ Failed to download $local_file_path"
        return 1
    fi
}

# === Download Profile-Specific Files ===
echo -e "\nApplying profile: $PROFILE"

# Case statement is the same, but the download paths are now relative
# to the local 'downloads' directory.
case "$PROFILE" in
    "enfant")
        download_file "filter.d/et-wp-hard.conf" "$REPO_BASE/filter.d/et-wp-hard.conf" "644"
        download_file "filter.d/et-wp-soft.conf" "$REPO_BASE/filter.d/et-wp-soft.conf" "644"
        download_file "filter.d/et-wp-extra.conf" "$REPO_BASE/filter.d/et-wp-extra.conf" "644"
        download_file "jail.d/enfant.conf" "$REPO_BASE/jail.d/enfant.conf" "640"
        ;;
    "posidonia")
        download_file "filter.d/rp-wp-hard.conf" "$REPO_BASE/filter.d/rp-wp-hard.conf" "644"
        download_file "filter.d/rp-wp-soft.conf" "$REPO_BASE/filter.d/rp-wp-soft.conf" "644"
        download_file "filter.d/rp-wp-extra.conf" "$REPO_BASE/filter.d/rp-wp-extra.conf" "644"
        download_file "jail.d/posidonia.conf" "$REPO_BASE/jail.d/posidonia.conf" "640"
        ;;
    *)
        echo "✗ Error: Unknown profile '$PROFILE'"
        exit 1
        ;;
esac

# === Download Common Files ===
echo "Downloading common files..."
download_file "action.d/cloudflare-zone.conf" "$REPO_BASE/action.d/cloudflare-zone.conf" "644"

# === Final Instructions ===
echo -e "\n✓ Test download complete for profile '$PROFILE'"
echo "▶ Files have been downloaded to the '$DOWNLOAD_BASE_DIR' directory."
echo
echo "▶ To inspect the downloaded files, you can run:"
echo "   ls -R $DOWNLOAD_BASE_DIR"
echo
echo "▶ To run the script with a profile, e.g.:"
echo "   ./test_script.sh --profile enfant --zone-id 'some-id' --api-token 'some-token'"
