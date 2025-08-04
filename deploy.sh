#!/bin/bash

# Cloudflare Fail2ban Deployment Script with Overwrite Prompt

# The base URL for the configuration files on GitHub
REPO_BASE="https://raw.githubusercontent.com/tingeka/fail2ban-rules/main"

# The directory to store backups, timestamped for uniqueness
BACKUP_DIR="/etc/fail2ban/backup-$(date +%Y%m%d-%H%M%S)"

# --- Function to download files with a user prompt and set permissions ---
download_file() {
    local file_path=$1
    local repo_url=$2
    local permissions=$3

    # Check if the file exists and prompt the user
    if [ -f "$file_path" ]; then
        read -p "File '$file_path' already exists. Overwrite? (y/n): " -n 1 -r
        echo # Move to a new line
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Skipping '$file_path'..."
            return 0
        fi
    fi

    # Download the file
    echo "Downloading $file_path..."
    if curl -s "$repo_url" -o "$file_path"; then
        echo "✓ Downloaded $file_path"
        # Set permissions immediately after a successful download
        if [ -n "$permissions" ]; then
            chmod "$permissions" "$file_path" 2>/dev/null || true
            echo "✓ Set permissions to $permissions for $file_path"
        fi
    else
        echo "✗ Failed to download $file_path"
        return 1
    fi
}

# --- Script Execution ---
echo "Cloudflare Fail2ban Configuration Deployment"
echo "============================================="

# Create backup
echo "Creating backup..."
mkdir -p "$BACKUP_DIR"
cp -r /etc/fail2ban/jail.d/* "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/fail2ban/filter.d/* "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/fail2ban/action.d/* "$BACKUP_DIR/" 2>/dev/null || true
echo "✓ Backup created at: $BACKUP_DIR"

# Download files with prompt
echo -e "\nDownloading configuration files..."

# Action
# The third argument is the permission to set
download_file "/etc/fail2ban/action.d/cloudflare-zone.conf" "$REPO_BASE/action.d/cloudflare-zone.conf" "644"

# Custom site-specific filters
download_file "/etc/fail2ban/filter.d/et-wp-hard.conf" "$REPO_BASE/filter.d/et-wp-hard.conf" "644"
download_file "/etc/fail2ban/filter.d/et-wp-soft.conf" "$REPO_BASE/filter.d/et-wp-soft.conf" "644"
download_file "/etc/fail2ban/filter.d/et-wp-extra.conf" "$REPO_BASE/filter.d/et-wp-extra.conf" "644"
download_file "/etc/fail2ban/filter.d/rp-wp-hard.conf" "$REPO_BASE/filter.d/rp-wp-hard.conf" "644"
download_file "/etc/fail2ban/filter.d/rp-wp-soft.conf" "$REPO_BASE/filter.d/rp-wp-soft.conf" "644"
download_file "/etc/fail2ban/filter.d/rp-wp-extra.conf" "$REPO_BASE/filter.d/rp-wp-extra.conf" "644"

# Jails
download_file "/etc/fail2ban/jail.d/enfant.conf" "$REPO_BASE/jail.d/enfant.conf" "640"
download_file "/etc/fail2ban/jail.d/posidonia.conf" "$REPO_BASE/jail.d/posidonia.conf" "640"

echo -e "\n✓ Deployment complete!"
echo "⚠ Remember to update zone IDs and API tokens in jail files."
echo "⚠ Run 'fail2ban-client -d' to check syntax."
echo "⚠ Run 'fail2ban-client -d && service fail2ban restart' to check syntax and restart fail2ban."

# --- End of Script ---