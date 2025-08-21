#!/bin/bash
# deploy.sh - Clone repo and deploy Fail2Ban configs with summary
# Supports --dry-run, --debug, and --force

set -euo pipefail

# ===== Configuration =====
DEBUG=${DEBUG:-false}
DRY_RUN=false
FORCE=false

REPO_URL="${REPO_URL:-https://github.com/tingeka/fail2ban-rules.git}"
TMP_DIR="${TMP_DIR:-/tmp/fail2ban-rules}"
FAIL2BAN_ACTION_DIR="${FAIL2BAN_ACTION_DIR:-/etc/fail2ban/action.d}"
FAIL2BAN_FILTER_DIR="${FAIL2BAN_FILTER_DIR:-/etc/fail2ban/filter.d}"
FAIL2BAN_JAIL_DIR="${FAIL2BAN_JAIL_DIR:-/etc/fail2ban/jail.d}"

# Track updated files
UPDATED_FILES=()

# ===== Usage =====
usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--debug] [--force] [--help]

Options:
  --dry-run   Show actions without making changes
  --debug     Enable bash debug mode
  --force     Skip all confirmation prompts
  --help      Show this message
EOF
}

# ===== Parse arguments =====
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --debug) DEBUG=true ;;
            --force) FORCE=true ;;
            --help) usage; exit 0 ;;
            *) echo "Unknown option: $arg"; usage; exit 1 ;;
        esac
    done
    $DEBUG && set -x
}

# ===== Logging & helper =====
run_cmd() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    if $DRY_RUN; then
        echo "[$ts][DRY-RUN] $*"
    else
        echo "[$ts][RUN] $*"
        "$@"
    fi
}

confirm() {
    $FORCE && return 0
    read -r -p "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) true ;;
        *) false ;;
    esac
}

copy_conf() {
    local src="$1"
    local dst_dir="$2"
    local dst="$dst_dir/$(basename "$src")"

    [[ -f "$src" ]] || { echo "Missing file $src"; return; }

    if [[ -e "$dst" && $FORCE == false ]]; then
        confirm "Overwrite $dst?" || { echo "Skipping $dst"; return; }
    fi

    run_cmd cp -v "$src" "$dst"
    run_cmd chown root:root "$dst"
    run_cmd chmod 0644 "$dst"

    # Track updated file
    UPDATED_FILES+=("$dst")
}

deploy_directory() {
    local src_dir="$1"
    local dst_dir="$2"
    local desc="$3"

    if [[ ! -d "$src_dir" ]]; then
        echo "Directory $src_dir not found. Skipping $desc."
        return
    fi

    if confirm "Deploy $desc to $dst_dir?"; then
        for file in "$src_dir"/*.conf; do
            [[ -f "$file" ]] || continue
            copy_conf "$file" "$dst_dir"
        done
    else
        echo "Skipping $desc deployment."
    fi
}

cleanup_tmp() {
    if [[ -d "$TMP_DIR" ]]; then
        if $DRY_RUN; then
            echo "[DRY-RUN] Would remove temporary directory $TMP_DIR"
        else
            if confirm "Remove temporary directory $TMP_DIR?"; then
                run_cmd rm -rf "$TMP_DIR"
            else
                echo "Temporary directory retained at $TMP_DIR."
            fi
        fi
    fi
}

reload_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "fail2ban-client not found, skipping reload."
        return
    fi

    if (( ${#UPDATED_FILES[@]} > 0 )); then
        echo
        echo "Updated files:"
        for f in "${UPDATED_FILES[@]}"; do
            echo "  $f"
        done
        echo
        if confirm "Reload Fail2Ban to apply these changes?"; then
            run_cmd fail2ban-client reload
        else
            echo "Skipping Fail2Ban reload."
        fi
    else
        echo "No files were updated. Skipping Fail2Ban reload."
    fi
}

main() {
    parse_args "$@"

    # Clone repo
    if [[ -d "$TMP_DIR" ]]; then
        confirm "Temporary directory $TMP_DIR exists. Remove and continue?" && run_cmd rm -rf "$TMP_DIR"
    fi
    run_cmd git clone "$REPO_URL" "$TMP_DIR"

    # Deploy configs
    deploy_directory "$TMP_DIR/action.d" "$FAIL2BAN_ACTION_DIR" "Fail2Ban actions"
    deploy_directory "$TMP_DIR/filter.d" "$FAIL2BAN_FILTER_DIR" "Fail2Ban filters"
    deploy_directory "$TMP_DIR/jail.d" "$FAIL2BAN_JAIL_DIR" "Fail2Ban jails"

    # Reload Fail2Ban interactively
    reload_fail2ban

    # Cleanup
    cleanup_tmp

    echo "Deployment finished."
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
