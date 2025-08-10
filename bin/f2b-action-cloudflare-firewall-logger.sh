#!/bin/bash
# /usr/local/bin/f2b-action-cloudflare-logger.sh
#
# This script is a Fail2Ban action handler. Its purpose is to record 'ban' and
# 'unban' events for specific IP addresses into a local log file, organized by
# hostname and Fail2Ban jail. This log file can then be used by another
# script (like the merger script) to consolidate data and interact with the
# Cloudflare API.
#
# The script is designed to be called by Fail2Ban itself, which passes in
# a set of arguments like the action type (ban/unban), the jail name,
# and the IP address.

# --- Script Configuration and Error Handling ---

# Exit immediately if any command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# The 'pipefail' option causes a pipeline to return the exit status of the
# last command in the pipe that failed. These settings ensure script robustness.

set -euo pipefail

# Path to the script's own log file. All actions and errors are logged here
# to provide an audit trail of its operations.

LOGFILE="/var/log/fail2ban-cloudflare.log"  # Log file for this script.

# --- Utility Functions ---

# Prints a usage message to standard error and exits with a status of 1.
# This function is called if the script receives an incorrect number of arguments.
usage() {
    echo "Usage: $0 <ban|unban|start|stop> <jail> <domain> [ip] [timestamp]" >&2
    exit 1
}

# A simple logging function that prepends a timestamp and a prefix
# to every message before writing it to the specified LOGFILE.
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [cloudflare] $*" >> "$LOGFILE"
}

# --- Argument Parsing and Validation ---

# Check if at least 3 arguments are provided (action, jail, domain).
# Fail2Ban will always provide these. If they are missing, something is wrong.

if [[ $# -lt 3 ]]; then
    usage
fi

# Assign positional arguments to named variables for clarity.

action="$1"    # The action to perform (e.g., 'ban', 'unban', 'start', 'stop').
jail="$2"      # The name of the Fail2Ban jail (e.g., 'sshd', 'nginx-http-auth').
domain="$3"  # The domain being protected (e.g., 'example.com').

# Optional arguments with defaults. The `:-` syntax assigns a default value
# if the variable is unset or null.

ip="${4:-}"        # The IP address to ban/unban.
ts="${5:-0}"       # The timestamp of the ban event.

# --- Directory and File Path Setup ---

# This directory is where the per-domain and per-jail log files are stored.
# It's located under /run, which is a volatile directory, meaning its contents
# are cleared on system reboot. This is intentional, as the bans should be
# managed by Fail2Ban's state, and this script's files are just temporary logs.

dir="/run/fail2ban/cloudflare-firewall/${domain}"

# The specific log file for this jail within the domain.
# The format is '/run/fail2ban/cloudflare-firewall/<domain>/<jail_name>.log'.

file="${dir}/${jail}.log"

# --- Action Dispatcher ---

# A 'case' statement is used to execute different code blocks based on the
# value of the 'action' variable.

case "$action" in

    start)
        
        # This block runs when a Fail2Ban jail is started.
        # It ensures that the necessary directory structure exists.
        
        mkdir -p "$dir"

        # Set permissions for the directory: read/write/execute for owner (root),
        # read/execute for group, and no permissions for others.
        
        chmod 750 "$dir"
        chown root:root "$dir"

        # Ensure the specific jail log file exists. 'touch' creates an empty
        # file if it doesn't already exist.
        
        touch "$file"

        # Log the start event to the script's main log file.
        
        log "Starting jail '$jail' for $domain"
        
        # Echo a message to standard error. Fail2Ban's logging daemon
        # will capture this output and include it in its own logs,
        # providing visibility for the user.
        
        echo "Initialized jail '$jail' for $domain" >&2
        ;;

    stop)
        
        # This block runs when a Fail2Ban jail is stopped.
        # It cleans up the log files and directories created on start.
        
        # Remove the jail's specific log file. The '-f' flag prevents errors if it
        # doesn't exist.
        
        rm -f "$file"

        # If the hostname directory is now empty, remove it. The 'ls -A "$dir"'
        # checks if the directory contains any entries (including hidden ones).
        # The 'rmdir' command will fail if the directory is not empty,
        # which is the desired behavior.
        
        if [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir")" ]]; then
            rmdir "$dir"
        fi
        
        # Log the stop event to the script's main log file.
        
        log "Stopping jail '$jail' for $hostname"
        
        # Echo a message to standard error for Fail2Ban's logs.
        
        echo "Stopped jail '$jail' for $hostname" >&2
        ;;

    ban)
        # This block runs when Fail2Ban bans an IP address.

        # Ensure the log file exists before attempting to write to it.
        
        touch "$file"
        
        # Use a subshell and file descriptor 200 for locking.
        # 'flock -x 200' acquires an exclusive lock on the file. This is crucial
        # to prevent multiple simultaneous calls (e.g., from different jails)
        # from causing race conditions or corrupting the file.
        # The '200>>"$file"' part redirects file descriptor 200 to append
        # to the log file.
        
        (
            flock -x 200

            # Use 'sed' to remove any existing lines in the file that start
            # with the IP address. The '-i' flag edits the file in place.
            # This ensures that an IP address only has one entry in the log file,
            # representing the most recent ban event.
            
            sed -i "\|^$ip |d" "$file"
        
            # Append the new IP and timestamp to the log file.
            
            echo "$ip $ts" >> "$file"

        ) 200>>"$file"

        # Log the ban event to the script's main log file.
        
        log "Added $ip in jail '$jail' for $domain"

        # Log the ban event to standard error for Fail2Ban's logs.
        
        echo "Added $ip in jail '$jail' for $domain" >&2
        ;;

    unban)
        # This block runs when Fail2Ban unbans an IP address.

        # Ensure the log file exists.
        
        touch "$file"
        
        # Use the same file locking mechanism as the 'ban' action
        # to prevent race conditions.
        
        (
            flock -x 200

            # Use 'sed' to remove any lines in the file that start with the
            # IP address. This effectively "unbans" the IP in the local log.
            
            sed -i "\|^$ip |d" "$file"

        ) 200>>"$file"

        # Log the unban event to the script's main log file.
        
        log "Removed $ip from jail '$jail' for $domain"

        # Log the unban event to standard error for Fail2Ban's logs.

        echo "Removed $ip from jail '$jail' for $domain" >&2
        ;;

    *)
        # Default case for invalid action.
        # This handles scenarios where Fail2Ban passes an unexpected action string.
        
        echo "Invalid action: $action (must be 'ban', 'unban', 'start', or 'stop')" >&2
        exit 1
        ;;
esac

# Script exits with a status of 0, indicating successful execution.

exit 0